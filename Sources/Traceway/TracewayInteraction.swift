import Foundation
import OpenTelemetryApi

/// One user action traced from start to end, e.g. a checkout: a span named
/// after it (`traceway.interaction: true`) that the requests made in `run`
/// are children of, and that the exceptions, messages and logs recorded in
/// `run` point to. Start one with `Traceway.startInteraction("checkout")`
/// and `end` it when the action is over.
///
/// ```swift
/// let checkout = Traceway.startInteraction("checkout")
/// do {
///     try checkout.run { try api.placeOrder(cart) }
/// } catch {
///     checkout.captureException(error)
/// }
/// checkout.end()
/// ```
///
/// Before the SDK has started, or once it has shut down, an interaction
/// records nothing; `run` still runs its code. Thread-safe.
public final class TracewayInteraction {
    private let span: Span?
    private weak var client: TracewayClient?
    private let lock = NSLock()
    private var failed = false
    private var ended = false

    init(span: Span?, client: TracewayClient?) {
        self.span = span
        self.client = client
    }

    /// The trace this interaction starts (32 hex digits), or nil when it
    /// records nothing.
    public var traceId: String? { span?.context.traceId.hexString }

    /// The interaction's own span id (16 hex digits), or nil.
    public var spanId: String? { span?.context.spanId.hexString }

    /// Whether `end` was called.
    public var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    /// Runs `body` as part of this interaction: requests it starts are child
    /// spans of it, and exceptions, messages and logs it records carry its
    /// trace. An interaction started inside is its child.
    @discardableResult
    public func run<T>(_ body: () throws -> T) rethrows -> T {
        guard let span = span else { return try body() }
        return try OpenTelemetry.instance.contextProvider.withActiveSpan(span, body)
    }

    /// Runs async `body` as part of this interaction, until it returns.
    @available(iOS 13.0, macOS 10.15, *)
    @discardableResult
    public func run<T>(_ body: () async throws -> T) async rethrows -> T {
        guard let span = span else { return try await body() }
        return try await OpenTelemetry.instance.contextProvider.withActiveSpan(span, body)
    }

    /// Sets an attribute on the interaction's span. Strings, booleans and
    /// numbers keep their type; anything else is described as a string.
    public func setAttribute(_ key: String, _ value: Any) {
        guard let span = span, !key.isEmpty, !isEnded else { return }
        span.setAttribute(key: key, value: TracewayClient.attribute(value))
    }

    /// Reports `error` as an exception of this interaction and marks the
    /// interaction failed: the exception carries its trace.
    @inline(never)
    public func captureException(_ error: Error, attributes: [String: String] = [:]) {
        let stack = Array(Thread.callStackReturnAddresses.map { UInt(truncating: $0) }.dropFirst(1))
        lock.lock()
        failed = true
        lock.unlock()
        run { client?.captureException(error, callStack: stack, attributes: attributes) }
    }

    /// Ends the interaction; only the first call counts. `failed` marks it
    /// failed even without a `captureException`.
    public func end(failed: Bool = false) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        let isFailed = self.failed || failed
        lock.unlock()
        guard let span = span else { return }
        span.status = isFailed ? .error(description: "failed") : .ok
        span.end()
    }
}
