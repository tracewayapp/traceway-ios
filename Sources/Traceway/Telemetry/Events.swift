import Foundation

// Event names and attributes shared with the browser and Flutter SDKs, so the
// backend and the settings schema treat every platform the same.

enum Events {
    static let exception = "exception"
    static let message = "traceway.message"
    static let action = "traceway.action"
    static let navigation = "browser.navigation"
    /// A tap, under the browser SDK's name so the dashboard shows it the same.
    static let click = "browser.user_action.click"
    static let sessionStart = "session.start"
    static let sessionEnd = "session.end"
    static let sessionUpdate = "traceway.session.update"
    static let triggerFired = "traceway.trigger.fired"
    static let captureStarted = "traceway.capture.started"
    static let configApplied = "traceway.config.applied"
    /// The SDK dropped data: the session's budget ran out, errors were
    /// suppressed, replay segments failed to upload.
    static let collectionHealth = "traceway.collection.health"
}

enum Attr {
    static let sessionId = "session.id"
    static let sessionStartedAt = "traceway.session.started_at"
    static let exceptionId = "traceway.exception.id"
    static let replayStatus = "traceway.replay.status"
    static let captureIds = "traceway.capture.ids"
    /// Marks an issue of an earlier run (a crash found on disk, a MetricKit
    /// report, a hang the app died in), as the Android SDK does.
    static let previousRun = "traceway.previous_run"
}

/// `control` records describe the SDK itself (sessions, triggers, config)
/// and are always sent.
let signalControl = "control"

private let controlEvents: Set<String> = [
    Events.sessionStart,
    Events.sessionEnd,
    Events.sessionUpdate,
    Events.triggerFired,
    Events.captureStarted,
    Events.configApplied,
    Events.collectionHealth,
]

/// Maps a log record's event name to the signal whose settings govern it.
/// A log line has no event name; `browser.console` is the browser SDK's
/// console record.
func classifyLog(_ eventName: String?) -> String {
    switch eventName {
    case Events.exception?: return "errors"
    case Events.message?: return "messages"
    case "browser.console"?, nil, ""?: return "console"
    case Events.navigation?: return "navigation"
    case Events.click?: return "userActions"
    case "browser.web_vital"?: return "webVitals"
    case "browser.resource_timing"?, "browser.navigation_timing"?: return "resourceTiming"
    case let name?: return controlEvents.contains(name) ? signalControl : "custom"
    }
}

/// Whether a log record belongs to Traceway even when ordinary logs go to
/// another receiver: exceptions and messages (the issues), and the SDK's
/// control records.
func isTracewayLog(_ eventName: String?) -> Bool {
    let signal = classifyLog(eventName)
    return signal == "errors" || signal == "messages" || signal == signalControl
}

private let severityNumbers: [String: Int] = [
    "trace": 1, "debug": 5, "info": 9, "warn": 13, "error": 17, "fatal": 21,
]

func severityNumber(of name: String) -> Int { severityNumbers[name] ?? 0 }
