import Foundation
import XCTest
@testable import FieldmartCore

final class JourneyTests: XCTestCase {
    /// The example of `02-APP-SPEC.md` §5.1, plus one step of every other kind.
    static let sample = """
    {
      "version": 1,
      "viewport": { "width": 412, "height": 892 },
      "scenarios": {
        "S5-checkout": {
          "launch": "cold",
          "start": "home",
          "durationMs": 90000,
          "steps": [
            { "t": 0,     "do": "waitFor",    "id": "fm-home-grid", "timeoutMs": 15000 },
            { "t": 2000,  "do": "tap",        "id": "fm-nav-checkout" },
            { "t": 3500,  "do": "checkpoint", "name": "s5-form-empty", "shows": ["Contact", "Full name"], "hides": [] },
            { "t": 4000,  "do": "tap",        "id": "fm-checkout-name" },
            { "t": 4500,  "do": "type",       "text": "Ada Fieldtest", "perCharMs": 120 },
            { "t": 7000,  "do": "checkpoint", "name": "s5-name-typed", "shows": ["Contact"], "hides": ["Ada Fieldtest"],
              "masked": ["fm-checkout-name"] },
            { "t": 8000,  "do": "fling", "id": "fm-checkout-form", "dir": "up", "distance": 0.6, "durationMs": 250 },
            { "t": 9000,  "do": "drag", "id": "fm-checkout-tip", "from": [0.1, 0.5], "to": {"x": 0.5, "y": 0.5},
              "durationMs": 800 },
            { "t": 10000, "do": "pick", "id": "fm-checkout-country", "value": "Norway" },
            { "t": 11000, "do": "pick", "id": "fm-checkout-date", "value": 14 },
            { "t": 12000, "do": "paste", "text": "xyz" },
            { "t": 13000, "do": "key", "name": "back" },
            { "t": 14000, "do": "fault", "mode": "refuse", "seconds": 45 },
            { "t": 15000, "do": "wiggle", "id": "fm-nav-home" },
            { "t": 16000, "do": "idle", "ms": 2000, "extra": true }
          ]
        },
        "S6": { "durationMs": 300000, "steps": [ { "t": 0, "do": "waitFor", "id": "fm-home-grid" } ] }
      }
    }
    """

