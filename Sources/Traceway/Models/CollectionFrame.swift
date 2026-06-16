import Foundation

/// A batch of telemetry uploaded together. The iOS SDK only ever populates
/// `stackTraces`; `metrics` and `traces` are always emitted as empty arrays for
/// wire parity, and `sessionRecordings` is omitted entirely (no replay).
struct CollectionFrame {
    let stackTraces: [ExceptionStackTrace]

    func toJSON() -> JSONValue {
        .object([
            ("stackTraces", .array(stackTraces.map { $0.toJSON() })),
            ("metrics", .array([])),
            ("traces", .array([])),
        ])
    }
}
