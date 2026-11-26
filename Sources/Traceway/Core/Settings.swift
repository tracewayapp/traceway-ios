import Foundation

// The collection settings document. The server sends a partial overlay of it
// over OpAMP (`config_map["traceway"]`); the SDK merges that onto its built-in
// defaults and clamps the result to the ceilings set at start. The schema,
// signal names, triggers and limits are the browser and Flutter SDKs', so one
// rule can target all of them.

/// `off` drops a signal, `buffer` keeps it on the device until a trigger or
/// capture flushes it, `stream` sends it.
enum Mode: Int, Comparable {
    case off = 0
    case buffer = 1
    case stream = 2

    init?(name: JSON?) {
        switch name?.string {
        case "off": self = .off
        case "buffer": self = .buffer
        case "stream": self = .stream
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .off: return "off"
        case .buffer: return "buffer"
        case .stream: return "stream"
        }
    }

    static func < (a: Mode, b: Mode) -> Bool { a.rawValue < b.rawValue }
}

func lowerMode(_ a: Mode, _ b: Mode) -> Mode { min(a, b) }

/// Signal names are shared with the browser SDK so one settings schema
/// serves every platform. `webVitals`, `resourceTiming`, `longTasks` and
/// `routeTiming` have no iOS source; they are known only so documents naming
/// them apply.
let signalNames: [String] = [
    "errors",
    "messages",
    "network",
    "console",
    "navigation",
    "userActions",
    "webVitals",
    "resourceTiming",
    "longTasks",
    "routeTiming",
    "custom",
]

let severityNames: [String] = ["trace", "debug", "info", "warn", "error", "fatal"]

struct SignalSettings: Equatable {
    var mode: Mode
    var sampleRate: Double = 1
    /// Console only: records below it are dropped.
    var minSeverity: String?
}

/// A condition on a field of a record, such as
/// `{"key": "event.name", "op": "eq", "value": "exception"}`.
struct Condition: Equatable {
    var key: String
    var op: String
    /// A string, number or boolean.
    var value: JSON?
    var values: [JSON]?

    func toJSON() -> JSON {
        var out: [String: JSON] = ["key": .string(key), "op": .string(op)]
        if let value = value { out["value"] = value }
        if let values = values { out["values"] = .array(values) }
        return .object(out)
    }
}

/// A step of a recorded journey: a tap (`click`), a pointer entering a view
/// (`hover`), a screen the app arrived at (`navigation`) or a log line
/// (`log`). Click and hover values are selectors over the view hierarchy,
/// see `ViewSelector`; navigation values are paths with optional `{param}`
/// segments.
struct EventMatcher: Equatable {
    /// `click`, `hover`, `navigation` or `log`.
    var type: String
    var value: String
    /// `exact` (default) or `contains`, for `log`.
    var mode: String?

    func toJSON() -> JSON {
        var event: [String: JSON] = ["type": .string(type), "value": .string(value)]
        if let mode = mode { event["mode"] = .string(mode) }
        return ["event": .object(event)]
    }
}

indirect enum Matcher: Equatable {
    case condition(Condition)
    case event(EventMatcher)
    case all([Matcher])
    case any([Matcher])
    case not(Matcher)

    func toJSON() -> JSON {
        switch self {
        case .condition(let c): return c.toJSON()
        case .event(let e): return e.toJSON()
        case .all(let items): return ["all": .array(items.map { $0.toJSON() })]
        case .any(let items): return ["any": .array(items.map { $0.toJSON() })]
        case .not(let inner): return ["not": inner.toJSON()]
        }
    }
}

/// One action of a trigger. `type` is `flush`, `stream`, `startReplay`,
/// `emit` or `capture`; the other fields apply as the type needs them.
struct TriggerAction: Equatable {
    var type: String
    var lookbackSeconds: Double?
    var durationSeconds: Double?
    /// `nil` means every signal; an empty list means none.
    var signals: [String]?
    var replay: Bool = false
    var eventName: String?
    var attributes: [String: String]?

    func toJSON() -> JSON {
        var out: [String: JSON] = ["type": .string(type)]
        if let v = lookbackSeconds { out["lookbackSeconds"] = .number(v) }
        if let v = durationSeconds { out["durationSeconds"] = .number(v) }
        if let v = signals { out["signals"] = JSON(v) }
        if replay { out["replay"] = true }
        if let v = eventName { out["eventName"] = .string(v) }
        if let v = attributes, !v.isEmpty { out["attributes"] = JSON(v) }
        return .object(out)
    }
}

struct TriggerStep: Equatable {
    var match: Matcher
    /// Longest gap allowed since the previous step; nil means no limit.
    var withinSeconds: Double?
    /// Matching records needed before the step completes. Default 1.
    var count: Int?
    /// With `count`: all of them within this many seconds of each other.
    var periodSeconds: Double?

    func toJSON() -> JSON {
        var out: [String: JSON] = [
            "match": match.toJSON(),
            "withinSeconds": withinSeconds.map { .number($0) } ?? .null,
        ]
        if let count = count {
            out["count"] = JSON(count)
            out["periodSeconds"] = periodSeconds.map { .number($0) } ?? .null
        }
        return .object(out)
    }
}

