import XCTest
@testable import Traceway

/// Ported from the Flutter SDK's core and sequence-trigger tests, which port
/// the browser SDK's, so all three engines are held to the same behaviour.
final class TriggerEngineTests: XCTestCase {
    private func event(_ timeMs: Int64, _ name: String) -> ObservedEvent {
        observed(timeMs, ["event.name": .string(name)])
    }

    private func parseTrigger(_ json: JSON) -> Trigger {
        let id = json["id"]!.string!
        return applyOverlay(defaultSettings(), ["triggers": [json]]).triggers.first { $0.id == id }!
    }

    private func named(_ name: String) -> JSON {
        ["key": "event.name", "op": "eq", "value": .string(name)]
    }

    private func run(_ steps: [JSON], _ events: [(Int64, String)]) -> [Int] {
        let engine = TriggerEngine()
        engine.setTriggers([parseTrigger([
            "id": "t",
            "steps": .array(steps),
            "actions": [["type": "emit", "eventName": "x"]],
        ])])
        return events.map { engine.observe(event($0.0, $0.1)).count }
    }

    private var journey: Trigger { parseTrigger(journeyTriggerJSON) }

    private func roundTrip(_ value: JSON) -> JSON {
        try! JSON.parse(value.encoded())
    }

    // MARK: core

    func testDefaultTriggerFiresOnExceptionsWithCooldownAndCap() {
        var trigger = defaultExceptionTrigger()
        trigger.maxPerSession = 2
        let engine = TriggerEngine()
        engine.setTriggers([trigger])
        XCTAssertTrue(engine.observe(event(0, "other")).isEmpty)
        XCTAssertEqual(engine.observe(event(1000, "exception")).count, 1)
        XCTAssertTrue(engine.skipped.isEmpty)
        XCTAssertTrue(engine.observe(event(2000, "exception")).isEmpty)
        XCTAssertEqual(engine.skipped[defaultExceptionTriggerId], "cooldown")
        XCTAssertEqual(engine.observe(event(7000, "exception")).count, 1)
        XCTAssertTrue(engine.observe(event(20000, "exception")).isEmpty)
        XCTAssertEqual(engine.skipped[defaultExceptionTriggerId], "session_clip_limit")
        // Skips describe the last observe call only.
        _ = engine.observe(event(20001, "other"))
        XCTAssertTrue(engine.skipped.isEmpty)
        engine.resetSession()
        XCTAssertEqual(engine.observe(event(30000, "exception")).count, 1)
        XCTAssertNil(engine.skipped[defaultExceptionTriggerId])
    }

    func testMultiStepTriggerHonoursWithinSeconds() {
        let step = Matcher.condition(Condition(key: "event.name", op: "eq", value: "fail"))
        let engine = TriggerEngine()
        engine.setTriggers([Trigger(
            id: "t",
            steps: [TriggerStep(match: step), TriggerStep(match: step, withinSeconds: 60)],
            actions: [TriggerAction(type: "flush", lookbackSeconds: 60)]
        )])
        XCTAssertTrue(engine.observe(event(0, "fail")).isEmpty)
        XCTAssertTrue(engine.observe(event(120_000, "fail")).isEmpty)
        XCTAssertEqual(engine.observe(event(130_000, "fail")).count, 1)
    }

    func testCountedStepNeedsNHitsInsideThePeriod() {
        let engine = TriggerEngine()
        engine.setTriggers([Trigger(
            id: "t",
            steps: [TriggerStep(
                match: .condition(Condition(key: "event.name", op: "eq", value: "e")),
                count: 3,
                periodSeconds: 10
            )],
            actions: [TriggerAction(type: "flush", lookbackSeconds: 60)]
        )])
        XCTAssertTrue(engine.observe(event(0, "e")).isEmpty)
        XCTAssertTrue(engine.observe(event(20000, "e")).isEmpty)
        XCTAssertTrue(engine.observe(event(21000, "e")).isEmpty)
        XCTAssertEqual(engine.observe(event(22000, "e")).count, 1)
        // The count starts over after a fire.
        XCTAssertTrue(engine.observe(event(22001, "e")).isEmpty)
        XCTAssertTrue(engine.observe(event(22002, "e")).isEmpty)
        XCTAssertEqual(engine.observe(event(22003, "e")).count, 1)
    }

