// The §14 features inside a running client, read back from in-memory
// exporters. Uses OpenTelemetry's types, so like `TracewayClientTests` it is
// not built into the iOS Simulator bundle (see project.yml).
import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import Traceway

/// Metrics payloads as the client sends them (OpenTelemetry has a `Locked`
/// of its own, so the SDK's is not named here).
private final class Payloads {
    private let lock = NSLock()
    private var bodies: [Data] = []

    func append(_ body: Data) {
        lock.lock()
        bodies.append(body)
        lock.unlock()
    }

    var value: [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }
}

final class AppExitsClientTests: XCTestCase {
    private var logs: MemoryLogExporter!
    private var spans: MemorySpanExporter!
    private var server: FakeServer!
    private var metricBodies: Payloads!

    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
        logs = MemoryLogExporter()
        spans = MemorySpanExporter()
        server = FakeServer()
        metricBodies = Payloads()
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        super.tearDown()
    }

    @discardableResult
    private func start(
        _ options: TracewayOptions = TracewayOptions(),
        stateDirectory: URL? = nil,
        vitalsHost: VitalsHost? = nil,
        scheduler: MetricsScheduler? = nil,
        mainStack: (() -> [UInt]?)? = nil,
        osLog: OSLogEntrySource? = nil,
        graceMs: Int64 = 50
    ) throws -> TracewayClient {
        var options = options
        options.exportDelayMs = 50
        let bodies = metricBodies ?? Payloads()
        return try TracewayClient.start(
            connectionString: "token@https://traceway.example.com",
            options: options,
            overrides: TracewayTestOverrides(
                logExporter: logs,
                spanExporter: spans,
                transport: server,
                stateDirectory: stateDirectory,
                deviceAttributes: ["os.name": "ios", "os.version": "iOS 17.2", "device.model": "iPhone15,2"],
                metricsSink: { body in
                    bodies.append(body)
                    return 200
                },
                metricsScheduler: scheduler,
                vitalsHost: vitalsHost,
                captureMainStack: mainStack,
                osLogSource: osLog,
                exitReasonGraceMs: graceMs
            )
        )
    }

    private var sums: [String: Double] { Decoded(metricBodies.value).sums }

    private func exceptions(_ type: String) -> [ReadableLogRecord] {
        logs.events("exception").filter { $0.string("exception.type") == type }
    }

    private func stateDirectory() -> URL {
        temporaryDirectory().appendingPathComponent("traceway_v2")
    }

    // MARK: - MetricKit (§14.1)

    func testAMetricKitCrashTheSDKDidNotRecordIsANativeCrashIssue() throws {
        let client = try start(stateDirectory: stateDirectory())
        let at = Date(timeIntervalSinceNow: -3600)
        client.receiveDiagnosticPayload(try metricKitFixture("crash-signal"), begin: at, end: at)
        client.flush(timeout: 5)
        let crash = try XCTUnwrap(exceptions("NativeCrash").first)
        XCTAssertEqual(exceptions("NativeCrash").count, 1)
        XCTAssertEqual(crash.severity, .fatal)
        XCTAssertEqual(crash.string("exception.message"), "SIGSEGV (EXC_BAD_ACCESS)")
        XCTAssertTrue(crash.string("exception.stacktrace")?.contains(
            "\n#00 70b89f2716343580a69557cdb41d7743 0x285b8 ShopApp") == true)
        XCTAssertEqual(crash.attributes["traceway.crash"], .bool(true))
        XCTAssertEqual(crash.attributes["exception.escaped"], .bool(true))
        XCTAssertEqual(crash.string("traceway.exit.source"), "metrickit")
        XCTAssertEqual(crash.string("traceway.exit.reason"), "Namespace SIGNAL, Code 0xb")
        XCTAssertEqual(crash.string("traceway.exit.mach_exception"), "EXC_BAD_ACCESS")
        XCTAssertEqual(crash.attributes["traceway.exit.signal"], .int(11))
        XCTAssertNotNil(crash.string("traceway.exception.id"))
        // Under the run that crashed.
        XCTAssertEqual(crash.resource.attributes["service.version"], .string("1.4.0"))
        XCTAssertEqual(crash.resource.attributes["os.version"], .string("iOS 17.2"))
        XCTAssertLessThanOrEqual(abs(Clock.ms(crash.timestamp) - Clock.ms(at)), 1)
        XCTAssertEqual(sums["app.crash"], 1)
    }

    func testACrashTheSignalHandlerRecordedIsNotReportedAgainByMetricKit() throws {
        let state = stateDirectory()
        let base = state.deletingLastPathComponent()
        let crashDir = CrashRecordStore.directory(base: base)
        try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        let crashedAt = Int64(Date().timeIntervalSince1970) - 600
        try """
        TRACEWAY_SIGNAL_V1
        signal=11
        time=\(crashedAt)
        appVersion=1.4.0
        ---FRAMES---
        0x100123
        """.write(to: crashDir.appendingPathComponent("crash-1.tw"), atomically: true, encoding: .utf8)
        let client = try start(stateDirectory: state)
        let at = Date(timeIntervalSince1970: Double(crashedAt))
        client.receiveDiagnosticPayload(try metricKitFixture("crash-signal"), begin: at, end: at.addingTimeInterval(20))
        // Another crash in the same window, which the handler did not record.
        client.receiveDiagnosticPayload(try metricKitFixture("objc-exception"), begin: at, end: at.addingTimeInterval(20))
        client.flush(timeout: 5)
        XCTAssertEqual(exceptions("Fatal Signal SIGSEGV (11)").count, 1, "the handler's own report")
        XCTAssertEqual(exceptions("NativeCrash").count, 1)
        XCTAssertTrue(exceptions("NativeCrash").first?.string("exception.message")?.contains("NSInvalidArgumentException") == true)
        XCTAssertEqual(sums["app.crash"], 2)
    }

    func testAWatchdogTerminationIsAnIssueAndAnANR() throws {
        let client = try start(stateDirectory: stateDirectory())
        let at = Date(timeIntervalSinceNow: -600)
        client.receiveDiagnosticPayload(try metricKitFixture("watchdog"), begin: at, end: at)
        client.flush(timeout: 5)
        let watchdog = try XCTUnwrap(exceptions("WatchdogTermination").first)
        XCTAssertEqual(watchdog.severity, .fatal)
        XCTAssertTrue(watchdog.string("exception.message")?.contains("0x8badf00d") == true)
        XCTAssertTrue(watchdog.string("exception.stacktrace")?.hasPrefix("WatchdogTermination: ") == true)
        XCTAssertNil(watchdog.attributes["traceway.crash"], "the system ended it; it did not crash")
        XCTAssertEqual(sums["app.anr"], 1)
        XCTAssertNil(sums["app.crash"])
    }

    func testCaptureExitReasonsOffIgnoresMetricKit() throws {
        let client = try start(TracewayOptions(captureExitReasons: false), stateDirectory: stateDirectory())
        client.receiveDiagnosticPayload(try metricKitFixture("crash-signal"), begin: Date(), end: Date())
        client.flush(timeout: 5)
        XCTAssertTrue(logs.events("exception").isEmpty)
    }

    // MARK: - Fatal hangs (§14.2)

    private func leaveFatalHang(in state: URL, startedAtMs: Int64, blockedMs: Int64) throws {
        let hang = AppHangReport(
            blockedMs: blockedMs, startedAtMs: startedAtMs,
            traceBody: "\n*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\nos: ios arch: arm64"
                + "\n#00 70b89f2716343580a69557cdb41d7743 0x1234 ShopApp",
            attributes: [Attr.sessionId: "11111111-2222-4333-8444-555555555555", "app.screen.name": "/cart",
                         "app.screen.duration_ms": "1200"],
            resource: ["service.version": "0.9.0"], fatal: false
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try hang.encoded().encodedData().write(to: state.appendingPathComponent(AppHangMonitor.fileName))
    }

    func testAHangThatEndedTheProcessIsReportedAtTheNextStart() throws {
        let state = stateDirectory()
        let startedAt = Clock.nowMs() - 60_000
        try leaveFatalHang(in: state, startedAtMs: startedAt, blockedMs: 15_000)
        let client = try start(stateDirectory: state)
        client.flush(timeout: 5)
        let hang = try XCTUnwrap(exceptions("AppHang").first)
        XCTAssertEqual(hang.string("exception.message"), "Main thread blocked for at least 15.0 s")
        XCTAssertTrue(hang.string("exception.stacktrace")?.hasPrefix(
            "AppHang: Main thread blocked for at least 15.0 s\n*** ***") == true)
        XCTAssertEqual(hang.attributes["app.hang.fatal"], .bool(true))
        XCTAssertEqual(hang.attributes["app.hang.duration_ms"], .int(15_000))
        XCTAssertEqual(hang.string("session.id"), "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(hang.string("app.screen.name"), "/cart")
        XCTAssertEqual(hang.attributes["app.screen.duration_ms"], .int(1200))
        XCTAssertEqual(hang.resource.attributes["service.version"], .string("0.9.0"))
        XCTAssertEqual(hang.severity, .fatal)
        XCTAssertLessThanOrEqual(abs(Clock.ms(hang.timestamp) - startedAt), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(AppHangMonitor.fileName).path))

        // The watchdog termination that ended it is counted, not reported again.
        let killed = Date(timeIntervalSince1970: Double(startedAt + 15_000) / 1000)
        client.receiveDiagnosticPayload(try metricKitFixture("watchdog"), begin: killed, end: killed)
        client.flush(timeout: 5)
        XCTAssertTrue(exceptions("WatchdogTermination").isEmpty)
        XCTAssertEqual(sums["app.anr"], 1)
    }

    // MARK: - Hangs as issues (§14.2)

    /// Drives a running client's watchdog by hand: the next probe waits
    /// `blockedMs` before the main thread runs it.
    private func blockMain(_ host: FakeVitalsHost, _ scheduler: ManualMetricsScheduler, forMs blockedMs: Int64) {
        host.runMain()
        scheduler.advance(500)
        var waited: Int64 = 0
        while waited < blockedMs {
            scheduler.advance(500)
            waited += 500
        }
        host.runMain()
    }

    func testAMainThreadBlockedPastTheThresholdIsAnAppHangIssue() throws {
        let host = FakeVitalsHost()
        let scheduler = ManualMetricsScheduler(nowMs: Clock.nowMs())
        let state = stateDirectory()
        let client = try start(stateDirectory: state, vitalsHost: host, scheduler: scheduler,
                               mainStack: { [0x100123, 0x100456] })
        Traceway.recordNavigation("/cart")
        host.runMain()
        scheduler.advance(500)
        for _ in 0..<4 { scheduler.advance(500) }
        client.appHangs?.settle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent(AppHangMonitor.fileName).path),
                      "kept on disk while the main thread is blocked")
        scheduler.advance(500)
        scheduler.advance(500)
        host.runMain()
        client.appHangs?.settle()
        client.flush(timeout: 5)
        XCTAssertEqual(exceptions("AppHang").count, 1)
        let hang = try XCTUnwrap(exceptions("AppHang").first)
        XCTAssertEqual(hang.string("exception.message"), "Main thread blocked for 3.0 s")
        XCTAssertEqual(hang.attributes["app.hang.fatal"], .bool(false))
        XCTAssertEqual(hang.attributes["app.hang.duration_ms"], .int(3000))
        XCTAssertEqual(hang.severity, .error)
        let trace = try XCTUnwrap(hang.string("exception.stacktrace"))
        XCTAssertTrue(trace.hasPrefix("AppHang: Main thread blocked for 3.0 s\n*** ***"), trace)
        XCTAssertTrue(trace.contains("os: ios arch: "))
        XCTAssertTrue(trace.contains("#00 ") && trace.contains("0x100123"), trace)
        XCTAssertTrue(trace.contains("#01 ") && trace.contains("0x100456"), trace)
        XCTAssertEqual(hang.string("app.screen.name"), "/cart")
        XCTAssertEqual(hang.string("session.id"), client.currentSessionId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent(AppHangMonitor.fileName).path))

        // A block under the threshold is the app.hang metric's business only.
        blockMain(host, scheduler, forMs: 1000)
        client.appHangs?.settle()
        client.flush(timeout: 5)
        XCTAssertEqual(exceptions("AppHang").count, 1)
    }

    func testAppHangsFollowTheirOptions() throws {
        // Off: no monitor.
        var host = FakeVitalsHost()
        var scheduler = ManualMetricsScheduler(nowMs: Clock.nowMs())
        var client = try start(TracewayOptions(captureAppHangs: false), vitalsHost: host, scheduler: scheduler,
                               mainStack: { [0x1] })
        XCTAssertNil(client.appHangs)
        blockMain(host, scheduler, forMs: 3000)
        client.flush(timeout: 5)
        XCTAssertTrue(exceptions("AppHang").isEmpty)
        client.shutdown()

        // Without metrics the watchdog still runs, for the issues alone.
        metricBodies = Payloads()
        host = FakeVitalsHost()
        scheduler = ManualMetricsScheduler(nowMs: Clock.nowMs())
        client = try start(TracewayOptions(captureMetrics: false, appHangThresholdMs: 1000), vitalsHost: host,
                           scheduler: scheduler, mainStack: { [0x1] })
        XCTAssertEqual(client.vitals?.recordsMetrics, false)
        blockMain(host, scheduler, forMs: 1500)
        client.appHangs?.settle()
        client.flush(timeout: 5)
        XCTAssertEqual(exceptions("AppHang").first?.string("exception.message"), "Main thread blocked for 1.5 s")
        XCTAssertNil(sums["app.hang"])
        client.shutdown()

        // Not under a debugger, and not what `ignoreErrors` names.
        logs = MemoryLogExporter()
        host = FakeVitalsHost()
        host.debugger = true
        scheduler = ManualMetricsScheduler(nowMs: Clock.nowMs())
        client = try start(vitalsHost: host, scheduler: scheduler, mainStack: { [0x1] })
        blockMain(host, scheduler, forMs: 3000)
        client.appHangs?.settle()
        client.flush(timeout: 5)
        XCTAssertTrue(exceptions("AppHang").isEmpty)
        client.shutdown()

        host = FakeVitalsHost()
        scheduler = ManualMetricsScheduler(nowMs: Clock.nowMs())
        client = try start(TracewayOptions(ignoreErrors: ["Main thread blocked"]), vitalsHost: host,
                           scheduler: scheduler, mainStack: { [0x1] })
        blockMain(host, scheduler, forMs: 3000)
        client.appHangs?.settle()
        client.flush(timeout: 5)
        XCTAssertTrue(exceptions("AppHang").isEmpty)
    }

    // MARK: - Out of memory (§14.1)

    /// What the next start counts as `app.oom` after a run `prepare` set up
    /// and that ended without a word (killed), or as `end` says.
    private func oomCount(
        _ prepare: (TracewayClient, URL) throws -> Void = { client, _ in client.appResumed() },
        end: (TracewayClient) -> Void = { $0.killForTesting() },
        beforeTheGraceEnds: ((TracewayClient) throws -> Void)? = nil,
        graceMs: Int64 = 50
    ) throws -> Double? {
        let state = stateDirectory()
        let first = try start(stateDirectory: state)
        try prepare(first, state)
        first.flush(timeout: 5)
        end(first)
        TracewayClient.resetForTesting()
        metricBodies = Payloads()
        let second = try start(stateDirectory: state, graceMs: graceMs)
        try beforeTheGraceEnds?(second)
        Thread.sleep(forTimeInterval: Double(graceMs) / 1000 + 0.2)
        second.flush(timeout: 5)
        let count = sums["app.oom"]
        second.shutdown()
        return count
    }

    func testARunThatEndedInTheForegroundWithoutAWordCountsAsOutOfMemory() throws {
        XCTAssertEqual(try oomCount(), 1)
    }

    func testOnlyAnUnexplainedEndInTheForegroundCountsAsOutOfMemory() throws {
        XCTAssertNil(try oomCount({ _, _ in }), "the last run never came to the foreground")
        XCTAssertNil(try oomCount({ client, _ in
            client.appResumed()
            client.appPaused {}
        }), "it went to the background")
        XCTAssertNil(try oomCount(end: { $0.shutdown() }), "it shut the SDK down")
        XCTAssertNil(try oomCount({ client, _ in
            client.appResumed()
            client.appTerminating()
        }), "the system told it it terminates")
        XCTAssertNil(try oomCount({ client, state in
            client.appResumed()
            FileManager.default.createFile(atPath: state.appendingPathComponent(ExitMarker.fileName).path, contents: nil)
        }), "it called exit")
        XCTAssertNil(try oomCount({ client, state in
            client.appResumed()
            let crashDir = CrashRecordStore.directory(base: state.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
            try "TRACEWAY_SIGNAL_V1\nsignal=6\ntime=\(Int(Date().timeIntervalSince1970))\n---FRAMES---\n"
                .write(to: crashDir.appendingPathComponent("crash-9.tw"), atomically: true, encoding: .utf8)
        }), "it crashed")
        XCTAssertNil(try oomCount(beforeTheGraceEnds: { client in
            let now = Date()
            client.receiveDiagnosticPayload(try metricKitFixture("crash-signal"), begin: now, end: now)
        }, graceMs: 1000), "MetricKit reported a crash")
    }

    // MARK: - Log capture (§14.3)

    private func lines(_ source: String) -> [ReadableLogRecord] {
        logs.consoleLines.filter { $0.string("log.source") == source }
    }

    func testUnifiedLogLinesAreReadBeforeAnExceptionAsItsBreadcrumbs() throws {
        let source = FakeOSLogSource()
        let client = try start(osLog: source)
        source.add("cart loaded", at: Date())
        source.add("[Traceway] started, instance 1", at: Date())
        source.add("payment failed", at: Date(), level: .error, subsystem: "com.example.shop", category: "pay")
        source.add("too quiet", at: Date(), level: .debug)
        client.flush(timeout: 5)
        XCTAssertTrue(lines("oslog").isEmpty, "not read yet, and breadcrumbs stay on the device")

        struct Declined: Error {}
        Traceway.captureException(Declined())
        client.flush(timeout: 5)
        XCTAssertEqual(lines("oslog").map { $0.body }, [.string("cart loaded"), .string("payment failed")])
        let failed = try XCTUnwrap(lines("oslog").last)
        XCTAssertEqual(failed.severity, .error)
        XCTAssertEqual(failed.string("oslog.subsystem"), "com.example.shop")
        XCTAssertEqual(failed.string("oslog.category"), "pay")
        XCTAssertNil(failed.eventName)
        XCTAssertEqual(logs.events("exception").count, 1)
    }

    func testLogCaptureFollowsTheConsoleSettings() throws {
        var source = FakeOSLogSource()
        var client = try start(TracewayOptions(collection: ["signals": ["console": ["mode": "off"]]]), osLog: source)
        source.add("hidden", at: Date())
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.recordStdLines(["printed"], stream: "stdout")
        client.flush(timeout: 5)
        XCTAssertTrue(logs.consoleLines.isEmpty)
        XCTAssertEqual(source.reads, 0, "the unified log is not read while the console is off")
        client.shutdown()

        source = FakeOSLogSource()
        client = try start(TracewayOptions(recordAllSessions: true,
                                           collection: ["signals": ["console": ["minSeverity": "warn"]]]),
                           osLog: source)
        source.add("routine", at: Date())
        source.add("disk almost full", at: Date(), level: .warn)
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertEqual(lines("oslog").map { $0.body }, [.string("disk almost full")])
        client.shutdown()

        logs = MemoryLogExporter()
        source = FakeOSLogSource()
        client = try start(TracewayOptions(recordAllSessions: true,
                                           collection: ["signals": ["console": ["sampleRate": 0]]]), osLog: source)
        source.add("sampled out", at: Date())
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertTrue(lines("oslog").isEmpty)
    }

    func testStandardOutputAndErrorLinesAreConsoleLines() throws {
        let client = try start(TracewayOptions(recordAllSessions: true), osLog: FakeOSLogSource())
        client.recordStdLines(["Loaded 12 items", "[Traceway] started"], stream: "stdout")
        client.recordStdLines(["warning: low disk",
                               "2026-11-27 10:00:00.123456+0100 Shop[12:3a] the NSLog copy of an os_log line"],
                              stream: "stderr")
        client.flush(timeout: 5)
        XCTAssertEqual(lines("stdout").map { $0.body }, [.string("Loaded 12 items")])
        XCTAssertEqual(lines("stdout").first?.severity, .info)
        XCTAssertEqual(lines("stderr").map { $0.body }, [.string("warning: low disk")],
                       "NSLog's copy on standard error is read from the unified log instead")
        XCTAssertEqual(lines("stderr").first?.severity, .error)
    }
}
