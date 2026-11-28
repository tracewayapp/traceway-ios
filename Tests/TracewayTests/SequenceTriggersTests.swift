import XCTest
@testable import Traceway

/// The browser SDK's sequence-trigger tests (js-client
/// packages/core/src/sequence-triggers.test.ts), by way of the Flutter and
/// Android ports, so every engine is held to the same behaviour.
final class SequenceTriggersTests: XCTestCase {
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

    private func engineWith(_ triggers: Trigger...) -> TriggerEngine {
        let engine = TriggerEngine()
        engine.setTriggers(triggers)
        return engine
    }

    private func trigger(_ id: String, _ steps: [JSON], maxPerSession: Int? = nil) -> Trigger {
        var json: [String: JSON] = ["id": .string(id), "steps": .array(steps), "actions": [["type": "emit", "eventName": "x"]]]
        if let max = maxPerSession { json["maxPerSession"] = JSON(max) }
        return parseTrigger(.object(json))
    }

    private func run(_ steps: [JSON], _ events: [(Int64, String)]) -> [Int] {
        let engine = engineWith(trigger("t", steps))
        return events.map { engine.observe(event($0.0, $0.1)).count }
    }

    private var journey: Trigger { parseTrigger(journeyTriggerJSON) }

    private func roundTrip(_ value: JSON) -> JSON {
        try! JSON.parse(value.encoded())
    }

    func testRestoresAClickAcrossAnAppRestartFiresOnceAndIgnoresUnrelatedLogs() {
        let first = engineWith(journey)
        _ = first.observe(observed(1000, [keyPointerAction: "click"], targetMatches: { $0 == "#users .open" }))
        let next = engineWith(journey)
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
        let first = engineWith(journey)
        _ = first.observe(observed(1000, [keyPointerAction: "click"], targetMatches: { _ in true }))
        var changed = journey
        changed.actions = [TriggerAction(type: "startReplay", durationSeconds: 10)]
        for (rule, now) in [(journey, Int64(12000)), (changed, Int64(2000))] {
            let restored = engineWith(rule)
            restored.restoreProgress(first.snapshotProgress(), nowMs: now)
            _ = restored.observe(observed(now, [
                "event.name": "browser.navigation", "attributes.url.full": "/users/42",
            ]))
            XCTAssertTrue(restored.observe(observed(now + 1, [
                "event.name": "browser.console", "body": "loaded",
            ])).isEmpty)
        }
    }

    func testAMalformedEventStepDropsTheTrigger() {
        let settings = applyOverlay(defaultSettings(), [
            "triggers": [[
                "id": "bad",
                "steps": [["match": ["event": ["type": "click", "value": "a:hover"]]]],
                "actions": [["type": "emit", "eventName": "x"]],
            ]],
        ])
        XCTAssertEqual(settings.triggers.map(\.id), ["default-exception"])
    }

    func testStepsAreReportedInTheSchemaTheServerValidates() throws {
        let trigger = applyOverlay(defaultSettings(), ["triggers": [journeyTriggerJSON]]).triggers.last!
        let steps = try JSON.parse(trigger.stepsJSON().encoded()).array!
        XCTAssertEqual(steps[0], [
            "match": ["event": ["type": "click", "value": "#users .open"]],
            "withinSeconds": nil,
        ])
        XCTAssertEqual(steps[1]["withinSeconds"], 10)
    }

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

    func testACountedLaterStepNeedsItsHitsInsideThePeriod() {
        XCTAssertEqual(
            run([["match": named("a")], ["match": named("b"), "count": 2, "periodSeconds": 1]],
                [(0, "a"), (100, "b"), (2000, "b"), (2500, "b")]),
            [0, 0, 0, 1]
        )
    }

    func testCarriesACountOnTheFirstStepAcrossAppStarts() {
        let counted = trigger("burst", [["match": named("err"), "count": 3, "periodSeconds": 60]])
        let first = engineWith(counted)
        _ = first.observe(event(1000, "err"))
        _ = first.observe(event(2000, "err"))
        let next = engineWith(counted)
        next.restoreProgress(roundTrip(first.snapshotProgress()), nowMs: 3000)
        XCTAssertEqual(next.observe(event(3000, "err")).count, 1)
    }

    func testRestoredHitsOutsideThePeriodAreDropped() {
        let counted = trigger("burst", [["match": named("err"), "count": 3, "periodSeconds": 60]])
        let first = engineWith(counted)
        _ = first.observe(event(1000, "err"))
        _ = first.observe(event(2000, "err"))
        let next = engineWith(counted)
        next.restoreProgress(first.snapshotProgress(), nowMs: 61_500)
        XCTAssertTrue(next.observe(event(61_500, "err")).isEmpty)
        XCTAssertEqual(next.observe(event(61_600, "err")).count, 1)
    }