    func testSampleRateUsesTheInjectedRandom() {
        var trigger = defaultExceptionTrigger()
        trigger.sampleRate = 0.5
        let engine = TriggerEngine(random: { 0.9 })
        engine.setTriggers([trigger])
        XCTAssertTrue(engine.observe(event(0, "exception")).isEmpty)
        XCTAssertEqual(engine.skipped[defaultExceptionTriggerId], "sampled_out")
        let lucky = TriggerEngine(random: { 0.49 })
        lucky.setTriggers([trigger])
        XCTAssertEqual(lucky.observe(event(0, "exception")).count, 1)
        trigger.sampleRate = 0
        let never = TriggerEngine(random: { 0 })
        never.setTriggers([trigger])
        XCTAssertTrue(never.observe(event(0, "exception")).isEmpty)
    }

    func testSetTriggersDropsDisabledAndReportsNewOrChangedOnes() {
        let engine = TriggerEngine()
        var disabled = parseTrigger(["id": "off", "steps": [["match": named("a")]],
                                     "actions": [["type": "emit", "eventName": "x"]]])
        disabled.enabled = false
        let a = parseTrigger(["id": "a", "steps": [["match": named("a")], ["match": named("b")]],
                              "actions": [["type": "emit", "eventName": "x"]]])
        XCTAssertEqual(engine.setTriggers([disabled, a]), ["a"])
        XCTAssertEqual(engine.triggers.map(\.id), ["a"])
        _ = engine.observe(event(0, "a"))
        // Unchanged steps and actions: progress kept, nothing new, whatever
        // else changed.
        var renamed = a
        renamed.name = "renamed"
        renamed.cooldownSeconds = 9
        XCTAssertEqual(engine.setTriggers([renamed]), [])
        XCTAssertEqual(engine.observe(event(1, "b")).count, 1)
        _ = engine.observe(event(2, "a"))
        var changed = a
        changed.actions = [TriggerAction(type: "emit", eventName: "y")]
        XCTAssertEqual(engine.setTriggers([changed, defaultExceptionTrigger()]), ["a", defaultExceptionTriggerId])
        // A changed rule starts over.
        XCTAssertTrue(engine.observe(event(3, "b")).isEmpty)
    }

    func testAChangedTriggerKeepsItsFireCount() {
        let once = parseTrigger(["id": "once", "maxPerSession": 1, "steps": [["match": named("a")]],
                                 "actions": [["type": "emit", "eventName": "x"]]])
        let engine = TriggerEngine()
        engine.setTriggers([once])
        XCTAssertEqual(engine.observe(event(0, "a")).count, 1)
        var changed = once
        changed.actions = [TriggerAction(type: "emit", eventName: "y")]
        engine.setTriggers([changed])
        XCTAssertTrue(engine.observe(event(1, "a")).isEmpty)
        XCTAssertEqual(engine.skipped["once"], "session_clip_limit")
        // Removed and added back within the session: the session's limits
        // still apply.
        engine.setTriggers([])
        engine.setTriggers([once])
        XCTAssertTrue(engine.observe(event(2, "a")).isEmpty)
    }

