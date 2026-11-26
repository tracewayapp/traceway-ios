import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
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
        connectionString: String? = "token@https://traceway.example.com",
        stateDirectory: URL? = nil,
        replay: ReplaySource? = nil,
        random: (() -> Double)? = nil
    ) throws -> TracewayClient {
        var options = options
        options.exportDelayMs = 50
        return try TracewayClient.start(
            connectionString: connectionString,
            options: options,
            overrides: TracewayTestOverrides(
                logExporter: logs,
                spanExporter: spans,
                transport: server,
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

    func testAnInvalidConnectionStringDoesNotStart() {
        XCTAssertNil(Traceway.start(connectionString: "no-at-sign"))
        XCTAssertNil(Traceway.start(connectionString: "token@ftp://example.com"))
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
        XCTAssertTrue(logs.events("browser.console").isEmpty)
        XCTAssertTrue(logs.events("traceway.action").isEmpty)

        struct PaymentFailed: Error {}
        Traceway.capture(PaymentFailed(), attributes: ["order": "42"])
        client.flush(timeout: 5)

        let exception = try XCTUnwrap(logs.events("exception").first)
        XCTAssertTrue(exception.string("exception.type")?.contains("PaymentFailed") == true)
        XCTAssertTrue(exception.string("exception.stacktrace")?.contains("os: ios arch:") == true)
        XCTAssertNotNil(exception.string("traceway.exception.id"))
        XCTAssertEqual(exception.string("order"), "42")
        XCTAssertEqual(exception.string("session.id"), client.currentSessionId)
        XCTAssertEqual(exception.string("traceway.replay.status"), "disabled")
        XCTAssertEqual(exception.severity, .error)
        XCTAssertEqual(logs.events("browser.console").first?.body, .string("opened cart"))
        XCTAssertEqual(logs.events("traceway.action").first?.string("traceway.action.data"), "{\"sku\":\"A1\"}")
        XCTAssertEqual(logs.events("browser.navigation").first?.string("url.full"), "/checkout")
        XCTAssertEqual(logs.events("traceway.trigger.fired").first?.string("traceway.trigger.id"), "default-exception")
    }

    func testMessagesStreamAsIssues() throws {
        let client = try start()
        Traceway.capture(message: "checkout reached", attributes: ["step": "3"])
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
        Traceway.capture(Boom())
        client.flush(timeout: 5)
        XCTAssertTrue(logs.events("exception").isEmpty)
        XCTAssertTrue(logs.events("browser.console").isEmpty)
    }

    func testIdenticalErrorsCollapseAndCountWhatWasSuppressed() throws {
        let client = try start()
        struct Same: Error {}
        for _ in 0..<3 { Traceway.capture(Same()) }
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("exception").count, 1)
        Thread.sleep(forTimeInterval: 1.1)
        Traceway.capture(Same())
        client.flush(timeout: 5)
        let second = logs.events("exception")
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.last?.attributes["traceway.error.suppressed_count"], .int(2))
    }

    func testGlobalAttributesAreStampedOnLaterRecords() throws {
        let client = try start(TracewayOptions(attributes: ["tenant": "acme"]))
        Traceway.setAttribute("user.id", "u-1")
        Traceway.capture(message: "hello")
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
        let client = try start(TracewayOptions(remoteConfig: false, collection: [
            "signals": ["navigation": ["mode": "stream"]],
            "triggers": [[
                "id": "checkout-failed-twice",
                "steps": [[
                    "match": ["key": "event.name", "op": "eq", "value": "checkout_failed"],
                    "count": 2, "periodSeconds": 60,
                ]],
                "actions": [["type": "flush", "lookbackSeconds": 120, "signals": ["*"]]],
            ]],
        ]))
        Traceway.recordNavigation("/cart")
        Traceway.log("before")
        Traceway.track("checkout_failed")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("browser.navigation").count, 1, "navigation streams")
        XCTAssertTrue(logs.events("browser.console").isEmpty, "console still buffers")
        Traceway.track("checkout_failed")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("browser.console").count, 1, "the second event flushed the buffer")
        XCTAssertEqual(logs.events("checkout_failed").count, 2)
        XCTAssertTrue(server.requests(to: "/api/otel/v1/opamp").isEmpty, "remoteConfig: false never polls")
    }

    func testRemoteConfigFromOpampAppliesAndIsReported() throws {
        server.remoteConfig = #"{"schemaVersion":1,"signals":{"console":{"mode":"stream"}}}"#
        let client = try start()
        XCTAssertTrue(eventually { client.onQueueSync { client.control.modeFor("console") } == .stream })
        Traceway.log("now streamed")
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("browser.console").first?.body, .string("now streamed"))
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
        XCTAssertThrowsError(try TracewayClient.start(connectionString: nil, options: TracewayOptions()))
        let client = try start(
            TracewayOptions(telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp")),
            connectionString: nil
        )
        Traceway.capture(message: "standalone")
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
        Traceway.capture(Boom())
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
        Traceway.capture(Boom())
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
        Traceway.capture(Boom())
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
        Traceway.capture(Boom())
        client.flush(timeout: 5)
        XCTAssertEqual(logs.events("browser.console").first?.body, .string("before the restart"))
        XCTAssertEqual(logs.events("traceway.session.update").count, 1)
    }

    func testAHardCrashFromTheLastRunIsReportedOnStart() throws {
        let base = temporaryDirectory()
        let crashDir = CrashRecordStore.directory(base: base)
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
        XCTAssertEqual(crash.attributes["traceway.session.started_at"], .int(1_699_999_990_000))
        XCTAssertEqual(Clock.ms(crash.timestamp), 1_700_000_000_000)
        XCTAssertTrue(crash.string("exception.stacktrace")?.contains("0123456789abcdef0123456789abcdef 0x123 MyApp") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashDir.appendingPathComponent("crash-1.tw").path))
    }

    func testUnsentReportsOfTheFirstSDKAreReportedOnce() throws {
        let base = temporaryDirectory()
        let pending = base.appendingPathComponent("traceway_pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let now = ISO8601.format(millis: Clock.nowMs() - 60_000)
        let report = """
        {"createdAt":"\(now)","exception":{"stackTrace":"MyError: boom\\n#00 0x1","recordedAt":"\(now)","attributes":{"os.name":"ios"},"isMessage":false}}
        """
        try report.write(to: pending.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let client = try start(stateDirectory: base.appendingPathComponent("traceway_v2"))
        client.flush(timeout: 5)
        let exception = try XCTUnwrap(logs.events("exception").first)
        XCTAssertEqual(exception.string("exception.type"), "MyError: boom")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
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
            connectionString: "token@https://traceway.example.com",
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
        Traceway.capture(PaymentFailed())
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
}
