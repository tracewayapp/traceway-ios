import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterCommon
@testable import Traceway

final class TracewayClientTests: XCTestCase {
    var logs: MemoryLogExporter!
    var spans: MemorySpanExporter!
    var server: FakeServer!

    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
        logs = MemoryLogExporter()
        spans = MemorySpanExporter()
        server = FakeServer()
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        super.tearDown()
    }

    @discardableResult
    func start(
        _ options: TracewayOptions = TracewayOptions(),
        token: String? = "token",
        stateDirectory: URL? = nil,
        replay: ReplaySource? = nil,
        random: (() -> Double)? = nil,
        transport: HTTPTransport? = nil
    ) throws -> TracewayClient {
        var options = options
        options.exportDelayMs = 50
        return try TracewayClient.start(
            token: token,
            baseUrl: "https://traceway.example.com",
            options: options,
            overrides: TracewayTestOverrides(
                logExporter: logs,
                spanExporter: spans,
                transport: transport ?? server,
                stateDirectory: stateDirectory,
                deviceAttributes: ["os.name": "ios", "device.model": "iPhone15,2"],
                random: random,
                replaySource: replay
            )
        )
    }

    // MARK: - Sessions and resource

    func testStartReportsASessionUnderTheResource() throws {
        let client = try start(TracewayOptions(version: "1.2.3", serviceName: "shop", environment: "prod"))
        client.flush(timeout: 5)
        let started = try XCTUnwrap(logs.events("session.start").first)
        XCTAssertEqual(started.string("session.id"), client.currentSessionId)
        XCTAssertNotNil(started.attributes["traceway.session.started_at"])
        let resource = started.resource.attributes
        XCTAssertEqual(resource["service.name"], .string("shop"))
        XCTAssertEqual(resource["service.version"], .string("1.2.3"))
        XCTAssertEqual(resource["deployment.environment.name"], .string("prod"))
        XCTAssertEqual(resource["service.instance.id"], .string(client.instanceId))
        XCTAssertEqual(resource["traceway.sdk.name"], .string("traceway-ios"))
        XCTAssertEqual(resource["traceway.sdk.version"], .string("2.1.0"))
        // OpenTelemetry's own version, not the SDK's.
        XCTAssertNotNil(resource["telemetry.sdk.version"])
        XCTAssertNotEqual(resource["telemetry.sdk.version"], .string("2.1.0"))
        XCTAssertEqual(started.instrumentationScopeInfo.version, "2.1.0")
        XCTAssertEqual(resource["telemetry.sdk.language"], .string("swift"))
        XCTAssertEqual(resource["device.model"], .string("iPhone15,2"))
        XCTAssertEqual(started.instrumentationScopeInfo.name, "traceway-ios")
    }

    func testShutdownEndsTheSession() throws {
        let client = try start()
        let session = client.currentSessionId
        client.shutdown()
        XCTAssertEqual(logs.events("session.end").first?.string("session.id"), session)
    }

    @available(*, deprecated)
    func testAnInvalidConnectionStringDoesNotStart() {
        XCTAssertNil(Traceway.initialize(connectionString: "no-at-sign"))
        XCTAssertNil(Traceway.initialize(connectionString: "token@ftp://example.com"))
        XCTAssertNil(Traceway.initialize(token: "token", baseUrl: "ftp://example.com"))
        XCTAssertNil(TracewayClient.shared)
    }

    // MARK: - Exceptions and breadcrumbs

    func testAnExceptionStreamsAndFlushesTheBreadcrumbsBeforeIt() throws {
        let client = try start()
        Traceway.log("opened cart")
        Traceway.recordAction(category: "cart", name: "add", data: ["sku": "A1"])
        Traceway.recordNavigation("/checkout")
        client.flush(timeout: 5)
        // Breadcrumbs stay on the device until something goes wrong.
        XCTAssertTrue(logs.consoleLines.isEmpty)
        XCTAssertTrue(logs.events("traceway.action").isEmpty)

        struct PaymentFailed: Error {}
        Traceway.captureException(PaymentFailed(), attributes: ["order": "42"])
        client.flush(timeout: 5)

        let exception = try XCTUnwrap(logs.events("exception").first)
        XCTAssertTrue(exception.string("exception.type")?.contains("PaymentFailed") == true)
        XCTAssertTrue(exception.string("exception.stacktrace")?.contains("os: ios arch:") == true)
        XCTAssertNotNil(exception.string("traceway.exception.id"))
        XCTAssertEqual(exception.string("order"), "42")
        XCTAssertEqual(exception.string("session.id"), client.currentSessionId)
        XCTAssertEqual(exception.string("traceway.replay.status"), "disabled")
        XCTAssertEqual(exception.severity, .error)
        XCTAssertEqual(logs.consoleLines.first?.body, .string("opened cart"))
        XCTAssertEqual(logs.events("traceway.action").first?.string("traceway.action.data"), "{\"sku\":\"A1\"}")
        XCTAssertEqual(logs.events("browser.navigation").first?.string("url.full"), "/checkout")
        XCTAssertEqual(logs.events("traceway.trigger.fired").first?.string("traceway.trigger.id"), "default-exception")
    }

    func testAnIssueReachesTheExporterBeforeTheBreadcrumbsItFlushes() throws {
        let client = try start()
        for i in 0..<5 { Traceway.log("breadcrumb \(i)") }
        client.flush(timeout: 5)
        XCTAssertTrue(logs.records.filter { $0.eventName == "exception" || $0.eventName == nil }.isEmpty)

        struct PaymentFailed: Error {}
        Traceway.captureException(PaymentFailed())
        client.flush(timeout: 5)
        let order = logs.records.filter { $0.eventName == "exception" || $0.eventName == nil }
            .map { $0.eventName ?? "breadcrumb" }
        XCTAssertEqual(order, ["exception"] + Array(repeating: "breadcrumb", count: 5))
        XCTAssertNotNil(logs.events("exception").first?.string("traceway.replay.status"),
                        "what the triggers add to the issue is sent with it")
    }

    /// With a disk the issue is written to the outbox before it is sent;
    /// its request still leaves before the breadcrumbs', once.
    func testAnIssueOnDiskIsSentBeforeTheBreadcrumbsItFlushesAndOnce() throws {
        let dir = temporaryDirectory().appendingPathComponent("traceway_v2")
        var options = TracewayOptions(remoteConfig: false)
        options.exportDelayMs = 50
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com", options: options,
            overrides: TracewayTestOverrides(transport: server, stateDirectory: dir,
                                             deviceAttributes: ["os.name": "ios"])
        )
        for i in 0..<5 { Traceway.log("breadcrumb \(i)") }
        client.flush(timeout: 5)
        struct PaymentFailed: Error {}
        Traceway.captureException(PaymentFailed())
        client.flush(timeout: 5)
        func sent() -> [String] {
            server.requests(to: "/api/otel/v1/logs").flatMap { request -> [String] in
                var body = request.body
                if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(body) { body = plain }
                return Otlp.logs(body).filter { $0.eventName == "exception" || $0.eventName.isEmpty }
                    .map { $0.eventName.isEmpty ? "breadcrumb" : $0.eventName }
            }
        }
        XCTAssertTrue(eventually { sent().count >= 6 }, "\(sent())")
        XCTAssertEqual(sent(), ["exception"] + Array(repeating: "breadcrumb", count: 5))
    }

    func testACrashIsNeverDroppedByTheErrorRateLimit() throws {
        let client = try start()
        struct Loop: Error { let i: Int }
        for i in 0..<70 { Traceway.captureException(Loop(i: i)) }
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("exception").count, 60, "the limit holds for errors the app handled")
        // What an uncaught NSException emits (`captureFatalException`).
        client.onQueueSync {
            client.emit(eventName: Events.exception, severity: .fatal, attributes: [
                "exception.type": .string("NSInvalidArgumentException"),
                "exception.message": .string("unrecognized selector"),
                "exception.escaped": .bool(true),
                "traceway.crash": .bool(true),
                Attr.exceptionId: .string(Ids.uuidv4()),
            ])
        }
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("exception").filter { $0.attributes["traceway.crash"] == .bool(true) }.count, 1)
    }

    func testARemovedScreenLeavesTheCurrentScreenAsItIs() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        Traceway.recordNavigation("/cart", route: "cart")
        Traceway.recordNavigation("/checkout/step2", action: "remove", from: "/checkout/step2", route: "checkout/:step")
        struct Declined: Error {}
        Traceway.captureException(Declined())
        client.flush(timeout: 5)
        let removed = try XCTUnwrap(logs.events("browser.navigation").last)
        XCTAssertEqual(removed.string("navigation.action"), "remove")
        XCTAssertEqual(removed.string("browser.navigation.type"), "remove")
        XCTAssertEqual(removed.string("url.full"), "")
        XCTAssertNil(removed.attributes["navigation.to"])
        XCTAssertEqual(removed.string("navigation.from"), "/checkout/step2")
        XCTAssertEqual(removed.string("app.screen.name"), "/cart")
        XCTAssertEqual(removed.string("app.screen.route"), "/cart")
        let issue = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(issue.string("app.screen.name"), "/cart", "the user arrived nowhere")
        XCTAssertEqual(issue.string("app.screen.route"), "/cart")
    }

    func testMessagesStreamAsIssues() throws {
        let client = try start()
        Traceway.captureMessage("checkout reached", attributes: ["step": "3"])
        client.flush(timeout: 5)
        let message = try XCTUnwrap(logs.events("traceway.message").first)
        XCTAssertEqual(message.body, .string("checkout reached"))
        XCTAssertEqual(message.string("step"), "3")
        XCTAssertNotNil(message.string("traceway.exception.id"))
    }

    func testSampledOutExceptionsAreDroppedWithoutFlushing() throws {
        let client = try start(TracewayOptions(sampleRate: 0))
        Traceway.log("breadcrumb")
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertTrue(logs.events("exception").isEmpty)
        XCTAssertTrue(logs.consoleLines.isEmpty)
    }

    func testIdenticalErrorsCollapseAndCountWhatWasSuppressed() throws {
        let client = try start()
        struct Same: Error {}
        for _ in 0..<3 { Traceway.captureException(Same()) }
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("exception").count, 1)
        Thread.sleep(forTimeInterval: 1.1)
        Traceway.captureException(Same())
        client.flush(timeout: 5)
        let second = logs.events("exception")
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.last?.attributes["traceway.error.suppressed_count"], .int(2))
    }

    func testGlobalAttributesAreStampedOnLaterRecords() throws {
        let client = try start(TracewayOptions(attributes: ["tenant": "acme"]))
        Traceway.setAttribute("user.id", "u-1")
        Traceway.captureMessage("hello")
        client.flush(timeout: 5)
        let message = try XCTUnwrap(logs.events("traceway.message").first)
        XCTAssertEqual(message.string("user.id"), "u-1")
        XCTAssertEqual(message.string("tenant"), "acme")
    }

    func testCustomEventsCarryTheirAttributes() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        Traceway.track("checkout_failed", attributes: ["reason": "card_declined", "attempt": 2, "retry": true])
        client.flush(timeout: 5)
        let event = try XCTUnwrap(logs.events("checkout_failed").first)
        XCTAssertEqual(event.string("reason"), "card_declined")
        XCTAssertEqual(event.attributes["attempt"], .int(2))
        XCTAssertEqual(event.attributes["retry"], .bool(true))
    }

    // MARK: - Local and remote settings

    func testLocalCollectionSettingsAndTriggersApply() throws {
        let client = try start(TracewayOptions(collection: [
            "signals": ["navigation": ["mode": "stream"]],
            "triggers": [[
                "id": "checkout-failed-twice",
                "steps": [[
                    "match": ["key": "event.name", "op": "eq", "value": "checkout_failed"],
                    "count": 2, "periodSeconds": 60,
                ]],
                "actions": [["type": "flush", "lookbackSeconds": 120, "signals": ["*"]]],
            ]],
        ], remoteConfig: false))
        Traceway.recordNavigation("/cart")
        Traceway.log("before")
        Traceway.track("checkout_failed")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("browser.navigation").count, 1, "navigation streams")
        XCTAssertTrue(logs.consoleLines.isEmpty, "console still buffers")
        Traceway.track("checkout_failed")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.consoleLines.count, 1, "the second event flushed the buffer")
        XCTAssertEqual(logs.events("checkout_failed").count, 2)
        XCTAssertTrue(server.requests(to: "/api/otel/v1/opamp").isEmpty, "remoteConfig: false never polls")
    }

    func testRemoteConfigFromOpampAppliesAndIsReported() throws {
        server.remoteConfig = #"{"schemaVersion":1,"signals":{"console":{"mode":"stream"}}}"#
        let client = try start()
        XCTAssertTrue(eventually { client.onQueueSync { client.control.modeFor("console") } == .stream })
        Traceway.log("now streamed")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.consoleLines.first?.body, .string("now streamed"))
        XCTAssertNotNil(logs.events("traceway.config.applied").first?.string("traceway.config.hash"))
        let poll = try XCTUnwrap(server.requests(to: "/api/otel/v1/opamp").first)
        XCTAssertEqual(poll.headers["Authorization"], "Bearer token")
        XCTAssertEqual(poll.headers["Content-Type"], "application/x-protobuf")
        XCTAssertEqual(poll.headers["OpAMP-Instance-UID"], client.instanceId)
    }

    func testCeilingsHoldAgainstRemoteSettings() throws {
        server.remoteConfig = #"{"signals":{"console":{"mode":"stream"},"network":{"mode":"stream"}}}"#
        let client = try start(TracewayOptions(captureLogs: false))
        XCTAssertTrue(eventually { !self.logs.events("traceway.config.applied").isEmpty || {
            client.flush(timeout: 1); return !self.logs.events("traceway.config.applied").isEmpty
        }() })
        XCTAssertEqual(client.onQueueSync { client.control.modeFor("console") }, .off)
        XCTAssertEqual(client.onQueueSync { client.control.modeFor("network") }, .stream)
    }

    func testTheConfigIsCachedForTheNextStart() throws {
        let dir = temporaryDirectory().appendingPathComponent("traceway_v2")
        server.remoteConfig = #"{"signals":{"custom":{"mode":"stream"}}}"#
        var client = try start(stateDirectory: dir)
        XCTAssertTrue(eventually { client.onQueueSync { client.control.modeFor("custom") } == .stream })
        client.shutdown()

        server.remoteConfig = nil
        client = try start(stateDirectory: dir)
        // In effect before the first poll answers.
        XCTAssertEqual(client.onQueueSync { client.control.modeFor("custom") }, .stream)
    }

    func testTheInstanceIdSurvivesRestarts() throws {
        let dir = temporaryDirectory().appendingPathComponent("traceway_v2")
        var client = try start(stateDirectory: dir)
        let id = client.instanceId
        XCTAssertEqual(id.count, 36)
        client.shutdown()
        client = try start(stateDirectory: dir)
        XCTAssertEqual(client.instanceId, id)
    }

    // MARK: - Standalone

    func testStandaloneNeedsADestinationAndNeverPolls() throws {
        XCTAssertThrowsError(try TracewayClient.start(token: nil, options: TracewayOptions()))
        let client = try start(
            TracewayOptions(telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp")),
            token: nil
        )
        Traceway.captureMessage("standalone")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("traceway.message").count, 1)
        XCTAssertTrue(logs.events("session.start").isEmpty, "no session records without Traceway")
        XCTAssertNotNil(client.currentSessionId, "the session id still exists")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testTelemetryRoutesSplitIssuesFromOrdinaryLogs() throws {
        let routes = try TelemetryRoutes.resolve(
            endpoints: resolveEndpoints("https://traceway.example.com/api/report"),
            token: "t",
            telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp/", headers: ["x-key": "k"])
        )
        XCTAssertEqual(routes.logs.url.absoluteString, "https://collector.example.com/otlp/v1/logs")
        XCTAssertEqual(routes.traces.url.absoluteString, "https://collector.example.com/otlp/v1/traces")
        XCTAssertEqual(routes.logs.headers, ["x-key": "k"])
        XCTAssertTrue(routes.splitsLogs)
        XCTAssertEqual(routes.traceway?.url.absoluteString, "https://traceway.example.com/api/otel/v1/logs")
        XCTAssertEqual(routes.traceway?.headers["Authorization"], "Bearer t")
        XCTAssertThrowsError(try TelemetryRoutes.resolve(endpoints: nil, token: nil,
                                                         telemetry: TracewayTelemetry(url: "https://u:p@x.com")))
    }

    func testEndpointsAreDerivedFromTheConnectionString() throws {
        for url in ["https://Traceway.Example.com/api/report", "https://traceway.example.com/", "https://traceway.example.com:443/api"] {
            let endpoints = try resolveEndpoints(url)
            XCTAssertEqual(endpoints.base, "https://traceway.example.com")
            XCTAssertEqual(endpoints.opamp.absoluteString, "https://traceway.example.com/api/otel/v1/opamp")
            XCTAssertEqual(endpoints.recordings.absoluteString, "https://traceway.example.com/api/recordings")
            XCTAssertTrue(endpoints.isOwn("https://traceway.example.com/api/otel/v1/logs"))
            XCTAssertFalse(endpoints.isOwn("https://traceway.example.com/api/users"))
        }
    }

    // MARK: - Replay

    func testAnExceptionUploadsItsReplayClip() throws {
        let source = FakeReplaySource()
        let client = try start(TracewayOptions(screenCapture: true), replay: source)
        XCTAssertTrue(eventually { source.isRunning }, "buffer mode records")
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        let exception = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(exception.string("traceway.replay.status"), "requested")
        XCTAssertTrue(eventually { !self.server.segments.isEmpty })
        let segment = try XCTUnwrap(server.segments.first)
        XCTAssertEqual(segment["exceptionId"]?.string, exception.string("traceway.exception.id"))
        XCTAssertEqual(segment["sessionId"]?.string, client.currentSessionId)
        XCTAssertEqual(segment["events"]?.array?.first?["type"], 4)
        let upload = try XCTUnwrap(server.requests(to: "/api/recordings").first)
        XCTAssertEqual(upload.headers["Authorization"], "Bearer token")
    }

    func testReplayIsOffWithoutScreenCapture() throws {
        let source = FakeReplaySource()
        let client = try start(TracewayOptions(screenCapture: false), replay: source)
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertFalse(source.isRunning)
        XCTAssertTrue(server.requests(to: "/api/recordings").isEmpty)
    }

    func testRecordAllSessionsStreamsReplaySegments() throws {
        let source = FakeReplaySource()
        let client = try start(TracewayOptions(screenCapture: true, recordAllSessions: true), replay: source)
        XCTAssertTrue(eventually { source.isRunning })
        XCTAssertEqual(client.onQueueSync { client.replay.mode }, .stream)
        // A segment covers the time since streaming began.
        Thread.sleep(forTimeInterval: 0.05)
        client.appPaused {}
        XCTAssertTrue(eventually { !self.server.segments.isEmpty })
        let segment = try XCTUnwrap(server.segments.first)
        XCTAssertNil(segment["exceptionId"])
        XCTAssertEqual(segment["segmentIndex"]?.int, 0)
    }

    // MARK: - Spans

    func testSpansAreRequestsOrCustomAndStampedWithTheSession() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        let tracer = try XCTUnwrap(Traceway.tracer)
        let request = tracer.spanBuilder(spanName: "GET").setSpanKind(spanKind: .client).startSpan()
        request.setAttribute(key: "http.request.method", value: "GET")
        request.setAttribute(key: "url.full", value: "https://api.example.com/items")
        request.end()
        tracer.spanBuilder(spanName: "checkout").startSpan().end()
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.spans.spans.count == 2 })
        for span in spans.spans {
            XCTAssertEqual(span.attributes["session.id"], .string(client.currentSessionId ?? ""))
            XCTAssertNotNil(span.attributes["traceway.collection.source"])
            // The attributes the SDK adds count as recorded: the OTLP
            // exporter sends total minus kept as the dropped count, unsigned.
            XCTAssertGreaterThanOrEqual(span.totalAttributeCount, span.attributes.count)
            XCTAssertEqual(SpanAdapter.toProtoSpan(spanData: span).droppedAttributesCount, 0)
        }
    }

    func testRequestSpansBufferUntilAnError() throws {
        let client = try start()
        let tracer = try XCTUnwrap(Traceway.tracer)
        let request = tracer.spanBuilder(spanName: "POST").setSpanKind(spanKind: .client).startSpan()
        request.setAttribute(key: "http.request.method", value: "POST")
        request.end()
        client.flush(timeout: 5)
        XCTAssertTrue(spans.spans.isEmpty)
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.spans.spans.count == 1 })
    }

    // MARK: - Persistence

    func testTheBufferSurvivesARestartWithinTheSession() throws {
        let dir = temporaryDirectory().appendingPathComponent("traceway_v2")
        var client = try start(TracewayOptions(remoteConfig: false), stateDirectory: dir)
        let session = client.currentSessionId
        Traceway.log("before the restart")
        // The app goes to the background, where the system kills it.
        let paused = expectation(description: "paused")
        client.appPaused { paused.fulfill() }
        wait(for: [paused], timeout: 5)
        client.killForTesting()
        logs = MemoryLogExporter()

        client = try start(TracewayOptions(remoteConfig: false), stateDirectory: dir)
        XCTAssertEqual(client.currentSessionId, session, "the session goes on")
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertEqual(logs.consoleLines.first?.body, .string("before the restart"))
        XCTAssertEqual(logs.events("traceway.session.update").count, 1)
    }

    func testAHardCrashFromTheLastRunIsReportedOnStart() throws {
        let base = temporaryDirectory()
        let diagnostics = try diagnosticFixtureDirectory(base.appendingPathComponent("traceway_v2"), token: "token", baseUrl: "https://traceway.example.com")
        let crashDir = CrashRecordStore.directory(base: diagnostics)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        let record = """
        TRACEWAY_SIGNAL_V1
        signal=11
        time=1700000000
        appVersion=1.0
        attr.session.id=11111111-2222-4333-8444-555555555555
        attr.traceway.session.started_at=1699999990000
        arch=arm64
        ---IMAGES---
        100000 4000 0123456789abcdef0123456789abcdef MyApp
        ---FRAMES---
        0x100123
        """
        try record.write(to: crashDir.appendingPathComponent("crash-1.tw"), atomically: true, encoding: .utf8)

        let client = try start(stateDirectory: base.appendingPathComponent("traceway_v2"))
        client.flush(timeout: 5)
        let crash = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(crash.string("exception.type"), "Fatal Signal SIGSEGV (11)")
        XCTAssertEqual(crash.attributes["traceway.crash"], .bool(true))
        XCTAssertEqual(crash.string("session.id"), "11111111-2222-4333-8444-555555555555")
        // Only session events carry the session's start.
        XCTAssertNil(crash.attributes["traceway.session.started_at"])
        XCTAssertEqual(Clock.ms(crash.timestamp), 1_700_000_000_000)
        XCTAssertTrue(crash.string("exception.stacktrace")?.contains("0123456789abcdef0123456789abcdef 0x123 MyApp") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashDir.appendingPathComponent("crash-1.tw").path))
    }

    /// A crash found on disk is the run before's: without a session of its
    /// own it is not put in this run's, and no trigger of this run fires.
    func testACrashOfAnEarlierRunIsNotPutInThisRunsSession() throws {
        let base = temporaryDirectory()
        let state = base.appendingPathComponent("traceway_v2")
        let diagnostics = try diagnosticFixtureDirectory(state, token: "token", baseUrl: "https://traceway.example.com")
        let crashDir = CrashRecordStore.directory(base: diagnostics)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        try """
        TRACEWAY_SIGNAL_V1
        signal=11
        time=1700000000
        appVersion=1.0
        ---FRAMES---
        0x100123
        """.write(to: crashDir.appendingPathComponent("crash-1.tw"), atomically: true, encoding: .utf8)

        let client = try start(stateDirectory: state)
        client.flush(timeout: 5)
        let crash = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(crash.attributes["traceway.previous_run"], .bool(true))
        XCTAssertNil(crash.attributes["session.id"], "not this run's session")
        XCTAssertNotNil(client.currentSessionId)
        XCTAssertEqual(crash.string("traceway.replay.status"), "buffer_unavailable")
        XCTAssertTrue(logs.events("traceway.trigger.fired").isEmpty, "no trigger of this run fires for it")
    }

    /// The breadcrumbs the crashed run left on disk are its context: they
    /// still go up with it. What this run recorded does not.
    func testACrashOfAnEarlierRunBringsTheBreadcrumbsThatRunLeft() throws {
        let base = temporaryDirectory()
        let state = base.appendingPathComponent("traceway_v2")
        var client = try start(TracewayOptions(remoteConfig: false), stateDirectory: state)
        let session = try XCTUnwrap(client.currentSessionId)
        Traceway.log("before the crash")
        let paused = expectation(description: "paused")
        client.appPaused { paused.fulfill() }
        wait(for: [paused], timeout: 5)
        client.killForTesting()
        logs = MemoryLogExporter()

        let diagnostics = try diagnosticFixtureDirectory(state, token: "token", baseUrl: "https://traceway.example.com")
        let crashDir = CrashRecordStore.directory(base: diagnostics)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        try """
        TRACEWAY_SIGNAL_V1
        signal=11
        time=\(Int(Date().timeIntervalSince1970))
        appVersion=1.0
        attr.session.id=\(session)
        ---FRAMES---
        0x100123
        """.write(to: crashDir.appendingPathComponent("crash-1.tw"), atomically: true, encoding: .utf8)

        client = try start(TracewayOptions(remoteConfig: false), stateDirectory: state)
        Traceway.log("after the restart")
        client.flush(timeout: 5)
        let crash = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(crash.string("session.id"), session)
        XCTAssertEqual(crash.attributes["traceway.previous_run"], .bool(true))
        XCTAssertEqual(logs.consoleLines.map { $0.body }, [.string("before the crash")])
        XCTAssertTrue(logs.events("traceway.trigger.fired").isEmpty)
    }

    func testUnattributedReportsOfEarlierSDKVersionsAreDiscarded() throws {
        let base = temporaryDirectory()
        let pending = base.appendingPathComponent("traceway_pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let now = ISO8601.format(millis: Clock.nowMs() - 60_000)
        let report = """
        {"createdAt":"\(now)","exception":{"stackTrace":"MyError: boom\\n#00 0x1","recordedAt":"\(now)","attributes":{"os.name":"ios"},"isMessage":false}}
        """
        try report.write(to: pending.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let crashDirectory = CrashRecordStore.directory(base: base)
        try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
        try "TRACEWAY_SIGNAL_V1\nsignal=6\ntime=1700000000\n---FRAMES---\n".write(
            to: crashDirectory.appendingPathComponent("crash-1.tw"), atomically: true, encoding: .utf8)

        let client = try start(stateDirectory: base.appendingPathComponent("traceway_v2"))
        client.flush(timeout: 5)
        XCTAssertTrue(logs.events("exception").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    // MARK: - Logs, screens and issues

    func testALogLineHasNoEventNameAndCarriesItsLevelAndAttributes() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        XCTAssertEqual(Traceway.currentSessionId, client.currentSessionId)
        Traceway.log("cache warmed", level: .warn, attributes: ["cache": "images", "log.source": "mine"])
        Traceway.log("too quiet", level: .debug)
        client.flush(timeout: 5)
        XCTAssertEqual(logs.consoleLines.count, 1, "below the console's minimum severity")
        let line = try XCTUnwrap(logs.consoleLines.first)
        XCTAssertNil(line.eventName)
        XCTAssertEqual(line.severity, .warn)
        XCTAssertEqual(line.severity?.description, "WARN")
        XCTAssertEqual(line.body, .string("cache warmed"))
        XCTAssertEqual(line.string("cache"), "images")
        XCTAssertEqual(line.string("log.source"), "api")
        XCTAssertNil(line.attributes["log.severity"])
        XCTAssertTrue(logs.events("browser.console").isEmpty)
    }

    func testIssuesCarryTheScreenTheyHappenedOn() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        client.screen.viewport = "390x844"
        Traceway.recordNavigation("/cart")
        Traceway.recordNavigation("/orders/42", from: "/cart")
        Traceway.setRoute("orders/{id}")
        struct Declined: Error {}
        Traceway.captureException(Declined(), attributes: ["order": "42"])
        Traceway.captureMessage("paid", attributes: ["viewport": "mine"])
        // The same screen again keeps its route; the next one loses it.
        Traceway.recordNavigation("/orders/42")
        Traceway.recordNavigation("/done", action: "pop", from: "/orders/42")
        client.flush(timeout: 5)

        let exception = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(exception.string("app.screen.name"), "/orders/42")
        XCTAssertEqual(exception.string("app.screen.route"), "/orders/{id}")
        XCTAssertEqual(exception.string("app.screen.previous"), "/cart")
        XCTAssertEqual(exception.string("viewport"), "390x844")
        XCTAssertEqual(exception.string("order"), "42")
        guard case .int(let shownMs)? = exception.attributes["app.screen.duration_ms"] else {
            return XCTFail("app.screen.duration_ms is a number")
        }
        XCTAssertGreaterThanOrEqual(shownMs, 0)
        let message = try XCTUnwrap(logs.events("traceway.message").first)
        XCTAssertEqual(message.string("app.screen.route"), "/orders/{id}")
        XCTAssertEqual(message.string("viewport"), "mine", "the caller's attributes win")

        let navigations = logs.events("browser.navigation")
        XCTAssertEqual(navigations.map { $0.string("url.full") }, ["/cart", "/orders/42", "/orders/42", "/done"])
        XCTAssertEqual(navigations.map { $0.string("app.screen.route") }, [nil, nil, "/orders/{id}", nil])
        XCTAssertEqual(navigations.last?.string("navigation.action"), "pop")
        XCTAssertEqual(navigations.last?.string("navigation.from"), "/orders/42")
        XCTAssertEqual(navigations.last?.string("app.screen.name"), "/done")
        XCTAssertEqual(ScreenState.template(" checkout "), "/checkout")
    }

    func testANavigationCanNameItsRouteTemplate() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        Traceway.recordNavigation("/orders/8841", from: "/cart", route: "orders/:id")
        struct Declined: Error {}
        Traceway.captureException(Declined())
        Traceway.recordNavigation("/home")
        client.flush(timeout: 5)
        let navigations = logs.events("browser.navigation")
        XCTAssertEqual(navigations.map { $0.string("app.screen.route") }, ["/orders/:id", nil])
        XCTAssertEqual(try XCTUnwrap(logs.events("exception").first).string("app.screen.route"), "/orders/:id")
        XCTAssertNil(ScreenState.template("  "))
        XCTAssertEqual(ScreenState.template(String(repeating: "a", count: 100))?.count, 64)
    }

    func testNetworkNoiseIsNotReportedByDefault() throws {
        let client = try start()
        func urlError(_ code: Int, _ text: String) -> NSError {
            NSError(domain: "NSURLErrorDomain", code: code, userInfo: [NSLocalizedDescriptionKey: text])
        }
        Traceway.captureException(urlError(-1009, "The Internet connection appears to be offline."))
        Traceway.captureException(urlError(-1001, "The request timed out."))
        Traceway.captureException(urlError(-1003, "A server with the specified hostname could not be found."))
        Traceway.captureException(urlError(-1005, "Lost it."))
        Traceway.captureMessage("Upload failed: 404")
        Traceway.captureMessage("Gateway timeout")
        Traceway.captureException(urlError(-1011, "The server returned a bad response."))
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("exception").map { $0.string("exception.message") },
                       ["The server returned a bad response. (code -1011)"])
        XCTAssertTrue(logs.events("traceway.message").isEmpty)
        let line = ignoreLine(type: "Foundation.URLError", message: "Error Domain=NSURLErrorDomain Code=-1009 \"(null)\"")
        XCTAssertTrue(TracewayOptions.defaultIgnoreErrors.contains { $0.matches(line) }, "a URLError's form too")
        XCTAssertEqual(ignoreLine(type: "E", message: "E: boom\nframe"), "E: boom", "the first line only")
    }

    func testIgnoreErrorsAndBeforeCaptureDecideWhatIsReported() throws {
        struct Broken: Error {}
        let lock = NSLock()
        var seen: [TracewayCapturedError] = []
        let client = try start(TracewayOptions(
            ignoreErrors: ["Ignored", .regex(#"^Noise\b"#)],
            beforeCapture: { captured in
                lock.lock(); seen.append(captured); lock.unlock()
                if captured.attributes["drop"] == "yes" { return false }
                if captured.message == "explode" { throw Broken() }
                return true
            }
        ))
        client.screen.navigated(to: "/pay", atMs: Clock.nowMs())
        Traceway.captureMessage("Ignored by its text")
        Traceway.captureMessage("Noise level high")
        Traceway.captureMessage("dropped", attributes: ["drop": "yes"])
        Traceway.captureMessage("explode")
        // A list of its own replaces the defaults.
        Traceway.captureException(NSError(domain: "NSURLErrorDomain", code: -1001,
                                          userInfo: [NSLocalizedDescriptionKey: "The request timed out."]))
        client.flush(timeout: 5)

        XCTAssertEqual(logs.events("traceway.message").map { $0.body }, [.string("explode")],
                       "a callback that throws keeps the record")
        XCTAssertEqual(logs.events("exception").count, 1)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(seen.map(\.message), ["dropped", "explode", "The request timed out. (code -1001)"])
        let message = seen[0]
        XCTAssertTrue(message.isMessage)
        XCTAssertNil(message.type)
        XCTAssertNil(message.error)
        XCTAssertNil(message.stackTrace)
        XCTAssertEqual(message.attributes["app.screen.name"], "/pay")
        let exception = seen[2]
        XCTAssertFalse(exception.isMessage)
        XCTAssertEqual(exception.type, "NSURLErrorDomain")
        XCTAssertNotNil(exception.error)
        XCTAssertTrue(exception.stackTrace?.contains("os: ios arch:") == true)
    }

    func testDroppedDataIsReportedAsCollectionHealth() throws {
        let client = try start()
        struct Same: Error {}
        for _ in 0..<3 { Traceway.captureException(Same()) }
        XCTAssertTrue(eventually(timeout: 5) {
            client.flush(timeout: 1)
            return !self.logs.events("traceway.collection.health").isEmpty
        })
        let health = try XCTUnwrap(logs.events("traceway.collection.health").first)
        XCTAssertEqual(health.attributes["traceway.error.suppressed_total"], .int(2))
        XCTAssertEqual(health.attributes["traceway.replay.failed_segments"], .int(0))
        XCTAssertEqual(health.attributes["traceway.collection.max_events"], .int(10_000))
        XCTAssertEqual(health.attributes["traceway.replay.image_bytes"], .int(0))
        XCTAssertEqual(health.string("session.id"), client.currentSessionId)
        let update = try XCTUnwrap(logs.events("traceway.session.update").first, "the session row learns of it once")
        XCTAssertEqual(update.attributes["traceway.error.suppressed_total"], .int(2))
    }

    func testSessionEventsCarryTheImagesPolicy() throws {
        func policy(_ options: TracewayOptions) throws -> String? {
            TracewayClient.resetForTesting()
            logs = MemoryLogExporter()
            let client = try start(options, replay: FakeReplaySource())
            client.flush(timeout: 5)
            let started = try XCTUnwrap(logs.events("session.start").first)
            XCTAssertEqual(started.attributes["traceway.replay.image_bytes"], .int(0))
            return started.string("traceway.replay.images")
        }
        XCTAssertEqual(try policy(TracewayOptions(screenCapture: true)), "wifi", "the setting's default")
        XCTAssertEqual(try policy(TracewayOptions(screenCapture: true, replayImages: .off)), "off")
        XCTAssertEqual(try policy(TracewayOptions(screenCapture: true, replayImages: .wifi,
                                                  collection: ["replay": ["images": "always"]])), "wifi")
        XCTAssertEqual(try policy(TracewayOptions(screenCapture: true, collection: ["replay": ["images": "always"]])),
                       "always")
        XCTAssertEqual(try policy(TracewayOptions(screenCapture: false)), "off")
    }

    // MARK: - Interactions

    func testAnInteractionTracesWhatRunsInIt() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        let checkout = Traceway.startInteraction("checkout", attributes: ["cart.items": 3])
        XCTAssertEqual(checkout.traceId?.count, 32)
        XCTAssertEqual(checkout.spanId?.count, 16)
        let total = checkout.run { () -> Int in
            Traceway.log("placing the order")
            return 42
        }
        XCTAssertEqual(total, 42)
        checkout.setAttribute("payment", "card")
        struct Declined: Error {}
        checkout.captureException(Declined())
        checkout.end()
        checkout.end(failed: false)
        XCTAssertTrue(checkout.isEnded)
        client.flush(timeout: 5)

        XCTAssertTrue(eventually { self.spans.spans.contains { $0.name == "checkout" } })
        let span = try XCTUnwrap(spans.spans.first { $0.name == "checkout" })
        XCTAssertEqual(spans.spans.filter { $0.name == "checkout" }.count, 1)
        XCTAssertEqual(span.attributes["traceway.interaction"], .bool(true))
        XCTAssertEqual(span.attributes["cart.items"], .int(3))
        XCTAssertEqual(span.attributes["payment"], .string("card"))
        XCTAssertTrue(span.status.isError, "an exception fails the interaction")
        XCTAssertEqual(span.kind, .internal)
        let exception = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(exception.spanContext?.traceId.hexString, checkout.traceId)
        XCTAssertEqual(exception.spanContext?.spanId.hexString, checkout.spanId)
        let line = try XCTUnwrap(logs.consoleLines.first)
        XCTAssertEqual(line.spanContext?.traceId.hexString, checkout.traceId)

        let search = Traceway.startInteraction("search")
        search.end(failed: true)
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.spans.spans.contains { $0.name == "search" && $0.status.isError } })
    }

    /// A failed interaction goes with the exception that failed it, as on
    /// Android, Flutter and in the browser, so the issue links to its trace
    /// (it ends after the exception's flush took the buffer); one that
    /// succeeds waits in the buffer like other spans.
    func testAFailedInteractionIsSentWithItsException() throws {
        let client = try start()
        let checkout = Traceway.startInteraction("checkout")
        struct Declined: Error {}
        checkout.captureException(Declined())
        checkout.end()
        let search = Traceway.startInteraction("search")
        search.end()
        let browse = Traceway.startInteraction("browse")
        browse.end(failed: true)
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.spans.spans.contains { $0.name == "checkout" } },
                      "the failed interaction is sent with its exception")
        XCTAssertTrue(spans.spans.contains { $0.name == "browse" && $0.status.isError })
        XCTAssertFalse(spans.spans.contains { $0.name == "search" }, "a successful one waits in the buffer")
        XCTAssertEqual(logs.events("exception").first?.spanContext?.traceId.hexString, checkout.traceId)
    }

    func testAnInteractionBeforeStartRecordsNothing() {
        let interaction = Traceway.startInteraction("early")
        XCTAssertNil(interaction.traceId)
        XCTAssertEqual(interaction.run { 7 }, 7)
        interaction.end()
        XCTAssertTrue(interaction.isEnded)
    }

    // MARK: - Outbox

    func testTheOutboxQueuesTransientFailuresAndDrainsThemLater() throws {
        let dir = temporaryDirectory()
        let flaky = FlakyTransport()
        let destination = OtlpDestination(url: URL(string: "https://traceway.example.com/api/otel/v1/logs")!,
                                          headers: ["Authorization": "Bearer t"])
        let outbox = Outbox(directory: dir, destinations: ["logs": destination], transport: flaky)
        outbox.claim()
        XCTAssertTrue(outbox.add(kind: "logs", body: Data([1, 2, 3]), gzipped: true))
        XCTAssertFalse(outbox.add(kind: "metrics", body: Data([1]), gzipped: false), "unknown kinds are refused")
        flaky.status = 503
        let first = expectation(description: "first drain")
        outbox.drain { first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertEqual(outbox.pendingCount, 1)
        flaky.status = 200
        let second = expectation(description: "second drain")
        outbox.drain { second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(outbox.pendingCount, 0)
        let sent = try XCTUnwrap(flaky.requests.last)
        XCTAssertEqual(sent.headers["Content-Encoding"], "gzip")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer t")
        XCTAssertEqual(sent.body, Data([1, 2, 3]))

        // Another destination's outbox drops what it did not queue.
        let other = Outbox(directory: dir, destinations: ["logs": OtlpDestination(url: destination.url, headers: [:])],
                           transport: flaky)
        XCTAssertTrue(outbox.add(kind: "logs", body: Data([4]), gzipped: false))
        other.claim()
        XCTAssertEqual(outbox.pendingCount, 0)
        outbox.dispose()
        other.dispose()
    }

    // MARK: - Crash safety (review IOS-3, 7, 8, 10, 18, 19, 20, 21)

    /// IOS-3: on Apple platforms `JSONSerialization` raises an Objective-C
    /// exception for anything that is not JSON, which no `catch` stops.
    func testACollectionThatIsNotJSONIsIgnoredInsteadOfRaising() throws {
        let client = try start(TracewayOptions(collection: [
            "captures": [["until": Date()]],
            "buffer": ["maxAgeSeconds": Double.nan],
        ]))
        XCTAssertNotNil(client.currentSessionId)
        XCTAssertEqual(client.onQueueSync { client.control.settings.bufferMaxAgeSeconds },
                       defaultSettings().bufferMaxAgeSeconds)
    }

    /// IOS-7: a corrupt crash file used to trap at every start, before it
    /// was removed: a crash loop until the app was reinstalled.
    func testACorruptCrashFileIsReportedAndRemovedWithoutTrapping() throws {
        let base = scratchDirectory(self)
        let diagnostics = try diagnosticFixtureDirectory(base.appendingPathComponent("traceway_v2"), token: "token", baseUrl: "https://traceway.example.com")
        let crashDir = CrashRecordStore.directory(base: diagnostics)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        let file = crashDir.appendingPathComponent("crash-7.tw")
        try "TRACEWAY_SIGNAL_V1\nsignal=4294967296\ntime=99999999999999999\n---FRAMES---\n0x1\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let before = Clock.nowMs()
        let client = try start(stateDirectory: base.appendingPathComponent("traceway_v2"))
        client.flush(timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let crash = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(crash.string("exception.type"), "Fatal Signal SIG4294967296 (4294967296)")
        // A time past any clock is not believed: the crash is dated now.
        XCTAssertGreaterThanOrEqual(Clock.ms(crash.timestamp), before - 1)
        XCTAssertLessThanOrEqual(Clock.ms(crash.timestamp), Clock.nowMs() + 1)
    }

    /// IOS-8: two `initialize` calls at once each started a full client.
    func testConcurrentStartsShareOneClient() throws {
        let lock = NSLock()
        var results: [ObjectIdentifier?] = Array(repeating: nil, count: 8)
        var clients: [TracewayClient] = []
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            let client = try? self.start()
            lock.lock()
            results[i] = client.map(ObjectIdentifier.init)
            if let client = client, !clients.contains(where: { $0 === client }) { clients.append(client) }
            lock.unlock()
        }
        defer { for client in clients where client !== TracewayClient.shared { client.shutdown() } }
        let shared = try XCTUnwrap(TracewayClient.shared)
        XCTAssertEqual(clients.count, 1, "one client for all eight calls")
        XCTAssertTrue(results.allSatisfy { $0 == ObjectIdentifier(shared) })
        shared.flush(timeout: 5)
        XCTAssertEqual(logs.events("session.start").count, 1)
    }

    /// IOS-10: `flush()` waited without a limit by default.
    func testFlushWaitsAtMostTenSecondsByDefault() throws {
        let silent = HangingTransport()
        let source = FakeReplaySource()
        let client = try start(TracewayOptions(screenCapture: true), replay: source, transport: silent)
        XCTAssertTrue(eventually { source.isRunning })
        struct Boom: Error {}
        Traceway.captureException(Boom())
        // Its clip goes out and never gets an answer.
        XCTAssertTrue(eventually { !silent.requests(to: "/api/recordings").isEmpty })
        let returned = DispatchSemaphore(value: 0)
        let started = Date()
        DispatchQueue.global().async {
            client.flush()
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 15), .success, "flush() returned")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 9)
    }

    /// On the main thread `flush` waits at most 2 seconds, whatever its
    /// timeout: longer is a hang the system may end the app for.
    func testFlushOnTheMainThreadWaitsAtMostTwoSeconds() throws {
        guard Thread.isMainThread else { throw XCTSkip("the test runs off the main thread here") }
        let silent = HangingTransport()
        let source = FakeReplaySource()
        let client = try start(TracewayOptions(screenCapture: true), replay: source, transport: silent)
        XCTAssertTrue(eventually { source.isRunning })
        struct Boom: Error {}
        Traceway.captureException(Boom())
        XCTAssertTrue(eventually { !silent.requests(to: "/api/recordings").isEmpty })
        for timeout in [10, nil] as [TimeInterval?] {
            let started = Date()
            client.flush(timeout: timeout)
            let waited = Date().timeIntervalSince(started)
            XCTAssertGreaterThanOrEqual(waited, 1.9, "\(String(describing: timeout))")
            XCTAssertLessThan(waited, 4, "\(String(describing: timeout))")
        }
        let started = Date()
        client.flush(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "a shorter timeout is kept")
    }

    /// CONTRACT §14.7: spans the app makes with `Traceway.tracer` go through
    /// Traceway with the session id, and nest under the interaction running.
    func testTracerSpansCarryTheSessionAndNestUnderTheInteraction() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        let tracer = try XCTUnwrap(Traceway.tracer)
        let checkout = Traceway.startInteraction("checkout")
        checkout.run {
            tracer.spanBuilder(spanName: "price.compute").startSpan().end()
        }
        checkout.end()
        tracer.spanBuilder(spanName: "outside").startSpan().end()
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.spans.spans.contains { $0.name == "outside" } })
        let inner = try XCTUnwrap(spans.spans.first { $0.name == "price.compute" })
        XCTAssertEqual(inner.traceId.hexString, checkout.traceId)
        XCTAssertEqual(inner.parentSpanId?.hexString, checkout.spanId)
        XCTAssertEqual(inner.attributes["session.id"], .string(client.currentSessionId ?? "none"))
        let outside = try XCTUnwrap(spans.spans.first { $0.name == "outside" })
        XCTAssertNotEqual(outside.traceId.hexString, checkout.traceId)
        XCTAssertEqual(outside.attributes["session.id"], .string(client.currentSessionId ?? "none"))
    }

    /// IOS-10: an `initialize` while the last client was still shutting
    /// down returned that client, and the SDK was off once it finished.
    func testStartingWhileTheLastClientShutsDownStartsANewOne() throws {
        let slow = FakeHTTP { request in
            if request.url.path == "/api/recordings" { Thread.sleep(forTimeInterval: 1) }
            return HTTPResult(statusCode: 200)
        }
        let source = FakeReplaySource()
        let old = try start(TracewayOptions(screenCapture: true, recordAllSessions: true), replay: source,
                            transport: slow)
        XCTAssertTrue(eventually { source.isRunning })
        Thread.sleep(forTimeInterval: 0.05)
        // A segment is on its way; the shutdown waits for its upload.
        old.appPaused {}
        let recordings = URL(string: "https://traceway.example.com/api/recordings")!
        XCTAssertTrue(eventually { !slow.requests(to: recordings).isEmpty })
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            old.shutdown()
            stopped.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)
        let next = try start(transport: slow)
        XCTAssertFalse(next === old)
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(TracewayClient.shared === next)
        XCTAssertFalse(next.isShutdown)
    }

    /// IOS-10: concurrent shutdowns join the first one.
    func testConcurrentShutdownsEndTheSessionOnce() throws {
        let client = try start()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in client.shutdown() }
        XCTAssertTrue(client.isShutdown)
        XCTAssertNil(TracewayClient.shared)
        XCTAssertEqual(logs.events("session.end").count, 1)
    }

    /// IOS-18: a `beforeCapture` that reports through Traceway recursed until
    /// the stack overflowed. A capture made inside it skips the callback.
    func testABeforeCaptureThatCapturesDoesNotRecurse() throws {
        let lock = NSLock()
        var calls = 0
        let client = try start(TracewayOptions(beforeCapture: { _ in
            lock.lock()
            calls += 1
            let n = calls
            lock.unlock()
            if n < 50 { Traceway.captureMessage("from the callback \(n)") }
            return true
        }))
        Traceway.captureMessage("first")
        client.flush(timeout: 5)
        lock.lock()
        XCTAssertEqual(calls, 1)
        lock.unlock()
        XCTAssertEqual(Set(logs.events("traceway.message").compactMap { $0.body?.description }),
                       ["first", "from the callback 1"])
        // Later captures run the callback again.
        Traceway.captureMessage("second")
        client.flush(timeout: 5)
        lock.lock()
        XCTAssertEqual(calls, 2)
        lock.unlock()
    }

    /// IOS-19: garbage numeric options are clamped, not multiplied into a trap.
    func testAbsurdNumericOptionsAreClamped() throws {
        let client = try start(TracewayOptions(fps: .max, maxBufferFrames: .max))
        XCTAssertNotNil(client.currentSessionId)
        let other = try TracewayClient(token: "token", baseUrl: "https://traceway.example.com",
                                       options: TracewayOptions(fps: .min, maxBufferFrames: .min, exportDelayMs: .max))
        XCTAssertFalse(other.isShutdown)
    }

    /// IOS-20: a span the app ends at an impossible time used to trap the
    /// client's queue when the router read its time.
    func testAnAppSuppliedTimeOutsideTheClockDoesNotTrap() throws {
        let client = try start()
        let tracer = try XCTUnwrap(client.openTelemetryTracer)
        let span = tracer.spanBuilder(spanName: "far")
            .setStartTime(time: Date(timeIntervalSince1970: -.infinity))
            .startSpan()
        span.end(time: Date(timeIntervalSince1970: .infinity))
        client.flush(timeout: 5)
        XCTAssertEqual(Clock.ms(Date(timeIntervalSince1970: .infinity)), .max)
        XCTAssertEqual(Clock.ms(Date(timeIntervalSince1970: -.infinity)), .min)
        XCTAssertEqual(Clock.ms(Date(timeIntervalSince1970: .nan)), 0)
        Traceway.captureMessage("still recording")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("traceway.message").count, 1)
    }

    /// IOS-21: a crash from an earlier run is reported under that run's
    /// resource (its app version), and like every record but the session
    /// events it carries no `traceway.session.started_at`.
    func testACrashFromAnEarlierVersionIsReportedUnderThatVersion() throws {
        let base = scratchDirectory(self)
        let diagnostics = try diagnosticFixtureDirectory(base.appendingPathComponent("traceway_v2"), token: "token", baseUrl: "https://traceway.example.com")
        let crashDir = CrashRecordStore.directory(base: diagnostics)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        try """
        TRACEWAY_SIGNAL_V1
        signal=6
        time=1700000000
        appVersion=1.0
        attr.service.version=1.0
        attr.os.version=17.0
        attr.user.id=u1
        attr.session.id=11111111-2222-4333-8444-555555555555
        attr.traceway.session.started_at=1
        ---FRAMES---
        0x100123
        """.write(to: crashDir.appendingPathComponent("crash-21.tw"), atomically: true, encoding: .utf8)

        let client = try start(TracewayOptions(version: "2.0"), stateDirectory: base.appendingPathComponent("traceway_v2"))
        client.flush(timeout: 5)
        let crash = try XCTUnwrap(logs.events("exception").first)
        XCTAssertNil(crash.attributes["traceway.session.started_at"])
        XCTAssertNil(crash.attributes["service.version"])
        XCTAssertNil(crash.attributes["os.version"])
        XCTAssertEqual(crash.resource.attributes["service.version"], .string("1.0"))
        XCTAssertEqual(crash.resource.attributes["os.version"], .string("17.0"))
        XCTAssertEqual(crash.resource.attributes["device.model"], .string("iPhone15,2"))
        XCTAssertEqual(crash.string("user.id"), "u1")
        XCTAssertEqual(crash.string("session.id"), "11111111-2222-4333-8444-555555555555")
        let session = try XCTUnwrap(logs.events("session.start").first)
        XCTAssertEqual(session.resource.attributes["service.version"], .string("2.0"))
    }

    /// IOS-14: each fire of a stream action added an override of its own,
    /// kept for up to a day; the trigger's override is extended instead.
    func testATriggerThatFiresOnEveryRecordKeepsOneOverride() throws {
        let client = try start(TracewayOptions(collection: ["triggers": [
            ["id": "s", "steps": [["match": ["key": "signal", "op": "exists"]]],
             "actions": [["type": "stream", "durationSeconds": 3600]]],
        ]]))
        for i in 0..<2000 { Traceway.log("line \(i)") }
        client.flush(timeout: 5)
        XCTAssertEqual(client.onQueueSync { client.control.activeOverrideCount }, 1)
        // It streams what it covers.
        XCTAssertEqual(client.onQueueSync { client.control.modeFor("console") }, .stream)
    }

    /// IOS-12: what is installed once per process (the URLSession
    /// instrumentation) kept the first client's tracer, dead after its
    /// shutdown.
    func testOncePerProcessHooksRecordForTheClientRunningNow() throws {
        let first = try start(TracewayOptions(recordAllSessions: true))
        let kept = try XCTUnwrap(first.tracer)
        first.shutdown()
        let second = try start(TracewayOptions(recordAllSessions: true))
        kept.spanBuilder(spanName: "lost").startSpan().end()
        CurrentClientTracer { TracewayClient.shared?.tracer }.spanBuilder(spanName: "network").startSpan().end()
        try XCTUnwrap(Traceway.tracer).spanBuilder(spanName: "app span").startSpan().end()
        struct Boom: Error {}
        Traceway.captureException(Boom())
        second.flush(timeout: 5)
        XCTAssertTrue(eventually { Set(self.spans.spans.map(\.name)).isSuperset(of: ["network", "app span"]) })
        XCTAssertFalse(spans.spans.contains { $0.name == "lost" }, "a stopped client's tracer records nothing")
        // With no client running, it records nothing and does not fail.
        second.shutdown()
        CurrentClientTracer { TracewayClient.shared?.tracer }.spanBuilder(spanName: "none").startSpan().end()
        XCTAssertNil(Traceway.tracer)
    }

    /// IOS2-14: Traceway never becomes the global OpenTelemetry, as on
    /// Android, Flutter and the browser: the app's own setup, and what
    /// libraries record through `OpenTelemetry.instance`, stay the app's.
    /// `Traceway.tracer` is how the app makes spans that go to Traceway.
    func testTheGlobalProvidersStayTheApps() throws {
        let client = try start(TracewayOptions(recordAllSessions: true))
        XCTAssertTrue(OpenTelemetry.instance.tracerProvider is DefaultTracerProvider)
        XCTAssertTrue(OpenTelemetry.instance.loggerProvider is DefaultLoggerProvider)
        OpenTelemetry.instance.tracerProvider.get(instrumentationName: "library", instrumentationVersion: nil)
            .spanBuilder(spanName: "library span").startSpan().end()
        try XCTUnwrap(Traceway.tracer).spanBuilder(spanName: "own span").startSpan().end()
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { self.spans.spans.contains { $0.name == "own span" } })
        XCTAssertFalse(spans.spans.contains { $0.name == "library span" })
        // The source no longer registers anything globally.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Traceway")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("registerTracerProvider") || text.contains("registerLoggerProvider"),
                           file.lastPathComponent)
        }
    }
}

