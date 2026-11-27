// The official OTLP/HTTP exporters on the SDK's HTTP client and outbox. Not
// in the iOS Simulator bundle (OpenTelemetry types, see OtlpTestSupport.swift).
#if !os(iOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenTelemetryApi
import OpenTelemetrySdk
import XCTest
@testable import Traceway

final class OtlpExportersTests: XCTestCase {
    private let logsURL = URL(string: "https://collector.test/v1/logs")!
    private let tracesURL = URL(string: "https://collector.test/v1/traces")!
    private var logs: OtlpDestination { OtlpDestination(url: logsURL, headers: ["X-Tenant": "a"], external: true) }
    private var traces: OtlpDestination { OtlpDestination(url: tracesURL, headers: [:], external: true) }

    private func outbox(_ dir: URL, _ http: FakeHTTP) -> Outbox {
        let outbox = Outbox(directory: dir, destinations: ["logs": logs, "traces": traces], transport: http)
        outbox.claim()
        addTeardownBlock { outbox.dispose() }
        return outbox
    }

    private func queued(_ dir: URL) -> [URL] {
        fileNames(dir).filter { $0.hasSuffix(".pb") }.map { dir.appendingPathComponent($0) }
    }

    func testTheLogExporterSendsProtobufWithTheDestinationsHeaders() {
        let http = FakeHTTP()
        let exporter = makeLogExporter(logs, outbox: nil, transport: http)
        XCTAssertEqual(exporter.export(logRecords: [logRecord("hello")], explicitTimeout: nil), .success)
        XCTAssertEqual(http.requests.count, 1)
        let request = http.requests[0]
        XCTAssertEqual(request.url, logsURL)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-protobuf")
        XCTAssertEqual(request.headers["X-Tenant"], "a")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertTrue(request.headers["User-Agent"]?.hasPrefix("OTel-OTLP-Exporter-Swift/") == true,
                      request.headers["User-Agent"] ?? "no User-Agent")
        if let encoding = request.headers["Content-Encoding"] { XCTAssertEqual(encoding, "gzip") }
        XCTAssertEqual(Otlp.logs(request.plain).map(\.body), ["hello"])
        XCTAssertEqual(Otlp.logs(request.plain).first?.resource["service.name"], "test-app")
    }

