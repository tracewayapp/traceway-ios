import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

// What is installed once per process (the URLSession instrumentation, the
// global OpenTelemetry providers) must not hold one client's tracer or
// logger: after that client's `shutdown` they record nothing, and a client
// started later would never see the app's requests, spans or logs. These
// look up the running client on each use instead.

/// A tracer that makes its spans with the tracer `resolve` returns now, or
/// with a no-op one while no client runs.
final class CurrentClientTracer: Tracer {
    private let resolve: () -> Tracer?

    init(_ resolve: @escaping () -> Tracer?) {
        self.resolve = resolve
    }

    func spanBuilder(spanName: String) -> SpanBuilder {
        (resolve() ?? DefaultTracer.instance).spanBuilder(spanName: spanName)
    }
}

/// The global tracer provider while the app has none of its own.
final class CurrentClientTracerProvider: TracerProvider {
    func get(
        instrumentationName: String,
        instrumentationVersion: String?,
        schemaUrl: String?,
        attributes: [String: AttributeValue]?
    ) -> any Tracer {
        CurrentClientTracer {
            TracewayClient.shared?.tracerProvider?.get(
                instrumentationName: instrumentationName,
                instrumentationVersion: instrumentationVersion,
                schemaUrl: schemaUrl,
                attributes: attributes
            )
        }
    }
}

/// The global logger provider while the app has none of its own.
final class CurrentClientLoggerProvider: LoggerProvider, @unchecked Sendable {
    func get(instrumentationScopeName: String) -> Logger {
        loggerBuilder(instrumentationScopeName: instrumentationScopeName).build()
    }

    func loggerBuilder(instrumentationScopeName: String) -> LoggerBuilder {
        CurrentClientLoggerBuilder(scope: instrumentationScopeName)
    }
}

final class CurrentClientLoggerBuilder: LoggerBuilder {
    private let scope: String
    private var version: String?
    private var schemaUrl: String?
    private var includeTraceContext: Bool?
    private var attributes: [String: AttributeValue]?

    init(scope: String) {
        self.scope = scope
    }

    /// Event domains are deprecated in OpenTelemetry; records name their
    /// event themselves.
    @available(*, deprecated, message: "Event domain is deprecated. Use event_name field directly.")
    func setEventDomain(_ eventDomain: String) -> Self { self }

    func setSchemaUrl(_ schemaUrl: String) -> Self {
        self.schemaUrl = schemaUrl
        return self
    }

    func setInstrumentationVersion(_ instrumentationVersion: String) -> Self {
        version = instrumentationVersion
        return self
    }

    func setIncludeTraceContext(_ includeTraceContext: Bool) -> Self {
        self.includeTraceContext = includeTraceContext
        return self
    }

    func setAttributes(_ attributes: [String: AttributeValue]) -> Self {
        self.attributes = attributes
        return self
    }

    func build() -> Logger {
        let scope = self.scope, version = self.version, schemaUrl = self.schemaUrl
        let includeTraceContext = self.includeTraceContext, attributes = self.attributes
        return CurrentClientLogger { provider in
            var builder = provider.loggerBuilder(instrumentationScopeName: scope)
            if let version = version { builder = builder.setInstrumentationVersion(version) }
            if let schemaUrl = schemaUrl { builder = builder.setSchemaUrl(schemaUrl) }
            if let include = includeTraceContext { builder = builder.setIncludeTraceContext(include) }
            if let attributes = attributes { builder = builder.setAttributes(attributes) }
            return builder.build()
        }
    }
}

/// A logger whose records go to the running client's logger provider,
/// nowhere while none runs. The logger made for a provider is kept until
/// the client changes.
final class CurrentClientLogger: Logger {
    private let make: (LoggerProvider) -> Logger
    private let lock = NSLock()
    private var cached: (provider: ObjectIdentifier, logger: Logger)?

    init(_ make: @escaping (LoggerProvider) -> Logger) {
        self.make = make
    }

    private func current() -> Logger {
        guard let provider = TracewayClient.shared?.loggerProvider else {
            return DefaultLoggerProvider.instance.get(instrumentationScopeName: "")
        }
        let id = ObjectIdentifier(provider)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached, cached.provider == id { return cached.logger }
        let logger = make(provider)
        cached = (id, logger)
        return logger
    }

    @available(*, deprecated, message: "Use logRecordBuilder() and setEventName(_:) instead")
    func eventBuilder(name: String) -> EventBuilder {
        current().eventBuilder(name: name)
    }

    func logRecordBuilder() -> LogRecordBuilder {
        current().logRecordBuilder()
    }
}

enum CurrentClientProviders {
    private static let lock = NSLock()
    private static var registered = false

    /// Makes the SDK the app's global OpenTelemetry providers, once per
    /// process, where the app has not registered its own.
    static func registerGlobally() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true
        if OpenTelemetry.instance.loggerProvider is DefaultLoggerProvider {
            OpenTelemetry.registerLoggerProvider(loggerProvider: CurrentClientLoggerProvider())
        }
        if OpenTelemetry.instance.tracerProvider is DefaultTracerProvider {
            OpenTelemetry.registerTracerProvider(tracerProvider: CurrentClientTracerProvider())
        }
    }
}
