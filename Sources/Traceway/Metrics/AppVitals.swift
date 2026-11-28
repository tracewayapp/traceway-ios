import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A start this slow counts the user as affected, the thresholds of the
/// Android SDK (Android vitals' "excessive" starts): cold 5 s, warm 2 s,
/// hot 1.5 s.
let slowColdStartMs = 5000.0
let slowWarmStartMs = 2000.0
let slowHotStartMs = 1500.0

/// A frame on screen this long is frozen (Android vitals, Sentry); between
/// the display's frame budget and this it is slow.
let frozenFrameNs: Int64 = 700_000_000

private let maxStartMs: Int64 = 120_000

/// A process the system started this long before the SDK (for a background
/// task, or the app starts the SDK late) measures from the SDK.
private let maxProcessToSdkMs: Int64 = 30_000

enum FrameKind {
    case normal, slow, frozen
}

enum FrameRules {
    /// The budget of one frame at `refreshRate` Hz; 60 Hz when the display
    /// reports something implausible.
    static func budgetNs(refreshRate: Double) -> Int64 {
        let rate = refreshRate >= 24 && refreshRate <= 500 ? refreshRate : 60
        return Int64((1e9 / rate).rounded())
    }

    /// A frame from the display link: `intervalNs` from its vsync to the
    /// next frame's. Frames start on vsync, so one budget is on time and
    /// two or more are slow; 700 ms or more is frozen.
    static func classify(intervalNs: Int64, budgetNs: Int64) -> FrameKind {
        if intervalNs >= frozenFrameNs { return .frozen }
        if intervalNs > budgetNs * 3 / 2 { return .slow }
        return .normal
    }
}

/// Counts frames by screen and hands them over in batches (a screen change,
/// a second, or `maxFrames`), so the recorder is not called for every
/// frame. Thread-safe.
final class FrameTally {
    private let emit: (_ screen: String?, _ total: Int, _ slow: Int, _ frozen: Int) -> Void
    private let batchMs: Int64
    private let maxFrames: Int
    private let lock = NSLock()
    private var screen: String?
    private var total = 0
    private var slow = 0
    private var frozen = 0
    private var startMs: Int64 = 0

    init(
        batchMs: Int64 = 1000,
        maxFrames: Int = 600,
        emit: @escaping (_ screen: String?, _ total: Int, _ slow: Int, _ frozen: Int) -> Void
    ) {
        self.batchMs = batchMs
        self.maxFrames = maxFrames
        self.emit = emit
    }

    func add(screen: String?, kind: FrameKind, nowMs: Int64) {
        lock.lock()
        var out: (String?, Int, Int, Int)?
        if total > 0 && screen != self.screen { out = takeLocked() }
        if total == 0 {
            self.screen = screen
            startMs = nowMs
        }
        total += 1
        switch kind {
        case .slow: slow += 1
        case .frozen: frozen += 1
        case .normal: break
        }
        if out == nil && (nowMs - startMs >= batchMs || total >= maxFrames) { out = takeLocked() }
        lock.unlock()
        if let out = out { emit(out.0, out.1, out.2, out.3) }
    }

    func flush() {
        lock.lock()
        let out = total > 0 ? takeLocked() : nil
        lock.unlock()
        if let out = out { emit(out.0, out.1, out.2, out.3) }
    }

    private func takeLocked() -> (String?, Int, Int, Int) {
        let batch = (screen, total, slow, frozen)
        total = 0
        slow = 0
        frozen = 0
        return batch
    }
}

/// Watches the main thread for hangs: every `intervalMs` a timer posts a
/// probe to the main thread, unless the last one has not run yet, and the
/// time the probe waited is how long the main thread could not respond.
/// Nothing spins: one block every half second, only while started.
///
/// With a `stallThresholdMs`, a tick that finds the probe still waiting
/// that long calls `onStall` on the timer's thread while the main thread is
/// still blocked (the `AppHang` capture takes its stack then), and the probe
/// calls `onRecovered` once it runs. Thread-safe.
final class HangWatchdog {
    private final class Probe {
        let postedAt: Int64
        let id: Int
        init(postedAt: Int64, id: Int) {
            self.postedAt = postedAt
            self.id = id
        }
    }

