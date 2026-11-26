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
                self._failedSegments += dropped.segments.count
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
            _failedSegments += batch.segments.count
            return nil
        }
        if batch.attempts > retryDelaysMs.count {
            _failedSegments += batch.segments.count
            return nil
        }
        return result.retryAfterMs.map { Int($0) } ?? retryDelaysMs[batch.attempts - 1]
    }
}

/// Bounds what replay uploads per session, as the browser SDK does: 50 MiB
/// and 10,000 segments. A streaming capture that runs for hours stops
/// uploading once a session has used its budget; the counts are reported on
/// the session's lifecycle events. Used on the client's queue.
final class CollectionBudget {
    let maxBytes: Int
    let maxEvents: Int
    var store: StateStore?
    private var sessionId: String?
    private var bytes = 0
    private var events = 0
    private var dropped = 0
    private var loaded = false

    init(maxBytes: Int = 50 * 1024 * 1024, maxEvents: Int = 10_000, store: StateStore? = nil) {
        self.maxBytes = maxBytes
        self.maxEvents = maxEvents
        self.store = store
    }

    func admit(_ sessionId: String?, bytes: Int, events count: Int = 1) -> Bool {
        switchTo(sessionId)
        if bytes + self.bytes > maxBytes || events + count > maxEvents {
            dropped += count
            save()
            return false
        }
        self.bytes += bytes
        events += count
        save()
        return true
    }

    /// Whether `sessionId` has uploaded any replay.
    func hasUploaded(_ sessionId: String) -> Bool {
        switchTo(sessionId)
        return events > 0
    }

    func snapshot(_ sessionId: String?) -> [String: Int] {
        switchTo(sessionId)
        return [
            "traceway.collection.bytes": bytes,
            "traceway.collection.events": events,
            "traceway.collection.dropped": dropped,
            "traceway.collection.max_bytes": maxBytes,
            "traceway.collection.max_events": maxEvents,
        ]
    }

    private func switchTo(_ sessionId: String?) {
        if loaded, sessionId == self.sessionId { return }
        loaded = true
        self.sessionId = sessionId
        bytes = 0
        events = 0
        dropped = 0
        if let sessionId = sessionId, let saved = store?.get("budget")?.object,
           saved["sessionId"]?.string == sessionId {
            bytes = max(0, saved["bytes"]?.int ?? 0)
            events = max(0, saved["events"]?.int ?? 0)
            dropped = max(0, saved["dropped"]?.int ?? 0)
        }
    }

    private func save() {
        guard let sessionId = sessionId else { return }
        store?.set("budget", [
            "sessionId": .string(sessionId),
            "bytes": JSON(bytes),
            "events": JSON(events),
            "dropped": JSON(dropped),
        ])
    }
}
