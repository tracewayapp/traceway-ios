import Foundation

let metricAppStart = "app.start.duration"
let metricScreenTTID = "app.screen.ttid"
let metricScreenTTFD = "app.screen.ttfd"
let metricFramesSlow = "app.frames.slow"
let metricFramesFrozen = "app.frames.frozen"
let metricHang = "app.hang"
let metricHangDuration = "app.hang.duration"
let metricCrash = "app.crash"
let metricSession = "app.session"
let metricUser = "app.user"
let metricUserAffected = "app.user.affected"
let metricMemoryPeak = "app.memory.peak"
let metricRequestDuration = "app.request.duration"
let metricRequestBytes = "app.request.bytes"
let metricRequestFailed = "app.request.failed"

/// `start_type` of `app.start.duration`, as the server's catalog has them.
let startCold = "cold"
let startWarm = "warm"
let startHot = "hot"

/// Things that went wrong for a user, counted once per user and day. The
/// server accepts exactly these (`app.user.affected` in its catalog).
enum UserIssue: String, CaseIterable {
    case crash
    case hang
    case slowStart = "slow_start"
    case frozenFrames = "frozen_frames"
    case failedRequest = "failed_request"
}

/// The device facts the server keeps as dimensions. Nothing that identifies
/// a user or a device.
let metricResourceKeys = [
    "service.name",
    "service.version",
    "deployment.environment.name",
    "os.name",
    "os.major",
    "device.form_factor",
    "device.class",
    "traceway.sdk.name",
    "traceway.sdk.version",
]

/// The server refuses a larger body (`clientmetrics.MaxBodyBytes` is 64 KiB).
let maxMetricsBodyBytes = 60 * 1024
private let maxHosts = 20
private let maxCustomDimensions = 2
private let maxDimensionLength = 64
private let defaultUserKey = "metricsUser"
private let dayMs: Int64 = 86_400_000
private let maxEarly = 64

/// Rejections a second attempt would get too.
private let permanentStatuses: Set<Int> = [400, 401, 403, 413, 422]
private let reservedPrefixes = ["browser.", "app.", "traceway.", "custom."]

/// Turns measurements into device histograms and counters and uploads them
/// as one small OTLP payload per flush, like the browser, Flutter and
/// Android SDKs' `MetricsRecorder`. The detailed records of the same
/// measurements still go through the router, where their signal's mode
/// decides what leaves the device: aggregates always travel, records only
/// when asked for.
///
/// Every payload is stored before it is sent and forgotten once answered,
/// so one that failed, or whose process died first, is resent once: after
/// the next upload that works or on the next start. The server drops a
/// resend it already has by its batch id.
///
/// Thread-safe: every method may be called from any thread. The recorder's
/// own lock is never held while it calls `sessionId`, `installationId`,
/// `resource`, `store` or `send`; `send` runs on the scheduler's upload
/// queue.
final class MetricsRecorder {
    private struct Drained {
        let batch: MetricBatch?
        let rate: Double
        let dimensions: [(key: String, value: String)]
    }

    private let lock = NSCondition()
    private let sessionId: () -> String?
    private let installationId: () -> String
    private let resource: () -> [String: String]
    /// One blocking upload of a protobuf body: the HTTP status, 0 when no
    /// answer came.
    private let send: (Data) -> Int
    private let store: () -> StateStore
    private let scheduler: MetricsScheduler
    private let scopeName: String
    private let scopeVersion: String
    private let userKey: String

    /// Exposed for tests.
    let aggregator: MetricAggregator
    private let pending: PendingMetrics

    // Guarded by `lock`.
    private var settings: MetricsSettings?
    private var flushSeconds: Double
    /// Observations made before `start`, while there is no session, no
    /// settings from disk and no installation id yet: the cold start, an
    /// earlier run's crash. They are recorded once it starts.
    private var ready: Bool
    private var early: [() -> Void] = []
    private var hosts: Set<String> = []
    private var inFlight: Set<String> = []
    private var customKeys: [String] = []
    private var customValues: [String: String] = [:]
    private var timer: MetricsCancellable?
    private var running = false
    private var uploads = 0
    private var countedSession: String?
    private var lastSession: String?
    /// The sample rate the cells collected so far were recorded under: a
    /// payload states one rate.
    private var batchRate: Double
    private var userDay: (day: Int64, seen: [String])?

