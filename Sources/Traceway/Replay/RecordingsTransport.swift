import Foundation

struct RecordingSegment {
    /// The `traceway.exception.id` of the exception this segment is a clip of.
    var exceptionId: String?
    var sessionId: String?
    var segmentIndex: Int?
    var events: [JSON]
    var startedAtMs: Int64?
    var endedAtMs: Int64?
    /// Size of the events as JSON when known.
    var approxBytes: Int?

    /// What the segment weighs in the upload queue.
    var bytes: Int { approxBytes ?? JSON.array(events).encoded().utf8.count }

    func toJSON() -> JSON {
        var out: [String: JSON] = ["events": .array(events)]
        if let v = exceptionId { out["exceptionId"] = .string(v) }
        if let v = sessionId { out["sessionId"] = .string(v) }
        if let v = segmentIndex { out["segmentIndex"] = JSON(v) }
        if let v = startedAtMs { out["startedAt"] = .string(ISO8601.format(millis: v)) }
        if let v = endedAtMs { out["endedAt"] = .string(ISO8601.format(millis: v)) }
        return .object(out)
    }
}

/// Sends replay clips to the dedicated, non-OpenTelemetry recordings
/// endpoint. Failed batches are retried a few times with growing delays and
/// then dropped, so a server that keeps rejecting them cannot grow memory;
/// what waits is bounded by `maxQueuedBytes` too, oldest first. Thread-safe.
final class RecordingsTransport {
    static let defaultRetryDelaysMs: [Int] = [5000, 30_000, 120_000]
    static let permanentFailures: Set<Int> = [400, 401, 403, 404, 413, 422]

    let url: URL?
    let token: String
    let maxQueuedBytes: Int
    private let transport: HTTPTransport
    private let retryDelaysMs: [Int]
    private let queue = DispatchQueue(label: "app.traceway.recordings", qos: .utility)

    private struct Batch {
        let segments: [RecordingSegment]
        let bytes: Int
        var attempts = 0
    }

    private var batches: [Batch] = []
    private var queuedBytes = 0
    private var timer: DispatchWorkItem?
    private var inFlight = false
    private var generation = 0
    private var idleWaiters: [() -> Void] = []
    private var _failedSegments = 0
    private var _sentSegments = 0
    /// Called on the transport's queue whenever segments are given up.
    var onFailure: (() -> Void)?

    init(
        url: URL?,
        token: String,
        transport: HTTPTransport,
        retryDelaysMs: [Int] = RecordingsTransport.defaultRetryDelaysMs,
        maxQueuedBytes: Int = 10 * 1024 * 1024
    ) {
        self.url = url
        self.token = token
        self.transport = transport
        self.retryDelaysMs = retryDelaysMs
        self.maxQueuedBytes = maxQueuedBytes
    }

    var failedSegments: Int { queue.sync { _failedSegments } }
    var sentSegments: Int { queue.sync { _sentSegments } }
    var pending: Int { queue.sync { batches.reduce(0) { $0 + $1.segments.count } } }

    func send(_ segments: [RecordingSegment]) {
        guard !segments.isEmpty, url != nil else { return }
        let bytes = segments.reduce(0) { $0 + $1.bytes }
        queue.async {
            self.batches.append(Batch(segments: segments, bytes: bytes))
            self.queuedBytes += bytes
            while self.queuedBytes > self.maxQueuedBytes, self.batches.count > 1 {
                let dropped = self.batches.removeFirst()
                self.queuedBytes -= dropped.bytes
                self.failed(dropped.segments.count)
            }
            self.schedule(afterMs: 0)
        }
    }

    func discard() {
        queue.async {
            self.generation += 1
            self.batches = []
            self.queuedBytes = 0
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Sends what is queued now; `completion` runs once the queue is empty
    /// or waiting to retry.
    func flush(_ completion: @escaping () -> Void) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.idleWaiters.append(completion)
            self.drain()
        }
    }

    // MARK: - On the transport queue

    private func schedule(afterMs delay: Int) {
        guard timer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.timer = nil
            self?.drain()
        }
        timer = work
        queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func becameIdle() {
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter() }
    }

    private func drain() {
        guard !inFlight else { return }
        guard !batches.isEmpty, let url = url else {
            becameIdle()
            return
        }
        var batch = batches.removeFirst()
        queuedBytes -= batch.bytes
        batch.attempts += 1
        inFlight = true
        let generation = self.generation
        let json = JSON.object(["segments": .array(batch.segments.map { $0.toJSON() })]).encodedData()
        var headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(token)",
        ]
        var body = json
        if let compressed = Gzip.compress(json) {
            body = compressed
            headers["Content-Encoding"] = "gzip"
        }
        let sent = batch
        transport.post(url: url, headers: headers, body: body, timeout: 30) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                self.inFlight = false
                if generation == self.generation, let retryMs = self.outcome(sent, result) {
                    self.batches.insert(sent, at: 0)
                    self.queuedBytes += sent.bytes
                    self.becameIdle()
                    self.schedule(afterMs: retryMs)
                    return
                }
                self.drain()
            }
        }
    }

    /// Nil when the batch is done (sent or given up), else the delay before
    /// it is tried again.
    private func outcome(_ batch: Batch, _ result: HTTPResult) -> Int? {
        if result.isSuccess {
            _sentSegments += batch.segments.count
            return nil
        }
        if RecordingsTransport.permanentFailures.contains(result.statusCode) {
            failed(batch.segments.count)
            return nil
        }
        if batch.attempts > retryDelaysMs.count {
            failed(batch.segments.count)
            return nil
        }
        return result.retryAfterMs.map { Int($0) } ?? retryDelaysMs[batch.attempts - 1]
    }

    private func failed(_ count: Int) {
        _failedSegments += count
        onFailure?()
    }
}
