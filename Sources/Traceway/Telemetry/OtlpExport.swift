import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterHttp
import SwiftProtobuf

// Records leave the device through the official OTLP/HTTP exporters of
// opentelemetry-swift, which encode them as protobuf and gzip them. Their
// requests go through `OutboxHTTPClient`: a request that fails for a reason
// that may pass is written to the `Outbox` and sent again later, so
// telemetry survives being offline and app restarts.

/// Delays between the attempts of a live export, before a batch that keeps
/// failing goes to the outbox.
let liveRetryDelaysMs: [Int] = [200, 1000]

/// OTLP batches that could not be delivered, kept on disk as the request
/// bodies the exporters made and sent again later: after start, when the app
/// returns to the foreground, on the next failed export. Bounded in count
/// and age so an unreachable server cannot fill the device. One outbox per
/// set of destinations, in its own directory.
final class Outbox {
    static let maxBatches = 200
    static let maxAge: TimeInterval = 24 * 60 * 60
    static let maxBatchBytes = 4 * 1024 * 1024

    let directory: URL?
    /// By kind: `logs`, `traces`.
    let destinations: [String: OtlpDestination]
    private let transport: HTTPTransport
    private let queue = DispatchQueue(label: "app.traceway.outbox", qos: .utility)
    private var sequence = 0
    private var claimed = false
    private var timer: DispatchWorkItem?
    private var draining = false
    private var drainWaiters: [() -> Void] = []
    private var attempts = 0
    private var disposed = false

    /// Identifies where this outbox sends, credentials included: batches
    /// queued for other destinations are dropped, never sent here.
    let destinationKey: String

    init(directory: URL?, destinations: [String: OtlpDestination], transport: HTTPTransport) {
        self.directory = directory
        self.destinations = destinations
        self.transport = transport
        var parts: [String] = []
        for (kind, destination) in destinations.sorted(by: { $0.key < $1.key }) {
            parts.append(kind)
            parts.append(destination.key)
        }
        destinationKey = Ids.fingerprint64(JSON(parts).encoded())
    }