    init(
        settings: MetricsSettings?,
        sessionId: @escaping () -> String?,
        installationId: @escaping () -> String,
        resource: @escaping () -> [String: String],
        send: @escaping (Data) -> Int,
        store: @escaping () -> StateStore,
        scheduler: MetricsScheduler,
        scopeName: String = TracewaySDK.name,
        scopeVersion: String = TracewaySDK.version,
        dimensions: [String: String]? = nil,
        deferUntilStart: Bool = false,
        /// Where the state kept between runs belongs: payloads waiting for a
        /// resend and the users counted today are kept per destination, so a
        /// changed receiver is not sent another's numbers.
        storageScope: String = ""
    ) {
        self.settings = settings
        flushSeconds = settings?.flushSeconds ?? defaultMetricsFlushSeconds
        batchRate = settings?.sampleRate ?? 0
        self.sessionId = sessionId
        self.installationId = installationId
        self.resource = resource
        self.send = send
        self.store = store
        self.scheduler = scheduler
        self.scopeName = scopeName
        self.scopeVersion = scopeVersion
        ready = !deferUntilStart
        userKey = storageScope.isEmpty ? defaultUserKey : "\(defaultUserKey):\(storageScope)"
        let clock = scheduler
        aggregator = MetricAggregator(now: { clock.now() })
        pending = PendingMetrics(now: { clock.now() }, scope: storageScope)
        for (key, value) in (dimensions ?? [:]).sorted(by: { $0.key < $1.key }) { setDimension(key, value) }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return work()
    }

    private func now() -> Int64 { scheduler.now() }

    func start() {
        let observations: [() -> Void] = locked {
            ready = true
            running = true
            let taken = early
            early = []
            return taken
        }
        for observe in observations { observe() }
        schedule()
        resend()
        user(nil)
    }

    func stop() {
        locked {
            running = false
            timer?.cancel()
            timer = nil
        }
    }

    /// True when `observe` was kept for `start`.
    private func deferred(_ observe: @escaping () -> Void) -> Bool {
        locked {
            if ready { return false }
            if early.count < maxEarly { early.append(observe) }
            return true
        }
    }

    /// The settings changed: the flush interval may have, and the sample
    /// rate. What was recorded under the old rate is uploaded with it first,
    /// since the server weights a whole payload by the rate it states.
    /// `settings` is nil when metrics are off.
    func configure(_ newSettings: MetricsSettings?, flushSeconds seconds: Double? = nil) {
        let rate = newSettings?.sampleRate ?? 0
        var drained: Drained?
        let reschedule: Bool = locked {
            settings = newSettings
            flushSeconds = seconds ?? newSettings?.flushSeconds ?? flushSeconds
            if rate != batchRate {
                // Switched off means nothing more is sent, including what was measured.
                if rate > 0 { drained = drainLocked() } else { _ = aggregator.drain() }
                batchRate = rate
            }
            return running
        }
        if let drained = drained { upload(drained, final: false) }
        if reschedule { schedule() }
    }

    /// The session's sample rate when it records metrics, else 0.
    private func rate(_ session: String? = nil) -> Double {
        guard let settings = locked({ settings }) else { return 0 }
        var id = session
        if id == nil {
            let current = sessionId()
            id = locked {
                if let current = current { lastSession = current }
                return lastSession
            }
        }
        guard let session = id else { return 0 }
        return Ids.unitHash(session) < settings.sampleRate ? settings.sampleRate : 0
    }

    var active: Bool { rate() > 0 }

    private func exemplar(_ worthOpening: Bool) -> String? {
        guard worthOpening else { return nil }
        return sessionId() ?? locked { lastSession }
    }

    /// An app-defined dimension on every metric from now on; nil removes it.
    /// A third key is ignored.
    func setDimension(_ key: String, _ value: String?) {
        locked {
            guard let value = value else {
                if customValues.removeValue(forKey: key) != nil { customKeys.removeAll { $0 == key } }
                return
            }
            guard MetricsRecorder.isDimensionKey(key),
                  customValues[key] != nil || customKeys.count < maxCustomDimensions
            else { return }
            if customValues[key] == nil { customKeys.append(key) }
            customValues[key] = MetricsRecorder.clip(value)
        }
    }

