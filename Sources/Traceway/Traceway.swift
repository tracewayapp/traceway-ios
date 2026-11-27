import Foundation
import OpenTelemetryApi

/// The Traceway SDK for iOS: errors and crashes, the breadcrumbs that led
/// to them and a wireframe replay of the screen, built on OpenTelemetry and
/// controlled from the dashboard over OpAMP.
///
/// ```swift
/// Traceway.initialize(token: "YOUR_TOKEN", options: TracewayOptions(screenCapture: true))
/// ```
public enum Traceway {

    /// Traceway Cloud: where the SDK sends when `initialize` gets no
    /// `baseUrl`.
    public static let defaultBaseUrl = "https://cloud.tracewayapp.com"

    /// Starts the SDK; call it as early as possible (the `App` initializer
    /// or `application(_:didFinishLaunchingWithOptions:)`). `token` is the
    /// project token from the project's Connection page (whitespace around
    /// it is ignored). `baseUrl` is the Traceway server, needed only for a
    /// self-hosted one: Traceway Cloud when nil or blank; a URL without a
    /// scheme gets `https://`, and an `/api` or `/api/report` the 2.0
    /// connection strings ended in is dropped. Without a token (nil or
    /// blank, as in `Traceway.initialize(options: …)`) the SDK runs
    /// standalone and sends everything to `options.telemetry`. Returns nil,
    /// and logs why, when the settings are invalid: the app runs without the
    /// SDK. Never throws or traps.
    ///
    /// The other Traceway SDKs call this `init` (Flutter: `run`); Swift keeps
    /// that name for initializers.
    @discardableResult
    public static func initialize(
        token: String? = nil,
        baseUrl: String? = nil,
        options: TracewayOptions = TracewayOptions()
    ) -> TracewayClient? {
        begin(token: token, baseUrl: baseUrl, options: options)
    }

    /// Starts the SDK from a 2.0 connection string,
    /// `token@https://host[/api[/report]]`: the same as
    /// `initialize(token:baseUrl:options:)` with its token and server (any
    /// `/api` or `/api/report` dropped, `https://` added when there is no
    /// scheme), with one warning per process that names the new form. A nil
    /// connection string starts standalone.
    @available(*, deprecated, message: "Pass the token: Traceway.initialize(token: \"YOUR_TOKEN\"), plus baseUrl: for a self-hosted server")
    @discardableResult
    public static func initialize(
        connectionString: String?,
        options: TracewayOptions = TracewayOptions()
    ) -> TracewayClient? {
        begin(connectionString: connectionString, options: options)
    }

    @available(*, deprecated, message: "Pass the token: Traceway.initialize(token: \"YOUR_TOKEN\"), plus baseUrl: for a self-hosted server")
    @discardableResult
    public static func start(
        connectionString: String?,
        options: TracewayOptions = TracewayOptions()
    ) -> TracewayClient? {
        begin(connectionString: connectionString, options: options)
    }

    /// `initialize(token:baseUrl:options:)`, with the test seams.
    static func begin(token: String?, baseUrl: String?, options: TracewayOptions,
                      overrides: TracewayTestOverrides? = nil) -> TracewayClient? {
        do {
            return try TracewayClient.start(token: token, baseUrl: baseUrl, options: options, overrides: overrides)
        } catch {
            Log.warn("not started: \(error)")
            return nil
        }
    }

    /// The deprecated connection-string entry points, with the test seams.
    static func begin(connectionString: String?, options: TracewayOptions,
                      overrides: TracewayTestOverrides? = nil) -> TracewayClient? {
        guard let connectionString = connectionString else {
            return begin(token: nil, baseUrl: nil, options: options, overrides: overrides)
        }
        let parsed: ParsedConnectionString
        do {
            parsed = try parseConnectionString(connectionString)
        } catch {
            Log.warn("not started: \(error)")
            return nil
        }
        // Never the token itself.
        let server = parsed.baseUrl == defaultBaseUrl ? "" : ", baseUrl: \"\(parsed.baseUrl)\""
        Log.once("connection string", "connection strings are deprecated; start with "
            + "Traceway.initialize(token: \"YOUR_TOKEN\"\(server))")
        return begin(token: parsed.token, baseUrl: parsed.baseUrl, options: options, overrides: overrides)
    }

    /// The running client. Before any `initialize`, one line per process
    /// says that `method` records nothing (after a `shutdown`, the app chose
    /// it: nothing is said).
    private static func running(_ method: String) -> TracewayClient? {
        if let client = TracewayClient.shared { return client }
        if !TracewayClient.everStarted {
            Log.once("before initialize", "Traceway.\(method) was called before Traceway.initialize, so nothing is "
                + "recorded. Call Traceway.initialize in your App's init or in "
                + "application(_:didFinishLaunchingWithOptions:).")
        }
        return nil
    }

    /// The running client, or nil before `initialize`.
    public static var client: TracewayClient? { TracewayClient.shared }

    // MARK: - Errors and messages

    /// Reports a caught error as an issue, with the stack of the caller and
    /// the screen it happened on.
    @inline(never)
    public static func captureException(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        running("captureException")?.captureException(error, callStack: stack, attributes: attributes)
    }

    /// Reports a message as an issue.
    public static func captureMessage(_ message: String, attributes: [String: String] = [:]) {
        running("captureMessage")?.captureMessage(message, attributes: attributes)
    }

    @available(*, deprecated, renamed: "captureException(_:attributes:)")
    @inline(never)
    public static func capture(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        running("captureException")?.captureException(error, callStack: stack, attributes: attributes)
    }

    @available(*, deprecated, renamed: "captureException(_:attributes:)")
    @inline(never)
    public static func capture(error: NSError, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        running("captureException")?.captureException(error as Error, callStack: stack, attributes: attributes)
    }

