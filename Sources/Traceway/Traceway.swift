import Foundation
import OpenTelemetryApi

/// The Traceway SDK for iOS: errors and crashes, the breadcrumbs that led
/// to them and a wireframe replay of the screen, built on OpenTelemetry and
/// controlled from the dashboard over OpAMP.
///
/// ```swift
/// Traceway.initialize(
///     connectionString: "your-token@https://traceway.example.com",
///     options: TracewayOptions(screenCapture: true)
/// )
/// ```
public enum Traceway {

    /// Starts the SDK; call it as early as possible (the `App` initializer
    /// or `application(_:didFinishLaunchingWithOptions:)`). The connection
    /// string is `{token}@{server URL}`; the 1.x form ending in `/api/report`
    /// still works. Without one, the SDK runs standalone and sends everything
    /// to `options.telemetry`. Returns nil, and logs why, when the settings
    /// are invalid: the app runs without the SDK.
    ///
    /// The other Traceway SDKs call this `init` (Flutter: `run`); Swift keeps
    /// that name for initializers.
    @discardableResult
    public static func initialize(
        connectionString: String?,
        options: TracewayOptions = TracewayOptions()
    ) -> TracewayClient? {
        do {
            return try TracewayClient.start(connectionString: connectionString, options: options)
        } catch {
            NSLog("[Traceway] not started: %@", "\(error)")
            return nil
        }
    }

    @available(*, deprecated, renamed: "initialize(connectionString:options:)")
    @discardableResult
    public static func start(
        connectionString: String?,
        options: TracewayOptions = TracewayOptions()
    ) -> TracewayClient? {
        initialize(connectionString: connectionString, options: options)
    }

    /// The running client, or nil before `initialize`.
    public static var client: TracewayClient? { TracewayClient.shared }

    // MARK: - Errors and messages

    /// Reports a caught error as an issue, with the stack of the caller and
    /// the screen it happened on.
    @inline(never)
    public static func captureException(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.captureException(error, callStack: stack, attributes: attributes)
    }

    /// Reports a message as an issue.
    public static func captureMessage(_ message: String, attributes: [String: String] = [:]) {
        TracewayClient.shared?.captureMessage(message, attributes: attributes)
    }

    @available(*, deprecated, renamed: "captureException(_:attributes:)")
    @inline(never)
    public static func capture(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.captureException(error, callStack: stack, attributes: attributes)
    }

    @available(*, deprecated, renamed: "captureException(_:attributes:)")
    @inline(never)
    public static func capture(error: NSError, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.captureException(error as Error, callStack: stack, attributes: attributes)
    }

    @available(*, deprecated, renamed: "captureMessage(_:attributes:)")
    public static func capture(message: String, attributes: [String: String] = [:]) {
        TracewayClient.shared?.captureMessage(message, attributes: attributes)
    }

    // MARK: - Logs, actions and events

    /// A log line on the session timeline (signal `console`) at `level`,
    /// filtered by the console's `minSeverity` setting.
    public static func log(_ message: String, level: TracewayLogLevel = .info, attributes: [String: String] = [:]) {
        TracewayClient.shared?.log(message, level: level, attributes: attributes)
    }

    @available(*, deprecated, renamed: "log(_:level:attributes:)")
    public static func log(_ message: String, severity: TracewayLogLevel) {
        TracewayClient.shared?.log(message, level: severity)
    }

    /// A named product event, e.g. `checkout_failed`; triggers can match it.
    public static func track(_ eventName: String, attributes: [String: Any] = [:]) {
        TracewayClient.shared?.track(eventName, attributes: attributes)
    }

    /// A custom breadcrumb on the session timeline.
    public static func recordAction(category: String, name: String, data: [String: Any]? = nil) {
        TracewayClient.shared?.recordAction(category: category, name: name, data: data)
    }

    // MARK: - Screens

    /// Records that the app shows `path`, for SwiftUI navigation and routers
    /// no view controller reports. Navigation triggers match it. `action`
    /// is `push` or `pop`; `from` is the screen left, when known; `route` is
    /// the screen's route template (`/orders/:id`) when the router knows it,
    /// the same as calling `setRoute(_:)` right after.
    public static func recordNavigation(_ path: String, action: String = "push", from: String? = nil,
                                        route: String? = nil) {
        TracewayClient.shared?.recordNavigation(path, action: action, from: from, route: route)
    }

    /// Names the current screen by its route template (`/orders/{id}`), so
    /// issues carry it (`app.screen.route`) and metrics group by it. Lasts
    /// until the app reaches another screen; nil removes it.
    public static func setRoute(_ template: String?) {
        TracewayClient.shared?.setRoute(template)
    }

    // MARK: - Metrics

    /// The screen on top shows everything it loads (data, images): ends its
    /// time to full display (`app.screen.ttfd`).
    public static func reportFullyDisplayed() {
        TracewayClient.shared?.reportFullyDisplayed()
    }

    /// Observes `value` of an app-defined distribution, e.g.
    /// `checkout.duration` in ms, charted like the built-in metrics. Names
    /// are `[a-z][a-z0-9_.]`, up to 63 characters, outside `app.`,
    /// `browser.`, `traceway.` and `custom.`; at most two dimensions.
    public static func metric(_ name: String, value: Double, dimensions: [String: Any] = [:]) {
        TracewayClient.shared?.metric(name, value: value, dimensions: dimensions)
    }

    /// Adds `n` to an app-defined counter, e.g. `cart.add`.
    public static func count(_ name: String, n: Double = 1, dimensions: [String: Any] = [:]) {
        TracewayClient.shared?.count(name, n: n, dimensions: dimensions)
    }

    /// Sets an app-defined dimension on every metric from now on
    /// (`custom.<key>`), at most two keys; nil removes it.
    public static func setMetricDimension(_ key: String, _ value: String?) {
        TracewayClient.shared?.setMetricDimension(key, value)
    }

    // MARK: - Interactions

    /// Starts an interaction named `name` (`checkout`, `search`): a span the
    /// requests made in its `run` are children of, and that the exceptions
    /// and logs recorded there point to. Call `end()` when the action is
    /// over. Before `initialize` it records nothing.
    public static func startInteraction(_ name: String, attributes: [String: Any] = [:]) -> TracewayInteraction {
        TracewayClient.shared?.startInteraction(name, attributes: attributes)
            ?? TracewayInteraction(span: nil, client: nil)
    }

    // MARK: - Attributes

    /// An attribute attached to every later record, usable to target this
    /// user or device from the dashboard (`user.id`, a plan, a cohort).
    public static func setAttribute(_ key: String, _ value: String) {
        TracewayClient.shared?.setAttribute(key, value)
    }

    public static func setAttributes(_ attributes: [String: String]) {
        TracewayClient.shared?.setAttributes(attributes)
    }

    public static func removeAttribute(_ key: String) {
        TracewayClient.shared?.removeAttribute(key)
    }

    public static func clearAttributes() {
        TracewayClient.shared?.clearAttributes()
    }

    // MARK: - Delivery

    /// Sends what is ready now, waiting at most `timeout` seconds (nil waits
    /// until done). Breadcrumbs held in the ring buffer stay there.
    public static func flush(timeout: TimeInterval? = nil) {
        TracewayClient.shared?.flush(timeout: timeout)
    }

    /// Flushes and stops the SDK.
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