    /// Counts this installation once per UTC day, and once per day for each
    /// thing that went wrong for it, so "users affected" is a ratio of two
    /// counters and no id leaves the device. Without storage that outlives
    /// the run nothing is counted: every start would count the user again.
    /// Sampled by installation, not by session, so a user with many sessions
    /// is not more likely to be counted.
    private func user(_ issue: UserIssue?) {
        guard let settings = locked({ settings }) else { return }
        let storage = store()
        guard storage.persistent, Ids.unitHash(installationId()) < settings.sampleRate else { return }
        let day = now() / dayMs
        let wanted = issue.map { [metricUser, $0.rawValue] } ?? [metricUser]
        locked {
            if let known = userDay, known.day == day, wanted.allSatisfy({ known.seen.contains($0) }) { return }
            var seen: [String] = []
            if let record = storage.get(userKey)?.object, let recorded = record["i"]?.array,
               record["d"]?.int.map(Int64.init) == day {
                seen = recorded.compactMap { $0.string }
            }
            let added = wanted.filter { !seen.contains($0) }
            seen += added
            if !added.isEmpty { storage.set(userKey, ["d": JSON(day), "i": JSON(seen)]) }
            userDay = (day, seen)
            for name in added {
                if name == metricUser {
                    aggregator.count(metricUser)
                } else {
                    aggregator.count(metricUserAffected, 1, dims: ["issue": name])
                }
            }
        }
    }

    func sessionStarted(_ id: String, resumed: Bool = false) {
        if deferred({ self.sessionStarted(id, resumed: resumed) }) { return }
        user(nil)
        let counts: Bool = locked {
            if countedSession == id { return false }
            if resumed {
                // An earlier run of the app counted it.
                countedSession = id
                return false
            }
            return true
        }
        guard counts, rate(id) > 0 else { return }
        locked {
            guard countedSession != id else { return }
            countedSession = id
            aggregator.count(metricSession)
        }
    }

    /// `type` is `startCold`, `startWarm` or `startHot`.
    func appStart(_ ms: Double, type: String, slow: Bool) {
        if deferred({ self.appStart(ms, type: type, slow: slow) }) { return }
        if slow { user(.slowStart) }
        guard active else { return }
        let session = exemplar(slow || ms > MetricsRecorder.exemplarStartMs(type))
        locked {
            aggregator.observe(metricAppStart, ms, dims: ["start_type": type], unit: "ms", exemplarSession: session)
        }
    }

    func screenDisplayed(_ screen: String, ms: Double) {
        if deferred({ self.screenDisplayed(screen, ms: ms) }) { return }
        guard active else { return }
        let session = exemplar(ms > 1000)
        locked {
            aggregator.observe(metricScreenTTID, ms, dims: ["screen": screen], unit: "ms", exemplarSession: session)
        }
    }

    func screenFullyDisplayed(_ screen: String, ms: Double) {
        if deferred({ self.screenFullyDisplayed(screen, ms: ms) }) { return }
        guard active else { return }
        let session = exemplar(ms > 2000)
        locked {
            aggregator.observe(metricScreenTTFD, ms, dims: ["screen": screen], unit: "ms", exemplarSession: session)
        }
    }

    func frames(screen: String?, total: Int, slow: Int, frozen: Int) {
        if frozen > 0 { user(.frozenFrames) }
        guard total > 0, active else { return }
        let dims: MetricDims = screen.map { ["screen": $0] } ?? [:]
        locked {
            aggregator.ratio(metricFramesSlow, part: Double(slow), total: Double(total), dims: dims)
            aggregator.ratio(metricFramesFrozen, part: Double(frozen), total: Double(total), dims: dims)
        }
    }

    func hang(_ ms: Double, screen: String?) {
        user(.hang)
        guard active else { return }
        let dims: MetricDims = screen.map { ["screen": $0] } ?? [:]
        let session = exemplar(true)
        locked {
            aggregator.count(metricHang, 1, dims: dims)
            aggregator.observe(metricHangDuration, ms, dims: dims, unit: "ms", exemplarSession: session)
        }
    }

    /// A crash: an uncaught `NSException` on its way out, or a signal crash
    /// of an earlier run reported at this start. For the first, call
    /// `flush(final: true)` right after and then flush the state store, so
    /// the count outlives the process.
    func crash() {
        if deferred({ self.crash() }) { return }
        user(.crash)
        guard active else { return }
        locked { aggregator.count(metricCrash) }
    }

