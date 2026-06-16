import Foundation

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