    @available(*, deprecated, renamed: "captureMessage(_:attributes:)")
    public static func capture(message: String, attributes: [String: String] = [:]) {
        running("captureMessage")?.captureMessage(message, attributes: attributes)
    }

    // MARK: - Logs, actions and events

    /// A log line on the session timeline (signal `console`) at `level`,
    /// filtered by the console's `minSeverity` setting.
    public static func log(_ message: String, level: TracewayLogLevel = .info, attributes: [String: String] = [:]) {
        running("log")?.log(message, level: level, attributes: attributes)
    }

    @available(*, deprecated, renamed: "log(_:level:attributes:)")
    public static func log(_ message: String, severity: TracewayLogLevel) {
        running("log")?.log(message, level: severity)
    }

    /// A named product event, e.g. `checkout_failed`; triggers can match it.
    public static func track(_ eventName: String, attributes: [String: Any] = [:]) {
        running("track")?.track(eventName, attributes: attributes)
    }

    /// A custom breadcrumb on the session timeline.
    public static func recordAction(category: String, name: String, data: [String: Any]? = nil) {
        running("recordAction")?.recordAction(category: category, name: name, data: data)
    }

    // MARK: - Screens

    /// Records that the app shows `path`, for SwiftUI navigation and routers
    /// no view controller reports. Navigation triggers match it. `action`
    /// is `push` or `pop`; `from` is the screen left, when known; `route` is
    /// the screen's route template (`/orders/:id`) when the router knows it,
    /// the same as calling `setRoute(_:)` right after.
    public static func recordNavigation(_ path: String, action: String = "push", from: String? = nil,
                                        route: String? = nil) {
        running("recordNavigation")?.recordNavigation(path, action: action, from: from, route: route)
    }

    /// Names the current screen by its route template (`/orders/:id`), so
    /// issues carry it (`app.screen.route`) and metrics group by it. Lasts
    /// until the app reaches another screen; nil removes it.
    public static func setRoute(_ template: String?) {
        running("setRoute")?.setRoute(template)
    }

    // MARK: - Metrics

    /// The screen on top shows everything it loads (data, images): ends its
    /// time to full display (`app.screen.ttfd`).
    public static func reportFullyDisplayed() {
        running("reportFullyDisplayed")?.reportFullyDisplayed()
    }

    /// Observes `value` of an app-defined distribution, e.g.
    /// `checkout.duration` in ms, charted like the built-in metrics. Names
    /// are `[a-z][a-z0-9_.]`, up to 63 characters, outside `app.`,
    /// `browser.`, `traceway.` and `custom.`; at most two dimensions.
    public static func metric(_ name: String, value: Double, dimensions: [String: Any] = [:]) {
        running("metric")?.metric(name, value: value, dimensions: dimensions)
    }

    /// Adds `n` to an app-defined counter, e.g. `cart.add`.
    public static func count(_ name: String, n: Double = 1, dimensions: [String: Any] = [:]) {
        running("count")?.count(name, n: n, dimensions: dimensions)
    }

    /// Sets an app-defined dimension on every metric from now on
    /// (`custom.<key>`), at most two keys; nil removes it.
    public static func setMetricDimension(_ key: String, _ value: String?) {
        running("setMetricDimension")?.setMetricDimension(key, value)
    }

    // MARK: - Interactions

    /// Starts an interaction named `name` (`checkout`, `search`): a span the
    /// requests made in its `run` are children of, and that the exceptions
    /// and logs recorded there point to. Call `end()` when the action is
    /// over. Before `initialize` it records nothing.
    public static func startInteraction(_ name: String, attributes: [String: Any] = [:]) -> TracewayInteraction {
        running("startInteraction")?.startInteraction(name, attributes: attributes)
            ?? TracewayInteraction(span: nil, client: nil)
    }

    // MARK: - Attributes

    /// An attribute attached to every later record, usable to target this
    /// user or device from the dashboard (`user.id`, a plan, a cohort).
    public static func setAttribute(_ key: String, _ value: String) {
        running("setAttribute")?.setAttribute(key, value)
    }

    public static func setAttributes(_ attributes: [String: String]) {
        running("setAttributes")?.setAttributes(attributes)
    }

    public static func removeAttribute(_ key: String) {
        running("removeAttribute")?.removeAttribute(key)
    }

    public static func clearAttributes() {
        running("clearAttributes")?.clearAttributes()
    }

    // MARK: - Delivery

    /// Sends what is ready now, waiting at most `timeout` seconds (10 by
    /// default, as on Android; nil waits until done). Breadcrumbs held in the
    /// ring buffer stay there.
    public static func flush(timeout: TimeInterval? = 10) {
        TracewayClient.shared?.flush(timeout: timeout)
    }

    /// Flushes and stops the SDK, waiting up to 10 seconds.
    public static func shutdown() {
        TracewayClient.shared?.shutdown()
    }

    /// Asks the server for collection settings now.
    public static func refreshConfig() {
        TracewayClient.shared?.refreshConfig()
    }

    // MARK: - Identity

    /// The id this installation reports (`service.instance.id`), usable to
    /// target it from the dashboard.
    public static var instanceId: String? { TracewayClient.shared?.instanceId }

    /// The current session id (`session.id`), or nil before `initialize`.
    public static var currentSessionId: String? { TracewayClient.shared?.currentSessionId }

    @available(*, deprecated, renamed: "currentSessionId")
    public static var sessionId: String? { TracewayClient.shared?.currentSessionId }

    /// The OpenTelemetry tracer of this installation, for spans of your own.
    public static var tracer: Tracer? { TracewayClient.shared?.openTelemetryTracer }
}