    /// A finished HTTP request the SDK saw.
    func request(_ url: String, ms: Double, failed: Bool, responseBytes: Int64? = nil) {
        if deferred({ self.request(url, ms: ms, failed: failed, responseBytes: responseBytes) }) { return }
        if failed { user(.failedRequest) }
        guard active, let parsed = MetricsRecorder.hostOf(url) else { return }
        locked {
            var host = parsed
            if !hosts.contains(host) {
                if hosts.count >= maxHosts { host = overflowValue } else { hosts.insert(host) }
            }
            let dims: MetricDims = ["host": MetricsRecorder.clip(host)]
            aggregator.observe(metricRequestDuration, ms, dims: dims, unit: "ms")
            aggregator.ratio(metricRequestFailed, part: failed ? 1 : 0, total: 1, dims: dims)
            if let bytes = responseBytes, bytes >= 0 {
                aggregator.observe(metricRequestBytes, Double(bytes), dims: dims, unit: "By")
            }
        }
    }

    /// The most memory the process used, once per session.
    func memoryPeak(session: String, bytes: Int64) {
        if deferred({ self.memoryPeak(session: session, bytes: bytes) }) { return }
        guard bytes > 0, rate(session) > 0 else { return }
        locked { aggregator.observe(metricMemoryPeak, Double(bytes), unit: "By") }
    }

    /// An app-defined distribution, e.g. `checkout.duration`.
    func metric(_ name: String, _ value: Double, dims: [String: Any]? = nil) {
        guard MetricsRecorder.isCustomName(name), active else { return }
        locked { aggregator.observe(name, value, dims: MetricsRecorder.customDims(dims)) }
    }

    /// An app-defined counter.
    func count(_ name: String, _ n: Double = 1, dims: [String: Any]? = nil) {
        guard MetricsRecorder.isCustomName(name), active else { return }
        locked { aggregator.count(name, n, dims: MetricsRecorder.customDims(dims)) }
    }

    /// Uploads what was collected; the request itself runs on the upload
    /// queue. `final` when the process may end soon (going to the
    /// background, a crash): the payload is already in the state store when
    /// this returns, so flush the store after it.
    func flush(final: Bool = false) {
        let drained = locked { drainLocked() }
        upload(drained, final: final)
    }

