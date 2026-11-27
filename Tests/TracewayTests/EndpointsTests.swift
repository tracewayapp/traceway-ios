import Foundation
import XCTest
@testable import Traceway

final class EndpointsTests: XCTestCase {
    func testAcceptsTheBareUrlAndThe1xReportUrl() throws {
        for url in [
            "https://host",
            "https://host/",
            "https://host/api",
            "https://host/api/report",
            "https://host/api/report/",
            "  https://host//  ",
        ] {
            let e = try resolveEndpoints(url)
            XCTAssertEqual(e.base, "https://host", url)
            XCTAssertEqual(e.logs.absoluteString, "https://host/api/otel/v1/logs", url)
            XCTAssertEqual(e.traces.absoluteString, "https://host/api/otel/v1/traces", url)
            XCTAssertEqual(e.metrics.absoluteString, "https://host/api/otel/v1/metrics", url)
            XCTAssertEqual(e.opamp.absoluteString, "https://host/api/otel/v1/opamp", url)
            XCTAssertEqual(e.recordings.absoluteString, "https://host/api/recordings", url)
        }
    }

    func testKeepsAPathPrefixAndAPort() throws {
        let e = try resolveEndpoints("http://10.0.2.2:8082/traceway/api/report")
        XCTAssertEqual(e.base, "http://10.0.2.2:8082/traceway")
        XCTAssertEqual(e.logs.absoluteString, "http://10.0.2.2:8082/traceway/api/otel/v1/logs")
        XCTAssertEqual(try resolveEndpoints("http://OTEL_Collector:4318/api").base, "http://otel_collector:4318")
        XCTAssertEqual(try resolveEndpoints("http://localhost:8082").base, "http://localhost:8082")
    }

    func testRecognisesTheSDKsOwnRequests() throws {
        let e = try resolveEndpoints("https://host/api/report")
        XCTAssertTrue(e.isOwn("https://host/api/otel/v1/logs"))
        XCTAssertTrue(e.isOwn("https://host/api/recordings"))
        XCTAssertFalse(e.isOwn("https://host/api/users"))
        XCTAssertFalse(e.isOwn("https://other/api/otel/v1/logs"))
        XCTAssertThrowsError(try resolveEndpoints(""))
        XCTAssertThrowsError(try resolveEndpoints("/api/report"))
    }

    func testRecognisesItsOwnRequestsWhateverTheCaseOfTheHostOrADefaultPort() throws {
        for url in ["https://Traceway.Test/api/report", "https://traceway.test:443", "HTTPS://TRACEWAY.TEST:443/"] {
            let e = try resolveEndpoints(url)
            XCTAssertTrue(e.isOwn("https://traceway.test/api/otel/v1/logs"), url)
            XCTAssertTrue(e.isOwn("https://traceway.test/api/recordings"), url)
        }
        XCTAssertEqual(try resolveEndpoints("http://host:8080").base, "http://host:8080")
        XCTAssertEqual(try resolveEndpoints("http://host:443").base, "http://host:443")
        XCTAssertEqual(try resolveEndpoints("http://host:80").base, "http://host")
    }

    /// The same rules as a connection string's URL, for a `baseUrl` given
    /// on its own.
    func testABaseUrlAloneIsNormalized() throws {
        for (raw, base) in [
            ("https://cloud.tracewayapp.com/api/report", "https://cloud.tracewayapp.com"),
            ("cloud.tracewayapp.com", "https://cloud.tracewayapp.com"),
            ("  https://cloud.tracewayapp.com/api/report?x=1#top  ", "https://cloud.tracewayapp.com"),
            ("localhost:8082", "http://localhost:8082"),
            ("127.0.0.1:8082/api", "http://127.0.0.1:8082"),
            ("10.0.2.2:8082", "http://10.0.2.2:8082"),
            ("[::1]:8082/api/report", "http://[::1]:8082"),
            ("traceway.mycompany.com/traceway/api/", "https://traceway.mycompany.com/traceway"),
            ("HTTPS://Cloud.TracewayApp.com:443/", "https://cloud.tracewayapp.com"),
        ] {
            XCTAssertEqual(try normalizeBaseUrl(raw), base, raw)
            XCTAssertEqual(try resolveEndpoints(raw).base, base, raw)
        }
        XCTAssertTrue(try normalizeBaseUrlDetailed("cloud.tracewayapp.com").schemeAdded)
        XCTAssertFalse(try normalizeBaseUrlDetailed("https://cloud.tracewayapp.com").schemeAdded)
        for bad in ["", "   ", "ftp://host", "https://", "/api/report", "\u{0}", "https://?x"] {
            XCTAssertThrowsError(try normalizeBaseUrl(bad), bad) { error in
                XCTAssertTrue("\(error)".contains("is not a Traceway server URL; expected https://host"), "\(error)")
            }
        }
    }

