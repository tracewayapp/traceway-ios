import Foundation

/// Options for `Traceway.initialize`. The `capture*` options, `screenCapture`,
/// `replayImages` and `sessions` are ceilings: remote settings from the
/// dashboard can lower what is collected but never raise it. `sampleRate`,
/// `baselineSampleRate` and `recordAllSessions` are defaults a rule can
/// change either way. The order is the same in every Traceway mobile SDK.
public struct TracewayOptions {
    /// Share of exceptions and messages that are reported (0.0–1.0).
    public var sampleRate: Double
    /// Log SDK activity with `NSLog`.
    public var debug: Bool
    /// App version, sent as `service.version`. Empty uses the bundle's
    /// `CFBundleShortVersionString`.
    public var version: String
    /// Sent as `service.name`. Nil uses the bundle identifier.
    public var serviceName: String?
    /// Sent as `deployment.environment.name`.
    public var environment: String?
    /// Attributes attached to every record.
    public var attributes: [String: String]

    /// Record the screen as a wireframe: the last seconds go up with an
    /// exception, and captures can stream it.
    public var screenCapture: Bool
    /// The most the replay may do with the pictures image views show: never
    /// (`.off`), on an unmetered connection (`.wifi`) or on any
    /// (`.always`). The remote setting `replay.images` (`wifi` by default)
    /// lowers it, never raises it. Without it, images are placeholders.
    public var replayImages: TracewayImagePolicy
    /// Most wireframe frames captured per second (1–15). A frame is kept
    /// only when the screen changed.
    public var fps: Int
    /// Frames in the recording ring; the upper bound of every clip.
    public var maxBufferFrames: Int

    /// Keep SDK state and undelivered telemetry on disk across restarts,
    /// and record hard crashes (signal handlers write them to disk).
    public var persistToDisk: Bool
    /// Record `Traceway.log` lines (signal `console`).
    public var captureLogs: Bool
    /// Record URLSession requests as client spans (signal `network`).
    public var captureNetwork: Bool
    /// Record screens as they appear: view controllers, and
    /// `Traceway.recordNavigation` (signal `navigation`).
    public var captureNavigation: Bool
    /// Record taps with the selector of the view that handled them, and feed
    /// them to recording triggers (signal `userActions`).
    public var captureUserActions: Bool
    /// Measure app start, screen display times, slow and frozen frames,
    /// hangs, crashes, sessions, users, memory and requests, and upload them
    /// as OTLP metrics (see `Traceway.metric`). A ceiling: a rule's
    /// `metrics` section can switch them off or sample them, never on.
    public var captureMetrics: Bool
    /// Up to two app-defined dimensions on every metric (`custom.<key>`);
    /// `Traceway.setMetricDimension` changes them later. Keys are lowercase
    /// `[a-z][a-z0-9_]`, up to 32 characters; values are cut at 64.
    public var metricDimensions: [String: String]

    /// Stream breadcrumbs and the screen recording all the time instead of
    /// keeping them for errors.
    public var recordAllSessions: Bool
    /// Local collection settings: the same document a Data Collection rule
    /// holds, laid over the built-in defaults. Values must be JSON types.
    public var collection: [String: Any]?
    /// Send session records (`session.start` / `session.end`). The session
    /// id exists either way.
    public var sessions: Bool
    /// Share of sessions whose breadcrumbs are sent continuously.
    public var baselineSampleRate: Double
    /// Poll the server for collection settings over OpAMP.
    public var remoteConfig: Bool
    /// How long finished records wait to be sent as one batch.
    public var exportDelayMs: Int
    /// Send ordinary logs and spans to another OTLP/HTTP receiver as well,
    /// or only there when the SDK runs without a connection string.
    public var telemetry: TracewayTelemetry?
    /// URL prefixes whose requests carry a W3C `traceparent` header naming
    /// the request's client span, so backend spans join the app's trace.
    public var propagateTraceHeaderUrls: [String]
    /// Exceptions and messages that are not reported, matched against their
    /// first line `Type: message` (never the stack frames). Nil uses
    /// `TracewayOptions.defaultIgnoreErrors`; `[]` reports everything.
    public var ignoreErrors: [TracewayErrorPattern]?
    /// Sees every exception and message before it is recorded; returning
    /// false drops it. Runs on the thread that captured it. A callback that
    /// throws keeps the record (and logs why with `debug`).
    public var beforeCapture: ((TracewayCapturedError) throws -> Bool)?
    /// Report hangs (`app.hang`) while a debugger is attached too. Off by
    /// default: a breakpoint or a step in the debugger stops the main thread
    /// exactly like a hang does, and there is no telling them apart. Turn it
    /// on to test hang reporting from Xcode.
    public var reportHangsInDebug: Bool

