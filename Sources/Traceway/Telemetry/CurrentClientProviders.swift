import Foundation
import OpenTelemetryApi

// What is installed once per process (the URLSession instrumentation) must
// not hold one client's tracer: after that client's `shutdown` it records
// nothing, and a client started later would never see the app's requests.
// This looks up the running client on each use instead. Traceway never
// registers itself as the global OpenTelemetry (`OpenTelemetry.instance`).

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