    func testSampleParses() throws {
        let journey = try Journey.load(Data(JourneyTests.sample.utf8))
        XCTAssertEqual(journey.version, 1)
        XCTAssertEqual(journey.viewport, Journey.Viewport(width: 412, height: 892))
        let (key, scenario) = try XCTUnwrap(journey.scenario(named: "S5"))
        XCTAssertEqual(key, "S5-checkout")
        XCTAssertEqual(scenario.durationMs, 90_000)
        XCTAssertEqual(scenario.steps.count, 15)
        XCTAssertEqual(scenario.steps[0].action, .waitFor)
        XCTAssertEqual(scenario.steps[0].timeoutMs, 15_000)
        XCTAssertEqual(scenario.checkpoints.map { $0.name }, ["s5-form-empty", "s5-name-typed"])
        XCTAssertEqual(scenario.steps[5].masked, ["fm-checkout-name"])
        XCTAssertEqual(scenario.steps[4].nominalDurationMs, 13 * 120)
        XCTAssertEqual(scenario.steps[6].dir, "up")
        XCTAssertEqual(scenario.steps[6].distance, 0.6)
        XCTAssertEqual(scenario.steps[7].from, FractionPoint(x: 0.1, y: 0.5))
        XCTAssertEqual(scenario.steps[7].to, FractionPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(scenario.steps[8].value, "Norway")
        XCTAssertEqual(scenario.steps[9].value, "14")
        XCTAssertEqual(scenario.steps[11].name, "back")
        XCTAssertEqual(scenario.steps[12].seconds, 45)
        XCTAssertEqual(scenario.steps[13].action, .other("wiggle"))
        XCTAssertEqual(scenario.steps[14].ms, 2000)
        XCTAssertEqual(journey.scenario(named: "S6")?.key, "S6")
        XCTAssertNil(journey.scenario(named: "S9"))
        XCTAssertTrue(journey.ids.contains("fm-checkout-name"))
    }

    func testTiming() {
        let timing = StepTiming(index: 3, action: "tap", dueEpochMs: 1000, startEpochMs: 2600, endEpochMs: 2700)
        XCTAssertEqual(timing.lateMs, 1600)
        XCTAssertTrue(timing.isLate)
        XCTAssertFalse(StepTiming(index: 0, action: "tap", dueEpochMs: 1000, startEpochMs: 900, endEpochMs: 950).isLate)
    }

    /// The shared journey (vendored into `FieldTest/shared/` by
    /// `tools/bin/sync-shared`): every scenario parses, steps are in time
    /// order, every checkpoint is named, and every id has the spec's form.
    func testSharedJourney() throws {
        let url = JourneyTests.sharedDirectory.appendingPathComponent("journey.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no shared/journey.json yet (run tools/bin/sync-shared)")
        }
        let journey = try Journey.load(Data(contentsOf: url))
        XCTAssertFalse(journey.scenarios.isEmpty)
        for name in ["S0", "S1", "S2", "S3", "S4", "S5", "S6", "S8"] {
            XCTAssertNotNil(journey.scenario(named: name), "scenario \(name)")
        }
        let idPattern = try NSRegularExpression(pattern: "^fm-[a-z0-9]+(-[A-Za-z0-9]+)*$")
        XCTAssertEqual(journey.lateMs, 1500)
        XCTAssertEqual(journey.rules?.revealMs, 900)
        // The S3 crosshair: a held drag, a checkpoint during it, then the release.
        let s3 = try XCTUnwrap(journey.scenario(named: "S3")?.scenario)
        let hold = try XCTUnwrap(s3.steps.firstIndex { $0.action == .drag && $0.hold == true })
        XCTAssertEqual(s3.steps[hold + 1].during, "drag")
        XCTAssertEqual(s3.steps[hold + 2].action, .release)
        XCTAssertEqual(s3.steps[hold].from, FractionPoint(x: 0.1, y: 0.5))
        let s5 = try XCTUnwrap(journey.scenario(named: "S5")?.scenario)
        XCTAssertEqual(s5.steps.first { $0.action == .type }?.into, "fm-checkout-name")
        XCTAssertEqual(s5.steps.first { $0.action == .pick && $0.id == "fm-checkout-date" }.flatMap { $0.value }
            .flatMap(Step.dayOffset), 14)
        XCTAssertTrue(s5.steps.contains { $0.reveal == true })
        XCTAssertFalse(try XCTUnwrap(journey.scenario(named: "S3-svg")?.scenario).exists(on: "ios"))
        XCTAssertEqual(try XCTUnwrap(journey.scenario(named: "S7a")?.scenario).variant, "buffer")
        let s7b = try XCTUnwrap(journey.scenario(named: "S7b")?.scenario)
        XCTAssertTrue(s7b.steps(on: "ios").contains { $0.action == .relaunch })
        XCTAssertFalse(s7b.steps(on: "web").contains { $0.action == .relaunch })
        XCTAssertEqual(try XCTUnwrap(journey.scenario(named: "S7i")?.scenario).settings?["fmRemote"], "1")
        for (key, scenario) in journey.scenarios {
            var last = -1
            for (index, step) in scenario.steps.enumerated() {
                XCTAssertGreaterThanOrEqual(step.t, last, "\(key) step \(index) out of order")
                last = step.t
                if step.action == .checkpoint { XCTAssertNotNil(step.name, "\(key) step \(index) has no name") }
                if case .other(let raw) = step.action { XCTFail("\(key) step \(index): unknown step kind \(raw)") }
                if let id = step.id {
                    let range = NSRange(id.startIndex..., in: id)
                    XCTAssertNotNil(idPattern.firstMatch(in: id, range: range), "\(key) step \(index): id \(id)")
                }
            }
            XCTAssertLessThanOrEqual(scenario.lastStepEndMs, scenario.durationMs, "\(key) ends after durationMs")
        }
        // ids.json lists every id the journey uses.
        let idsURL = JourneyTests.sharedDirectory.appendingPathComponent("ids.json")
        let ids = try JSONValue.parse(Data(contentsOf: idsURL))
        let listed = Set(ids.items("ids").compactMap { $0.string })
        XCTAssertEqual(listed.count, 157)
        XCTAssertTrue(Set(journey.ids).isSubset(of: listed), "\(Set(journey.ids).subtracting(listed))")
    }

    /// `FieldTest/shared/`, found from this file's path.
    static var sharedDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FieldmartCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // FieldmartCore
            .deletingLastPathComponent()  // FieldTest
            .appendingPathComponent("shared")
    }
}
