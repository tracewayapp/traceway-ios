import XCTest
@testable import Traceway

final class SettingsMergeTests: XCTestCase {
    // MARK: defaults

    func testDefaultsBufferBreadcrumbsAndStreamErrors() {
        let s = defaultSettings()
        XCTAssertEqual(s.signal("errors").mode, .stream)
        XCTAssertEqual(s.signal("console").mode, .buffer)
        XCTAssertEqual(s.signal("network").mode, .buffer)
        XCTAssertEqual(s.replayMode, .buffer)
        XCTAssertEqual(s.bufferMaxBytes, 2 * 1024 * 1024)
        XCTAssertEqual(s.bufferMaxAgeSeconds, 600)
        XCTAssertEqual(s.triggers.map(\.id), [defaultExceptionTriggerId])
    }

    func testRecordAllSessionsStreamsBreadcrumbsAndReplay() {
        let s = defaultSettings(baselineSampleRate: 7, recordAllSessions: true)
        XCTAssertEqual(s.signal("console").mode, .stream)
        XCTAssertEqual(s.signal("custom").mode, .stream)
        XCTAssertEqual(s.signal("webVitals").mode, .buffer)
        XCTAssertEqual(s.replayMode, .stream)
        XCTAssertEqual(s.baselineSampleRate, 1)
        XCTAssertEqual(defaultSettings(baselineSampleRate: .nan).baselineSampleRate, 0)
        XCTAssertEqual(Array(defaultSettings().signals.keys).sorted(), signalNames.sorted())
    }

    // MARK: overlay