    func testKeepsAStepWithoutATimeoutForAsLongAsTheSession() {
        let open = trigger("open", [["match": named("a")], ["match": named("b")]])
        let first = engineWith(open)
        _ = first.observe(event(0, "a"))
        let next = engineWith(open)
        next.restoreProgress(first.snapshotProgress(), nowMs: 3_600_000)
        XCTAssertEqual(next.observe(event(3_600_000, "b")).count, 1)
        // But not past a day.
        let late = engineWith(open)
        late.restoreProgress(first.snapshotProgress(), nowMs: 86_400_001)
        XCTAssertTrue(late.observe(event(86_400_001, "b")).isEmpty)
    }

    func testMatchesATapOnlyAgainstStepsThatNameAClick() {
        let engine = engineWith(
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
            ])
        )
        let fired = engine.observe(observed(
            0, [keyPointerAction: "click", "global.plan": "pro"], sequence: "click", targetMatches: { _ in true }
        ))
        XCTAssertEqual(fired.map(\.trigger.id), ["pro-click"])
        XCTAssertEqual(eventKinds(engine.triggers[1].steps[0].match), ["click"])
    }

    func testOnlyReportsAChangeOfProgressWhenThereIsOne() {
        let engine = engineWith(trigger("t", [["match": named("a")], ["match": named("b")]]))
        let before = engine.progressVersion
        _ = engine.observe(event(0, "other"))
        XCTAssertEqual(engine.progressVersion, before)
        _ = engine.observe(event(1, "a"))
        XCTAssertNotEqual(engine.progressVersion, before)
    }

    func testASnapshotDoesNotChangeWithLaterProgress() {
        let engine = engineWith(trigger("burst", [["match": named("a")], ["match": named("err"), "count": 5, "periodSeconds": 1]]))
        _ = engine.observe(event(0, "a"))
        _ = engine.observe(event(100, "err"))
        let snapshot = engine.snapshotProgress()
        let saved = snapshot.encoded(sortedKeys: true)
        for t in stride(from: Int64(2000), to: 2600, by: 100) {
            _ = engine.observe(event(t, "err"))
        }
        XCTAssertEqual(snapshot.encoded(sortedKeys: true), saved)
        XCTAssertNotEqual(engine.snapshotProgress().encoded(sortedKeys: true), saved)
    }

    func testFireCountsSurviveARestartWithinTheSession() {
        let once = trigger("once", [["match": named("a")]], maxPerSession: 1)
        let first = engineWith(once)
        XCTAssertEqual(first.observe(event(0, "a")).count, 1)
        let limits = roundTrip(first.snapshotSessionLimits())
        XCTAssertEqual(limits, ["once": ["fires": 1, "lastFireMs": 0]])
        let next = engineWith(once)
        next.restoreSessionLimits(limits)
        XCTAssertTrue(next.observe(event(1, "a")).isEmpty)
        XCTAssertEqual(next.skipped["once"], "session_clip_limit")
    }

    func testAFiredSequenceStartsOverAndANewSessionForgetsProgress() {
        let engine = engineWith(trigger("ab", [["match": named("a")], ["match": named("b")]]))
        _ = engine.observe(event(0, "a"))
        XCTAssertEqual(engine.observe(event(1, "b")).count, 1)
        XCTAssertTrue(engine.observe(event(2, "b")).isEmpty)
        XCTAssertEqual(engine.snapshotProgress(), [])
        _ = engine.observe(event(3, "a"))
        XCTAssertEqual(engine.snapshotProgress().array?.count, 1)
        engine.resetSession()
        XCTAssertEqual(engine.snapshotProgress(), [])
        XCTAssertEqual(engine.snapshotSessionLimits(), [:])
        XCTAssertTrue(engine.observe(event(4, "b")).isEmpty)
    }

    func testRestoringOnlyNewTriggersLeavesRunningOnesAlone() {
        // The client restores saved progress for the triggers setTriggers
        // reports as new; one already running keeps its newer progress.
        let ab = trigger("ab", [["match": named("a")], ["match": named("b")]])
        let engine = engineWith(ab)
        _ = engine.observe(event(0, "a"))
        let saved = engine.snapshotProgress()
        XCTAssertEqual(engine.observe(event(1, "b")).count, 1)
        let created = engine.setTriggers([ab])
        XCTAssertEqual(created, [])
        engine.restoreProgress(saved, nowMs: 2, only: created)
        XCTAssertTrue(engine.observe(event(2, "b")).isEmpty)
    }
}
