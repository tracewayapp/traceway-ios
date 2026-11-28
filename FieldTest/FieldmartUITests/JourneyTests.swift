import Foundation
import XCTest
import FieldmartCore

/// The field-test driver: one test that plays the scenario `FM_SCENARIO`
/// on the app `FM_APP` (see `RunConfig`). Run it with
/// `xcodebuild test-without-building -only-testing:FieldmartUITests/JourneyTests/testJourney`
/// and `TEST_RUNNER_FM_*` variables.
class JourneyTests: XCTestCase {
    private var log: DriverLog?

    override func setUp() {
        super.setUp()
        // A missed tap is logged and the journey goes on: the run is judged
        // from driver.json afterwards, not by XCTest.
        continueAfterFailure = true
    }

    /// Not `throws`: an error is written to `driver-error.txt` and recorded
    /// as an XCTest failure.
    func testJourney() {
        let config = RunConfig.fromEnvironment()
        XCTContext.runActivity(named: "FM driver start: out \(config.out.path), run \(config.run), "
            + "scenario \(config.scenario), app \(config.app)") { _ in }
        // What the test runner was given, before anything can go wrong.
        let environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("FM_") }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let start = "testJourney started \(Date())\nout \(config.out.path)\nbundle \(Bundle(for: JourneyTests.self).bundlePath)\n"
            + environment + "\n"
        try? FileManager.default.createDirectory(at: config.out, withIntermediateDirectories: true)
        let wrote = FileManager.default.createFile(atPath: config.out.appendingPathComponent("driver-start.txt").path,
                                                   contents: Data(start.utf8))
        print("FMDRIVER \(start)wrote driver-start.txt: \(wrote)")
        XCTContext.runActivity(named: "FM driver-start.txt written: \(wrote)") { _ in }
        let driver = JourneyDriver(config: config)
        log = driver.log
        do {
            try driver.run()
        } catch {
            let text = "driver error: \(error)\n"
            print("FMDRIVER " + text)
            FileManager.default.createFile(atPath: config.out.appendingPathComponent("driver-error.txt").path,
                                           contents: Data(text.utf8))
            XCTFail(text)
        }
        XCTContext.runActivity(named: "FM driver finished") { _ in }
        print("FMDRIVER testJourney finished")
    }

    override func record(_ issue: XCTIssue) {
        log?.write("xctest issue: \(issue.compactDescription)")
        super.record(issue)
    }
}

/// App launch time (`03-MEASUREMENT.md` §4, M-ST-1): `XCTApplicationLaunchMetric`
/// over `FM_ITERATIONS` launches of `FM_APP`. The app's own `FM_PROC_START`
/// and `FM_READY` markers for every launch land in `FM_OUT/markers.jsonl`.
class StartupTests: XCTestCase {
    func testLaunch() {
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

/// XCUITest waits for the app to be idle around each event, and a list
/// that is still decelerating after a fling counts as busy: in the first
/// smoke run every fling took 3–5 s and every run came out late. With
/// `FM_QUIESCENCE=skip` (the default) every "quiescence" method of the test
/// runner's application classes returns at once. This touches the UI test
/// runner only (private API of XCTest), never the app. What was replaced is
/// written to driver.log.
enum Quiescence {
    static func skip() -> String {
        var replaced: [String] = []
        for className in ["XCUIApplicationProcess", "XCUIApplicationImpl", "XCUIApplication"] {
            guard let cls = NSClassFromString(className) else { continue }
            var count: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &count) else { continue }
            defer { free(methods) }
            for index in 0..<Int(count) {
                let method = methods[index]
                let name = NSStringFromSelector(method_getName(method))
                guard name.lowercased().contains("quiescence") else { continue }
                let rawReturn = method_copyReturnType(method)
                let returnType = String(cString: rawReturn)
                free(rawReturn)
                let arguments = Int(method_getNumberOfArguments(method)) - 2
                guard let block = noOp(arguments: arguments, returnType: returnType) else {
                    replaced.append("\(className).\(name) kept (\(returnType), \(arguments) arguments)")
                    continue
                }
                method_setImplementation(method, imp_implementationWithBlock(block))
                replaced.append("\(className).\(name)")
            }
        }
        return replaced.isEmpty ? "quiescence: no method found" : "quiescence skipped: " + replaced.joined(separator: ", ")
    }

    /// A block that ignores its arguments and returns nothing (or YES).
    private static func noOp(arguments: Int, returnType: String) -> Any? {
        switch (arguments, returnType) {
        case (0, "v"):
            let block: @convention(block) (AnyObject) -> Void = { _ in }
            return block
        case (1, "v"):
            let block: @convention(block) (AnyObject, Int) -> Void = { _, _ in }
            return block
        case (2, "v"):
            let block: @convention(block) (AnyObject, Int, Int) -> Void = { _, _, _ in }
            return block
        case (0, "B"), (0, "c"):
            let block: @convention(block) (AnyObject) -> Bool = { _ in true }
            return block
        case (1, "B"), (1, "c"):
            let block: @convention(block) (AnyObject, Int) -> Bool = { _, _ in true }
            return block
        case (2, "B"), (2, "c"):
            let block: @convention(block) (AnyObject, Int, Int) -> Bool = { _, _, _ in true }
            return block
        default:
            return nil
        }
    }
}