    func testOverlayMergesKnownFieldsAndIgnoresMalformedOnes() throws {
        let merged = applyOverlay(defaultSettings(), try parseSettingsDocument("""
        {"schemaVersion":1,
          "signals":{"custom":{"mode":"stream","sampleRate":7},
                     "console":{"mode":"nope","minSeverity":"warn"}},
          "sessions":{"baselineSampleRate":0.25},
          "buffer":{"maxBytes":1e12,"maxAgeSeconds":30},
          "unknown":{"x":1},
          "triggers":[{"id":"default-exception","enabled":false},
                      {"id":"t2","steps":[{"match":{"key":"event.name","op":"eq","value":"x"}}],
                       "actions":[{"type":"flush","lookbackSeconds":60,"signals":["custom","bogus"]}]},
                      {"id":"bad","steps":[],"actions":[]}],
          "captures":[{"id":"c1","until":"2099-01-01T00:00:00Z","lookbackSeconds":0},
                      {"id":"c2","until":"not a date"}]}
        """))
        XCTAssertEqual(merged.signal("custom").mode, .stream)
        XCTAssertEqual(merged.signal("custom").sampleRate, 1)
        XCTAssertEqual(merged.signal("console").mode, .buffer)
        XCTAssertEqual(merged.signal("console").minSeverity, "warn")
        XCTAssertEqual(merged.baselineSampleRate, 0.25)
        XCTAssertEqual(merged.bufferMaxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(merged.bufferMaxAgeSeconds, 30)
        XCTAssertEqual(merged.triggers.map(\.id), ["default-exception", "t2"])
        XCTAssertEqual(merged.triggers[0].enabled, false)
        XCTAssertEqual(merged.triggers[0].steps.count, 1)
        XCTAssertEqual(merged.triggers[1].actions.first?.signals, ["custom"])
        XCTAssertEqual(merged.captures.map(\.id), ["c1"])
        XCTAssertEqual(merged.captures.first?.lookbackSeconds, 0)
        XCTAssertEqual(merged.captures.first?.until, Date(timeIntervalSince1970: 4_070_908_800))
    }

    func testOverlayLeavesTheBaseUntouched() {
        let base = defaultSettings()
        let merged = applyOverlay(base, ["enabled": false, "signals": ["console": ["mode": "off"]]])
        XCTAssertFalse(merged.enabled)
        XCTAssertEqual(merged.signal("console").mode, .off)
        XCTAssertTrue(base.enabled)
        XCTAssertEqual(base.signal("console").mode, .buffer)
    }

    func testRejectsDocumentsItCannotApply() {
        for body in ["nope", "[]", #"{"schemaVersion":2}"#, #"{"schemaVersion":"1"}"#] {
            XCTAssertThrowsError(try parseSettingsDocument(body), body) { error in
                XCTAssertTrue(error is SettingsError)
            }
        }
        XCTAssertNoThrow(try parseSettingsDocument(#"{"schemaVersion":1.0}"#))
        XCTAssertNoThrow(try parseSettingsDocument(#"{"schemaVersion":null}"#))
    }

    func testBooleansAreNotNumbersInTheDocument() throws {
        let merged = applyOverlay(defaultSettings(), try parseSettingsDocument("""
        {"enabled":1,"signals":{"errors":{"sampleRate":true}},"replay":{"maskAllInputs":false},
         "buffer":{"persist":0,"maxBytes":true}}
        """))
        XCTAssertTrue(merged.enabled)
        XCTAssertEqual(merged.signal("errors").sampleRate, 1)
        XCTAssertFalse(merged.replayMaskAllInputs)
        XCTAssertTrue(merged.persist)
        XCTAssertEqual(merged.bufferMaxBytes, 2 * 1024 * 1024)
    }

    func testSessionsReplayAndBufferSettings() throws {
        let merged = applyOverlay(defaultSettings(), try parseSettingsDocument("""
        {"sessions":{"enabled":false,"baselineSampleRate":-3},
         "replay":{"mode":"stream","sessionSampleRate":0.5,"captureMode":"video"},
         "buffer":{"maxAgeSeconds":1e9,"persist":false,"maxBytes":-1}}
        """))
        XCTAssertFalse(merged.sessionsEnabled)
        XCTAssertEqual(merged.baselineSampleRate, 0)
        XCTAssertEqual(merged.replayMode, .stream)
        XCTAssertEqual(merged.replaySessionSampleRate, 0.5)
        XCTAssertEqual(merged.bufferMaxAgeSeconds, 86400)
        XCTAssertFalse(merged.persist)
        XCTAssertEqual(merged.bufferMaxBytes, 2 * 1024 * 1024)
    }

    func testTriggersMergeByIdKeepingWhatTheOverlayLeavesOut() {
        let merged = applyOverlay(defaultSettings(), [
            "triggers": [
                ["id": "default-exception", "cooldownSeconds": 0, "maxPerSession": 3.7, "name": "Clip"],
                ["id": "default-exception", "steps": []],
                ["id": "", "steps": [["match": ["key": "a", "op": "eq"]]], "actions": [["type": "emit", "eventName": "x"]]],
                ["id": "new", "steps": [["match": ["key": "a", "op": "exists"]]]],
            ],
        ])
        XCTAssertEqual(merged.triggers.map(\.id), [defaultExceptionTriggerId])
        let trigger = merged.triggers[0]
        XCTAssertEqual(trigger.cooldownSeconds, 0)
        XCTAssertEqual(trigger.maxPerSession, 3)
        XCTAssertEqual(trigger.name, "Clip")
        XCTAssertEqual(trigger.steps, defaultExceptionTrigger().steps)
        XCTAssertEqual(trigger.actions, defaultExceptionTrigger().actions)
        XCTAssertEqual(trigger.sampleRate, 1)
    }

    func testStepsAndActions() {
        let merged = applyOverlay(defaultSettings(), [
            "triggers": [[
                "id": "t",
                "steps": [
                    ["match": ["key": "event.name", "op": "eq", "value": "a"], "withinSeconds": 0],
                    ["match": ["key": "event.name", "op": "eq", "value": "b"], "withinSeconds": 5,
                     "count": 5000, "periodSeconds": 1e9],
                    ["match": ["key": "event.name", "op": "eq", "value": "c"], "count": 2.5],
                    ["match": ["key": "event.name", "op": "eq", "value": "d"], "count": 1, "periodSeconds": 5],
                ],
                "actions": [
                    ["type": "stream", "durationSeconds": 30, "replay": true],
                    ["type": "startReplay", "durationSeconds": 1e9],
                    ["type": "capture", "durationSeconds": 60, "lookbackSeconds": 0, "signals": ["*", "network"]],
                    ["type": "emit", "eventName": "marked", "attributes": ["k": "v", "n": 1]],
                ],
            ]],
        ])
        let trigger = merged.triggers.first { $0.id == "t" }!
        XCTAssertNil(trigger.steps[0].withinSeconds)
        XCTAssertEqual(trigger.steps[1].withinSeconds, 5)
        XCTAssertEqual(trigger.steps[1].count, 1000)
        XCTAssertEqual(trigger.steps[1].periodSeconds, 86400)
        XCTAssertNil(trigger.steps[2].count)
        XCTAssertNil(trigger.steps[3].count)
        XCTAssertNil(trigger.steps[3].periodSeconds)
        XCTAssertEqual(trigger.actions[0], TriggerAction(type: "stream", durationSeconds: 30, replay: true))
        XCTAssertEqual(trigger.actions[1], TriggerAction(type: "startReplay", durationSeconds: 86400))
        XCTAssertEqual(
            trigger.actions[2],
            TriggerAction(type: "capture", lookbackSeconds: nil, durationSeconds: 60, signals: ["*", "network"])
        )
        XCTAssertEqual(trigger.actions[3], TriggerAction(type: "emit", eventName: "marked", attributes: ["k": "v"]))
    }

    func testOneBadActionDropsTheTrigger() {
        let merged = applyOverlay(defaultSettings(), [
            "triggers": [[
                "id": "t",
                "steps": [["match": ["key": "event.name", "op": "eq", "value": "a"]]],
                "actions": [["type": "emit", "eventName": "x"], ["type": "flush"]],
            ]],
        ])
        XCTAssertEqual(merged.triggers.map(\.id), [defaultExceptionTriggerId])
    }

    func testActionsAreValidatedByType() throws {
        func actions(_ json: String) throws -> [TriggerAction]? {
            let merged = applyOverlay(defaultSettings(), try parseSettingsDocument(
                #"{"triggers":[{"id":"t","steps":[{"match":{"key":"a","op":"exists"}}],"actions":"# + json + "}]}"
            ))
            return merged.triggers.first { $0.id == "t" }?.actions
        }
        let ok = try XCTUnwrap(try actions("""
        [{"type":"flush","lookbackSeconds":1e9,"replay":true},
         {"type":"stream","durationSeconds":10,"signals":["*","console"]},
         {"type":"startReplay","durationSeconds":5,"signals":["console"]},
         {"type":"capture","durationSeconds":30,"lookbackSeconds":-1},
         {"type":"emit","eventName":"x"}]
        """))
        XCTAssertEqual(ok.map(\.type), ["flush", "stream", "startReplay", "capture", "emit"])
        XCTAssertEqual(ok[0].lookbackSeconds, 86400)
        XCTAssertTrue(ok[0].replay)
        XCTAssertNil(ok[0].signals)
        XCTAssertEqual(ok[1].signals, ["*", "console"])
        XCTAssertNil(ok[2].signals)
        XCTAssertNil(ok[3].lookbackSeconds)
        for bad in [
            #"[{"type":"flush"}]"#,
            #"[{"type":"stream","durationSeconds":0}]"#,
            #"[{"type":"startReplay"}]"#,
            #"[{"type":"capture","lookbackSeconds":5}]"#,
            #"[{"type":"emit","eventName":""}]"#,
            #"[{"type":"explode"}]"#,
            "[]",
            "{}",
        ] {
            XCTAssertNil(try actions(bad), bad)
        }
    }

    func testMatcherParsing() {
        XCTAssertEqual(
            parseMatcher(["all": [["key": "a", "op": "eq", "value": 1], ["not": ["key": "b", "op": "exists"]]]]),
            .all([
                .condition(Condition(key: "a", op: "eq", value: 1)),
                .not(.condition(Condition(key: "b", op: "exists"))),
            ])
        )
        XCTAssertEqual(
            parseMatcher(["key": "a", "op": "in", "values": [1, "x", true]]),
            .condition(Condition(key: "a", op: "in", values: [1, "x", true]))
        )
        XCTAssertNil(parseMatcher(["key": "a", "op": "like"]))
        XCTAssertNil(parseMatcher(["key": "", "op": "eq"]))
        XCTAssertNil(parseMatcher(["key": "a", "op": "eq", "value": ["x": 1]]))
        XCTAssertNil(parseMatcher(["key": "a", "op": "in", "values": [["x"]]]))
        XCTAssertNil(parseMatcher(["any": [["key": "a", "op": "eq"], ["key": "b", "op": "bogus"]]]))
        XCTAssertNil(parseMatcher(.array([])))

        var deep: JSON = ["key": "a", "op": "exists"]
        for _ in 0..<8 { deep = ["not": deep] }
        XCTAssertNotNil(parseMatcher(deep))
        XCTAssertNil(parseMatcher(["not": deep]))
    }

    func testValidatesBoundedEventMatchers() {
        XCTAssertEqual(
            parseMatcher(["event": ["type": "hover", "value": "#menu"]]),
            .event(EventMatcher(type: "hover", value: "#menu"))
        )
        XCTAssertEqual(
            parseMatcher(["event": ["type": "log", "value": "a:b", "mode": "contains"]]),
            .event(EventMatcher(type: "log", value: "a:b", mode: "contains"))
        )
        let bad: [JSON] = [
            ["type": "click", "value": ":has(*)"],
            ["type": "click", "value": "a, b"],
            ["type": "hover", "value": "a\\b"],
            ["type": "unknown", "value": "x"],
            ["type": "log", "value": " "],
            ["type": "log", "value": "x", "mode": "regex"],
            ["type": "log", "value": .string(String(repeating: "x", count: 257))],
        ]
        for event in bad {
            XCTAssertNil(parseMatcher(["event": event]), event.encoded())
        }
    }

    func testCapturesParseRFC3339() {
        let merged = applyOverlay(defaultSettings(), [
            "captures": [
                ["id": "a", "until": "2026-11-26T10:00:00.250+02:00", "signals": ["network"], "replay": true],
                ["id": "b", "until": "2026-11-26T08:00:00Z", "lookbackSeconds": 1e9],
                ["id": "c", "until": "2026-11-26 08:00:00z", "lookbackSeconds": -5],
                ["id": "d"],
                ["until": "2026-11-26T08:00:00Z"],
            ],
        ])
        XCTAssertEqual(merged.captures.map(\.id), ["a", "b", "c"])
        let base = Date(timeIntervalSince1970: 1_795_680_000) // 2026-11-26T08:00:00Z
        XCTAssertEqual(merged.captures[0].until.timeIntervalSince1970, base.timeIntervalSince1970 + 0.25, accuracy: 1e-6)
        XCTAssertEqual(merged.captures[0].signals, ["network"])
        XCTAssertTrue(merged.captures[0].replay)
        XCTAssertEqual(merged.captures[1].until, base)
        XCTAssertEqual(merged.captures[1].lookbackSeconds, 86400)
        XCTAssertEqual(merged.captures[2].until, base)
        XCTAssertNil(merged.captures[2].lookbackSeconds)
        XCTAssertNil(merged.captures[2].signals)
        XCTAssertEqual(parseRFC3339("20261126T080000Z"), base)
        XCTAssertNil(parseRFC3339("26-11-2026"))
    }

    func testCapturesAreReplacedAsAWhole() throws {
        let base = applyOverlay(defaultSettings(), try parseSettingsDocument(
            #"{"captures":[{"id":"c1","until":"2099-01-01T00:00:00Z","signals":["console"],"replay":true}]}"#
        ))
        let capture = try XCTUnwrap(base.captures.first)
        XCTAssertEqual(base.captures.count, 1)
        XCTAssertEqual(capture.signals, ["console"])
        XCTAssertTrue(capture.replay)
        XCTAssertNil(capture.lookbackSeconds)
        XCTAssertTrue(applyOverlay(base, ["captures": []]).captures.isEmpty)
        XCTAssertEqual(applyOverlay(base, ["captures": "x"]).captures.count, 1)
    }

    func testTheSignatureChangesWithStepsAndActionsOnly() throws {
        let t = defaultExceptionTrigger()
        var renamed = t
        renamed.name = "x"
        renamed.cooldownSeconds = 1
        renamed.maxPerSession = 1
        XCTAssertEqual(renamed.signature, t.signature)
        var other = t
        other.actions = [TriggerAction(type: "emit", eventName: "x")]
        XCTAssertNotEqual(other.signature, t.signature)
        let steps = try JSON.parse(t.stepsJSON().encoded())
        XCTAssertEqual(steps, [[
            "match": ["key": "event.name", "op": "eq", "value": "exception"],
            "withinSeconds": nil,
        ]])
    }

    // MARK: limits and ceilings

    func testLimitsLowerTheCeilings() throws {
        let limited = applyLimits(ceilingsFrom(screenCapture: true), try parseSettingsDocument(
            #"{"limits":{"signals":{"custom":"buffer","network":"bogus"},"replay":"off"}}"#
        ))
        XCTAssertEqual(limited.signal("custom"), .buffer)
        XCTAssertEqual(limited.signal("network"), .stream)
        XCTAssertEqual(limited.replay, .off)
        XCTAssertEqual(applyLimits(ceilingsFrom(), nil), ceilingsFrom())
        // A limit never raises a ceiling.
        let raised = applyLimits(ceilingsFrom(captureNetwork: false), ["limits": ["signals": ["network": "stream"]]])
        XCTAssertEqual(raised.signal("network"), .off)
    }

    func testReplayImagesDefaultToWifiFollowTheDocumentsAndStayUnderTheAppsCeiling() throws {
        let defaults = defaultSettings()
        XCTAssertEqual(defaults.replayImages, .wifi)
        let always = applyOverlay(defaults, ["replay": ["images": "always"]])
        XCTAssertEqual(always.replayImages, .always)
        XCTAssertEqual(defaults.replayImages, .wifi)
        for bad in [#""sometimes""#, #""WIFI""#, "1", "true", "null"] {
            let merged = applyOverlay(always, try parseSettingsDocument(#"{"replay":{"images":"# + bad + "}}"))
            XCTAssertEqual(merged.replayImages, .always, bad)
        }
        let off = applyOverlay(always, ["replay": ["images": "off"]])
        XCTAssertEqual(off.replayImages, .off)

        // The lower of the setting and the app's ceiling.
        XCTAssertEqual(clampToCeilings(always, ceilingsFrom(screenCapture: true)).replayImages, .always)
        let wifiCeiling = ceilingsFrom(screenCapture: true, replayImages: .wifi)
        XCTAssertEqual(clampToCeilings(always, wifiCeiling).replayImages, .wifi)
        XCTAssertEqual(clampToCeilings(off, wifiCeiling).replayImages, .off)
        let offCeiling = ceilingsFrom(screenCapture: true, replayImages: .off)
        XCTAssertEqual(clampToCeilings(always, offCeiling).replayImages, .off)
        // No replay, no pictures: the app records no screen, or the plan allows no replay.
        XCTAssertEqual(clampToCeilings(always, ceilingsFrom(screenCapture: false)).replayImages, .off)
        let limited = applyLimits(wifiCeiling, ["limits": ["replay": "off"]])
        XCTAssertEqual(limited.replayImages, .wifi)
        XCTAssertEqual(clampToCeilings(always, limited).replayImages, .off)
        XCTAssertEqual(min(TracewayImagePolicy.off, .always), .off)
        XCTAssertEqual(TracewayImagePolicy.wifi.rawValue, "wifi")
    }

    func testCeilingsFollowTheStartOptions() {
        let c = ceilingsFrom(captureLogs: false, captureNavigation: false, captureUserActions: false)
        XCTAssertEqual(c.signal("console"), .off)
        XCTAssertEqual(c.signal("navigation"), .off)
        XCTAssertEqual(c.signal("userActions"), .off)
        XCTAssertEqual(c.signal("network"), .stream)
        XCTAssertEqual(c.signal("errors"), .stream)
        XCTAssertEqual(c.replay, .off)
        XCTAssertEqual(lowerMode(.stream, .buffer), .buffer)
        XCTAssertEqual(lowerMode(.off, .stream), .off)
        XCTAssertEqual(Mode(name: "stream"), .stream)
        XCTAssertNil(Mode(name: "STREAM"))
        XCTAssertEqual(Mode.buffer.name, "buffer")
    }

    func testClampHoldsModesAtTheCeilings() {
        var settings = defaultSettings(recordAllSessions: true)
        settings.sessionsEnabled = true
        let clamped = clampToCeilings(settings, ceilingsFrom(
            enabled: false, screenCapture: false, captureLogs: false, sessions: false
        ))
        XCTAssertFalse(clamped.enabled)
        XCTAssertEqual(clamped.signal("console").mode, .off)
        XCTAssertEqual(clamped.signal("network").mode, .stream)
        XCTAssertEqual(clamped.replayMode, .off)
        XCTAssertFalse(clamped.sessionsEnabled)
    }
}

/// The browser SDK's journey: a click, the profile route, then a log line.
let journeyTriggerJSON: JSON = [
    "id": "journey",
    "maxPerSession": 1,
    "steps": [
        ["match": ["event": ["type": "click", "value": "#users .open"]]],
        ["match": ["event": ["type": "navigation", "value": "/users/{id}"]], "withinSeconds": 10],
        ["match": ["event": ["type": "log", "value": "loaded"]], "withinSeconds": 5],
    ],
    "actions": [["type": "capture", "replay": true, "durationSeconds": 30]],
]