    public init(
        sampleRate: Double = 1.0,
        debug: Bool = false,
        version: String = "",
        serviceName: String? = nil,
        environment: String? = nil,
        attributes: [String: String] = [:],
        screenCapture: Bool = false,
        replayImages: TracewayImagePolicy = .always,
        fps: Int = 4,
        maxBufferFrames: Int = 150,
        persistToDisk: Bool = true,
        captureLogs: Bool = true,
        captureNetwork: Bool = true,
        captureNavigation: Bool = true,
        captureUserActions: Bool = true,
        captureMetrics: Bool = true,
        metricDimensions: [String: String] = [:],
        recordAllSessions: Bool = false,
        collection: [String: Any]? = nil,
        sessions: Bool = true,
        baselineSampleRate: Double = 0,
        remoteConfig: Bool = true,
        exportDelayMs: Int = 1000,
        telemetry: TracewayTelemetry? = nil,
        propagateTraceHeaderUrls: [String] = [],
        ignoreErrors: [TracewayErrorPattern]? = nil,
        beforeCapture: ((TracewayCapturedError) throws -> Bool)? = nil,
        reportHangsInDebug: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.debug = debug
        self.version = version
        self.serviceName = serviceName
        self.environment = environment
        self.attributes = attributes
        self.screenCapture = screenCapture
        self.replayImages = replayImages
        self.fps = fps
        self.maxBufferFrames = maxBufferFrames
        self.persistToDisk = persistToDisk
        self.captureLogs = captureLogs
        self.captureNetwork = captureNetwork
        self.captureNavigation = captureNavigation
        self.captureUserActions = captureUserActions
        self.captureMetrics = captureMetrics
        self.metricDimensions = metricDimensions
        self.recordAllSessions = recordAllSessions
        self.collection = collection
        self.sessions = sessions
        self.baselineSampleRate = baselineSampleRate
        self.remoteConfig = remoteConfig
        self.exportDelayMs = exportDelayMs
        self.telemetry = telemetry
        self.propagateTraceHeaderUrls = propagateTraceHeaderUrls
        self.ignoreErrors = ignoreErrors
        self.beforeCapture = beforeCapture
        self.reportHangsInDebug = reportHangsInDebug
    }

    /// What is not reported unless `ignoreErrors` says otherwise: a phone
    /// losing its connection, a request timing out or a server answering
    /// 4xx is the network's doing, not a bug in the app. URL errors
    /// -1001 (timed out), -1003 (host not found), -1004 (cannot connect),
    /// -1005 (connection lost) and -1009 (offline), in the form an `NSError`
    /// or a `URLError` renders its first line.
    public static let defaultIgnoreErrors: [TracewayErrorPattern] = [
        .regex(#"NSURLErrorDomain\b.*(?:\(code |Code=)-10(?:01|03|04|05|09)\b"#),
        "The network connection was lost",
        "The Internet connection appears to be offline",
        .regex("timeout", options: [.caseInsensitive]),
        .regex(#"status code (of )?4\d{2}"#),
        .regex(#"failed: 4\d{2}"#),
    ]
}

/// Another OTLP/HTTP receiver (an OpenTelemetry Collector, Grafana,
/// Honeycomb, ...). The shared `url` gets `/v1/logs`, `/v1/traces` and
/// `/v1/metrics` appended; a per-signal endpoint is a complete URL, used as
/// given. Without a shared `url`, the signals not listed keep their Traceway
/// destination. With a connection string, exceptions, messages and the SDK's
/// session and control records still go to Traceway only, as do OpAMP and
/// screen recordings. The Traceway token is never sent to these receivers.
public struct TracewayTelemetry {
    public var url: String?
    public var headers: [String: String]
    public var logs: TracewayTelemetryEndpoint?
    public var traces: TracewayTelemetryEndpoint?
    public var metrics: TracewayTelemetryEndpoint?

    public init(
        url: String? = nil,
        headers: [String: String] = [:],
        logs: TracewayTelemetryEndpoint? = nil,
        traces: TracewayTelemetryEndpoint? = nil,
        metrics: TracewayTelemetryEndpoint? = nil
    ) {
        self.url = url
        self.headers = headers
        self.logs = logs
        self.traces = traces
        self.metrics = metrics
    }

    /// The shared url; a blank one is unset, as in the browser and Android
    /// SDKs.
    var baseURL: String? {
        url.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Whether every signal has a destination here, as standalone mode needs.
    var coversAllSignals: Bool { baseURL != nil || (logs != nil && traces != nil && metrics != nil) }
}

public struct TracewayTelemetryEndpoint {
    /// The complete signal URL; no path is appended.
    public var url: String
    /// Override the shared headers key by key.
    public var headers: [String: String]

    public init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// The level of a `Traceway.log` line: its OpenTelemetry severity, and what
/// the console's `minSeverity` setting compares.
public enum TracewayLogLevel: String, CaseIterable {
    case trace, debug, info, warn, error, fatal
}

@available(*, deprecated, renamed: "TracewayLogLevel")
public typealias TracewayLogSeverity = TracewayLogLevel

/// When the replay records the pictures image views show, ordered
/// `off < wifi < always`. `wifi` means an unmetered connection: cellular,
/// a personal hotspot and Low Data Mode count as metered.
public enum TracewayImagePolicy: String, CaseIterable, Comparable {
    case off, wifi, always

    private var rank: Int {
        switch self {
        case .off: return 0
        case .wifi: return 1
        case .always: return 2
        }
    }

    public static func < (lhs: TracewayImagePolicy, rhs: TracewayImagePolicy) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Whether a picture may be recorded now, on a connection that is
    /// unmetered or not. Decided at capture time.
    func allowsCapture(unmetered: Bool) -> Bool {
        switch self {
        case .off: return false
        case .wifi: return unmetered
        case .always: return true
        }
    }
}