    func claim() {
        queue.sync {
            guard let dir = directory else { return }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                excludeFromBackup(dir)
                for name in try fm.contentsOfDirectory(atPath: dir.path) {
                    let url = dir.appendingPathComponent(name)
                    if name.hasSuffix(".tmp") {
                        // Left half written by a crash before its rename.
                        try? fm.removeItem(at: url)
                    } else if name.hasSuffix(".pb"), !name.hasPrefix(destinationKey + "-") {
                        try? fm.removeItem(at: url)
                    }
                }
                try Data(destinationKey.utf8).write(to: dir.appendingPathComponent("destination"), options: .atomic)
                claimed = true
            } catch {
                Log.debug("outbox unavailable: \(error)")
            }
        }
    }

    /// Queues one request body; returns false when it could not be stored.
    @discardableResult
    func add(kind: String, body: Data, gzipped: Bool) -> Bool {
        queue.sync {
            guard claimed, !disposed, let dir = directory, !body.isEmpty,
                  body.count <= Outbox.maxBatchBytes, destinations[kind] != nil
            else { return false }
            let micros = Int64(Date().timeIntervalSince1970 * 1_000_000)
            let name = "\(destinationKey)-\(String(format: "%020lld", micros))-\(sequence).\(kind)\(gzipped ? ".gz" : "").pb"
            sequence += 1
            let file = dir.appendingPathComponent(name)
            let tmp = dir.appendingPathComponent(name + ".tmp")
            do {
                try body.write(to: tmp)
                try FileManager.default.moveItem(at: tmp, to: file)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            prune()
            scheduleLocked(afterMs: backoffMs())
            return true
        }
    }

    /// Writes log records to disk as one OTLP request, encoded with the
    /// official adapter, before they are sent: an issue must survive the app
    /// dying right after it. The next drain sends them.
    @discardableResult
    func persist(logs records: [ReadableLogRecord]) -> Bool {
        guard !records.isEmpty else { return false }
        let request = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.with {
            $0.resourceLogs = LogRecordAdapter.toProtoResourceRecordLog(logRecordList: records)
        }
        guard let raw = try? request.serializedData() else { return false }
        if let compressed = Gzip.compress(raw) {
            return add(kind: "logs", body: compressed, gzipped: true)
        }
        return add(kind: "logs", body: raw, gzipped: false)
    }

    var pendingCount: Int {
        queue.sync { files().count }
    }

    func schedule(afterMs: Int) {
        queue.async { self.scheduleLocked(afterMs: afterMs) }
    }

    /// Sends what is queued; `completion` runs when this drain is over.
    func drain(completion: (() -> Void)? = nil) {
        queue.async {
            if let completion = completion { self.drainWaiters.append(completion) }
            self.drainLocked()
        }
    }

    /// Starts sending what is queued and returns once the first request has
    /// been handed to the network; never called on the outbox's queue.
    func drainNow() {
        queue.sync { self.drainLocked() }
    }

    func dispose() {
        queue.sync {
            disposed = true
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - On the outbox queue

    private func backoffMs() -> Int {
        min(300_000, 5000 * (1 << min(attempts, 6)))
    }

    private func scheduleLocked(afterMs delay: Int) {
        guard !disposed, directory != nil, timer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.timer = nil
            self.drainLocked()
        }
        timer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func files() -> [URL] {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names
            .filter { $0.hasPrefix(destinationKey + "-") && $0.hasSuffix(".pb") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    private func prune() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Outbox.maxAge)
        var keep: [URL] = []
        for file in files() {
            let modified = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            if let modified = modified, modified < cutoff {
                try? fm.removeItem(at: file)
            } else {
                keep.append(file)
            }
        }
        if keep.count > Outbox.maxBatches {
            for file in keep.prefix(keep.count - Outbox.maxBatches) {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func finishDrain() {
        draining = false
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter() }
    }

    private func drainLocked() {
        guard !draining else { return }
        guard claimed, !disposed else {
            finishDrain()
            return
        }
        draining = true
        prune()
        sendNext(files()[...])
    }

    private func sendNext(_ remaining: ArraySlice<URL>) {
        guard !disposed, let file = remaining.first else {
            attempts = 0
            finishDrain()
            return
        }
        let name = file.lastPathComponent
        let kind = name.contains(".traces.") ? "traces" : "logs"
        guard let body = try? Data(contentsOf: file), let destination = destinations[kind] else {
            try? FileManager.default.removeItem(at: file)
            sendNext(remaining.dropFirst())
            return
        }
        var headers = destination.headers
        headers["Content-Type"] = "application/x-protobuf"
        if name.contains(".gz.") { headers["Content-Encoding"] = "gzip" }
        transport.post(url: destination.url, headers: headers, body: body, timeout: 15) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                if result.isTransientFailure {
                    self.attempts += 1
                    self.finishDrain()
                    self.scheduleLocked(afterMs: self.backoffMs())
                    return
                }
                // Delivered, or rejected for good: either way it is done.
                try? FileManager.default.removeItem(at: file)
                self.sendNext(remaining.dropFirst())
            }
        }
    }
}

func excludeFromBackup(_ url: URL) {
    #if canImport(Darwin)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var target = url
    try? target.setResourceValues(values)
    #endif
}

/// The `HTTPClient` the official exporters send through. A request that
/// fails for a reason that may pass is tried again after `liveRetryDelaysMs`
/// and then queued in the outbox, which counts as delivered for the
/// exporter: the batch is durable and leaves later. A request the server
/// rejects for good is reported as a failure and dropped.
final class OutboxHTTPClient: HTTPClient, @unchecked Sendable {
    let kind: String
    let outbox: Outbox?
    let transport: HTTPTransport
    private let retryQueue = DispatchQueue(label: "app.traceway.export-retry", qos: .utility)

    init(kind: String, outbox: Outbox?, transport: HTTPTransport) {
        self.kind = kind
        self.outbox = outbox
        self.transport = transport
    }

    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        guard let url = request.url, let body = request.httpBody else {
            completion(.failure(ConfigurationError(description: "OTLP request without a URL or body")))
            return
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        let gzipped = headers.contains { $0.key.lowercased() == "content-encoding" && $0.value == "gzip" }
        attempt(url: url, headers: headers, body: body, gzipped: gzipped, retry: 0, completion: completion)
    }

    func send(request: URLRequest) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            send(request: request) { result in continuation.resume(with: result) }
        }
    }

    private func attempt(
        url: URL, headers: [String: String], body: Data, gzipped: Bool, retry: Int,
        completion: @escaping (Result<HTTPURLResponse, Error>) -> Void
    ) {
        transport.post(url: url, headers: headers, body: body, timeout: 15) { [self] result in
            if result.isSuccess {
                completion(Self.response(url, result.statusCode))
                return
            }
            guard result.isTransientFailure else {
                Log.debug("\(kind) export rejected (HTTP \(result.statusCode))")
                completion(.failure(ConfigurationError(description: "HTTP \(result.statusCode)")))
                return
            }
            if retry < liveRetryDelaysMs.count {
                retryQueue.asyncAfter(deadline: .now() + .milliseconds(liveRetryDelaysMs[retry])) {
                    self.attempt(url: url, headers: headers, body: body, gzipped: gzipped,
                                 retry: retry + 1, completion: completion)
                }
                return
            }
            if outbox?.add(kind: kind, body: body, gzipped: gzipped) == true {
                Log.debug("\(kind) export queued for later (HTTP \(result.statusCode))")
                completion(Self.response(url, 202))
            } else {
                completion(.failure(ConfigurationError(description: "HTTP \(result.statusCode)")))
            }
        }
    }

    private static func response(_ url: URL, _ status: Int) -> Result<HTTPURLResponse, Error> {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])
        else { return .failure(ConfigurationError(description: "no response for \(url)")) }
        return .success(response)
    }
}

