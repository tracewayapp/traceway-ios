import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// The ring buffer on disk, so an app the system killed in the background
/// still has its breadcrumbs when the same session goes on after a restart,
/// like the browser SDK's buffer survives a reload. Written when the app goes
/// to the background and on `flush()`, never on a timer. What a restart
/// restores is only uploaded by a trigger or capture, like the rest of the
/// buffer, and only within the same session.
final class BufferPersistence {
    let directory: URL?
    /// Where restored records would be sent. A file saved for other
    /// destinations is dropped.
    let destination: String
    private let writer = DispatchQueue(label: "app.traceway.buffer", qos: .utility)

    init(directory: URL?, destination: String) {
        self.directory = directory
        self.destination = destination
    }

    private var file: URL? { directory?.appendingPathComponent("buffer.json") }

    private struct Saved: Codable {
        var v: Int
        var sessionId: String
        var d: String
        /// Resources, saved once each; entries name theirs by index.
        var resources: [Resource]
        var entries: [Entry]
    }

    private struct Entry: Codable {
        var t: Int64
        var s: String
        var b: Int
        var r: Int
        var log: ReadableLogRecord?
        var span: SpanData?
    }

    /// The entries the last run saved for `sessionId`, within `maxAgeMs` and
    /// `maxBytes` (the newest win); anything else is dropped. The file is
    /// removed once read, so the records cannot be sent twice.
    func load(sessionId: String?, maxAgeMs: Int64, maxBytes: Int) -> [BufferEntry<TelemetryItem>] {
        guard let file = file else { return [] }
        defer { clear() }
        guard let sessionId = sessionId,
              let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.v == 1, saved.sessionId == sessionId, saved.d == destination
        else { return [] }
        let cutoff = Clock.nowMs() - maxAgeMs
        var entries: [BufferEntry<TelemetryItem>] = []
        for entry in saved.entries where entry.t >= cutoff {
            let resource = entry.r >= 0 && entry.r < saved.resources.count ? saved.resources[entry.r] : Resource()
            if let log = entry.log {
                let restored = ReadableLogRecord(
                    resource: resource,
                    instrumentationScopeInfo: log.instrumentationScopeInfo,
                    timestamp: log.timestamp,
                    observedTimestamp: log.observedTimestamp,
                    spanContext: log.spanContext,
                    severity: log.severity,
                    body: log.body,
                    attributes: log.attributes,
                    eventName: log.eventName
                )
                entries.append(BufferEntry(timeMs: entry.t, signal: entry.s, bytes: entry.b, item: TelemetryItem(.log(restored))))
            } else if var span = entry.span {
                span.settingResource(resource)
                entries.append(BufferEntry(timeMs: entry.t, signal: entry.s, bytes: entry.b, item: TelemetryItem(.span(span))))
            }
        }
        var bytes = 0
        var keepFrom = 0
        for index in stride(from: entries.count - 1, through: 0, by: -1) {
            bytes += entries[index].bytes
            if bytes > maxBytes {
                keepFrom = index + 1
                break
            }
        }
        return Array(entries[keepFrom...])
    }

    /// Writes `entries` for `sessionId`, replacing what was saved. Saves run
    /// one after the other.
    func save(sessionId: String?, entries: [BufferEntry<TelemetryItem>], completion: (() -> Void)? = nil) {
        guard let file = file, let directory = directory else {
            completion?()
            return
        }
        let destination = self.destination
        writer.async {
            defer { completion?() }
            guard let sessionId = sessionId, !entries.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            var resources: [Resource] = []
            var index: [Resource: Int] = [:]
            func resourceIndex(_ resource: Resource) -> Int {
                if let i = index[resource] { return i }
                resources.append(resource)
                index[resource] = resources.count - 1
                return resources.count - 1
            }
            let empty = Resource(attributes: [:])
            var saved: [Entry] = []
            for entry in entries {
                switch entry.item.record {
                case .log(let log):
                    let stripped = ReadableLogRecord(
                        resource: empty,
                        instrumentationScopeInfo: log.instrumentationScopeInfo,
                        timestamp: log.timestamp,
                        observedTimestamp: log.observedTimestamp,
                        spanContext: log.spanContext,
                        severity: log.severity,
                        body: log.body,
                        attributes: log.attributes,
                        eventName: log.eventName
                    )
                    saved.append(Entry(t: entry.timeMs, s: entry.signal, b: entry.bytes,
                                       r: resourceIndex(log.resource), log: stripped, span: nil))
                case .span(var span):
                    let r = resourceIndex(span.resource)
                    span.settingResource(empty)
                    saved.append(Entry(t: entry.timeMs, s: entry.signal, b: entry.bytes, r: r, log: nil, span: span))
                }
            }
            do {
                let data = try JSONEncoder().encode(Saved(
                    v: 1, sessionId: sessionId, d: destination, resources: resources, entries: saved
                ))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func clear() {
        guard let file = file else { return }
        writer.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Waits for saves in progress.
    func waitForWrites() {
        writer.sync {}
    }
}
