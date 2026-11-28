// OpenTelemetry records and OTLP decoding for the exporter, outbox and
// buffer suites. Like OTelTestSupport.swift, left out of the iOS Simulator
// bundle (it cannot link the host app's OpenTelemetry symbols); these suites
// run under `swift test` on macOS and Linux.
#if !os(iOS)
import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk
import SwiftProtobuf
@testable import Traceway

let testResource = Resource(attributes: [
    "service.name": .string("test-app"),
    "service.version": .string("1.0"),
])

let testScope = InstrumentationScopeInfo(name: "traceway-ios", version: "2.0.0")

/// A log record as the SDK hands it to an exporter.
func logRecord(
    _ body: String,
    event: String? = nil,
    atMs: Int64 = 1_700_000_000_000,
    severity: Severity = .info,
    attributes: [String: AttributeValue] = [:],
    resource: Resource = testResource
) -> ReadableLogRecord {
    ReadableLogRecord(
        resource: resource,
        instrumentationScopeInfo: testScope,
        timestamp: Clock.date(ms: atMs),
        observedTimestamp: Clock.date(ms: atMs),
        spanContext: nil,
        severity: severity,
        body: .string(body),
        attributes: attributes,
        eventName: event
    )
}

private final class EndedSpans: SpanProcessor {
    var spans: [SpanData] = []
    var isStartRequired: Bool { false }
    var isEndRequired: Bool { true }
    func onStart(parentContext: SpanContext?, span: ReadableSpan) {}
    func onEnd(span: ReadableSpan) { spans.append(span.toSpanData()) }
    func shutdown(explicitTimeout: TimeInterval?) {}
    func forceFlush(timeout: TimeInterval?) {}
}

/// An ended client span of 50 ms.
func endedSpan(
    _ name: String,
    endMs: Int64 = 1_700_000_000_000,
    attributes: [String: AttributeValue] = [:],
    resource: Resource = testResource
) -> SpanData {
    let ended = EndedSpans()
    let provider = TracerProviderBuilder().with(resource: resource).add(spanProcessor: ended).build()
    let builder = provider.get(instrumentationName: "test", instrumentationVersion: nil)
        .spanBuilder(spanName: name)
        .setSpanKind(spanKind: .client)
        .setStartTime(time: Clock.date(ms: endMs - 50))
    let span = builder.startSpan()
    for (key, value) in attributes { span.setAttribute(key: key, value: value) }
    span.end(time: Clock.date(ms: endMs))
    return ended.spans[0]
}

/// What the tests look at of an OTLP log record.
struct DecodedLog {
    let eventName: String
    let body: String?
    let severityText: String
    let attributes: [String: String]
    let resource: [String: String]
}

struct DecodedSpan {
    let name: String
    let attributes: [String: String]
    let resource: [String: String]
}

private func text(_ value: Opentelemetry_Proto_Common_V1_AnyValue) -> String? {
    switch value.value {
    case .stringValue(let s)?: return s
    case .boolValue(let b)?: return String(b)
    case .intValue(let i)?: return String(i)
    case .doubleValue(let d)?: return String(d)
    default: return nil
    }
}

private func strings(_ pairs: [Opentelemetry_Proto_Common_V1_KeyValue]) -> [String: String] {
    var out: [String: String] = [:]
    for pair in pairs { out[pair.key] = text(pair.value) }
    return out
}

enum Otlp {
    static func logsRequest(_ body: Data) -> Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest? {
        try? Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest(serializedBytes: body)
    }

    /// The records of an OTLP logs request, in order.
    static func logs(_ body: Data) -> [DecodedLog] {
        var out: [DecodedLog] = []
        for resourceLogs in logsRequest(body)?.resourceLogs ?? [] {
            let resource = strings(resourceLogs.resource.attributes)
            for scopeLogs in resourceLogs.scopeLogs {
                for record in scopeLogs.logRecords {
                    out.append(DecodedLog(
                        eventName: record.eventName,
                        body: record.hasBody ? text(record.body) : nil,
                        severityText: record.severityText,
                        attributes: strings(record.attributes),
                        resource: resource
                    ))
                }
            }
        }
        return out
    }

    /// How many resource containers a logs request has.
    static func resourceCount(_ body: Data) -> Int { logsRequest(body)?.resourceLogs.count ?? 0 }

    static func spans(_ body: Data) -> [DecodedSpan] {
        guard let request = try? Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: body)
        else { return [] }
        var out: [DecodedSpan] = []
        for resourceSpans in request.resourceSpans {
            let resource = strings(resourceSpans.resource.attributes)
            for scopeSpans in resourceSpans.scopeSpans {
                for span in scopeSpans.spans {
                    out.append(DecodedSpan(name: span.name, attributes: strings(span.attributes), resource: resource))
                }
            }
        }
        return out
    }
}

/// A queued outbox file's request body, gunzipped when it was stored
/// compressed.
func outboxBody(_ file: URL) -> Data {
    let data = (try? Data(contentsOf: file)) ?? Data()
    return file.lastPathComponent.contains(".gz.") ? (Gzip.decompress(data) ?? Data()) : data
}
#endif
