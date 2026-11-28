import Foundation

/// `shared/journey.json` (`02-APP-SPEC.md` §5): every scenario as timed
/// steps. Unknown fields are ignored and unknown step kinds are kept (with
/// their name) so a driver can log and skip them.
public struct Journey: Decodable {
    public var version: Int
    public var viewport: Viewport?
    public var rules: Rules?
    public var scenarios: [String: Scenario]

    /// The journey's timing rules (shared version 1: lateMs 1500, revealMs 900 …).
    public struct Rules: Decodable, Equatable {
        public var lateMs: Int?
        public var defaultSettleMs: Int?
        public var checkpointCaptureMs: Int?
        public var revealMs: Int?
        public var perCharMs: Int?
    }

    /// The late limit: `rules.lateMs`, else 1,500 ms.
    public var lateMs: Int { rules?.lateMs ?? Int(StepTiming.lateLimitMs) }

    public struct Viewport: Decodable, Equatable {
        public var width: Double
        public var height: Double
    }

    public static func load(_ data: Data) throws -> Journey {
        try JSONDecoder().decode(Journey.self, from: data)
    }

    /// The scenario named `name`: the exact key, else the one key that is
    /// `name` followed by `-…` (`S5` finds `S5-checkout`).
    public func scenario(named name: String) -> (key: String, scenario: Scenario)? {
        if let exact = scenarios[name] { return (name, exact) }
        let matches = scenarios.keys.filter { $0.hasPrefix(name + "-") }.sorted()
        if matches.count == 1, let key = matches.first, let found = scenarios[key] { return (key, found) }
        let lower = name.lowercased()
        if let key = scenarios.keys.sorted().first(where: { $0.lowercased() == lower }), let found = scenarios[key] {
            return (key, found)
        }
        return nil
    }

    /// Every id the journey touches or checks, sorted.
    public var ids: [String] {
        var all = Set<String>()
        for scenario in scenarios.values {
            for step in scenario.steps {
                if let id = step.id { all.insert(id) }
                for id in step.masked ?? [] { all.insert(id) }
            }
        }
        return all.sorted()
    }
}

public struct Scenario: Decodable {
    public var launch: String?
    public var start: String?
    public var durationMs: Int
    public var steps: [Step]
    /// Extra launch settings the scenario asks for (`fmToolkit`, `fmChart`, `fmRemote`).
    public var settings: [String: String]?
    /// The platforms the scenario exists on (nil: all).
    public var platforms: [String]?
    /// The variant an S7 part runs in (`buffer`, `stream-img`).
    public var variant: String?
    public var measured: Bool?
    /// `close-now` replaces the standard ending (browser only).
    public var ending: String?

    enum CodingKeys: String, CodingKey {
        case launch, start, durationMs, steps, settings, launchSettings, platforms, variant, measured, ending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launch = try? container.decodeIfPresent(String.self, forKey: .launch)
        start = try? container.decodeIfPresent(String.self, forKey: .start)
        durationMs = try container.decode(Int.self, forKey: .durationMs)
        steps = try container.decode([Step].self, forKey: .steps)
        settings = (try? container.decodeIfPresent([String: String].self, forKey: .launchSettings))
            ?? (try? container.decodeIfPresent([String: String].self, forKey: .settings))
        platforms = try? container.decodeIfPresent([String].self, forKey: .platforms)
        variant = try? container.decodeIfPresent(String.self, forKey: .variant)
        measured = try? container.decodeIfPresent(Bool.self, forKey: .measured)
        ending = try? container.decodeIfPresent(String.self, forKey: .ending)
    }

    /// Whether the scenario exists on `platform` (`ios`).
    public func exists(on platform: String) -> Bool {
        platforms.map { $0.contains(platform) } ?? true
    }

    /// The steps that run on `platform`.
    public func steps(on platform: String) -> [Step] {
        steps.filter { $0.runs(on: platform) }
    }

