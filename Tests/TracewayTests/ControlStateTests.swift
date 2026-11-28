import XCTest
@testable import Traceway

final class ControlStateTests: XCTestCase {
    func testRemoteSettingsCannotExceedTheStartCeilings() throws {
        let control = ControlState(
            defaults: defaultSettings(),
            ceilings: ceilingsFrom(screenCapture: false, captureNetwork: false)
        )
        control.applyRemote(try parseSettingsDocument(
            #"{"signals":{"network":{"mode":"stream"}},"replay":{"mode":"stream"}}"#
        ))
        XCTAssertEqual(control.modeFor("network"), .off)
        XCTAssertFalse(control.canExport("network"))
        XCTAssertEqual(control.replayMode, .off)
    }

    func testReplayStreamsForARuleOrAnOverrideThatAsksForIt() throws {
        var now: Int64 = 0
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom(screenCapture: true), now: { now })
        XCTAssertEqual(control.replayMode, .buffer)
        control.addOverride(StreamOverride(signals: ["*"], untilMs: 1000))
        XCTAssertEqual(control.replayMode, .buffer)
        control.addOverride(StreamOverride(signals: [], untilMs: 2000, replay: true))
        XCTAssertEqual(control.replayMode, .stream)
        XCTAssertEqual(control.nextOverrideExpiryMs, 1000)
        now = 2001
        XCTAssertEqual(control.replayMode, .buffer)
        XCTAssertNil(control.nextOverrideExpiryMs)
        control.applyRemote(try parseSettingsDocument(#"{"replay":{"mode":"stream","sessionSampleRate":1}}"#))
        XCTAssertEqual(control.replayMode, .stream)
        control.applyRemote(try parseSettingsDocument(#"{"replay":{"mode":"off"}}"#))
        XCTAssertEqual(control.replayMode, .off)
    }

    func testAnOverrideCannotStreamReplayPastTheCeiling() {
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom())
        control.addOverride(StreamOverride(signals: [], untilMs: 1 << 50, replay: true))
        XCTAssertEqual(control.replayMode, .off)
    }

    func testPlanLimitsLowerTheCeilings() throws {
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom(screenCapture: true))
        control.applyRemote(try parseSettingsDocument(
            #"{"signals":{"custom":{"mode":"stream"}},"limits":{"signals":{"custom":"buffer"},"replay":"off"}}"#
        ))
        XCTAssertEqual(control.modeFor("custom"), .buffer)
        XCTAssertEqual(control.replayMode, .off)
        // An override cannot go past the plan either.
        control.addOverride(StreamOverride(signals: ["custom"], untilMs: 1 << 50))
        XCTAssertEqual(control.modeFor("custom"), .buffer)
        XCTAssertFalse(control.canExport("custom"))
        // Without the limit the next document lifts it again.
        control.applyRemote(try parseSettingsDocument("{}"))
        XCTAssertEqual(control.modeFor("custom"), .stream)
    }

    func testStreamOverridesExpire() {
        var now: Int64 = 0
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom(), now: { now })
        control.addOverride(StreamOverride(signals: ["console"], untilMs: 1000))
        XCTAssertEqual(control.modeFor("console"), .stream)
        XCTAssertEqual(control.modeFor("network"), .buffer)
        now = 1001
        XCTAssertEqual(control.modeFor("console"), .buffer)
    }

    func testAWildcardOnlyBringsBackSignalsRulesSwitchedOffForACapture() throws {
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom())
        control.applyRemote(try parseSettingsDocument(#"{"signals":{"network":{"mode":"off"}}}"#))
        control.setOverrides("trigger", [StreamOverride(signals: ["*"], untilMs: 1 << 50)])
        XCTAssertEqual(control.modeFor("network"), .off)
        XCTAssertEqual(control.modeFor("console"), .stream)
        // Off by default stays off even for a capture.
        XCTAssertEqual(control.modeFor("resourceTiming"), .off)
        control.setOverrides("capture", [StreamOverride(signals: ["*"], untilMs: 1 << 50, includeOff: true)])
        XCTAssertEqual(control.modeFor("network"), .stream)
        XCTAssertEqual(control.modeFor("resourceTiming"), .off)
        // Naming the signal turns it on whatever its mode.
        control.setOverrides("named", [StreamOverride(signals: ["resourceTiming"], untilMs: 1 << 50)])
        XCTAssertEqual(control.modeFor("resourceTiming"), .stream)
        control.setOverrides("capture", [])
        control.setOverrides("named", [])
        XCTAssertEqual(control.modeFor("network"), .off)
        XCTAssertEqual(control.modeFor("resourceTiming"), .off)
    }

    func testAnOverrideNeverGoesPastTheAppsCeiling() {
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom(captureLogs: false))
        control.addOverride(StreamOverride(signals: ["console", "*"], untilMs: 1 << 50, includeOff: true))
        XCTAssertEqual(control.modeFor("console"), .off)
        XCTAssertFalse(control.canExport("console"))
    }

    func testReplayImagesFollowARuleOverTheLocalDocument() throws {
        let local = applyOverlay(defaultSettings(), ["replay": ["images": "always"]])
        let control = ControlState(defaults: local, ceilings: ceilingsFrom(screenCapture: true))
        XCTAssertEqual(control.settings.replayImages, .always)
        control.applyRemote(try parseSettingsDocument(#"{"replay":{"images":"wifi"}}"#))
        XCTAssertEqual(control.settings.replayImages, .wifi)
        // A rule that leaves images out keeps the local document's policy.
        control.applyRemote(try parseSettingsDocument(#"{"replay":{"mode":"stream"}}"#))
        XCTAssertEqual(control.settings.replayImages, .always)
        // A plan without replay has no pictures either.
        control.applyRemote(try parseSettingsDocument(#"{"limits":{"replay":"off"}}"#))
        XCTAssertEqual(control.settings.replayImages, .off)
    }

    func testKillSwitchTurnsEverythingOff() throws {
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom(screenCapture: true))
        control.applyRemote(try parseSettingsDocument(#"{"enabled":false}"#))
        XCTAssertFalse(control.enabled)
        XCTAssertEqual(control.modeFor("errors"), .off)
        XCTAssertEqual(control.replayMode, .off)
        XCTAssertFalse(control.canExport("errors"))
        control.addOverride(StreamOverride(signals: ["*"], untilMs: 1 << 50, replay: true))
        XCTAssertEqual(control.modeFor("console"), .off)
    }

    func testListenersSeeEveryApply() throws {
        let control = ControlState(defaults: defaultSettings(), ceilings: ceilingsFrom())
        var seen: [Mode] = []
        control.onChange { seen.append($0.signal("console").mode) }
        control.applyRemote(try parseSettingsDocument(#"{"signals":{"console":{"mode":"stream"}}}"#))
        control.applyRemote(nil)
        XCTAssertEqual(seen, [.stream, .buffer])
        XCTAssertEqual(control.sampleRate("console"), 1)
    }
}