/// Takes every request and never answers, as a network that hangs.
final class HangingTransport: HTTPTransport {
    private let lock = NSLock()
    private var seen: [URL] = []

    func requests(to path: String) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return seen.filter { $0.path == path }
    }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        seen.append(url)
        lock.unlock()
    }
}

final class FlakyTransport: HTTPTransport {
    private let lock = NSLock()
    var status = 200
    private(set) var requests: [FakeServer.Request] = []

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        requests.append(FakeServer.Request(url: url, headers: headers, body: body))
        let status = self.status
        lock.unlock()
        DispatchQueue.global().async { completion(HTTPResult(statusCode: status)) }
    }
}

/// The client with the real wireframe recorder, fed frames by hand as the
/// UIKit driver would.
final class WireframeReplayIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        super.tearDown()
    }

    private func screen(_ label: String) -> VNode {
        VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw", "style": "width:390px;height:844px"], children: [
            VNode(element: firstCapturedNodeId, tag: "div", attributes: ["class": "t", "style": "left:16px;top:100px"], children: [
                VNode(text: firstCapturedNodeId + 1, text: label),
            ]),
        ])
    }

    func testAnExceptionUploadsAnRrwebClipOfTheScreen() throws {
        let logs = MemoryLogExporter()
        let server = FakeServer()
        let recorder = WireframeRecorder(maxFrames: 50, fps: 4)
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(screenCapture: true, exportDelayMs: 50),
            overrides: TracewayTestOverrides(
                logExporter: logs, spanExporter: MemorySpanExporter(), transport: server, replaySource: recorder
            )
        )
        XCTAssertTrue(eventually { recorder.isRunning })
        let start = Clock.nowMs() - 2000
        recorder.push(WireframeFrame(screen: screen("Cart"), width: 390, height: 844, timestampMs: start, href: "/cart"))
        recorder.pointerDown(pointer: 1, x: 40, y: 110, touch: true)
        recorder.pointerUp(pointer: 1, x: 40, y: 110, touch: true, tap: true)
        recorder.push(WireframeFrame(screen: screen("Paying…"), width: 390, height: 844,
                                     timestampMs: start + 1000, href: "/cart"))
        // A clip ends where the exception is, exclusive: the tap comes first.
        Thread.sleep(forTimeInterval: 0.02)

        struct PaymentFailed: Error {}
        Traceway.captureException(PaymentFailed())
        client.flush(timeout: 5)

        XCTAssertTrue(eventually { !server.segments.isEmpty })
        let exception = try XCTUnwrap(logs.events("exception").first)
        let segment = try XCTUnwrap(server.segments.first)
        XCTAssertEqual(segment["exceptionId"]?.string, exception.string("traceway.exception.id"))
        let events = try XCTUnwrap(segment["events"]?.array)
        XCTAssertEqual(events.first?["type"], 4, "a Meta event first")
        XCTAssertEqual(events.first?["data"]?["href"]?.string, "/cart")
        XCTAssertEqual(events.dropFirst().first?["type"], 2, "then a full snapshot")
        XCTAssertTrue(events.contains { $0["type"] == 3 && $0["data"]?["source"] == 0 }, "the text change is a mutation")
        XCTAssertTrue(events.contains { $0["type"] == 3 && $0["data"]?["source"] == 2 }, "the tap is an interaction")
        XCTAssertTrue(JSON.array(events).encoded().contains("Paying…"))
        XCTAssertNotNil(segment["startedAt"]?.string)
    }

    func testTighteningInputMaskingDropsWhatWasRecordedBefore() throws {
        let server = FakeServer()
        server.remoteConfig = #"{"replay":{"maskAllInputs":false}}"#
        let recorder = WireframeRecorder(maxFrames: 50, fps: 4)
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(screenCapture: true, exportDelayMs: 50),
            overrides: TracewayTestOverrides(
                logExporter: MemoryLogExporter(), spanExporter: MemorySpanExporter(), transport: server,
                replaySource: recorder
            )
        )
        XCTAssertTrue(eventually { recorder.isRunning && !recorder.maskAllInputs })
        recorder.push(WireframeFrame(screen: screen("4242 4242"), width: 390, height: 844,
                                     timestampMs: Clock.nowMs() - 2000, href: "/pay"))
        client.onQueueSync {
            client.control.applyRemote(["replay": ["maskAllInputs": true]])
            client.applyReplay()
        }
        XCTAssertTrue(recorder.maskAllInputs)
        XCTAssertEqual(recorder.bufferedFrameCount, 0)

        struct PaymentFailed: Error {}
        Traceway.captureException(PaymentFailed())
        client.flush(timeout: 5)
        XCTAssertTrue(server.segments.isEmpty, "nothing recorded before the change goes up")
    }
}
