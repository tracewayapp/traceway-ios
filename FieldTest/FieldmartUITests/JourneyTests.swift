import Foundation
import XCTest
import FieldmartCore

/// The field-test driver: one test that plays the scenario `FM_SCENARIO`
/// on the app `FM_APP` (see `RunConfig`). Run it with
/// `xcodebuild test-without-building -only-testing:FieldmartUITests/JourneyTests/testRun`
/// and `TEST_RUNNER_FM_*` variables.
final class JourneyTests: XCTestCase {
    private var log: DriverLog?

    override func setUp() {
        super.setUp()
        // A missed tap is logged and the journey goes on: the run is judged
        // from driver.json afterwards, not by XCTest.
        continueAfterFailure = true
    }

    func testRun() throws {
        let config = RunConfig.fromEnvironment()
        // What the test runner was given, before anything can go wrong.
        let environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("FM_") }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let start = "testRun started \(Date())\nout \(config.out.path)\nbundle \(Bundle(for: JourneyTests.self).bundlePath)\n"
            + environment + "\n"
        try? FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        let wrote = FileManager.default.createFile(atPath: config.out.appendingPathComponent("driver-start.txt").path,
                                                   contents: Data(start.utf8))
        print("FMDRIVER \(start)wrote driver-start.txt: \(wrote)")
        let driver = JourneyDriver(config: config)
        log = driver.log
        do {
            try driver.run()
        } catch {
            let text = "driver error: \(error)\n"
            print("FMDRIVER " + text)
            FileManager.default.createFile(atPath: config.out.appendingPathComponent("driver-error.txt").path,
                                           contents: Data(text.utf8))
            throw error
        }
        print("FMDRIVER testRun finished")
    }

    override func record(_ issue: XCTIssue) {
        log?.write("xctest issue: \(issue.compactDescription)")
        super.record(issue)
    }
}

/// App launch time (`03-MEASUREMENT.md` §4, M-ST-1): `XCTApplicationLaunchMetric`
/// over `FM_ITERATIONS` launches of `FM_APP`. The app's own `FM_PROC_START`
/// and `FM_READY` markers for every launch land in `FM_OUT/markers.jsonl`.
final class StartupTests: XCTestCase {
    func testLaunch() throws {
        let config = RunConfig.fromEnvironment()
        try? FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        let app = XCUIApplication(bundleIdentifier: config.app)
        app.launchArguments = config.launchArguments(scenarioSettings: nil)
        let options = XCTMeasureOptions()
        options.iterationCount = max(1, config.iterations)
        var launches: [String] = []
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let start = FMClock.nowMs()
            app.launch()
            let end = FMClock.nowMs()
            launches.append("{\"launchStartEpochMs\":\(start),\"launchEndEpochMs\":\(end)}")
        }
        app.terminate()
        Out.write("[\n" + launches.joined(separator: ",\n") + "\n]\n", to: config.out.appendingPathComponent("launches.json"))
    }
}

/// XCUITest waits for the app to be idle before each event. With
/// `FM_QUIESCENCE=skip` that wait is replaced by nothing (private API of
/// the test runner only; the app is untouched). Off by default.
enum Quiescence {
    static func skip() -> String {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { return "quiescence: class not found" }
        var replaced: [String] = []
        let one = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
        if let method = class_getInstanceMethod(cls, one) {
            let block: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(block))
            replaced.append(NSStringFromSelector(one))
        }
        let two = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        if let method = class_getInstanceMethod(cls, two) {
            let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(block))
            replaced.append(NSStringFromSelector(two))
        }
        return replaced.isEmpty ? "quiescence: no method replaced" : "quiescence: skipped \(replaced.joined(separator: ", "))"
    }
}
