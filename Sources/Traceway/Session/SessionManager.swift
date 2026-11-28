import Foundation

struct SessionInfo: Equatable {
    let id: String
    let startedAtMs: Int64
}

/// One session per app run, ended after `inactivityMs` without user
/// activity or `maxDurationMs` in total. A restart or a return from the
/// background inside the inactivity window continues the same session. A
/// session the app was killed in, and not opened again inside the window,
/// is ended by the next start (`onStoredEnd`) before its successor starts,
/// unless it was ended already. Used on the client's queue; `queue` runs
/// its expiry check.
final class SessionManager {
    static let defaultInactivityMs: Int64 = 15 * 60 * 1000
    static let defaultMaxDurationMs: Int64 = 60 * 60 * 1000
    private static let storeKey = "session"

    let store: StateStore
    let inactivityMs: Int64
    let maxDurationMs: Int64
    private let onStart: (SessionInfo, Bool) -> Void
    private let onEnd: (SessionInfo, Int64) -> Void
    private let onStoredEnd: (SessionInfo, Int64) -> Void
    private let now: () -> Int64
    private let queue: DispatchQueue

    private(set) var current: SessionInfo?
    private var lastActivityMs: Int64 = 0
    /// When the app last left the foreground, after the last activity: the
    /// end of a session the app is not brought back to.
    private var leftMs: Int64?
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
        onEnd: @escaping (SessionInfo, Int64) -> Void,
        onStoredEnd: @escaping (SessionInfo, Int64) -> Void = { _, _ in }
    ) {
        self.store = store
        self.queue = queue
        self.inactivityMs = inactivityMs
        self.maxDurationMs = maxDurationMs
        self.now = now
        self.onStart = onStart
        self.onEnd = onEnd
        self.onStoredEnd = onStoredEnd
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

    /// `ended`: the session's end was reported, so a later start that finds
    /// it expired does not end it again. Inside the window it still goes on.
    func stop(ended: Bool = false) {
        timer?.cancel()
        timer = nil
        persist(ended: ended)
        current = nil
    }

    /// The app left the foreground: it may be killed there, so the session
    /// is saved with this time as its end.
    func paused() {
        guard current != nil else { return }
        leftMs = now()
        persist()
    }

    /// Saves the session as it is now.
    func save() { persist() }

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
        let endedAt = idle ? endOfActivity : nowMs
        current = nil
        store.set(SessionManager.storeKey, nil)
        onEnd(session, endedAt)
    }

    /// The last activity, or the app leaving the foreground after it.
    private var endOfActivity: Int64 { max(lastActivityMs, leftMs ?? lastActivityMs) }

    private func open() {
        let nowMs = now()
        var resumed: SessionInfo?
        if let stored = store.get(SessionManager.storeKey)?.object,
           let id = stored["id"]?.string,
           let startedAt = stored["startedAtMs"]?.int,
           let lastActivity = stored["lastActivityMs"]?.int {
            let session = SessionInfo(id: id, startedAtMs: Int64(startedAt))
            if nowMs - Int64(lastActivity) < inactivityMs, nowMs - Int64(startedAt) < maxDurationMs {
                resumed = session
                segmentIndex = stored["segmentIndex"]?.int ?? 0
            } else if stored["ended"]?.bool != true {
                // The app was killed in it and not opened again in time.
                let left = stored["leftMs"]?.int.map(Int64.init) ?? Int64(lastActivity)
                onStoredEnd(session, max(Int64(lastActivity), left))
            }
        }
        if resumed == nil { segmentIndex = 0 }
        let session = resumed ?? SessionInfo(id: Ids.uuidv4(), startedAtMs: nowMs)
        current = session
        lastActivityMs = nowMs
        leftMs = nil
        persist()
        onStart(session, resumed != nil)
    }

    private func persist(ended: Bool = false) {
        guard let session = current else { return }
        lastPersistMs = now()
        var record: [String: JSON] = [
            "id": .string(session.id),
            "startedAtMs": JSON(session.startedAtMs),
            "lastActivityMs": JSON(lastActivityMs),
            "segmentIndex": JSON(segmentIndex),
        ]
        if let left = leftMs, left > lastActivityMs { record["leftMs"] = JSON(left) }
        if ended { record["ended"] = .bool(true) }
        store.set(SessionManager.storeKey, .object(record))
    }
}
