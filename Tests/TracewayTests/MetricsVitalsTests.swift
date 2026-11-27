import Foundation
import XCTest
@testable import Traceway

/// The platform side, driven by the test: draws, the main queue, the launch
/// check.
final class FakeVitalsHost: VitalsHost {
    var draws = 0
    var cancels = 0
    var main: [() -> Void] = []
    var launch: ((LaunchInfo) -> Void)?
    var debugger = false
    var installed = false

    func install(_ vitals: AppVitals) { installed = true }
    func uninstall() { installed = false }
    func requestDraw() { draws += 1 }
    func cancelDraw() { cancels += 1 }

    func postToMain(_ task: @escaping () -> Void) -> Bool {
        main.append(task)
        return true
    }

    func checkLaunch(_ result: @escaping (LaunchInfo) -> Void) { launch = result }
    func debuggerAttached() -> Bool { debugger }

    func runMain() {
        while !main.isEmpty { main.removeFirst()() }
    }
}

final class MetricsVitalsTests: XCTestCase {
    private var r: Recorded!
    private var host: FakeVitalsHost!
    private var vitals: AppVitals!
    private var screen: String? = "/cart"

    private var clock: Int64 { r.scheduler.nowMs }

    override func setUp() {
        super.setUp()
        r = makeRecorder()
        host = FakeVitalsHost()
        vitals = makeVitals()
    }

    override func tearDown() {
        vitals.stop()
        super.tearDown()
    }

    private func makeVitals(currentScreen: (() -> String?)? = nil, reportHangsWithDebugger: Bool = false) -> AppVitals {
        let scheduler = r.scheduler
        return AppVitals(
            recorder: r.recorder,
            currentScreen: currentScreen ?? { [unowned self] in self.screen },
            scheduler: scheduler,
            elapsedMs: { scheduler.nowMs },
            uptimeMs: { scheduler.nowMs },
            epochMs: { scheduler.nowMs },
            hangThresholdMs: 150,
            watchdogIntervalMs: 20,
            reportHangsWithDebugger: reportHangsWithDebugger
        )
    }

    func testTimeToInitialAndFullDisplayOfAPushedScreen() throws {
        vitals.start(host: host)
        XCTAssertTrue(host.installed)
        vitals.navigated("/users/:id", action: "push", timeMs: clock)
        XCTAssertEqual(host.draws, 1)
        r.scheduler.advance(250)
        vitals.drawn()
        r.scheduler.advance(750)
        vitals.fullyDisplayed()
        vitals.fullyDisplayed()
        // A return to a screen already built is not a display.
        vitals.navigated("/cart", action: "pop", timeMs: clock)
        vitals.drawn()
        vitals.stop()
        r.recorder.flush()
        let h = r.decoded.histograms
        XCTAssertEqual(Set(h.keys), ["app.screen.ttid|screen=/users/:id", "app.screen.ttfd|screen=/users/:id"])
        XCTAssertEqual(h["app.screen.ttid|screen=/users/:id"]?.sum, 250)
        XCTAssertEqual(h["app.screen.ttfd|screen=/users/:id"]?.sum, 1000)
    }