    func testAFiredTriggerCarriesTheEventThatCompletedIt() {
        let engine = TriggerEngine()
        engine.setTriggers([defaultExceptionTrigger()])
        let cause = observed(5, ["event.name": "exception", "attributes.traceway.exception.id": "e1"])
        let fired = engine.observe(cause)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.trigger.id, defaultExceptionTriggerId)
        XCTAssertEqual(fired.first?.cause.timeMs, 5)
        XCTAssertEqual(fired.first?.cause.lookup("attributes.traceway.exception.id"), "e1")
    }

    func testCooldownIsMeasuredFromTheLastFireNotTheLastAttempt() {
        let engine = TriggerEngine()
        engine.setTriggers([defaultExceptionTrigger()])
        XCTAssertEqual(engine.observe(event(0, "exception")).count, 1)
        XCTAssertTrue(engine.observe(event(4000, "exception")).isEmpty)
        XCTAssertEqual(engine.observe(event(5000, "exception")).count, 1)
    }

    func testACountedStepWithoutAPeriodCountsEveryHit() {
        let engine = TriggerEngine()
        engine.setTriggers([parseTrigger([
            "id": "t",
            "steps": [["match": named("e"), "count": 2]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])])
        XCTAssertTrue(engine.observe(event(0, "e")).isEmpty)
        XCTAssertEqual(engine.observe(event(80_000_000, "e")).count, 1)
    }

    func testASampledOutFireDoesNotCountTowardsTheLimits() {
        var roll = 0.9
        var trigger = defaultExceptionTrigger()
        trigger.sampleRate = 0.5
        let engine = TriggerEngine(random: { roll })
        engine.setTriggers([trigger])
        XCTAssertTrue(engine.observe(event(0, "exception")).isEmpty)
        XCTAssertEqual(engine.snapshotSessionLimits(), [:])
        roll = 0.1
        XCTAssertEqual(engine.observe(event(1, "exception")).count, 1)
        XCTAssertEqual(engine.snapshotSessionLimits(), [defaultExceptionTriggerId: ["fires": 1, "lastFireMs": 1]])
    }

    func testDisabledAndEmptyTriggersAreLeftOut() {
        var disabled = defaultExceptionTrigger()
        disabled.enabled = false
        let emit = [TriggerAction(type: "emit", eventName: "x")]
        let exists = TriggerStep(match: .condition(Condition(key: "a", op: "exists")))
        let engine = TriggerEngine()
        let created = engine.setTriggers([
            disabled,
            Trigger(id: "no-steps", steps: [], actions: emit),
            Trigger(id: "no-actions", steps: [exists], actions: []),
            Trigger(id: "ok", steps: [exists], actions: emit),
        ])
        XCTAssertEqual(engine.triggers.map(\.id), ["ok"])
        XCTAssertEqual(created, ["ok"])
        XCTAssertTrue(engine.observe(event(0, "exception")).isEmpty)
    }

    func testProgressVersionChangesWithProgressAndWithSettings() {
        let engine = TriggerEngine()
        let v0 = engine.progressVersion
        engine.setTriggers([defaultExceptionTrigger()])
        let v1 = engine.progressVersion
        XCTAssertNotEqual(v1, v0)
        // A single-step trigger has no progress to save.
        _ = engine.observe(event(0, "exception"))
        XCTAssertEqual(engine.progressVersion, v1)
        XCTAssertEqual(engine.snapshotProgress(), [])
        engine.resetSession()
        XCTAssertNotEqual(engine.progressVersion, v1)
    }

    func testEventKindsCollectsTheEventTypesAMatcherNames() {
        let matcher = Matcher.all([
            .event(EventMatcher(type: "click", value: "#a")),
            .any([.not(.event(EventMatcher(type: "hover", value: "#b"))), .condition(Condition(key: "x", op: "exists"))]),
            .event(EventMatcher(type: "click", value: "#c")),
        ])
        XCTAssertEqual(eventKinds(matcher), ["click", "hover"])
        XCTAssertTrue(eventKinds(.condition(Condition(key: "x", op: "exists"))).isEmpty)
    }

    func testSessionLimitsRoundTripThroughJSONAndIgnoreMalformedEntries() throws {
        let engine = TriggerEngine()
        engine.setTriggers([defaultExceptionTrigger()])
        _ = engine.observe(event(1000, "exception"))
        let saved = roundTrip(engine.snapshotSessionLimits())
        XCTAssertEqual(saved, [defaultExceptionTriggerId: ["fires": 1, "lastFireMs": 1000]])

        let next = TriggerEngine()
        next.setTriggers([defaultExceptionTrigger()])
        next.restoreSessionLimits(saved)
        XCTAssertEqual(next.snapshotSessionLimits(), saved)
        XCTAssertTrue(next.observe(event(2000, "exception")).isEmpty)
        XCTAssertEqual(next.skipped[defaultExceptionTriggerId], "cooldown")

        let other = TriggerEngine()
        other.restoreSessionLimits(try JSON.parse(
            #"{"a":{"fires":-1,"lastFireMs":0},"b":{"fires":1.5,"lastFireMs":0},"c":{"fires":1},"d":"x","e":{"fires":2,"lastFireMs":5}}"#
        ))
        other.restoreSessionLimits([1, 2])
        other.restoreSessionLimits(nil)
        XCTAssertEqual(other.snapshotSessionLimits(), ["e": ["fires": 2, "lastFireMs": 5]])
        // Limits restored before the trigger is known apply once it is.
        var e = defaultExceptionTrigger()
        e.id = "e"
        other.setTriggers([e])
        XCTAssertTrue(other.observe(event(6, "exception")).isEmpty)
        XCTAssertEqual(other.skipped["e"], "cooldown")
    }

    func testRestoreProgressAcceptsOnlyItsOwnFormat() throws {
        let ab = parseTrigger([
            "id": "ab",
            "steps": [["match": named("a")], ["match": named("b")]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])
        let engine = TriggerEngine()
        engine.setTriggers([ab])
        _ = engine.observe(event(50, "a"))
        let good = engine.snapshotProgress()
        XCTAssertEqual(good.array?.count, 1)
        let item = try XCTUnwrap(good.array?.first?.object)
        XCTAssertEqual(item["id"], "ab")
        XCTAssertEqual(item["v"], 2)
        XCTAssertEqual(item["signature"]?.string, ab.signature)

        func restoredFires(_ saved: JSON?, only: Set<String>? = nil) -> Int {
            let next = TriggerEngine()
            next.setTriggers([ab])
            next.restoreProgress(saved, nowMs: 100, only: only)
            return next.observe(event(100, "b")).count
        }
        func with(_ key: String, _ value: JSON) -> JSON {
            var changed = item
            changed[key] = value
            return [.object(changed)]
        }
        XCTAssertEqual(restoredFires(good), 1)
        XCTAssertEqual(restoredFires(roundTrip(good)), 1)
        XCTAssertEqual(restoredFires(good, only: ["ab"]), 1)
        XCTAssertEqual(restoredFires(good, only: ["other"]), 0)
        XCTAssertEqual(restoredFires(nil), 0)
        XCTAssertEqual(restoredFires(["x": 1]), 0)
        XCTAssertEqual(restoredFires(with("v", 1)), 0)
        XCTAssertEqual(restoredFires(with("v", 2.0)), 1)
        XCTAssertEqual(restoredFires(with("signature", "other")), 0)
        XCTAssertEqual(restoredFires(with("id", "zz")), 0)
        XCTAssertEqual(restoredFires(with("steps", [item["steps"]!])), 0)
        XCTAssertEqual(restoredFires(with("steps", "x")), 0)
        // An anchor in the future, or with a fractional start, is not progress.
        XCTAssertEqual(restoredFires(with("steps", [["anchors": [], "hits": []], ["anchors": [[150, 0]], "hits": []]])), 0)
        XCTAssertEqual(restoredFires(with("steps", [[:], ["anchors": [[50, 0.5]]]])), 0)
        XCTAssertEqual(restoredFires(with("steps", [[:], ["anchors": ["junk", [50.9, 0]]]])), 1)
    }

    // MARK: progress

    func testRestoreHonoursOnly() {
        let first = TriggerEngine()
        first.setTriggers([journey])
        _ = first.observe(observed(1000, [keyPointerAction: "click"], targetMatches: { _ in true }))
        let next = TriggerEngine()
        next.setTriggers([journey])
        next.restoreProgress(first.snapshotProgress(), nowMs: 1500, only: ["other"])
        XCTAssertEqual(next.snapshotProgress(), .array([]))
        next.restoreProgress(first.snapshotProgress(), nowMs: 1500, only: ["journey"])
        XCTAssertEqual(next.snapshotProgress().array?.count, 1)
    }

    func testSnapshotShape() {
        let engine = TriggerEngine()
        engine.setTriggers([parseTrigger([
            "id": "burst",
            "steps": [["match": named("a")], ["match": named("err"), "count": 3, "periodSeconds": 60]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])])
        XCTAssertEqual(engine.snapshotProgress(), .array([]))
        _ = engine.observe(event(1000, "a"))
        _ = engine.observe(event(2000, "err"))
        let snapshot = engine.snapshotProgress().array!
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0]["id"], "burst")
        XCTAssertEqual(snapshot[0]["v"], 2)
        XCTAssertEqual(snapshot[0]["signature"]?.string, engine.triggers[0].signature)
        XCTAssertEqual(snapshot[0]["steps"], [
            ["anchors": [], "hits": []],
            ["anchors": [[1000, 0]], "hits": [2000]],
        ])
    }

    func testSessionLimitsRestoredBeforeTheTriggersArrive() {
        let once = parseTrigger([
            "id": "once",
            "maxPerSession": 1,
            "steps": [["match": named("a")]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])
        let engine = TriggerEngine()
        engine.restoreSessionLimits(["once": ["fires": 1, "lastFireMs": 5], "bad": ["fires": -1, "lastFireMs": 0]])
        engine.setTriggers([once])
        XCTAssertTrue(engine.observe(event(10, "a")).isEmpty)
        XCTAssertEqual(engine.snapshotSessionLimits(), ["once": ["fires": 1, "lastFireMs": 5]])
    }

    func testAnchorsAreBoundedToEight() {
        // A counted second step keeps one anchor per completion of the
        // first; the ninth replaces the newest.
        let engine = TriggerEngine()
        engine.setTriggers([parseTrigger([
            "id": "t",
            "steps": [["match": named("a")], ["match": named("b"), "count": 2]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])])
        for t in 0..<10 { _ = engine.observe(event(Int64(t), "a")) }
        let steps = engine.snapshotProgress().array![0]["steps"]!.array!
        XCTAssertEqual(steps[1]["anchors"]?.array?.count, 8)
        XCTAssertEqual(steps[1]["anchors"]?.array?.last, [9, 0])
    }
}
