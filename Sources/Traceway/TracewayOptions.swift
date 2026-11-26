import Foundation

/// Options for `Traceway.start`. The `capture*` options, `screenCapture` and
/// `sessions` are ceilings: remote settings from the dashboard can lower what
/// is collected but never raise it. `sampleRate`, `baselineSampleRate` and
/// `recordAllSessions` are defaults a rule can change either way.
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

    /// Stream breadcrumbs and the screen recording all the time instead of
    /// keeping them for errors.
    public var recordAllSessions: Bool
    /// Share of sessions whose breadcrumbs are sent continuously.
    public var baselineSampleRate: Double
    /// Send session records (`session.start` / `session.end`). The session
    /// id exists either way.
    public var sessions: Bool
    /// Poll the server for collection settings over OpAMP.
    public var remoteConfig: Bool
    /// Local collection settings: the same document a Data Collection rule
    /// holds, laid over the built-in defaults. Values must be JSON types.
    public var collection: [String: Any]?
    /// How long finished records wait to be sent as one batch.
    public var exportDelayMs: Int
    /// URL prefixes whose requests carry a W3C `traceparent` header naming
    /// the request's client span, so backend spans join the app's trace.
    public var propagateTraceHeaderUrls: [String]
    /// Send ordinary logs and spans to another OTLP/HTTP receiver as well,
    /// or only there when the SDK runs without a connection string.
    public var telemetry: TracewayTelemetry?

    public init(
        sampleRate: Double = 1.0,
        debug: Bool = false,
        version: String = "",
        serviceName: String? = nil,
        environment: String? = nil,
        attributes: [String: String] = [:],
        screenCapture: Bool = false,
        fps: Int = 4,
        maxBufferFrames: Int = 150,
        persistToDisk: Bool = true,
        captureLogs: Bool = true,
        captureNetwork: Bool = true,
        captureNavigation: Bool = true,
        captureUserActions: Bool = true,
        recordAllSessions: Bool = false,
        baselineSampleRate: Double = 0,
        sessions: Bool = true,
        remoteConfig: Bool = true,
        collection: [String: Any]? = nil,
        exportDelayMs: Int = 1000,
        propagateTraceHeaderUrls: [String] = [],
        telemetry: TracewayTelemetry? = nil
    ) {
        self.sampleRate = sampleRate
        self.debug = debug
        self.version = version
        self.serviceName = serviceName
        self.environment = environment
        self.attributes = attributes
        self.screenCapture = screenCapture
        self.fps = fps
        self.maxBufferFrames = maxBufferFrames
        self.persistToDisk = persistToDisk
        self.captureLogs = captureLogs
        self.captureNetwork = captureNetwork
        self.captureNavigation = captureNavigation
        self.captureUserActions = captureUserActions
        self.recordAllSessions = recordAllSessions
        self.baselineSampleRate = baselineSampleRate
        self.sessions = sessions
        self.remoteConfig = remoteConfig
        self.collection = collection
        self.exportDelayMs = exportDelayMs
        self.propagateTraceHeaderUrls = propagateTraceHeaderUrls
        self.telemetry = telemetry
    }
}

/// Another OTLP/HTTP receiver (an OpenTelemetry Collector, Grafana,
/// Honeycomb, ...). The shared `url` gets `/v1/logs` and `/v1/traces`
/// appended; a per-signal endpoint is a complete URL, used as given. With a
/// connection string, exceptions, messages and the SDK's session and control
/// records still go to Traceway only, as do OpAMP and screen recordings.
public struct TracewayTelemetry {
    public var url: String?
    public var headers: [String: String]
    public var logs: TracewayTelemetryEndpoint?
    public var traces: TracewayTelemetryEndpoint?

    public init(
        url: String? = nil,
        headers: [String: String] = [:],
        logs: TracewayTelemetryEndpoint? = nil,
        traces: TracewayTelemetryEndpoint? = nil
    ) {
        self.url = url
        self.headers = headers
        self.logs = logs
        self.traces = traces
    }

    var coversAllSignals: Bool { url != nil || (logs != nil && traces != nil) }
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

/// Severity of a `Traceway.log` line.
public enum TracewayLogSeverity: String {
    case trace, debug, info, warn, error, fatal
}