    func testAPassingFailureIsRetriedBeforeTheBatchIsQueued() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP.sequence(503, 429)
        let exporter = makeLogExporter(logs, outbox: outbox(dir, http), transport: http)
        let started = Date()
        XCTAssertEqual(exporter.export(logRecords: [logRecord("retried")], explicitTimeout: nil), .success)
        XCTAssertEqual(http.requests.count, 3)
        // The live retries wait 200 ms, then 1 s.
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.1)
        XCTAssertTrue(queued(dir).isEmpty)
        XCTAssertEqual(Otlp.logs(http.requests[2].plain).map(\.body), ["retried"])
    }

    func testABatchThatKeepsFailingGoesToTheOutbox() throws {
        let dir = scratchDirectory(self)
        let http = FakeHTTP { _ in HTTPResult(statusCode: 503) }
        let exporter = makeLogExporter(logs, outbox: outbox(dir, http), transport: http)
        XCTAssertEqual(exporter.export(logRecords: [logRecord("queued")], explicitTimeout: nil), .success)
        XCTAssertEqual(http.requests.count, 3)
        let files = queued(dir)
        XCTAssertEqual(files.count, 1)
        let name = try XCTUnwrap(files.first?.lastPathComponent)
        XCTAssertTrue(name.hasSuffix(".logs.pb") || name.hasSuffix(".logs.gz.pb"), name)
        XCTAssertEqual(name.contains(".gz."), http.requests[0].headers["Content-Encoding"] == "gzip")
        XCTAssertEqual(Otlp.logs(outboxBody(files[0])).map(\.body), ["queued"])
    }

    func testARejectedBatchIsDroppedNotQueued() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP { _ in HTTPResult(statusCode: 400) }
        let exporter = makeLogExporter(logs, outbox: outbox(dir, http), transport: http)
        XCTAssertEqual(exporter.export(logRecords: [logRecord("rejected")], explicitTimeout: nil), .failure)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertTrue(queued(dir).isEmpty)
    }

    func testWithoutAnOutboxABatchThatKeepsFailingIsAFailure() {
        let http = FakeHTTP { _ in .noAnswer }
        let exporter = makeLogExporter(logs, outbox: nil, transport: http)
        XCTAssertEqual(exporter.export(logRecords: [logRecord("lost")], explicitTimeout: nil), .failure)
        XCTAssertEqual(http.requests.count, 3)
        // Nothing is held for a later flush: the SDK keeps its own queue.
        XCTAssertEqual(exporter.forceFlush(explicitTimeout: nil), .success)
        XCTAssertEqual(http.requests.count, 3)
    }

    func testSpansAreSentAsTraceRequests() {
        let http = FakeHTTP()
        let exporter = makeSpanExporter(traces, outbox: nil, transport: http)
        XCTAssertEqual(exporter.export(spans: [endedSpan("GET /a"), endedSpan("GET /b")], explicitTimeout: nil), .success)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url, tracesURL)
        let spans = Otlp.spans(http.requests[0].plain)
        XCTAssertEqual(spans.map(\.name), ["GET /a", "GET /b"])
        XCTAssertEqual(spans.first?.resource["service.name"], "test-app")
    }

    func testRoutingSendsIssuesAndControlRecordsToTraceway() {
        let http = FakeHTTP()
        let tracewayURL = URL(string: "https://traceway.test/api/otel/v1/logs")!
        let routing = RoutingLogExporter(
            inner: makeLogExporter(logs, outbox: nil, transport: http),
            traceway: makeLogExporter(
                OtlpDestination(url: tracewayURL, headers: ["Authorization": "Bearer t"]), outbox: nil, transport: http
            )
        )
        let records = [
            logRecord("boom", event: Events.exception),
            logRecord("line"),
            logRecord("start", event: Events.sessionStart),
            logRecord("custom", event: "checkout_failed"),
            logRecord("note", event: Events.message),
        ]
        XCTAssertEqual(routing.export(logRecords: records, explicitTimeout: nil), .success)
        XCTAssertEqual(
            http.requests(to: tracewayURL).flatMap { Otlp.logs($0.plain) }.map(\.eventName),
            [Events.exception, Events.sessionStart, Events.message]
        )
        XCTAssertEqual(http.requests(to: logsURL).flatMap { Otlp.logs($0.plain) }.map(\.body), ["line", "custom"])
        XCTAssertEqual(http.requests(to: tracewayURL).map { $0.headers["Authorization"] }, ["Bearer t"])
        XCTAssertEqual(http.requests(to: logsURL).map { $0.headers["Authorization"] }, [nil])
    }

    func testRoutingReportsAFailedExporterAndStillSendsTheRest() {
        final class Failing: LogRecordExporter, @unchecked Sendable {
            var calls = 0
            func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
                calls += 1
                return .failure
            }
            func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
            func shutdown(explicitTimeout: TimeInterval?) {}
        }
        let http = FakeHTTP()
        let failing = Failing()
        let routing = RoutingLogExporter(inner: failing, traceway: makeLogExporter(logs, outbox: nil, transport: http))
        XCTAssertEqual(routing.export(logRecords: [logRecord("x"), logRecord("e", event: Events.exception)], explicitTimeout: nil), .failure)
        XCTAssertEqual(failing.calls, 1)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(Otlp.logs(http.requests[0].plain).map(\.eventName), [Events.exception])
        // Only issues: the other exporter is not called at all.
        XCTAssertEqual(routing.export(logRecords: [logRecord("e2", event: Events.exception)], explicitTimeout: nil), .success)
        XCTAssertEqual(failing.calls, 1)
    }

    func testARequestWithoutABodyIsRefusedBeforeItLeaves() {
        let http = FakeHTTP()
        let client = OutboxHTTPClient(kind: "logs", outbox: nil, transport: http)
        var request = URLRequest(url: logsURL)
        request.httpMethod = "POST"
        var failed = false
        client.send(request: request) { result in
            if case .failure = result { failed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testTheRecordsKeepTheirEventNamesSeverityAndAttributes() {
        let http = FakeHTTP()
        let exporter = makeLogExporter(logs, outbox: nil, transport: http)
        let record = logRecord("boom", event: Events.exception, severity: .error,
                             attributes: ["exception.type": .string("E"), "count": .int(3), "ok": .bool(true)])
        XCTAssertEqual(exporter.export(logRecords: [record], explicitTimeout: nil), .success)
        let decoded = Otlp.logs(http.requests[0].plain)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.eventName, "exception")
        XCTAssertEqual(decoded.first?.attributes, ["exception.type": "E", "count": "3", "ok": "true"])
    }
}
#endif
