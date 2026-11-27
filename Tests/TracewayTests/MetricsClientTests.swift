import Foundation
import XCTest
#if !os(iOS)
// A test bundle hosted in the iOS app cannot link OpenTelemetry's types;
// the span test runs under `swift test` on macOS and Linux.
import OpenTelemetryApi
#endif
@testable import Traceway

/// The metrics pipeline inside a running client: what reaches the metrics
/// endpoint, through the real transport path to a fake server.
final class MetricsClientTests: XCTestCase {
    private var server: FakeServer!

    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
        server = FakeServer()
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        super.tearDown()
    }

    @discardableResult
    private func start(
        _ options: TracewayOptions = TracewayOptions(remoteConfig: false),
        connectionString: String? = "token@https://traceway.example.com"
    ) throws -> TracewayClient {
        var options = options
        options.exportDelayMs = 50
        return try TracewayClient.start(
            connectionString: connectionString,
            options: options,
            overrides: TracewayTestOverrides(
                transport: server,
                deviceAttributes: [
                    "os.name": "ios", "os.major": "18", "device.form_factor": "phone",
                    "device.class": "high", "device.model": "iPhone17,1",
                ]
            )
        )
    }

    private func payloads(_ path: String = "/api/otel/v1/metrics") -> [Data] {
        server.requests(to: path).map { request in
            if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(request.body) {
                return plain
            }
            return request.body
        }
    }

    func testAFlushSendsTheSessionToTheMetricsEndpoint() throws {
        let client = try start(TracewayOptions(version: "1.2.3", serviceName: "shop", environment: "prod",
                                               remoteConfig: false))
        client.flush(timeout: 10)
        let request = try XCTUnwrap(server.requests(to: "/api/otel/v1/metrics").first)
        XCTAssertEqual(request.url.absoluteString, "https://traceway.example.com/api/otel/v1/metrics")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-protobuf")
        let decoded = Decoded(payloads())
        XCTAssertEqual(decoded.sums["app.session"], 1)
        let resource = decoded.resource()
        XCTAssertEqual(resource["service.name"], .string("shop"))
        XCTAssertEqual(resource["service.version"], .string("1.2.3"))
        XCTAssertEqual(resource["deployment.environment.name"], .string("prod"))
        XCTAssertEqual(resource["os.name"], .string("ios"))
        XCTAssertEqual(resource["device.class"], .string("high"))
        XCTAssertEqual(resource["traceway.sdk.name"], .string("traceway-ios"))
        XCTAssertEqual(resource["traceway.metrics"], .string("aggregated"))
        XCTAssertNil(resource["device.model"])
        XCTAssertNil(resource["service.instance.id"])
        XCTAssertEqual(client.resourceAttributes["traceway.metrics"], "aggregated",
                       "logs and spans say their numbers arrive as metrics")
    }

    func testCustomMetricsAndDimensionsThroughTheFacade() throws {
        let client = try start(TracewayOptions(remoteConfig: false))
        Traceway.setMetricDimension("experiment", "b")
        Traceway.metric("checkout.duration", value: 420, dimensions: ["plan": "pro"])
        Traceway.count("cart.add")
        Traceway.count("cart.add", n: 2)
        Traceway.metric("app.start.duration", value: 1)
        Traceway.reportFullyDisplayed()
        client.flush(timeout: 10)
        let decoded = Decoded(payloads())
        XCTAssertEqual(decoded.histograms["checkout.duration|plan=pro"]?.sum, 420)
        XCTAssertEqual(decoded.sums["cart.add"], 3)
        XCTAssertNil(decoded.histograms["app.start.duration"], "reserved names are the SDK's")
        XCTAssertEqual(decoded.resource()["custom.experiment"], .string("b"))
    }

    func testCaptureMetricsFalseSendsNoMetrics() throws {
        let client = try start(TracewayOptions(captureMetrics: false, remoteConfig: false))
        // Only the hang watchdog runs, for AppHang issues.
        XCTAssertEqual(client.vitals?.recordsMetrics, false)
        Traceway.count("cart.add")
        client.flush(timeout: 10)
        XCTAssertTrue(server.requests(to: "/api/otel/v1/metrics").isEmpty)
        XCTAssertNil(client.resourceAttributes["traceway.metrics"])
        client.shutdown()
        let none = try start(TracewayOptions(captureMetrics: false, remoteConfig: false, captureAppHangs: false))
        XCTAssertNil(none.vitals)
    }

    func testTheOptionsDimensionsAreOnEveryPayload() throws {
        let client = try start(TracewayOptions(metricDimensions: ["tier": "gold", "region": "eu", "third": "no"],
                                               remoteConfig: false))
        client.flush(timeout: 10)
        let resource = Decoded(payloads()).resource()
        XCTAssertEqual(resource["custom.region"], .string("eu"))
        XCTAssertEqual(resource["custom.third"], .string("no"))
        XCTAssertNil(resource["custom.tier"], "two at most, by key order")
    }

    func testAPlanLimitTurnsMetricsOff() throws {
        server.remoteConfig = #"{"limits":{"metrics":"off"}}"#
        let client = try start(TracewayOptions())
        XCTAssertTrue(eventually(timeout: 10) { client.onQueueSync { client.control.settings.activeMetrics == nil } })
        Traceway.count("cart.add")
        client.flush(timeout: 10)
        XCTAssertTrue(server.requests(to: "/api/otel/v1/metrics").isEmpty)
    }

    func testAnotherReceiverGetsTheMetricsAtItsOwnURL() throws {
        let client = try start(
            TracewayOptions(telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp/",
                                                         headers: ["x-key": "k"])),
            connectionString: nil
        )
        client.flush(timeout: 10)
        let request = try XCTUnwrap(server.requests(to: "/otlp/v1/metrics").first)
        XCTAssertEqual(request.url.host, "collector.example.com")
        XCTAssertEqual(request.headers["x-key"], "k")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(Decoded(payloads("/otlp/v1/metrics")).sums["app.session"], 1)
        XCTAssertTrue(client.isOwnRequest("https://collector.example.com/otlp/v1/metrics"))
    }

    func testStandaloneNeedsADestinationForEverySignal() throws {
        let endpoint = TracewayTelemetryEndpoint(url: "https://collector.example.com/v1/logs")
        let traces = TracewayTelemetryEndpoint(url: "https://collector.example.com/v1/traces")
        XCTAssertThrowsError(try start(TracewayOptions(telemetry: TracewayTelemetry(logs: endpoint, traces: traces)),
                                       connectionString: nil))
        let metrics = TracewayTelemetryEndpoint(url: "https://metrics.example.com/ingest", headers: ["x-key": "m"])
        let routes = try TelemetryRoutes.resolve(
            endpoints: nil, token: nil,
            telemetry: TracewayTelemetry(logs: endpoint, traces: traces, metrics: metrics)
        )
        XCTAssertEqual(routes.metrics.url.absoluteString, "https://metrics.example.com/ingest")
        XCTAssertEqual(routes.metrics.headers, ["x-key": "m"])
        XCTAssertTrue(routes.metrics.external)
        let traceway = try TelemetryRoutes.resolve(
            endpoints: resolveEndpoints("https://traceway.example.com"), token: "t", telemetry: nil
        )
        XCTAssertEqual(traceway.metrics.url.absoluteString, "https://traceway.example.com/api/otel/v1/metrics")
        XCTAssertEqual(traceway.metrics.headers, ["Authorization": "Bearer t"])
    }

    func testABlankTelemetryURLIsUnset() throws {
        XCTAssertFalse(TracewayTelemetry(url: "").coversAllSignals)
        XCTAssertFalse(TracewayTelemetry(url: "  \n").coversAllSignals)
        XCTAssertTrue(TracewayTelemetry(url: "https://collector.example.com").coversAllSignals)
        let endpoint = TracewayTelemetryEndpoint(url: "https://collector.example.com/v1/x")
        XCTAssertTrue(TracewayTelemetry(url: "", logs: endpoint, traces: endpoint, metrics: endpoint).coversAllSignals)
        XCTAssertThrowsError(try start(TracewayOptions(telemetry: TracewayTelemetry(url: " ")), connectionString: nil))
        XCTAssertNil(TracewayClient.shared)
        // With a connection string a blank url keeps every signal on Traceway.
        let client = try start(TracewayOptions(remoteConfig: false, telemetry: TracewayTelemetry(url: "")))
        XCTAssertFalse(client.routes.metrics.external)
        XCTAssertEqual(client.routes.metrics.url.absoluteString, "https://traceway.example.com/api/otel/v1/metrics")
    }

    func testTheMetricsScreenIsTheRouteOrThePathWithItsIdsFolded() {
        let screen = ScreenState()
        XCTAssertNil(TracewayClient.metricsScreen(screen))
        screen.navigated(to: "/orders/8841", atMs: 0)
        XCTAssertEqual(TracewayClient.metricsScreen(screen), "/orders/:id")
        screen.setRoute("orders/{id}")
        XCTAssertEqual(TracewayClient.metricsScreen(screen), "/orders/{id}")
    }

    #if !os(iOS)
    func testRequestSpansBecomeRequestMetricsByHost() throws {
        let client = try start()
        let tracer = try XCTUnwrap(client.openTelemetryTracer)
        func request(_ url: String, status: Int, bytes: Int? = nil) {
            let span = tracer.spanBuilder(spanName: "GET").setSpanKind(spanKind: .client).startSpan()
            span.setAttribute(key: "http.request.method", value: .string("GET"))
            span.setAttribute(key: "url.full", value: .string(url))
            span.setAttribute(key: "http.response.status_code", value: .int(status))
            if let bytes = bytes { span.setAttribute(key: "http.response.body.size", value: .int(bytes)) }
            if status >= 400 { span.setAttribute(key: "error.type", value: .string("\(status)")) }
            span.end()
        }
        request("https://API.shop.test/cart", status: 200, bytes: 512)
        request("https://api.shop.test/pay", status: 503)
        let checkout = tracer.spanBuilder(spanName: "checkout").startSpan()
        checkout.setAttribute(key: "http.request.method", value: .string("GET"))
        checkout.end()
        client.flush(timeout: 10)
        let decoded = Decoded(payloads())
        XCTAssertEqual(decoded.sums["app.request.failed.total|host=api.shop.test"], 2)
        XCTAssertEqual(decoded.sums["app.request.failed|host=api.shop.test"], 1)
        XCTAssertEqual(decoded.histograms["app.request.duration|host=api.shop.test"]?.count, 2)
        XCTAssertEqual(decoded.histograms["app.request.bytes|host=api.shop.test"]?.sum, 512)
        XCTAssertEqual(decoded.sums["app.user.affected|issue=failed_request"], nil,
                       "without lasting storage no user is counted")
    }
    #endif
}