    /// A monotonic clock that stops while the device sleeps.
    private let clock: () -> Int64
    private let postToMain: (@escaping () -> Void) -> Bool
    private let schedule: (Int64, @escaping () -> Void) -> MetricsCancellable
    private let thresholdMs: Int64
    private let intervalMs: Int64
    /// True while a hang is not the app's (a debugger stopped it).
    private let excused: () -> Bool
    private let onHang: (_ blockedMs: Int64) -> Void
    private let stallThresholdMs: Int64?
    /// The probe `id` has waited `waitedMs` so far; the main thread is
    /// still blocked. Called at every tick until it runs.
    private let onStall: ((_ id: Int, _ waitedMs: Int64) -> Void)?
    /// Probe `id`, which waited `stallThresholdMs` or more, ran after
    /// `blockedMs`. On the main thread.
    private let onRecovered: ((_ id: Int, _ blockedMs: Int64) -> Void)?
    private let lock = NSLock()
    private var running = false
    private var timer: MetricsCancellable?
    private var probe: Probe?
    private var nextProbeId = 0

    init(
        clock: @escaping () -> Int64,
        postToMain: @escaping (@escaping () -> Void) -> Bool,
        schedule: @escaping (Int64, @escaping () -> Void) -> MetricsCancellable,
        thresholdMs: Int64,
        intervalMs: Int64,
        excused: @escaping () -> Bool = { false },
        stallThresholdMs: Int64? = nil,
        onStall: ((_ id: Int, _ waitedMs: Int64) -> Void)? = nil,
        onRecovered: ((_ id: Int, _ blockedMs: Int64) -> Void)? = nil,
        onHang: @escaping (_ blockedMs: Int64) -> Void
    ) {
        self.clock = clock
        self.postToMain = postToMain
        self.schedule = schedule
        self.thresholdMs = thresholdMs
        self.intervalMs = intervalMs
        self.excused = excused
        self.stallThresholdMs = stallThresholdMs
        self.onStall = onStall
        self.onRecovered = onRecovered
        self.onHang = onHang
    }

    func start() {
        lock.lock()
        let wasRunning = running
        running = true
        lock.unlock()
        if !wasRunning { tick() }
    }

    func stop() {
        lock.lock()
        running = false
        timer?.cancel()
        timer = nil
        probe = nil
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        var post: Probe?
        var stall: (id: Int, waitedMs: Int64)?
        if let pending = probe {
            if let threshold = stallThresholdMs {
                let waited = clock() - pending.postedAt
                if waited >= threshold { stall = (pending.id, waited) }
            }
        } else {
            nextProbeId = nextProbeId &+ 1
            post = Probe(postedAt: clock(), id: nextProbeId)
            probe = post
        }
        timer = schedule(intervalMs) { [weak self] in self?.tick() }
        lock.unlock()
        if let stall = stall, !excused() { onStall?(stall.id, stall.waitedMs) }
        guard let p = post else { return }
        if !postToMain({ [weak self] in self?.ran(p) }) {
            lock.lock()
            if probe === p { probe = nil }
            lock.unlock()
        }
    }

    private func ran(_ p: Probe) {
        let at = clock()
        lock.lock()
        guard probe === p else {
            lock.unlock()
            return
        }
        probe = nil
        let isRunning = running
        lock.unlock()
        guard isRunning else { return }
        let blocked = at - p.postedAt
        if blocked >= thresholdMs && !excused() { onHang(blocked) }
        if let threshold = stallThresholdMs, blocked >= threshold { onRecovered?(p.id, blocked) }
    }
}