    /// Waits up to `timeoutMs` for the uploads started so far. False when
    /// some are still running.
    @discardableResult
    func awaitUploads(timeoutMs: Int64) -> Bool {
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000)
        lock.lock(); defer { lock.unlock() }
        while uploads > 0 {
            if !lock.wait(until: deadline) { return uploads == 0 }
        }
        return true
    }

    private func drainLocked() -> Drained {
        Drained(
            batch: aggregator.drain(),
            rate: batchRate,
            dimensions: customKeys.compactMap { key in customValues[key].map { (key, $0) } }
        )
    }

    private func upload(_ drained: Drained, final: Bool) {
        guard let batch = drained.batch, drained.rate > 0, locked({ settings }) != nil else { return }
        sendBatch(batch, drained, resource(), final: final)
    }

    /// A payload over the server's body limit is sent as two; only a single
    /// cell that is too large is dropped.
    private func sendBatch(_ batch: MetricBatch, _ drained: Drained, _ all: [String: String], final: Bool) {
        let id = Ids.hex(Ids.randomBytes(16))
        var attributes: [String: MetricAttribute] = [
            "traceway.metrics": .string("aggregated"),
            "traceway.sample_rate": .double(drained.rate),
            attrSentAt: .int(now()),
            "traceway.batch_id": .string(id),
        ]
        for key in metricResourceKeys {
            if let value = all[key], !value.isEmpty { attributes[key] = .string(value) }
        }
        for (key, value) in drained.dimensions { attributes["custom.\(key)"] = .string(value) }
        let body = encodeMetrics(batch, resource: attributes, scopeName: scopeName, scopeVersion: scopeVersion)
        if body.count > maxMetricsBodyBytes {
            guard batch.cells >= 2 else { return }
            let half = (batch.cells + 1) / 2
            let cut = min(half, batch.histograms.count)
            sendBatch(MetricBatch(
                startMs: batch.startMs, endMs: batch.endMs,
                histograms: Array(batch.histograms[..<cut]), sums: Array(batch.sums[..<(half - cut)])
            ), drained, all, final: final)
            sendBatch(MetricBatch(
                startMs: batch.startMs, endMs: batch.endMs,
                histograms: Array(batch.histograms[cut...]), sums: Array(batch.sums[(half - cut)...])
            ), drained, all, final: final)
            return
        }
        // Stored before it is sent: the process may not live to see the answer.
        let storage = store()
        locked {
            inFlight.insert(id)
            pending.add(storage, id: id, body: body)
        }
        track { [self] in
            let status = attempt(body)
            let failed = status == 0 || status == 429 || status >= 500
            locked {
                inFlight.remove(id)
                if !failed { pending.remove(storage, id: id) }
            }
            if !final, !failed, !permanentStatuses.contains(status) { resend() }
        }
    }

    private func attempt(_ body: Data) -> Int { send(body) }

    /// The one retry of each waiting payload. It is forgotten before it is
    /// sent, whatever the answer will be.
    private func resend() {
        guard locked({ settings }) != nil else { return }
        let storage = store()
        let waiting = locked { pending.take(storage, skip: inFlight) }
        for entry in waiting {
            // A payload this run cannot read is dropped.
            guard let body = restampForRetry(entry.body, sentAtMs: now()) else { continue }
            track { [self] in _ = attempt(body) }
        }
    }

    /// Runs `upload` on the upload queue, counted for `awaitUploads`.
    private func track(_ upload: @escaping () -> Void) {
        locked { uploads += 1 }
        scheduler.io { [self] in
            upload()
            lock.lock()
            uploads -= 1
            lock.broadcast()
            lock.unlock()
        }
    }

    private func schedule() {
        locked {
            timer?.cancel()
            timer = nil
            guard running else { return }
            let delay = Int64((flushSeconds * 1000).rounded())
            timer = scheduler.schedule(afterMs: delay) { [weak self] in self?.onTimer() }
        }
    }

    private func onTimer() {
        guard locked({ running }) else { return }
        flush()
        schedule()
    }

    // MARK: - Names and values

    static func exemplarStartMs(_ type: String) -> Double { type == startCold ? 2000 : 1000 }

    /// `^[a-z][a-z0-9_.]{0,62}$`, not under a prefix the SDKs and the server
    /// keep for themselves.
    static func isCustomName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, first >= "a", first <= "z", scalars.count <= 63 else { return false }
        for c in scalars.dropFirst() where !((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == ".") {
            return false
        }
        return !reservedPrefixes.contains { name.hasPrefix($0) }
    }

    /// `^[a-z][a-z0-9_]{0,31}$`: it becomes the resource key `custom.<key>`.
    static func isDimensionKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard let first = scalars.first, first >= "a", first <= "z", scalars.count <= 32 else { return false }
        return scalars.dropFirst().allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_" }
    }

    static func clip(_ value: String) -> String {
        guard value.utf16.count > maxDimensionLength else { return value }
        return String(decoding: Array(value.utf16.prefix(maxDimensionLength)), as: UTF16.self)
    }

    /// At most two dimensions, by key order, values as text.
    static func customDims(_ dims: [String: Any]?) -> MetricDims {
        guard let dims = dims, !dims.isEmpty else { return [:] }
        var out: MetricDims = [:]
        for (key, value) in dims.sorted(by: { $0.key < $1.key }).prefix(maxCustomDimensions) {
            out[clip(key)] = clip("\(value)")
        }
        return out
    }

    /// The `host` dimension of `url`: its host, lowercase, with the port
    /// when it is not the scheme's default. Nil without a host.
    static func hostOf(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://"), schemeEnd.lowerBound > url.startIndex else { return nil }
        let scheme = url[..<schemeEnd.lowerBound].lowercased()
        var authority = url[schemeEnd.upperBound...]
        if let cut = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<cut]
        }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        let host: Substring
        var port: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[...close]
            let after = authority.index(after: close)
            if after < authority.endIndex, authority[after] == ":" { port = authority[authority.index(after: after)...] }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            port = authority[authority.index(after: colon)...]
        } else {
            host = authority
        }
        guard !host.isEmpty else { return nil }
        let lower = host.lowercased()
        let number = port.flatMap { Int($0) }
        let defaultPort = scheme == "https" ? 443 : 80
        if let number = number, number != defaultPort { return "\(lower):\(number)" }
        return lower
    }
}
