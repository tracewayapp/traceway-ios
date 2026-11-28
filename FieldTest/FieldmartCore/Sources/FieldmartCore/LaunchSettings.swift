import Foundation

/// The launch settings of `02-APP-SPEC.md` §6. On iOS they arrive as launch
/// arguments (`-fmRun x -fmVariant stream-img …`), which `UserDefaults`
/// exposes in its argument domain; the app passes a lookup over it.
///
/// iOS additions, all optional: `fmMarkers` (a host path the app also
/// appends its marker lines to, for the UI test driver), `fmCampaign` and
/// `fmTarget` (the `fm.campaign` and `fm.target` attributes).
public struct LaunchSettings: Equatable {
    public var run: String
    public var variant: String
    public var scenario: String?
    public var baseUrl: String
    public var fixtures: String
    public var token: String
    public var evidence: Bool
    public var fps: Int?
    public var chart: String
    public var toolkit: FeedToolkit
    public var remote: Bool
    public var autopilot: Bool
    public var markersPath: String?
    public var campaign: String
    public var target: String?

    public static let defaultBaseUrl = "http://127.0.0.1:18190"
    public static let defaultFixtures = "http://127.0.0.1:18190/fx"
    public static let defaultToken = "ios-dev-token"

    public init(
        run: String = "manual",
        variant: String = "core",
        scenario: String? = nil,
        baseUrl: String = LaunchSettings.defaultBaseUrl,
        fixtures: String = LaunchSettings.defaultFixtures,
        token: String = LaunchSettings.defaultToken,
        evidence: Bool = false,
        fps: Int? = nil,
        chart: String = "canvas",
        toolkit: FeedToolkit = .uikit,
        remote: Bool = false,
        autopilot: Bool = false,
        markersPath: String? = nil,
        campaign: String = "manual",
        target: String? = nil
    ) {
        self.run = run
        self.variant = variant
        self.scenario = scenario
        self.baseUrl = baseUrl
        self.fixtures = fixtures
        self.token = token
        self.evidence = evidence
        self.fps = fps
        self.chart = chart
        self.toolkit = toolkit
        self.remote = remote
        self.autopilot = autopilot
        self.markersPath = markersPath
        self.campaign = campaign
        self.target = target
    }

    /// Reads every key through `lookup` (nil or blank: the default).
    public init(lookup: (String) -> String?) {
        func value(_ key: String) -> String? {
            guard let raw = lookup(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }
        func flag(_ key: String) -> Bool {
            guard let raw = value(key)?.lowercased() else { return false }
            return raw == "1" || raw == "true" || raw == "yes"
        }
        self.init()
        if let run = value("fmRun"), LaunchSettings.isValidRunId(run) { self.run = run }
        if let variant = value("fmVariant") { self.variant = variant }
        scenario = value("fmScenario")
        if let base = value("fmBaseUrl") { baseUrl = base }
        if let fx = value("fmFixtures") { fixtures = fx }
        if let token = value("fmToken") { self.token = token }
        evidence = flag("fmEvidence")
        if let raw = value("fmFps"), let fps = Int(raw), fps > 0 { self.fps = fps }
        if let chart = value("fmChart") { self.chart = chart }
        if let raw = value("fmToolkit"), let toolkit = FeedToolkit(rawValue: raw.lowercased()) { self.toolkit = toolkit }
        remote = flag("fmRemote")
        autopilot = flag("fmAutopilot")
        markersPath = value("fmMarkers")
        if let campaign = value("fmCampaign") { self.campaign = campaign }
        target = value("fmTarget")
    }

    /// Parses `-key value` pairs as a process's arguments carry them.
    public init(arguments: [String]) {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg.hasPrefix("-"), arg.count > 1, index + 1 < arguments.count {
                values[String(arg.dropFirst())] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        self.init(lookup: { values[$0] })
    }

    /// Letters, digits and dashes only (`05-RESULTS-FORMAT.md` §1).
    public static func isValidRunId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "-"
        }
    }

    /// The fixture base without a trailing slash.
    public var fixturesBase: String {
        var base = fixtures
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// `fm.*` attributes every SDK record carries.
    public func attributes(target defaultTarget: String) -> [String: String] {
        var attrs: [String: String] = [
            "fm.run": run,
            "fm.variant": variant,
            "fm.target": target ?? defaultTarget,
            "fm.campaign": campaign,
        ]
        attrs["fm.scenario"] = scenario ?? "none"
        return attrs
    }

    /// What the SDK-on build starts with for this variant
    /// (`03-MEASUREMENT.md` §1.4).
    public var sdkPlan: SDKPlan {
        SDKPlan.forVariant(variant, evidence: evidence, remote: remote, fps: fps)
    }
}

/// Which Feed implementation the app shows (`fmToolkit`).
public enum FeedToolkit: String, CaseIterable {
    /// `UITableView`, the default.
    case uikit
    /// A SwiftUI `List`.
    case swiftui
    /// A non-lazy `UIStackView` of 5,000 rows inside a `UIScrollView` (H-I2).
    case stack
}

/// The SDK options a variant asks for, as plain data (the app maps them to
/// `TracewayOptions`).
public struct SDKPlan: Equatable {
    /// Whether the variant starts the SDK at all (false for unknown names
    /// only; `off` builds never link it).
    public var known: Bool
    public var screenCapture: Bool
    public var recordAllSessions: Bool
    /// `collection.replay.images`; nil leaves the SDK default (`wifi`).
    public var replayImages: String?
    public var debug: Bool
    public var remoteConfig: Bool
    public var fps: Int?

    public static let version = "fieldtest-2.1.0"
    public static let environment = "fieldtest"

    public static func forVariant(_ variant: String, evidence: Bool, remote: Bool, fps: Int?) -> SDKPlan {
        var plan = SDKPlan(known: true, screenCapture: false, recordAllSessions: false, replayImages: nil,
                           debug: evidence, remoteConfig: remote, fps: fps)
        switch variant {
        case "core":
            break
        case "buffer":
            plan.screenCapture = true
            plan.replayImages = "always"
        case "buffer-nopin":
            // The default image policy (`wifi`, decided by NWPathMonitor).
            plan.screenCapture = true
        case "stream-img":
            plan.screenCapture = true
            plan.recordAllSessions = true
            plan.replayImages = "always"
        case "stream-noimg":
            plan.screenCapture = true
            plan.recordAllSessions = true
            plan.replayImages = "off"
        default:
            plan.known = false
        }
        return plan
    }

    /// The `collection` option, or nil when the variant leaves it alone.
    public var collection: [String: Any]? {
        guard let images = replayImages else { return nil }
        return ["replay": ["images": images]]
    }
}
