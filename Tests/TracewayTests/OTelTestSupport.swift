// OpenTelemetry exporters in memory for the client tests. Not built into the
// iOS Simulator test bundle (see project.yml): it cannot link the
// OpenTelemetry symbols of its host app, so the client suite runs under
// `swift test` on macOS and Linux.
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import Traceway

/// Collects exported log records.
final class MemoryLogExporter: LogRecordExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [ReadableLogRecord] = []

    var records: [ReadableLogRecord] {
        lock.lock(); defer { lock.unlock() }
        return _records
    }

    func events(_ name: String) -> [ReadableLogRecord] { records.filter { $0.eventName == name } }

    /// `Traceway.log` lines: records without an event name.
    var consoleLines: [ReadableLogRecord] { records.filter { $0.eventName == nil || $0.eventName == "" } }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        lock.lock()
        _records.append(contentsOf: logRecords)
        lock.unlock()
        return .success
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

/// Collects exported spans.
final class MemorySpanExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _spans: [SpanData] = []

    var spans: [SpanData] {
        lock.lock(); defer { lock.unlock() }
        return _spans
    }

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        lock.lock()
        _spans.append(contentsOf: spans)
        lock.unlock()
        return .success
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

extension ReadableLogRecord {
    func string(_ key: String) -> String? {
        if case .string(let value)? = attributes[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let value)? = attributes[key] { return value }
        return nil
    }
}
