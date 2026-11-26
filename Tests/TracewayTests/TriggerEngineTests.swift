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
        XCTAssertTrue(engine.observe(event(2000, "exception")).isEmpty)
        XCTAssertEqual(engine.skipped[defaultExceptionTriggerId], "cooldown")
        XCTAssertEqual(engine.observe(event(7000, "exception")).count, 1)
        XCTAssertTrue(engine.observe(event(20000, "exception")).isEmpty)
        XCTAssertEqual(engine.skipped[defaultExceptionTriggerId], "session_clip_limit")
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
    }

    func testSampleRateUsesTheInjectedRandom() {
        var trigger = defaultExceptionTrigger()
        trigger.sampleRate = 0.5
        let engine = TriggerEngine(random: { 0.9 })
        engine.setTriggers([trigger])
        XCTAssertTrue(engine.observe(event(0, "exception")).isEmpty)
        XCTAssertEqual(engine.skipped[defaultExceptionTriggerId], "sampled_out")
        let lucky = TriggerEngine(random: { 0.1 })
        lucky.setTriggers([trigger])
        XCTAssertEqual(lucky.observe(event(0, "exception")).count, 1)
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
        // Unchanged: progress kept, nothing new.
        XCTAssertEqual(engine.setTriggers([a]), [])
        XCTAssertEqual(engine.observe(event(1, "b")).count, 1)
        var changed = a
        changed.actions = [TriggerAction(type: "emit", eventName: "y")]
        XCTAssertEqual(engine.setTriggers([changed]), ["a"])
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
    }

    // MARK: event sequences

    func testRestoresAClickAcrossAnAppRestartFiresOnceAndIgnoresUnrelatedLogs() {
        let first = TriggerEngine()
        first.setTriggers([journey])
        _ = first.observe(observed(1000, [keyPointerAction: "click"], targetMatches: { $0 == "#users .open" }))
        let next = TriggerEngine()
        next.setTriggers([journey])
        next.restoreProgress(roundTrip(first.snapshotProgress()), nowMs: 2000)
        XCTAssertTrue(next.observe(observed(2000, [
            "event.name": "browser.navigation",
            "attributes.url.full": "https://app.test/users/42?secret=hidden",
        ])).isEmpty)
        XCTAssertTrue(next.observe(observed(2100, ["event.name": "browser.console", "body": "other"])).isEmpty)
        XCTAssertEqual(next.observe(observed(2200, ["event.name": "browser.console", "body": "loaded"])).count, 1)
        XCTAssertTrue(next.observe(observed(2300, ["event.name": "browser.console", "body": "loaded"])).isEmpty)
    }

    func testRejectsExpiredAndChangedRuleProgress() {
        let engine = TriggerEngine()
        engine.setTriggers([journey])
        _ = engine.observe(observed(1000, [keyPointerAction: "click"], targetMatches: { _ in true }))
        var changed = journey
        changed.actions = [TriggerAction(type: "startReplay", durationSeconds: 10)]
        for (rule, now) in [(journey, Int64(12000)), (changed, Int64(2000))] {
            let restored = TriggerEngine()
            restored.setTriggers([rule])
            restored.restoreProgress(engine.snapshotProgress(), nowMs: now)
            _ = restored.observe(observed(now, [
                "event.name": "browser.navigation", "attributes.url.full": "/users/42",
            ]))
            XCTAssertTrue(restored.observe(observed(now + 1, [
                "event.name": "browser.console", "body": "loaded",
            ])).isEmpty)
        }
    }

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

    // MARK: overlapping sequences

    func testKeepsProgressWhenTheFirstStepHappensAgain() {
        XCTAssertEqual(
            run([["match": named("a")], ["match": named("b")], ["match": named("c")]],
                [(1, "a"), (2, "b"), (3, "a"), (4, "c")]),
            [0, 0, 0, 1]
        )
    }

    func testFiresAnActionAfterAnErrorStormThatKeepsGoing() {
        XCTAssertEqual(
            run([["match": named("err"), "count": 3, "periodSeconds": 10],
                 ["match": named("retry"), "withinSeconds": 5]],
                [(0, "err"), (100, "err"), (200, "err"), (300, "err"), (400, "retry")]),
            [0, 0, 0, 0, 1]
        )
    }

    func testMeasuresATimeoutFromTheLatestEarlierStep() {
        let steps: [JSON] = [["match": named("a")], ["match": named("b"), "withinSeconds": 5]]
        XCTAssertEqual(run(steps, [(0, "a"), (4000, "a"), (8000, "b")]), [0, 0, 1])
        XCTAssertEqual(run(steps, [(0, "a"), (6000, "b")]), [0, 0])
    }

    func testCountsALaterStepOnlyFromTheMomentTheEarlierOneCompleted() {
        XCTAssertEqual(
            run([["match": named("a")], ["match": named("b"), "count": 2, "withinSeconds": 10]],
                [(0, "b"), (1, "a"), (2, "b"), (3, "a"), (3, "b")]),
            [0, 0, 0, 0, 1]
        )
    }

    func testDoesNotLetOneEventCompleteTwoSteps() {
        XCTAssertEqual(
            run([["match": named("a")], ["match": named("a")]], [(0, "a"), (0, "a"), (0, "a"), (0, "a")]),
            [0, 1, 0, 1]
        )
    }

    func testCarriesACountOnTheFirstStepAcrossAppStarts() {
        let counted = parseTrigger([
            "id": "burst",
            "steps": [["match": named("err"), "count": 3, "periodSeconds": 60]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])
        let first = TriggerEngine()
        first.setTriggers([counted])
        _ = first.observe(event(1000, "err"))
        _ = first.observe(event(2000, "err"))
        let next = TriggerEngine()
        next.setTriggers([counted])
        next.restoreProgress(roundTrip(first.snapshotProgress()), nowMs: 3000)
        XCTAssertEqual(next.observe(event(3000, "err")).count, 1)
    }

    func testRestoredHitsOutsideThePeriodAreDropped() {
        let counted = parseTrigger([
            "id": "burst",
            "steps": [["match": named("err"), "count": 3, "periodSeconds": 60]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])
        let first = TriggerEngine()
        first.setTriggers([counted])
        _ = first.observe(event(1000, "err"))
        _ = first.observe(event(2000, "err"))
        let next = TriggerEngine()
        next.setTriggers([counted])
        next.restoreProgress(first.snapshotProgress(), nowMs: 61_500)
        XCTAssertTrue(next.observe(event(61_500, "err")).isEmpty)
        XCTAssertEqual(next.observe(event(61_600, "err")).count, 1)
    }

    func testKeepsAStepWithoutATimeoutForAsLongAsTheSession() {
        let open = parseTrigger([
            "id": "open",
            "steps": [["match": named("a")], ["match": named("b")]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])
        let first = TriggerEngine()
        first.setTriggers([open])
        _ = first.observe(event(0, "a"))
        let next = TriggerEngine()
        next.setTriggers([open])
        next.restoreProgress(first.snapshotProgress(), nowMs: 3_600_000)
        XCTAssertEqual(next.observe(event(3_600_000, "b")).count, 1)
    }

    func testMatchesATapOnlyAgainstStepsThatNameAClick() {
        let engine = TriggerEngine()
        engine.setTriggers([
            parseTrigger([
                "id": "negated",
                "steps": [["match": ["not": named("exception")]]],
                "actions": [["type": "emit", "eventName": "x"]],
            ]),
            parseTrigger([
                "id": "pro-click",
                "steps": [["match": ["all": [
                    ["event": ["type": "click", "value": "#buy"]],
                    ["key": "global.plan", "op": "eq", "value": "pro"],
                ]]]],
                "actions": [["type": "emit", "eventName": "x"]],
            ]),
        ])
        let fired = engine.observe(observed(
            0, [keyPointerAction: "click", "global.plan": "pro"], sequence: "click", targetMatches: { _ in true }
        ))
        XCTAssertEqual(fired.map(\.trigger.id), ["pro-click"])
        XCTAssertEqual(eventKinds(engine.triggers[1].steps[0].match), ["click"])
    }

    func testOnlyReportsAChangeOfProgressWhenThereIsOne() {
        let engine = TriggerEngine()
        engine.setTriggers([parseTrigger([
            "id": "t",
            "steps": [["match": named("a")], ["match": named("b")]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])])
        let before = engine.progressVersion
        _ = engine.observe(event(0, "other"))
        XCTAssertEqual(engine.progressVersion, before)
        _ = engine.observe(event(1, "a"))
        XCTAssertNotEqual(engine.progressVersion, before)
    }

    func testASnapshotDoesNotChangeWithLaterProgress() {
        let engine = TriggerEngine()
        engine.setTriggers([parseTrigger([
            "id": "burst",
            "steps": [["match": named("a")], ["match": named("err"), "count": 5, "periodSeconds": 1]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])])
        _ = engine.observe(event(0, "a"))
        _ = engine.observe(event(100, "err"))
        let snapshot = engine.snapshotProgress()
        let saved = snapshot.encoded(sortedKeys: true)
        for t in stride(from: Int64(2000), to: 2600, by: 100) {
            _ = engine.observe(event(t, "err"))
        }
        XCTAssertEqual(snapshot.encoded(sortedKeys: true), saved)
    }

    func testFireCountsSurviveARestartWithinTheSession() {
        let once = parseTrigger([
            "id": "once",
            "maxPerSession": 1,
            "steps": [["match": named("a")]],
            "actions": [["type": "emit", "eventName": "x"]],
        ])
        let first = TriggerEngine()
        first.setTriggers([once])
        XCTAssertEqual(first.observe(event(0, "a")).count, 1)
        let limits = roundTrip(first.snapshotSessionLimits())
        XCTAssertEqual(limits, ["once": ["fires": 1, "lastFireMs": 0]])
        let next = TriggerEngine()
        next.setTriggers([once])
        next.restoreSessionLimits(limits)
        XCTAssertTrue(next.observe(event(1, "a")).isEmpty)
        XCTAssertEqual(next.skipped["once"], "session_clip_limit")
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