    public var checkpoints: [Step] { steps.filter { $0.action == .checkpoint } }

    /// The time the last step ends, by its own duration.
    public var lastStepEndMs: Int {
        steps.map { $0.t + $0.nominalDurationMs }.max() ?? 0
    }
}

/// A point inside an element as fractions of its size, written `[x, y]` or
/// `{"x": …, "y": …}`.
public struct FractionPoint: Decodable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            x = try array.decode(Double.self)
            y = try array.decode(Double.self)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
    }
}

public struct Step: Decodable {
    public enum Action: Equatable {
        case waitFor, tap, longPress, fling, drag, type, paste, key, pick, idle
        case background, foreground, checkpoint, mark, fault, kill, relaunch, release
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "waitFor": self = .waitFor
            case "tap": self = .tap
            case "longPress": self = .longPress
            case "fling": self = .fling
            case "drag": self = .drag
            case "type": self = .type
            case "paste": self = .paste
            case "key": self = .key
            case "pick": self = .pick
            case "idle": self = .idle
            case "background": self = .background
            case "foreground": self = .foreground
            case "checkpoint": self = .checkpoint
            case "mark": self = .mark
            case "fault": self = .fault
            case "kill": self = .kill
            case "relaunch": self = .relaunch
            case "release": self = .release
            default: self = .other(raw)
            }
        }

        public var name: String {
            switch self {
            case .waitFor: return "waitFor"
            case .tap: return "tap"
            case .longPress: return "longPress"
            case .fling: return "fling"
            case .drag: return "drag"
            case .type: return "type"
            case .paste: return "paste"
            case .key: return "key"
            case .pick: return "pick"
            case .idle: return "idle"
            case .background: return "background"
            case .foreground: return "foreground"
            case .checkpoint: return "checkpoint"
            case .mark: return "mark"
            case .fault: return "fault"
            case .kill: return "kill"
            case .relaunch: return "relaunch"
            case .release: return "release"
            case .other(let raw): return raw
            }
        }
    }

    public var t: Int
    public var action: Action
    public var id: String?
    public var timeoutMs: Int?
    public var ms: Int?
    public var dir: String?
    public var distance: Double?
    public var durationMs: Int?
    public var from: FractionPoint?
    public var to: FractionPoint?
    public var text: String?
    public var perCharMs: Int?
    public var name: String?
    public var value: String?
    public var shows: [String]?
    public var hides: [String]?
    public var masked: [String]?
    public var settleMs: Int?
    public var mode: String?
    public var seconds: Double?
    public var holdMs: Int?
    /// Bring the element fully into view first (with a drag of its scroll
    /// container, after dismissing a keyboard that covers it).
    public var reveal: Bool?
    /// The field a `type` or `paste` goes into.
    public var into: String?
    /// A `drag` that leaves the finger down until the next `release`.
    public var hold: Bool?
    /// A checkpoint taken during a gesture (`drag`: the finger is down).
    public var during: String?
    /// The kind of overlay a checkpoint shows (`sheet`, `dialog`, `menu`, `picker`, `toast`).
    public var overlay: String?
    /// The list a checkpoint's first and last visible rows are taken from.
    public var list: String?
    /// The screen a checkpoint is on.
    public var screen: String?
    /// The platforms the step runs on (nil: all).
    public var platforms: [String]?

    enum CodingKeys: String, CodingKey {
        case t, action = "do", id, timeoutMs, ms, dir, distance, durationMs, from, to, text, perCharMs, name
        case value, shows, hides, masked, settleMs, mode, seconds, holdMs
        case reveal, into, hold, during, overlay, list, screen, platforms
    }

    public init(t: Int, action: Action, id: String? = nil, name: String? = nil) {
        self.t = t
        self.action = action
        self.id = id
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Int.self, forKey: .t)
        action = Action(try c.decode(String.self, forKey: .action))
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        timeoutMs = try? c.decodeIfPresent(Int.self, forKey: .timeoutMs)
        ms = try? c.decodeIfPresent(Int.self, forKey: .ms)
        dir = try? c.decodeIfPresent(String.self, forKey: .dir)
        distance = try? c.decodeIfPresent(Double.self, forKey: .distance)
        durationMs = try? c.decodeIfPresent(Int.self, forKey: .durationMs)
        from = try? c.decodeIfPresent(FractionPoint.self, forKey: .from)
        to = try? c.decodeIfPresent(FractionPoint.self, forKey: .to)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        perCharMs = try? c.decodeIfPresent(Int.self, forKey: .perCharMs)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        // `pick` values may be numbers ("value": 14) as well as strings.
        if let string = try? c.decodeIfPresent(String.self, forKey: .value) {
            value = string
        } else if let number = try? c.decodeIfPresent(Double.self, forKey: .value) {
            value = number == number.rounded() ? String(Int(number)) : String(number)
        }
        shows = try? c.decodeIfPresent([String].self, forKey: .shows)
        hides = try? c.decodeIfPresent([String].self, forKey: .hides)
        masked = try? c.decodeIfPresent([String].self, forKey: .masked)
        settleMs = try? c.decodeIfPresent(Int.self, forKey: .settleMs)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        seconds = try? c.decodeIfPresent(Double.self, forKey: .seconds)
        holdMs = try? c.decodeIfPresent(Int.self, forKey: .holdMs)
        reveal = try? c.decodeIfPresent(Bool.self, forKey: .reveal)
        into = try? c.decodeIfPresent(String.self, forKey: .into)
        hold = try? c.decodeIfPresent(Bool.self, forKey: .hold)
        during = try? c.decodeIfPresent(String.self, forKey: .during)
        overlay = try? c.decodeIfPresent(String.self, forKey: .overlay)
        list = try? c.decodeIfPresent(String.self, forKey: .list)
        screen = try? c.decodeIfPresent(String.self, forKey: .screen)
        platforms = try? c.decodeIfPresent([String].self, forKey: .platforms)
    }

    /// Whether the step runs on `platform` (`ios`).
    public func runs(on platform: String) -> Bool {
        platforms.map { $0.contains(platform) } ?? true
    }

    /// A date value: `+14d` (days from `start`), else `yyyy-MM-dd`.
    public static func dayOffset(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("d") else { return Int(trimmed) }
        var digits = trimmed.dropLast()
        if digits.hasPrefix("+") { digits = digits.dropFirst() }
        return Int(digits)
    }

    /// How long the step takes by its own fields (typing: characters × delay).
    public var nominalDurationMs: Int {
        switch action {
        case .type: return (text?.count ?? 0) * (perCharMs ?? 120)
        case .idle: return ms ?? 0
        case .longPress: return ms ?? 800
        case .fling, .drag: return (durationMs ?? 300) + (holdMs ?? 0)
        case .checkpoint: return settleMs ?? 400
        default: return 0
        }
    }

    /// `settleMs`, 400 by default.
    public var settle: Int { settleMs ?? 400 }
}

/// Lateness bookkeeping shared by the drivers: a step starts at T0 + t,
/// never earlier; more than 1,500 ms late marks the run `late`.
public struct StepTiming: Equatable {
    public static let lateLimitMs: Int64 = 1500

    public var index: Int
    public var action: String
    public var dueEpochMs: Int64
    public var startEpochMs: Int64
    public var endEpochMs: Int64

    public init(index: Int, action: String, dueEpochMs: Int64, startEpochMs: Int64, endEpochMs: Int64) {
        self.index = index
        self.action = action
        self.dueEpochMs = dueEpochMs
        self.startEpochMs = startEpochMs
        self.endEpochMs = endEpochMs
    }

    public var lateMs: Int64 { max(0, startEpochMs - dueEpochMs) }
    public var isLate: Bool { lateMs > StepTiming.lateLimitMs }
}
