import Foundation
import OpenTelemetryApi

/// The Traceway SDK for iOS: errors and crashes, the breadcrumbs that led
/// to them and a wireframe replay of the screen, built on OpenTelemetry and
/// controlled from the dashboard over OpAMP.
///
/// ```swift
/// Traceway.start(
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
    @discardableResult
    public static func start(
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

    /// The running client, or nil before `start`.
    public static var client: TracewayClient? { TracewayClient.shared }

    /// Captures a caught error with the stack of the caller.
    @inline(never)
    public static func capture(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.captureException(error, callStack: stack, attributes: attributes)
    }

    @inline(never)
    public static func capture(error: NSError, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        TracewayClient.shared?.captureException(error as Error, callStack: stack, attributes: attributes)
    }

    /// Reports a message as an issue.
    public static func capture(message: String, attributes: [String: String] = [:]) {
        TracewayClient.shared?.captureMessage(message, attributes: attributes)
    }

    /// A named product event, e.g. `checkout_failed`; triggers can match it.
    public static func track(_ eventName: String, attributes: [String: Any] = [:]) {
        TracewayClient.shared?.track(eventName, attributes: attributes)
    }

    /// A custom breadcrumb on the session timeline.
    public static func recordAction(category: String, name: String, data: [String: Any]? = nil) {
        TracewayClient.shared?.recordAction(category: category, name: name, data: data)
    }

    /// A log line on the session timeline (signal `console`).
    public static func log(_ message: String, severity: TracewayLogSeverity = .info) {
        TracewayClient.shared?.log(message, severity: severity)
    }

    /// Records that the app shows `path`, for SwiftUI navigation and routers
    /// no view controller reports. Navigation triggers match it.
    public static func recordNavigation(_ path: String) {
        TracewayClient.shared?.recordNavigation(path)
    }

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

    /// The id this installation reports (`service.instance.id`), usable to
    /// target it from the dashboard.
    public static var instanceId: String? { TracewayClient.shared?.instanceId }

    /// The current session id.
    public static var sessionId: String? { TracewayClient.shared?.currentSessionId }

    /// The OpenTelemetry tracer of this installation, for spans of your own.
    public static var tracer: Tracer? { TracewayClient.shared?.openTelemetryTracer }
}
