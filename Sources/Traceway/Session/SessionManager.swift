import Foundation

struct SessionInfo: Equatable {
    let id: String
    let startedAtMs: Int64
}

/// One session per app run, ended after `inactivityMs` without user
/// activity or `maxDurationMs` in total. A restart or a return from the
/// background inside the inactivity window continues the same session. Used
/// on the client's queue; `queue` runs its expiry check.
final class SessionManager {
    static let defaultInactivityMs: Int64 = 15 * 60 * 1000
    static let defaultMaxDurationMs: Int64 = 60 * 60 * 1000
    private static let storeKey = "session"

    let store: StateStore
    let inactivityMs: Int64
    let maxDurationMs: Int64
    private let onStart: (SessionInfo, Bool) -> Void
    private let onEnd: (SessionInfo, Int64) -> Void
    private let now: () -> Int64
    private let queue: DispatchQueue

    private(set) var current: SessionInfo?
    private var lastActivityMs: Int64 = 0
    private var segmentIndex = 0
    private var lastPersistMs: Int64 = 0
    private var timer: DispatchSourceTimer?

    var currentId: String? { current?.id }

    init(
        store: StateStore,
        queue: DispatchQueue,
        inactivityMs: Int64 = SessionManager.defaultInactivityMs,
        maxDurationMs: Int64 = SessionManager.defaultMaxDurationMs,
        now: @escaping () -> Int64 = Clock.nowMs,
        onStart: @escaping (SessionInfo, Bool) -> Void,
        onEnd: @escaping (SessionInfo, Int64) -> Void
    ) {
        self.store = store
        self.queue = queue
        self.inactivityMs = inactivityMs
        self.maxDurationMs = maxDurationMs
        self.now = now
        self.onStart = onStart
        self.onEnd = onEnd
    }

    func start() {
        guard timer == nil else { return }
        open()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 30, repeating: 30)
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        persist()
        current = nil
    }

    /// Next index for a replay segment of this session.
    func nextSegmentIndex() -> Int {
        let index = segmentIndex
        segmentIndex += 1
        persist()
        return index
    }

    /// Notes user activity; an expired session is replaced first.
    func markActivity() {
        guard timer != nil else { return }
        check()
        if current == nil { open() }
        lastActivityMs = now()
        if lastActivityMs - lastPersistMs > 5000 { persist() }
    }

    /// Ends an expired session. The next activity starts its successor.
    func check() {
        guard let session = current else { return }
        let nowMs = now()
        let idle = nowMs - lastActivityMs >= inactivityMs
        let tooLong = nowMs - session.startedAtMs >= maxDurationMs
        guard idle || tooLong else { return }
        let endedAt = idle ? lastActivityMs : nowMs
        current = nil
        store.set(SessionManager.storeKey, nil)
        onEnd(session, endedAt)
    }

    private func open() {
        let nowMs = now()
        var resumed: SessionInfo?
        if let stored = store.get(SessionManager.storeKey)?.object,
           let id = stored["id"]?.string,
           let startedAt = stored["startedAtMs"]?.int,
           let lastActivity = stored["lastActivityMs"]?.int,
           nowMs - Int64(lastActivity) < inactivityMs,
           nowMs - Int64(startedAt) < maxDurationMs {
            resumed = SessionInfo(id: id, startedAtMs: Int64(startedAt))
            segmentIndex = stored["segmentIndex"]?.int ?? 0
        }
        if resumed == nil { segmentIndex = 0 }
        let session = resumed ?? SessionInfo(id: Ids.uuidv4(), startedAtMs: nowMs)
        current = session
        lastActivityMs = nowMs
        persist()
        onStart(session, resumed != nil)
    }

    private func persist() {
        guard let session = current else { return }
        lastPersistMs = now()
        store.set(SessionManager.storeKey, [
            "id": .string(session.id),
            "startedAtMs": JSON(session.startedAtMs),
            "lastActivityMs": JSON(lastActivityMs),
            "segmentIndex": JSON(segmentIndex),
        ])
    }
}
