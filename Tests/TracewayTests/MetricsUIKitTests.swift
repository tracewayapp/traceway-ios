#if canImport(UIKit)
import UIKit
import XCTest
@testable import Traceway

/// The UIKit host of the vitals on the iOS Simulator: the display link, the
/// lifecycle notifications and the launch check of the test host app.
final class MetricsUIKitTests: XCTestCase {
    private var r: Recorded!
    private var vitals: AppVitals!
    private var host: UIKitVitalsHost!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard UIApplication.shared.applicationState != .background else {
            throw XCTSkip("the test host app is in the background: no frames")
        }
        r = makeRecorder()
        vitals = AppVitals(recorder: r.recorder, currentScreen: { "/test" }, scheduler: r.scheduler)
        host = UIKitVitalsHost()
        vitals.start(host: host)
    }

    override func tearDown() {
        vitals?.stop()
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntilActive() throws {
        let deadline = Date().addingTimeInterval(5)
        while UIApplication.shared.applicationState != .active, Date() < deadline { spin(0.05) }
        guard UIApplication.shared.applicationState == .active else {
            throw XCTSkip("the test host app is not active")
        }
    }

    func testTheDisplayLinkCountsFramesAndEndsADisplay() throws {
        try waitUntilActive()
        vitals.navigated("/OrdersViewController", action: "push", timeMs: Clock.nowMs() - 20)
        spin(0.5)
        vitals.stop()
        r.recorder.flush()
        let sums = r.decoded.sums
        XCTAssertGreaterThan(sums["app.frames.slow.total|screen=/OrdersViewController"] ?? 0, 5,
                             "half a second of frames at 60 Hz or more")
        let ttid = try XCTUnwrap(r.decoded.histograms["app.screen.ttid|screen=/OrdersViewController"])
        XCTAssertEqual(ttid.count, 1)
        XCTAssertGreaterThanOrEqual(ttid.sum, 20)
        XCTAssertLessThan(ttid.sum, 1000)
    }

    @MainActor
    func testAReturnFromTheBackgroundIsAHotStart() async throws {
        try waitUntilActive()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let returnedAt = AppVitals.monotonicMs()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let metric = "app.start.duration|start_type=hot"
        let deadline = Date().addingTimeInterval(5)
        repeat {
            // Let the display link draw, then inspect the exported measurement.
            try await Task.sleep(nanoseconds: 20_000_000)
            r.recorder.flush()
        } while r.decoded.histograms[metric] == nil && Date() < deadline
        let start = try XCTUnwrap(r.decoded.histograms[metric])
        XCTAssertEqual(start.count, 1)
        XCTAssertGreaterThanOrEqual(start.sum, 0)
        XCTAssertLessThanOrEqual(start.sum, Double(AppVitals.monotonicMs() - returnedAt))
    }

    func testTheTestHostWasLaunchedForItsUI() {
        XCTAssertTrue(UIKitVitalsHost.launchedForUI())
        let launched = expectation(description: "launch check")
        host.checkLaunch { info in
            XCTAssertTrue(info.foreground)
            launched.fulfill()
        }
        wait(for: [launched], timeout: 5)
    }

    func testTheMainQueueRunsTheWatchdogsProbes() {
        let ran = expectation(description: "probe")
        XCTAssertTrue(host.postToMain {
            XCTAssertTrue(Thread.isMainThread)
            ran.fulfill()
        })
        wait(for: [ran], timeout: 5)
    }

    func testAViewControllerKeepsWhenItBeganToLoad() {
        let controller = UIViewController()
        XCTAssertNil(controller.tracewayDisplayStartMs)
        controller.tracewayDisplayStartMs = 1234
        XCTAssertEqual(controller.tracewayDisplayStartMs, 1234)
        controller.tracewayDisplayStartMs = nil
        XCTAssertNil(controller.tracewayDisplayStartMs)
    }

    func testTheProcessStartIsBeforeNowAndTheFootprintIsRead() {
        let start = AppVitals.processStartMonotonicMs()
        XCTAssertNotNil(start)
        if let start = start { XCTAssertLessThanOrEqual(start, AppVitals.monotonicMs()) }
        XCTAssertGreaterThan(MemoryPeaks.readPeakBytes(), 1 << 20)
        XCTAssertNotNil(DeviceDimensions.collect()["device.class"])
    }
}
#endif
