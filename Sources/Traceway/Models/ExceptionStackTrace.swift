import Foundation

/// A single captured exception/crash, in the Traceway wire shape.
///
/// Reference type (class) because the client mutates `attributes`/`fileId`
/// after construction and tracks identity in its pending list — mirroring the
/// Android `ExceptionStackTrace`.
final class ExceptionStackTrace {
    var stackTrace: String
    var recordedAtMs: Int64
    var traceId: String?
    var isTask: Bool
    var attributes: [String: String]?
    var isMessage: Bool
    var sessionRecordingId: String?
    var distributedTraceId: String?

    /// Transient id of the on-disk file backing this record. Never serialized
    /// to the API; used to delete the file once the record is uploaded.
    var fileId: String?

    init(
        stackTrace: String,
        recordedAtMs: Int64,
        traceId: String? = nil,
        isTask: Bool = false,
        attributes: [String: String]? = nil,
        isMessage: Bool = false,
        sessionRecordingId: String? = nil,
        distributedTraceId: String? = nil,
        fileId: String? = nil
    ) {
        self.stackTrace = stackTrace
        self.recordedAtMs = recordedAtMs
        self.traceId = traceId
        self.isTask = isTask
        self.attributes = attributes
        self.isMessage = isMessage
        self.sessionRecordingId = sessionRecordingId
        self.distributedTraceId = distributedTraceId
        self.fileId = fileId
    }

    /// The wire JSON. Key order and literal-`null` semantics match the Android
    /// contract exactly (`null`-valued ids are emitted, not omitted).
    func toJSON() -> JSONValue {
        .object([
            ("traceId", traceId.map { .string($0) } ?? .null),
            ("isTask", .bool(isTask)),
            ("stackTrace", .string(stackTrace)),
            ("recordedAt", .string(ISO8601.format(millis: recordedAtMs))),
            ("attributes", JSONValue.stringMap(attributes ?? [:])),
            ("isMessage", .bool(isMessage)),
            ("sessionRecordingId", sessionRecordingId.map { .string($0) } ?? .null),
            ("distributedTraceId", distributedTraceId.map { .string($0) } ?? .null),
        ])
    }

    /// Reconstructs a record from a parsed JSON object (disk persistence).
    static func from(jsonObject obj: [String: Any]) -> ExceptionStackTrace {
        var attrs: [String: String]?
        if let raw = obj["attributes"] as? [String: Any], !raw.isEmpty {
            var map: [String: String] = [:]
            for (key, value) in raw {
                map[key] = (value as? String) ?? String(describing: value)
            }
            attrs = map
        }
        return ExceptionStackTrace(
            stackTrace: obj["stackTrace"] as? String ?? "",
            recordedAtMs: ISO8601.parseMillis(obj["recordedAt"] as? String ?? ""),
            traceId: (obj["traceId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isTask: obj["isTask"] as? Bool ?? false,
            attributes: attrs,
            isMessage: obj["isMessage"] as? Bool ?? false,
            sessionRecordingId: (obj["sessionRecordingId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            distributedTraceId: (obj["distributedTraceId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