    private func traceway() throws -> TracewayEndpoints { try resolveEndpoints("https://traceway.test/api/report") }

    func testWithoutTelemetryEverySignalGoesToTracewayWithTheToken() throws {
        let routes = try TelemetryRoutes.resolve(endpoints: traceway(), token: "tok", telemetry: nil)
        XCTAssertEqual(routes.logs.url.absoluteString, "https://traceway.test/api/otel/v1/logs")
        XCTAssertEqual(routes.traces.url.absoluteString, "https://traceway.test/api/otel/v1/traces")
        XCTAssertEqual(routes.metrics.url.absoluteString, "https://traceway.test/api/otel/v1/metrics")
        for destination in [routes.logs, routes.traces, routes.metrics] {
            XCTAssertEqual(destination.headers, ["Authorization": "Bearer tok"])
        }
        XCTAssertFalse(routes.logs.external)
        XCTAssertFalse(routes.splitsLogs)
        // Traceway requests are recognised by TracewayEndpoints.
        XCTAssertFalse(routes.isOwn("https://traceway.test/api/otel/v1/logs"))
        XCTAssertEqual(routes.traceway?.url.absoluteString, "https://traceway.test/api/otel/v1/logs")
    }

    func testABaseUrlAppendsTheSignalPathsAndNeverSendsTheToken() throws {
        let routes = try TelemetryRoutes.resolve(
            endpoints: traceway(),
            token: "tok",
            telemetry: TracewayTelemetry(url: "https://collector.test/otlp/", headers: ["x-key": "k"])
        )
        XCTAssertEqual(routes.logs.url.absoluteString, "https://collector.test/otlp/v1/logs")
        XCTAssertEqual(routes.traces.url.absoluteString, "https://collector.test/otlp/v1/traces")
        XCTAssertEqual(routes.metrics.url.absoluteString, "https://collector.test/otlp/v1/metrics")
        for destination in [routes.logs, routes.traces, routes.metrics] {
            XCTAssertEqual(destination.headers, ["x-key": "k"])
            XCTAssertTrue(destination.external)
        }
        XCTAssertTrue(routes.splitsLogs)
        XCTAssertEqual(routes.traceway?.headers, ["Authorization": "Bearer tok"])
        XCTAssertTrue(routes.isOwn("https://collector.test/otlp/v1/traces"))
        XCTAssertFalse(routes.isOwn("https://api.example.com/cart"))
    }

    func testASignalEndpointIsUsedAsGivenAndOverridesHeaders() throws {
        let routes = try TelemetryRoutes.resolve(
            endpoints: traceway(),
            token: "tok",
            telemetry: TracewayTelemetry(
                headers: ["x-key": "shared", "x-team": "app"],
                metrics: TracewayTelemetryEndpoint(url: "https://metrics.test/ingest", headers: ["x-key": "metrics"])
            )
        )
        XCTAssertEqual(routes.metrics.url.absoluteString, "https://metrics.test/ingest")
        XCTAssertEqual(routes.metrics.headers, ["x-key": "metrics", "x-team": "app"])
        // Signals without a destination stay on Traceway.
        XCTAssertEqual(routes.logs.url.absoluteString, "https://traceway.test/api/otel/v1/logs")
        XCTAssertFalse(routes.traces.external)
        XCTAssertFalse(routes.splitsLogs)
    }