/// What the platform says about how the process started.
struct LaunchInfo {
    /// The app was launched to show its UI, not for a background task.
    let foreground: Bool
}

/// The platform side of `AppVitals`: lifecycle, frames, the main thread.
protocol VitalsHost: AnyObject {
    /// Starts observing for `vitals`; on the main thread.
    func install(_ vitals: AppVitals)
    func uninstall()
    /// Calls `AppVitals.drawn` at the next frame drawn while the app is
    /// active.
    func requestDraw()
    func cancelDraw()
    func postToMain(_ task: @escaping () -> Void) -> Bool
    /// Calls back on the main thread, soon after the SDK started, with how
    /// the process was launched.
    func checkLaunch(_ result: @escaping (LaunchInfo) -> Void)
    func debuggerAttached() -> Bool
}

/// Measures what the dashboard charts as app performance, from the platform
/// alone, with the Android SDK's names and rules:
///
/// * cold start: from the process start (`kinfo_proc`; the SDK's start when
///   iOS prewarmed the process, or started it long before) to the first
///   frame drawn while the app is active, only when the process was
///   launched to show its UI; warm start: the first return to the
///   foreground of a process launched in the background, or one whose scene
///   had to be connected again; hot start: any other return from the
///   background, to its next frame;
/// * time to initial display of a screen: from the navigation (for a view
///   controller, when it began loading or appearing) to the first frame
///   after it; time to full display: until the app calls
///   `Traceway.reportFullyDisplayed()`;
/// * slow and frozen frames from the display link: slow over one and a half
///   frame budgets at the display's rate, frozen at 700 ms or more, only in
///   the foreground;
/// * hangs: the main thread did not respond for 2 s or more while the app
///   was in the foreground, not while a debugger is attached unless
///   `reportHangsInDebug` says so.
///
/// Thread-safe; the platform callbacks run on the main thread. The recorder
/// is never called under this class's lock.
final class AppVitals {
    private struct PendingStart {
        let type: String
        let originMs: Int64
    }

    private final class Visit {
        var screen: String
        let startMs: Int64
        var displayed = false
        var fullyDisplayed = false

        init(screen: String, startMs: Int64) {
            self.screen = screen
            self.startMs = startMs
        }
    }

    private let recorder: MetricsRecorder
    /// False when only the hang watchdog runs (`captureMetrics: false`,
    /// `captureAppHangs: true`): nothing reaches the recorder.
    let recordsMetrics: Bool
    /// The `AppHang` issues the watchdog's stalls become, when captured.
    let appHangs: AppHangMonitor?
    /// The screen being shown, normalized, for the frame and hang dimensions.
    private let currentScreen: () -> String?
    /// The clock of the process start and of every duration measured here.
    private let elapsedMs: () -> Int64
    /// The clock of the navigation times the client passes (Unix ms).
    private let epochMs: () -> Int64
    private let frameClock: () -> Int64
    private let lock = NSLock()
    private let tally: FrameTally
    /// Set at the end of `init`: its callbacks hold `self` weakly.
    private var watchdog: HangWatchdog?

    // Guarded by `lock`.
    private var host: VitalsHost?
    private var started = false
    private var foreground = true
    private var foregroundKnown = false
    private var backgrounded = false
    private var launchedInBackground = false
    private var firstFrameDone = false
    private var backgroundedBeforeFirstFrame = false
    private var pendingStart: PendingStart?
    private var visit: Visit?
    private var createdWhileBackground = false
    private var returnAtMs: Int64?
    /// The screen of the last navigation, for the frame and hang dimensions.
    private var screen: String?