struct Trigger: Equatable {
    var id: String
    var name: String?
    var enabled: Bool?
    var sampleRate: Double?
    var cooldownSeconds: Double?
    var maxPerSession: Int?
    var steps: [TriggerStep]
    var actions: [TriggerAction]

    /// Changes whenever the steps or actions do, so progress made under an
    /// older version of a trigger is not carried over.
    var signature: String {
        JSON.array([
            .array(steps.map { $0.toJSON() }),
            .array(actions.map { $0.toJSON() }),
        ]).encoded(sortedKeys: true)
    }

    func stepsJSON() -> JSON { .array(steps.map { $0.toJSON() }) }
}

/// An on-demand capture requested from the dashboard; only the server
/// creates these.
struct Capture: Equatable {
    var id: String
    var until: Date
    var lookbackSeconds: Double?
    var signals: [String]?
    var replay: Bool = false
}

struct Settings: Equatable {
    /// Kill switch: when false nothing but the OpAMP poll leaves the device.
    var enabled: Bool
    var signals: [String: SignalSettings]
    var sessionsEnabled: Bool
    var baselineSampleRate: Double
    var replayMode: Mode
    var replaySessionSampleRate: Double
    /// Wireframe recordings mask what is typed into text fields
    /// (`replay.maskAllInputs`, as in the browser SDK).
    var replayMaskAllInputs: Bool = true
    var bufferMaxBytes: Int
    var bufferMaxAgeSeconds: Double
    var persist: Bool
    var triggers: [Trigger]
    var captures: [Capture]

    func signal(_ name: String) -> SignalSettings {
        signals[name] ?? SignalSettings(mode: .off)
    }
}

/// The most a signal may do in this app, set from the start options. Remote
/// settings can only go lower.
struct Ceilings: Equatable {
    var enabled: Bool
    var signals: [String: Mode]
    /// `.off` when screen capture is not allowed.
    var replay: Mode
    var sessions: Bool

    func signal(_ name: String) -> Mode { signals[name] ?? .off }
}

let defaultExceptionTriggerId = "default-exception"

/// Lookback of the default replay clip. The frame ring buffer holds less
/// than this, so the clip is always "everything the buffer has".
let defaultReplayLookbackSeconds: Double = 30

func defaultExceptionTrigger() -> Trigger {
    Trigger(
        id: defaultExceptionTriggerId,
        name: "Error clip",
        enabled: true,
        sampleRate: 1,
        cooldownSeconds: 5,
        maxPerSession: 20,
        steps: [
            TriggerStep(match: .condition(Condition(key: "event.name", op: "eq", value: "exception"))),
        ],
        actions: [
            TriggerAction(type: "flush", lookbackSeconds: 600, signals: ["*"]),
            TriggerAction(
                type: "flush",
                lookbackSeconds: defaultReplayLookbackSeconds,
                signals: [],
                replay: true
            ),
        ]
    )
}

/// The built-in collection policy, the same as the browser and Flutter
/// SDKs': errors and messages stream, breadcrumbs and replay stay on the
/// device until an error or a capture asks for them. `recordAllSessions`
/// streams breadcrumbs and replay instead.
func defaultSettings(baselineSampleRate: Double = 0, recordAllSessions: Bool = false) -> Settings {
    let breadcrumbs: Mode = recordAllSessions ? .stream : .buffer
    let baseline = baselineSampleRate.isFinite ? min(max(baselineSampleRate, 0), 1) : 0
    return Settings(
        enabled: true,
        signals: [
            "errors": SignalSettings(mode: .stream),
            "messages": SignalSettings(mode: .stream),
            "network": SignalSettings(mode: breadcrumbs),
            "console": SignalSettings(mode: breadcrumbs, minSeverity: "info"),
            "navigation": SignalSettings(mode: breadcrumbs),
            "userActions": SignalSettings(mode: breadcrumbs),
            "webVitals": SignalSettings(mode: .buffer),
            "resourceTiming": SignalSettings(mode: .off),
            "longTasks": SignalSettings(mode: .off),
            "routeTiming": SignalSettings(mode: .off),
            "custom": SignalSettings(mode: breadcrumbs),
        ],
        sessionsEnabled: true,
        baselineSampleRate: baseline,
        replayMode: recordAllSessions ? .stream : .buffer,
        replaySessionSampleRate: 1,
        bufferMaxBytes: 2 * 1024 * 1024,
        bufferMaxAgeSeconds: 600,
        persist: true,
        triggers: [defaultExceptionTrigger()],
        captures: []
    )
}

func ceilingsFrom(
    enabled: Bool = true,
    screenCapture: Bool = false,
    captureLogs: Bool = true,
    captureNetwork: Bool = true,
    captureNavigation: Bool = true,
    captureUserActions: Bool = true,
    sessions: Bool = true
) -> Ceilings {
    func allow(_ flag: Bool) -> Mode { flag ? .stream : .off }
    var signals: [String: Mode] = [:]
    for name in signalNames { signals[name] = .stream }
    signals["console"] = allow(captureLogs)
    signals["network"] = allow(captureNetwork)
    signals["navigation"] = allow(captureNavigation)
    signals["userActions"] = allow(captureUserActions)
    return Ceilings(
        enabled: enabled,
        signals: signals,
        replay: allow(screenCapture),
        sessions: sessions
    )
}