    func testCollectorUrlsAreTrimmedAndRecognised() throws {
        let routes = try TelemetryRoutes.resolve(
            endpoints: traceway(),
            token: "tok",
            telemetry: TracewayTelemetry(
                url: " https://collector.test:4318 ",
                logs: TracewayTelemetryEndpoint(url: " http://otel_collector:4318/v1/logs ")
            )
        )
        XCTAssertEqual(routes.logs.url.absoluteString, "http://otel_collector:4318/v1/logs")
        XCTAssertEqual(routes.traces.url.absoluteString, "https://collector.test:4318/v1/traces")
        XCTAssertTrue(routes.isOwn("https://collector.test:4318/v1/traces"))
        XCTAssertTrue(routes.isOwn("http://otel_collector:4318/v1/logs"))
    }

    func testRejectsURLsThatAreNotPlainHTTPS() throws {
        for url in [
            "ftp://collector.test",
            "https://user:pw@collector.test",
            "https://user@collector.test",
            "https://collector.test/?key=1",
            "https://collector.test/?",
            "https://collector.test/#x",
            "collector.test",
            "https://",
            "https://:4318/v1",
            "https://collector.test:port/v1",
            "https://bad host/v1",
            "https://[::1/v1",
        ] {
            XCTAssertThrowsError(
                try TelemetryRoutes.resolve(endpoints: traceway(), token: "tok", telemetry: TracewayTelemetry(url: url)),
                url
            )
        }
    }

    func testStandaloneNeedsADestinationForEverySignal() throws {
        XCTAssertThrowsError(try TelemetryRoutes.resolve(
            endpoints: nil,
            token: nil,
            telemetry: TracewayTelemetry(logs: TracewayTelemetryEndpoint(url: "https://c.test/v1/logs"))
        ))
        XCTAssertThrowsError(try TelemetryRoutes.resolve(
            endpoints: nil,
            token: nil,
            telemetry: TracewayTelemetry(
                logs: TracewayTelemetryEndpoint(url: "https://c.test/v1/logs"),
                traces: TracewayTelemetryEndpoint(url: "https://c.test/v1/traces")
            )
        ), "standalone without metrics")
        XCTAssertFalse(TracewayTelemetry(logs: TracewayTelemetryEndpoint(url: "https://c.test/v1/logs")).coversAllSignals)
        let routes = try TelemetryRoutes.resolve(endpoints: nil, token: nil, telemetry: TracewayTelemetry(url: "https://c.test"))
        XCTAssertNil(routes.traceway)
        XCTAssertFalse(routes.splitsLogs)
        XCTAssertTrue(routes.logs.headers.isEmpty)
        XCTAssertEqual(routes.logs.url.absoluteString, "https://c.test/v1/logs")
        XCTAssertEqual(routes.traces.url.absoluteString, "https://c.test/v1/traces")
        XCTAssertEqual(routes.metrics.url.absoluteString, "https://c.test/v1/metrics")
    }

    func testAnEmptyBaseUrlCountsAsUnset() throws {
        for blank in ["", " "] {
            let routes = try TelemetryRoutes.resolve(
                endpoints: resolveEndpoints("https://traceway.test"),
                token: "tok",
                telemetry: TracewayTelemetry(url: blank)
            )
            XCTAssertFalse(routes.logs.external, "<\(blank)>")
            XCTAssertEqual(routes.traces.url.absoluteString, "https://traceway.test/api/otel/v1/traces")
            XCTAssertThrowsError(try TelemetryRoutes.resolve(endpoints: nil, token: nil, telemetry: TracewayTelemetry(url: blank)))
        }
    }

    func testCollectorIdentityIncludesTenantHeadersAndCanonicalizesTheirOrderAndNames() {
        let url = URL(string: "https://collector.test/v1/logs")!
        let current = OtlpDestination(url: url, headers: ["Authorization": "one", "X-Tenant": "a"], external: true)
        XCTAssertEqual(current.key, OtlpDestination(url: url, headers: ["x-tenant": "a", "authorization": "one"], external: true).key)
        XCTAssertNotEqual(current.key, OtlpDestination(url: url, headers: ["Authorization": "one", "X-Tenant": "b"], external: true).key)
        XCTAssertNotEqual(current.key, OtlpDestination(url: url, headers: ["Authorization": "one", "X-Tenant": "a"]).key)
        XCTAssertNotEqual(
            current.key,
            OtlpDestination(url: URL(string: "https://collector.test/v1/logs/")!, headers: ["Authorization": "one", "X-Tenant": "a"], external: true).key
        )
        XCTAssertEqual(current.key.count, 16)
        XCTAssertFalse(current.key.contains("one"))
    }
}
