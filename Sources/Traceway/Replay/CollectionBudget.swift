import Foundation

/// Bounds what replay uploads per session, as the browser SDK does: 50 MiB
/// and 10,000 events (rrweb events of the segments admitted). A streaming
/// capture that runs for hours stops uploading once a session has used its
/// budget; the counts are reported on the session's lifecycle events (its
/// start, the update sent when the app goes to the background or flushes,
/// and its end, also when the next start ends a session the app was killed
/// in).
///
/// Within that, the pictures the wireframe inlines get at most
/// `maxImageBytes` of encoded data per session; past it images stay
/// placeholders. The counts are kept with the session in the state store,
/// so a restart within the session goes on from them.
///
/// Thread-safe: segments are admitted on the client's queue, pictures on
/// the main thread.
final class CollectionBudget {
    let maxBytes: Int
    let maxEvents: Int
    let maxImageBytes: Int
    private let lock = NSLock()
    private var _store: StateStore?
    private var sessionId: String?
    private var bytes = 0
    private var events = 0
    private var dropped = 0
    private var imageBytes = 0
    private var loaded = false

    init(
        maxBytes: Int = 50 * 1024 * 1024,
        maxEvents: Int = 10_000,
        maxImageBytes: Int = 4 * 1024 * 1024,
        store: StateStore? = nil
    ) {
        self.maxBytes = maxBytes
        self.maxEvents = maxEvents
        self.maxImageBytes = maxImageBytes
        _store = store
    }

    var store: StateStore? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _store
        }
        set {
            lock.lock()
            _store = newValue
            loaded = false
            lock.unlock()
        }
    }

    /// Counts `bytes` and `count` events of a segment of `sessionId`, or
    /// refuses the segment when they do not fit any more.
    func admit(_ sessionId: String?, bytes: Int, events count: Int = 1) -> Bool {
        lock.lock(); defer { lock.unlock() }
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

    /// Makes `sessionId` the session pictures are counted for.
    func use(_ sessionId: String?) {
        lock.lock(); defer { lock.unlock() }
        switchTo(sessionId)
    }

    /// The session pictures are counted for now.
    var currentSession: String? {
        lock.lock(); defer { lock.unlock() }
        return sessionId
    }

    /// Counts a picture of `bytes` encoded bytes for the current session, or
    /// refuses it when the session's image allowance is used up.
    func admitImage(bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sessionId != nil, imageBytes + bytes <= maxImageBytes else { return false }
        imageBytes += bytes
        save()
        return true
    }

    /// Whether `sessionId` has uploaded any replay.
    func hasUploaded(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switchTo(sessionId)
        return events > 0
    }

    /// The counters of `sessionId`, as session events and health reports
    /// carry them.
    func snapshot(_ sessionId: String?) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        switchTo(sessionId)
        return [
            "traceway.collection.bytes": bytes,
            "traceway.collection.events": events,
            "traceway.collection.dropped": dropped,
            "traceway.collection.max_bytes": maxBytes,
            "traceway.collection.max_events": maxEvents,
            "traceway.replay.image_bytes": imageBytes,
        ]
    }

    private func switchTo(_ sessionId: String?) {
        if loaded, sessionId == self.sessionId { return }
        loaded = true
        self.sessionId = sessionId
        bytes = 0
        events = 0
        dropped = 0
        imageBytes = 0
        if let sessionId = sessionId, let saved = _store?.get("budget")?.object,
           saved["sessionId"]?.string == sessionId {
            bytes = max(0, saved["bytes"]?.int ?? 0)
            events = max(0, saved["events"]?.int ?? 0)
            dropped = max(0, saved["dropped"]?.int ?? 0)
            imageBytes = max(0, saved["imageBytes"]?.int ?? 0)
        }
    }

    private func save() {
        guard let sessionId = sessionId else { return }
        _store?.set("budget", [
            "sessionId": .string(sessionId),
            "bytes": JSON(bytes),
            "events": JSON(events),
            "dropped": JSON(dropped),
            "imageBytes": JSON(imageBytes),
        ])
    }
}