func otlpConfiguration(_ destination: OtlpDestination) -> OtlpConfiguration {
    OtlpConfiguration(
        timeout: 20,
        compression: .gzip,
        headers: destination.headers.map { ($0.key, $0.value) }
    )
}

func makeLogExporter(_ destination: OtlpDestination, outbox: Outbox?, transport: HTTPTransport) -> LogRecordExporter {
    OtlpHttpLogExporter(
        endpoint: destination.url,
        config: otlpConfiguration(destination),
        httpClient: OutboxHTTPClient(kind: "logs", outbox: outbox, transport: transport),
        envVarHeaders: nil,
        requeueOnFailure: false
    )
}

func makeSpanExporter(_ destination: OtlpDestination, outbox: Outbox?, transport: HTTPTransport) -> SpanExporter {
    OtlpHttpTraceExporter(
        endpoint: destination.url,
        config: otlpConfiguration(destination),
        httpClient: OutboxHTTPClient(kind: "traces", outbox: outbox, transport: transport),
        envVarHeaders: nil,
        requeueOnFailure: false
    )
}

/// Sends what `isTracewayLog` selects to `traceway`, everything else to
/// `inner`. Runs after the ring buffer, so a record flushed by a trigger is
/// routed the same as one streamed live.
final class RoutingLogExporter: LogRecordExporter, @unchecked Sendable {
    let inner: LogRecordExporter
    let traceway: LogRecordExporter

    init(inner: LogRecordExporter, traceway: LogRecordExporter) {
        self.inner = inner
        self.traceway = traceway
    }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        var own: [ReadableLogRecord] = []
        var rest: [ReadableLogRecord] = []
        for record in logRecords {
            if isTracewayLog(record.eventName) { own.append(record) } else { rest.append(record) }
        }
        var result = ExportResult.success
        if !own.isEmpty, traceway.export(logRecords: own, explicitTimeout: explicitTimeout) == .failure {
            result = .failure
        }
        if !rest.isEmpty, inner.export(logRecords: rest, explicitTimeout: explicitTimeout) == .failure {
            result = .failure
        }
        return result
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        _ = traceway.forceFlush(explicitTimeout: explicitTimeout)
        return inner.forceFlush(explicitTimeout: explicitTimeout)
    }

    func shutdown(explicitTimeout: TimeInterval?) {
        traceway.shutdown(explicitTimeout: explicitTimeout)
        inner.shutdown(explicitTimeout: explicitTimeout)
    }
}