    init(
        recorder: MetricsRecorder,
        currentScreen: @escaping () -> String?,
        scheduler: MetricsScheduler,
        elapsedMs: @escaping () -> Int64 = AppVitals.monotonicMs,
        uptimeMs: @escaping () -> Int64 = AppVitals.monotonicMs,
        epochMs: @escaping () -> Int64 = Clock.nowMs,
        hangThresholdMs: Int64 = 2000,
        watchdogIntervalMs: Int64 = 500,
        reportHangsWithDebugger: Bool = false,
        recordsMetrics: Bool = true,
        appHangs: AppHangMonitor? = nil
    ) {
        self.recorder = recorder
        self.recordsMetrics = recordsMetrics
        self.appHangs = appHangs
        self.currentScreen = currentScreen
        self.elapsedMs = elapsedMs
        self.epochMs = epochMs
        frameClock = uptimeMs
        let countsFrames = recordsMetrics
        tally = FrameTally { [weak recorder] screen, total, slow, frozen in
            guard countsFrames else { return }
            recorder?.frames(screen: screen, total: total, slow: slow, frozen: frozen)
        }
        watchdog = HangWatchdog(
            clock: uptimeMs,
            postToMain: { [weak self] task in self?.currentHost?.postToMain(task) ?? false },
            schedule: { delay, task in scheduler.schedule(afterMs: delay, task) },
            thresholdMs: hangThresholdMs,
            intervalMs: watchdogIntervalMs,
            excused: { [weak self] in !reportHangsWithDebugger && self?.currentHost?.debuggerAttached() == true },
            stallThresholdMs: appHangs?.thresholdMs,
            onStall: { [weak appHangs] id, waited in appHangs?.stalled(id: id, waitedMs: waited) },
            onRecovered: { [weak appHangs] id, blocked in appHangs?.recovered(id: id, blockedMs: blocked) },
            onHang: { [weak self] ms in
                guard let self = self, self.recordsMetrics else { return }
                self.recorder.hang(Double(ms), screen: self.lastScreen ?? self.currentScreen())
            }
        )
    }

    private var currentHost: VitalsHost? {
        lock.lock(); defer { lock.unlock() }
        return host
    }

    private var lastScreen: String? {
        lock.lock(); defer { lock.unlock() }
        return screen
    }