    func testANavigationReportedLateIsMeasuredFromWhenItBegan() {
        vitals.start(host: host)
        // viewDidAppear reports the screen after it began loading.
        vitals.navigated("/a", action: "push", timeMs: clock - 40)
        r.scheduler.advance(60)
        vitals.drawn()
        vitals.stop()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.histograms["app.screen.ttid|screen=/a"]?.sum, 100)
    }

    func testARouteNamesTheScreenItsTimesAreCountedUnder() {
        vitals.start(host: host)
        vitals.navigated("/OrderViewController", action: "push", timeMs: clock)
        vitals.routeNamed("/orders/{id}")
        r.scheduler.advance(80)
        vitals.drawn()
        vitals.frame(.slow)
        vitals.stop()
        r.recorder.flush()
        XCTAssertEqual(Set(r.decoded.histograms.keys), ["app.screen.ttid|screen=/orders/{id}"])
        XCTAssertEqual(r.decoded.sums["app.frames.slow|screen=/orders/{id}"], 1)
    }

    func testAScreenLeftForTheBackgroundIsNotDisplayedLater() {
        vitals.start(host: host)
        vitals.navigated("/a", action: "push", timeMs: clock)
        vitals.lifecycleChanged(foreground: false)
        XCTAssertEqual(host.cancels, 1)
        vitals.drawn()
        vitals.fullyDisplayed()
        vitals.navigated("/b", action: "push", timeMs: clock)
        XCTAssertEqual(host.draws, 1, "no draw is waited for in the background")
        r.recorder.flush()
        XCTAssertTrue(r.bodies.value.isEmpty)
    }

    func testFramesAreClassifiedAgainstTheDisplaysBudget() {
        let budget = FrameRules.budgetNs(refreshRate: 60)
        XCTAssertEqual(budget, 16_666_667)
        XCTAssertEqual(FrameRules.budgetNs(refreshRate: 120), 8_333_333)
        XCTAssertEqual(FrameRules.budgetNs(refreshRate: 0), budget, "implausible rates are 60 Hz")
        // The display link: frames start on vsync, one interval is on time.
        XCTAssertEqual(FrameRules.classify(intervalNs: 16_700_000, budgetNs: budget), .normal)
        XCTAssertEqual(FrameRules.classify(intervalNs: 33_300_000, budgetNs: budget), .slow)
        XCTAssertEqual(FrameRules.classify(intervalNs: 16_700_000, budgetNs: 8_333_333), .slow)
        XCTAssertEqual(FrameRules.classify(intervalNs: 700_000_000, budgetNs: budget), .frozen)
        XCTAssertEqual(FrameRules.classify(intervalNs: 750_000_000, budgetNs: budget), .frozen)
    }

    func testSlowAndFrozenFramesByScreen() {
        vitals.start(host: host)
        for kind in [FrameKind.normal, .slow, .slow, .frozen] { vitals.frame(kind) }
        vitals.navigated("/b", action: "pop", timeMs: clock)
        vitals.frame(.normal)
        vitals.framesPaused()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums, [
            "app.frames.slow.total|screen=/cart": 4,
            "app.frames.slow|screen=/cart": 2,
            "app.frames.frozen.total|screen=/cart": 4,
            "app.frames.frozen|screen=/cart": 1,
            "app.frames.slow.total|screen=/b": 1,
            "app.frames.frozen.total|screen=/b": 1,
        ])
    }

    func testFramesWithoutAScreenAndOnlyInTheForeground() {
        vitals = makeVitals(currentScreen: { nil })
        vitals.start(host: host)
        vitals.frame(.normal)
        vitals.lifecycleChanged(foreground: false)
        vitals.frame(.frozen)
        vitals.framesPaused()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums, ["app.frames.slow.total": 1, "app.frames.frozen.total": 1])
    }

    func testFramesAreHandedOverInBatches() {
        var batches: [[String]] = []
        var now: Int64 = 0
        let tally = FrameTally { screen, total, slow, frozen in
            batches.append([screen ?? "-", "\(total)", "\(slow)", "\(frozen)"])
        }
        tally.add(screen: "/a", kind: .slow, nowMs: now)
        now += 500
        tally.add(screen: "/a", kind: .normal, nowMs: now)
        XCTAssertTrue(batches.isEmpty)
        now += 500
        tally.add(screen: "/a", kind: .frozen, nowMs: now)
        XCTAssertEqual(batches, [["/a", "3", "1", "1"]])
        tally.add(screen: "/a", kind: .normal, nowMs: now)
        tally.add(screen: "/b", kind: .normal, nowMs: now)
        XCTAssertEqual(batches.last, ["/a", "1", "0", "0"])
        tally.flush()
        XCTAssertEqual(batches.last, ["/b", "1", "0", "0"])
        tally.flush()
        XCTAssertEqual(batches.count, 3)
    }

    func testABlockedMainThreadIsAHangOnlyInTheForeground() throws {
        vitals.start(host: host)
        host.runMain()
        r.scheduler.advance(20)
        // The main thread is busy for 300 ms: the probe posted now waits.
        r.scheduler.advance(300)
        host.runMain()
        r.scheduler.advance(20)
        host.runMain()
        vitals.lifecycleChanged(foreground: false)
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums["app.hang|screen=/cart"], 1)
        XCTAssertEqual(r.decoded.histograms["app.hang.duration|screen=/cart"]?.sum, 300)

        // In the background the main thread may be suspended: no watchdog runs.
        r.bodies.value = []
        r.scheduler.advance(300)
        host.runMain()
        r.scheduler.advance(300)
        host.runMain()
        r.recorder.flush()
        XCTAssertTrue(r.bodies.value.isEmpty)
        XCTAssertEqual(r.scheduler.pendingTimers, 0)
    }

    func testAShortDelayOrADebuggerIsNotAHang() {
        vitals.start(host: host)
        r.scheduler.advance(100)
        host.runMain()
        host.debugger = true
        r.scheduler.advance(20)
        r.scheduler.advance(500)
        host.runMain()
        r.recorder.flush()
        XCTAssertTrue(r.bodies.value.isEmpty)
    }

    func testReportHangsInDebugCountsHangsUnderADebugger() {
        vitals.stop()
        vitals = makeVitals(reportHangsWithDebugger: true)
        host.debugger = true
        vitals.start(host: host)
        host.runMain()
        r.scheduler.advance(20)
        r.scheduler.advance(500)
        host.runMain()
        r.recorder.flush()
        XCTAssertEqual(r.decoded.sums["app.hang|screen=/cart"], 1)
    }

    func testTheWatchdogPostsOneProbeAtATime() {
        var main: [() -> Void] = []
        let scheduler = ManualMetricsScheduler()
        var hangs: [Int64] = []
        let watchdog = HangWatchdog(
            clock: { scheduler.nowMs },
            postToMain: { main.append($0); return true },
            schedule: { delay, task in scheduler.schedule(afterMs: delay, task) },
            thresholdMs: 2000,
            intervalMs: 500,
            onHang: { hangs.append($0) }
        )
        watchdog.start()
        scheduler.advance(5000)
        XCTAssertEqual(main.count, 1)
        main.removeFirst()()
        XCTAssertEqual(hangs, [5000])
        watchdog.stop()
        watchdog.start()
        scheduler.advance(100)
        let stale = main.removeFirst()
        watchdog.stop()
        scheduler.advance(3000)
        stale()
        XCTAssertEqual(hangs.count, 1, "a probe of a stopped watchdog is ignored")
    }

    func testAColdStartRunsFromTheProcessStartToTheFirstFrame() throws {
        vitals.watchColdStart(sdkStartMs: clock - 200, processStartMs: clock - 1000)
        XCTAssertEqual(host.draws, 0, "nothing to wait for before start")
        vitals.start(host: host)
        XCTAssertEqual(host.draws, 1)
        host.launch?(LaunchInfo(foreground: true))
        r.scheduler.advance(500)
        vitals.drawn()
        vitals.drawn()
        r.recorder.flush()
        let start = try XCTUnwrap(r.decoded.histograms["app.start.duration|start_type=cold"])
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start.sum, 1500)
    }

    func testAColdStartMeasuresFromTheSdkWhenTheProcessStartIsImplausible() {
        XCTAssertEqual(AppVitals.coldStartOrigin(processStartMs: 1000, sdkStartMs: 5000), 1000)
        XCTAssertEqual(AppVitals.coldStartOrigin(processStartMs: 1000, sdkStartMs: 50_000), 50_000,
                       "long before the SDK: prewarmed, or started late")
        XCTAssertEqual(AppVitals.coldStartOrigin(processStartMs: 6000, sdkStartMs: 5000), 5000, "after the SDK")
        XCTAssertEqual(AppVitals.coldStartOrigin(processStartMs: nil, sdkStartMs: 5000), 5000,
                       "unknown, or the process was prewarmed")
        XCTAssertTrue(AppVitals.coldStartCounts(backgroundedBeforeFirstFrame: false, foreground: true))
        XCTAssertFalse(AppVitals.coldStartCounts(backgroundedBeforeFirstFrame: true, foreground: true))
        XCTAssertFalse(AppVitals.coldStartCounts(backgroundedBeforeFirstFrame: false, foreground: false))
        XCTAssertEqual(AppVitals.slowStartMs(startCold), 5000)
        XCTAssertEqual(AppVitals.slowStartMs(startWarm), 2000)
        XCTAssertEqual(AppVitals.slowStartMs(startHot), 1500)
    }

    func testAProcessLaunchedInTheBackgroundHasNoColdStartAndItsFirstReturnIsWarm() throws {
        vitals.start(host: host)
        vitals.watchColdStart(sdkStartMs: clock, processStartMs: clock - 100)
        host.launch?(LaunchInfo(foreground: false))
        vitals.drawn()
        r.scheduler.advance(5000)
        vitals.lifecycleChanged(foreground: true)
        XCTAssertEqual(host.draws, 2)
        r.scheduler.advance(400)
        vitals.drawn()
        r.recorder.flush()
        XCTAssertEqual(Set(r.decoded.histograms.keys), ["app.start.duration|start_type=warm"])
        XCTAssertEqual(r.decoded.histograms.values.first?.sum, 400)
    }

    func testLeavingBeforeTheFirstFrameIsNoColdStartButTheReturnIsHot() {
        vitals.start(host: host)
        vitals.watchColdStart(sdkStartMs: clock, processStartMs: clock - 100)
        host.launch?(LaunchInfo(foreground: true))
        vitals.lifecycleChanged(foreground: false)
        vitals.drawn()
        r.scheduler.advance(10_000)
        vitals.lifecycleChanged(foreground: true)
        r.scheduler.advance(120)
        vitals.drawn()
        r.recorder.flush()
        XCTAssertEqual(Set(r.decoded.histograms.keys), ["app.start.duration|start_type=hot"])
        XCTAssertEqual(r.decoded.histograms.values.first?.sum, 120)
    }

    func testAReturnThatReconnectsTheSceneIsWarmAndASlowOneIsReported() throws {
        vitals.start(host: host)
        vitals.lifecycleChanged(foreground: false)
        r.scheduler.advance(60_000)
        vitals.sceneConnected()
        r.scheduler.advance(1500)
        vitals.lifecycleChanged(foreground: true)
        r.scheduler.advance(1000)
        vitals.drawn()
        r.recorder.flush()
        let warm = try XCTUnwrap(r.decoded.histograms["app.start.duration|start_type=warm"])
        XCTAssertEqual(warm.sum, 2500)
        XCTAssertEqual(warm.exemplars.count, 1, "slow warm starts are worth opening")
    }

    func testBecomingActiveWithoutLeavingIsNotAStart() {
        vitals.start(host: host)
        // A launch posts no return, and a scene connecting in the foreground is not one.
        vitals.lifecycleChanged(foreground: true)
        vitals.sceneConnected()
        vitals.drawn()
        r.recorder.flush()
        XCTAssertTrue(r.bodies.value.isEmpty)
        XCTAssertEqual(host.draws, 0)
    }

    func testTheProcessStartAndTheDebuggerAreReadFromThePlatform() {
        XCTAssertEqual(AppVitals.tracerPid("Name:\tapp\nTracerPid:\t4242\nUid:\t0\n"), 4242)
        XCTAssertEqual(AppVitals.tracerPid("Name:\tapp\nTracerPid:\t0\n"), 0)
        XCTAssertEqual(AppVitals.tracerPid(""), 0)
        _ = AppVitals.debuggerAttached()
        #if canImport(Darwin)
        let start = AppVitals.processStartUnixMs()
        XCTAssertNotNil(start)
        if let start = start {
            XCTAssertLessThanOrEqual(start, Clock.nowMs())
            XCTAssertGreaterThan(start, Clock.nowMs() - 86_400_000, "this test process started today")
        }
        #endif
    }
}