    /// Starts observing the app through `host` and the hang watchdog. Call
    /// as early as possible, after `watchColdStart`.
    func start(host newHost: VitalsHost?) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        host = newHost
        let coldStart = pendingStart?.type == startCold
        let isForeground = foreground
        lock.unlock()
        let screenNow = currentScreen()
        lock.lock()
        if screen == nil { screen = screenNow }
        lock.unlock()
        newHost?.install(self)
        if coldStart { awaitFirstFrame(newHost) }
        if isForeground { watchdog?.start() }
    }

    func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        let h = host
        lock.unlock()
        watchdog?.stop()
        // A hang under way when the SDK stops is never reported: it must
        // not come back as fatal at the next start.
        appHangs?.cancel()
        h?.uninstall()
        tally.flush()
    }

    // MARK: - App start

    /// Measures the cold start, when the process was launched for its UI,
    /// to the first frame. `sdkStartMs` and `processStartMs` are on the
    /// `elapsedMs` clock; `processStartMs` is nil when unknown or when iOS
    /// prewarmed the process.
    func watchColdStart(sdkStartMs: Int64, processStartMs: Int64?) {
        let origin = AppVitals.coldStartOrigin(processStartMs: processStartMs, sdkStartMs: sdkStartMs)
        lock.lock()
        guard !firstFrameDone, pendingStart == nil else {
            lock.unlock()
            return
        }
        pendingStart = PendingStart(type: startCold, originMs: origin)
        let h = started ? host : nil
        lock.unlock()
        if let h = h { awaitFirstFrame(h) }
    }

    private func awaitFirstFrame(_ h: VitalsHost?) {
        guard let h = h else { return }
        h.requestDraw()
        h.checkLaunch { [weak self] info in self?.launched(info) }
    }

    /// Launched for a background task (a fetch, a notification, a location
    /// update), the process has no cold start somebody waited for; its
    /// first return to the foreground is a warm start.
    func launched(_ info: LaunchInfo) {
        guard !info.foreground else { return }
        lock.lock()
        if pendingStart?.type == startCold { pendingStart = nil }
        backgrounded = true
        launchedInBackground = true
        let stopWatchdog = !foregroundKnown
        if stopWatchdog { foreground = false }
        lock.unlock()
        if stopWatchdog { stopWatchingHangs() }
    }

    /// The app is not in the foreground: hangs are not watched there. One
    /// under way is forgotten with its file, or the next start would report
    /// it as the hang the app died in; its probe never reports back.
    private func stopWatchingHangs() {
        watchdog?.stop()
        appHangs?.cancel()
    }

    /// A scene connected: in the background, the return it prepares
    /// rebuilds the UI (a warm start), measured from now.
    func sceneConnected() {
        lock.lock()
        if backgrounded {
            createdWhileBackground = true
            if returnAtMs == nil { returnAtMs = elapsedMs() }
        }
        lock.unlock()
    }

    /// The app entered the foreground (`true`) or the background.
    func lifecycleChanged(foreground isForeground: Bool) {
        lock.lock()
        foregroundKnown = true
        foreground = isForeground
        var request = false
        if !isForeground {
            if !firstFrameDone { backgroundedBeforeFirstFrame = true }
            // A start or a screen still loading when the user left is not displayed later.
            pendingStart = nil
            visit = nil
            backgrounded = true
        } else if backgrounded {
            let type = createdWhileBackground || launchedInBackground ? startWarm : startHot
            pendingStart = PendingStart(type: type, originMs: returnAtMs ?? elapsedMs())
            backgrounded = false
            createdWhileBackground = false
            launchedInBackground = false
            returnAtMs = nil
            request = true
        }
        let h = host
        let isStarted = started
        lock.unlock()
        if isForeground {
            if isStarted { watchdog?.start() }
            if request { h?.requestDraw() }
        } else {
            stopWatchingHangs()
            tally.flush()
            h?.cancelDraw()
        }
    }

    // MARK: - Screens

    /// A navigation to `screen` (normalized) that began at `timeMs` (Unix
    /// ms). Only a screen that is new (`push`, `replace`) is built and
    /// displayed; returning to one is not.
    func navigated(_ screen: String?, action: String, timeMs: Int64) {
        lock.lock()
        if let screen = screen { self.screen = screen }
        guard let screen = screen, action == "push" || action == "replace" else {
            if action != "remove" { visit = nil }
            lock.unlock()
            return
        }
        guard foreground else {
            visit = nil
            lock.unlock()
            return
        }
        let ago = max(0, epochMs() - timeMs)
        visit = Visit(screen: screen, startMs: elapsedMs() - ago)
        let h = host
        lock.unlock()
        h?.requestDraw()
    }

    /// The app named the current screen by its route template
    /// (`Traceway.setRoute`): its display times and frames are counted under
    /// it from now on.
    func routeNamed(_ route: String) {
        lock.lock()
        screen = route
        visit?.screen = route
        lock.unlock()
    }

    /// The current screen shows everything it loads.
    func fullyDisplayed() {
        lock.lock()
        guard let v = visit, !v.fullyDisplayed else {
            lock.unlock()
            return
        }
        v.fullyDisplayed = true
        let ms = elapsedMs() - v.startMs
        let name = v.screen
        lock.unlock()
        if recordsMetrics, ms >= 0 && ms <= maxStartMs { recorder.screenFullyDisplayed(name, ms: Double(ms)) }
    }

    /// The frame `VitalsHost.requestDraw` waited for is drawn.
    func drawn() {
        let at = elapsedMs()
        var start: (type: String, ms: Int64)?
        var displayed: (screen: String, ms: Int64)?
        lock.lock()
        if let p = pendingStart {
            pendingStart = nil
            let counts = p.type != startCold
                || AppVitals.coldStartCounts(backgroundedBeforeFirstFrame: backgroundedBeforeFirstFrame,
                                             foreground: foreground)
            let ms = at - p.originMs
            // A foreground transition and the first draw can share a millisecond.
            if counts && ms >= 0 && ms <= maxStartMs { start = (p.type, ms) }
        }
        firstFrameDone = true
        if let v = visit, !v.displayed {
            v.displayed = true
            let ms = at - v.startMs
            if ms >= 0 && ms <= maxStartMs { displayed = (v.screen, ms) }
        }
        lock.unlock()
        guard recordsMetrics else { return }
        if let start = start {
            recorder.appStart(Double(start.ms), type: start.type,
                              slow: Double(start.ms) >= AppVitals.slowStartMs(start.type))
        }
        if let displayed = displayed { recorder.screenDisplayed(displayed.screen, ms: Double(displayed.ms)) }
    }

    // MARK: - Frames

    /// One frame of the app on screen; any thread.
    func frame(_ kind: FrameKind) {
        lock.lock()
        let isForeground = foreground
        let name = screen
        lock.unlock()
        guard isForeground, recordsMetrics else { return }
        tally.add(screen: name, kind: kind, nowMs: frameClock())
    }

    /// The display link paused: what it counted is handed over now.
    func framesPaused() { tally.flush() }

    // MARK: - Rules and platform facts

    /// Where a cold start is measured from: the process start, unless it is
    /// unknown, after the SDK's or long before it.
    static func coldStartOrigin(processStartMs: Int64?, sdkStartMs: Int64) -> Int64 {
        if let process = processStartMs, process <= sdkStartMs, sdkStartMs - process < maxProcessToSdkMs {
            return process
        }
        return sdkStartMs
    }

    /// Whether a cold start whose first frame came now is one somebody
    /// waited for.
    static func coldStartCounts(backgroundedBeforeFirstFrame: Bool, foreground: Bool) -> Bool {
        !backgroundedBeforeFirstFrame && foreground
    }

    static func slowStartMs(_ type: String) -> Double {
        switch type {
        case startCold: return slowColdStartMs
        case startWarm: return slowWarmStartMs
        default: return slowHotStartMs
        }
    }

    /// A monotonic clock in milliseconds that stops while the device sleeps
    /// (`mach_absolute_time` on Apple platforms).
    static func monotonicMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// iOS 15 and later can launch an app's process ahead of time
    /// (`ActivePrewarm`), so the process start says nothing about when the
    /// user opened it.
    static var isPrewarmed: Bool {
        ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }

    /// When the process started, on the `monotonicMs` clock; nil when
    /// unknown or when the process was prewarmed.
    static func processStartMonotonicMs() -> Int64? {
        guard !isPrewarmed, let wall = processStartUnixMs() else { return nil }
        return monotonicMs() - max(0, Clock.nowMs() - wall)
    }

    /// When the kernel started the process (`kinfo_proc.p_starttime`), as
    /// Unix ms; nil where it cannot be read.
    static func processStartUnixMs() -> Int64? {
        #if canImport(Darwin)
        guard let info = processInfo() else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let ms = Int64(start.tv_sec) * 1000 + Int64(start.tv_usec) / 1000
        return ms > 0 ? ms : nil
        #else
        return nil
        #endif
    }

    /// Whether a debugger is attached to the process (`P_TRACED`; on Linux
    /// `TracerPid`).
    static func debuggerAttached() -> Bool {
        #if canImport(Darwin)
        guard let info = processInfo() else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
        #else
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return false }
        return tracerPid(status) != 0
        #endif
    }

    /// `TracerPid` of `/proc/self/status`; 0 when nothing traces the process.
    static func tracerPid(_ status: String) -> Int {
        for line in status.split(separator: "\n") where line.hasPrefix("TracerPid:") {
            return Int(line.dropFirst("TracerPid:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    #if canImport(Darwin)
    private static func processInfo() -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        return info
    }
    #endif
}
