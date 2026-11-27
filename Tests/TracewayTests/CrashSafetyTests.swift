import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Traceway

/// CONTRACT §13: the SDK never takes the app down. Its sources keep no
/// traps; every public call works before `initialize`, after `shutdown`,
/// twice, at once from many threads and with garbage arguments; what
/// breaks inside (the network, the server's settings, a trigger, the app's
/// callbacks) leaves the app's operation and the SDK itself working; and the
/// app's own crashes still reach the handlers installed before Traceway's.
/// Runs on Linux, the macOS host and the iOS Simulator; the UIKit hooks only
/// on the Simulator.
final class CrashSafetyTests: XCTestCase {
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
        _ options: TracewayOptions = TracewayOptions(),
        transport: HTTPTransport? = nil,
        replay: ReplaySource? = nil
    ) throws -> TracewayClient {
        var options = options
        options.exportDelayMs = 50
        return try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: options,
            overrides: TracewayTestOverrides(
                transport: transport ?? server,
                deviceAttributes: ["os.name": "ios", "device.model": "iPhone15,2"],
                replaySource: replay
            )
        )
    }

    /// Whether an OTLP logs request to `server` carried `text`: protobuf
    /// keeps strings as their UTF-8 bytes, so no decoding is needed.
    private func sent(_ text: String, to server: FakeServer? = nil) -> Bool {
        let needle = Data(text.utf8)
        return (server ?? self.server).requests(to: "/api/otel/v1/logs").contains { request in
            var body = request.body
            if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(body) { body = plain }
            return body.range(of: needle) != nil
        }
    }

    /// The client still records and sends: a message reaches the server.
    /// (`flush` waits at most 2 s on the main thread, so the check waits on.)
    private func assertStillWorks(_ client: TracewayClient, _ marker: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        Traceway.captureMessage(marker)
        client.flush(timeout: 5)
        XCTAssertTrue(eventually(timeout: 15) { self.sent(marker) }, "\(marker) was sent", file: file, line: line)
    }

    // MARK: - No traps in the sources (§13.4)

    /// `try!`, `as!` (but checked CF bridging casts, each marked), force
    /// unwraps and implicitly unwrapped types, `fatalError` and the other
    /// traps, `unowned`, and the Foundation calls that raise an Objective-C
    /// exception without the check that keeps them from it.
    func testTheSourcesKeepNoTraps() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Traceway")
        guard FileManager.default.fileExists(atPath: sources.path) else {
            throw XCTSkip("the package sources are not readable here")
        }
        var problems: [String] = []
        var bridging: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            let name = String(file.path.dropFirst(sources.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            let found = SourceTraps.scan(text)
            problems += found.problems.map { "\(name):\($0)" }
            if found.bridgingCasts > 0 { bridging[name] = found.bridgingCasts }
        }
        XCTAssertEqual(problems, [], "traps in Sources/Traceway")
        // The only `as!` left: CF types checked with CFGetTypeID first.
        XCTAssertEqual(bridging, [
            "Wireframe/WireframeCapture.swift": 2,
            "Wireframe/WireframeSwiftUICapture.swift": 1,
        ])
    }

    /// The scan finds what it bans, and only in code.
    func testTheTrapScanReadsCodeOnly() {
        let flagged = SourceTraps.scan(#"""
        let a = try! load()
        let b = value as! String
        let c = dict["k"]!.count
        let d = f()!
        var e: Int!
        fatalError("no")
        precondition(x > 0)
        [unowned self] in
        let g = try JSONSerialization.data(withJSONObject: object)
        let h = "\(name!)"
        """#).problems
        XCTAssertEqual(flagged.count, 10, "\(flagged)")

        let clean = SourceTraps.scan(#"""
        // try! in a comment, x!, fatalError()
        /* as! /* nested */ y! */
        let s = "Hello! try! as! \"quoted!\" \\"
        let r = #"raw "x!" \(not interpolated!)"#
        let m = """
            fatalError(here) is text!
            """
        if !ready, a != b, c !== d { negate(!flag) }
        let cast = ref as! CGColor // CF bridging: CFGetTypeID checked above
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
        #if !os(iOS)
        let ok = value.map { "\($0) done!" } ?? "none!"
        """#)
        XCTAssertEqual(clean.problems, [])
        XCTAssertEqual(clean.bridgingCasts, 1)
    }

    // MARK: - Public API before init, after shutdown, twice, at once (§13.1)

    /// Every public call, with arguments sane and not.
    private func callEveryPublicAPI(_ i: Int = 0) {
        struct Failure: Error {}
        let huge = String(repeating: "x", count: 100_000)
        Traceway.captureException(Failure(), attributes: ["i": "\(i)", "": huge])
        Traceway.captureException(NSError(domain: "", code: Int.min, userInfo: nil))
        Traceway.captureMessage("message \(i)", attributes: ["k": "v"])
        Traceway.captureMessage("")
        Traceway.log("line \(i)", level: .warn, attributes: ["k": "v"])
        Traceway.log(huge, level: .fatal)
        Traceway.track("event_\(i)", attributes: ["n": i, "d": Double.nan, "date": Date(), "nested": ["a": [1]]])
        Traceway.track("")
        Traceway.recordAction(category: "c", name: "n", data: ["date": Date(), "nan": Double.infinity, "ok": 1])
        Traceway.recordAction(category: "", name: "", data: [:])
        Traceway.recordNavigation("/screen/\(i)", action: "push", from: "/", route: "/screen/{id}")
        Traceway.recordNavigation("", action: "", from: nil, route: "")
        Traceway.setRoute("/screen/{id}")
        Traceway.setRoute(nil)
        Traceway.reportFullyDisplayed()
        Traceway.metric("checkout.duration", value: .nan, dimensions: ["a": 1, "b": Date(), "c": "x"])
        Traceway.metric("bad name!", value: .infinity)
        Traceway.count("cart.add", n: -.greatestFiniteMagnitude, dimensions: [:])
        Traceway.setMetricDimension("plan", "pro")
        Traceway.setMetricDimension("", nil)
        Traceway.setAttribute("user.id", "u\(i)")
        Traceway.setAttribute("", "")
        Traceway.setAttributes(["a": "1", "b": huge])
        Traceway.removeAttribute("a")
        Traceway.removeAttribute("missing")
        Traceway.clearAttributes()
        Traceway.refreshConfig()
        _ = Traceway.instanceId
        _ = Traceway.currentSessionId
        _ = Traceway.client
        _ = Traceway.tracer
        let interaction = Traceway.startInteraction("checkout \(i)", attributes: ["k": Date(), "": 1])
        interaction.setAttribute("step", Double.nan)
        _ = interaction.run { interaction.traceId }
        interaction.captureException(Failure())
        interaction.end(failed: true)
        interaction.end()
        _ = interaction.isEnded
        _ = Traceway.startInteraction("")
    }

    func testEveryPublicCallBeforeInitializeDoesNothing() {
        XCTAssertNil(TracewayClient.shared)
        callEveryPublicAPI()
        Traceway.flush()
        Traceway.flush(timeout: 0)
        Traceway.shutdown()
        XCTAssertNil(Traceway.instanceId)
        XCTAssertNil(Traceway.currentSessionId)
        XCTAssertNil(Traceway.tracer)
        XCTAssertNil(TracewayClient.shared)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testEveryPublicCallAfterShutdownDoesNothing() throws {
        let client = try start()
        client.shutdown()
        XCTAssertNil(TracewayClient.shared)
        let before = server.requests.count
        callEveryPublicAPI()
        // The stopped client itself, still held by the app.
        client.captureMessage("late")
        client.log("late")
        client.track("late")
        client.recordNavigation("/late")
        client.setAttribute("k", "v")
        client.flush(timeout: 1)
        client.shutdown()
        _ = client.instanceId
        _ = client.currentSessionId
        _ = client.startInteraction("late").run { 1 }
        XCTAssertFalse(sent("late"))
        XCTAssertEqual(server.requests.filter { $0.url.path == "/api/otel/v1/logs" }.count,
                       server.requests.prefix(before).filter { $0.url.path == "/api/otel/v1/logs" }.count)
        // A new start works again.
        let next = try start()
        XCTAssertFalse(next === client)
        assertStillWorks(next, "after the restart")
    }

    func testPublicCallsWithGarbageArgumentsLeaveTheClientWorking() throws {
        let client = try start(TracewayOptions(
            sampleRate: .nan, attributes: ["": ""], fps: .min, maxBufferFrames: .max,
            metricDimensions: ["": ""], collection: ["buffer": ["maxAgeSeconds": Double.infinity], "x": Date()],
            baselineSampleRate: .infinity, exportDelayMs: .min, propagateTraceHeaderUrls: [""],
            ignoreErrors: [.regex("(unclosed")]
        ))
        callEveryPublicAPI()
        assertStillWorks(client, "garbage survived")
    }

    func testStartAndShutdownTwiceAndAtOnce() throws {
        let first = try start()
        XCTAssertTrue(try start() === first)
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            if i % 2 == 0 { first.shutdown() } else { _ = try? self.start() }
        }
        XCTAssertTrue(first.isShutdown)
        let client = try XCTUnwrap(TracewayClient.shared ?? (try? start()))
        assertStillWorks(client, "after starts and shutdowns at once")
    }

    /// Tokens and server URLs no one should pass (a NUL, a megabyte, another
    /// scheme, half a URL) never trap: an unusable URL returns nil, before
    /// any start, after a shutdown and from many threads at once, through
    /// the deprecated connection strings too.
    @available(*, deprecated)
    func testGarbageTokensAndServerURLsNeverTrap() throws {
        let huge = String(repeating: "x", count: 1_000_000)
        let badURLs = ["\u{0}", huge, "ftp://host", "https://", "[", "[::1", "http://:0", "tok@", "?#", "javascript:x"]
        let tokens: [String?] = [nil, "", " ", "\u{0}", huge, "tok\n@x"]
        func options() -> TracewayOptions { TracewayOptions(exportDelayMs: 50) }
        func overrides() -> TracewayTestOverrides {
            TracewayTestOverrides(transport: server, deviceAttributes: ["os.name": "ios"])
        }
        func tryAll() {
            for url in badURLs {
                XCTAssertNil(Traceway.begin(token: "tok", baseUrl: url, options: options(), overrides: overrides()))
                XCTAssertNil(Traceway.begin(connectionString: "tok@" + url, options: options(),
                                            overrides: overrides()))
            }
            for cs in ["\u{0}", huge, "@", "@@", huge + "@ftp://h"] {
                XCTAssertNil(Traceway.begin(connectionString: cs, options: options(), overrides: overrides()))
            }
            for token in tokens {
                // A token is any text: these may start. They must not trap.
                Traceway.begin(token: token, baseUrl: nil, options: options(), overrides: overrides())?.shutdown()
            }
        }
        tryAll()
        XCTAssertNil(Traceway.initialize(token: "tok", baseUrl: "ftp://host"))
        XCTAssertNil(Traceway.initialize(connectionString: "\u{0}"))
        let client = try start()
        client.shutdown()
        tryAll()
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            XCTAssertNil(Traceway.begin(token: "tok", baseUrl: badURLs[i % badURLs.count], options: options(),
                                        overrides: overrides()))
        }
        let next = try start()
        assertStillWorks(next, "after garbage starts")
    }

    func testPublicCallsFromManyThreadsAtOnce() throws {
        let client = try start(TracewayOptions(screenCapture: true, recordAllSessions: true),
                               replay: FakeReplaySource())
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            callEveryPublicAPI(i)
            if i % 16 == 0 { Traceway.flush(timeout: 0.1) }
        }
        assertStillWorks(client, "after many threads")
    }

    // MARK: - Fault injection (§13.6)

    /// The network fails in every way: no answer, errors, garbage bodies,
    /// absurd headers. Calls return, `flush` keeps to its time, and the
    /// client goes on working once the server answers again.
    func testANetworkThatFailsInEveryWayLeavesTheClientWorking() throws {
        let lock = NSLock()
        var calls = 0
        let flaky = FakeHTTP { request in
            lock.lock()
            calls += 1
            let n = calls
            lock.unlock()
            switch n % 5 {
            case 0: return HTTPResult(statusCode: 503, headers: ["retry-after": "99999999999999999999"])
            case 1: return HTTPResult(statusCode: 200, body: Data((0..<64).map { UInt8($0 * 37 % 256) }))
            case 2: return .noAnswer
            case 3: return HTTPResult(statusCode: 429, headers: ["retry-after": "-1"])
            default: return HTTPResult(statusCode: 500, body: Data("{".utf8))
            }
        }
        let client = try start(TracewayOptions(screenCapture: true, recordAllSessions: true),
                               transport: flaky, replay: FakeReplaySource())
        for i in 0..<20 { Traceway.captureMessage("while the network fails \(i)") }
        client.appPaused {}
        let began = Date()
        client.flush(timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
        XCTAssertNotNil(client.currentSessionId)
        flaky.handler = { _ in HTTPResult(statusCode: 200) }
        client.shutdown()
        let next = try start()
        assertStillWorks(next, "after the network failed")
    }

    /// The server's settings are not JSON, not an object, or full of
    /// absurd values: each is ignored, the client keeps its defaults.
    func testSettingsTheSDKCannotUseAreIgnored() throws {
        for document in [
            "{not json",
            "[1,2,3]",
            #"{"schemaVersion": 99}"#,
            #"{"buffer":{"maxBytes":1e300,"maxAgeSeconds":-1},"metrics":{"flushSeconds":1e300},"#
                + #""triggers":[{"id":"dropped","steps":[{"match":{"key":"x","op":"exists"}}],"#
                + #""actions":[{"type":"capture","durationSeconds":-5}]},"#
                + #"{"id":"t","steps":[{"match":{"key":"event.name","op":"glob","value":"*"},"#
                + #""withinSeconds":1e300,"count":1e300,"periodSeconds":1e300},{"match":{"not":{"not":{"not":"#
                + #"{"key":"x","op":"exists"}}}},"withinSeconds":1e16}],"actions":[{"type":"stream","#
                + #""durationSeconds":1e300},{"type":"capture","durationSeconds":1e300,"lookbackSeconds":1e300},"#
                + #"{"type":"emit","eventName":"e"}],"#
                + #""cooldownSeconds":-1,"maxPerSession":1e300,"sampleRate":"x"}],"#
                + #""captures":[{"id":"c","until":"99999-99-99","lookbackSeconds":1e300}]}"#,
        ] {
            TracewayClient.resetForTesting()
            server = FakeServer()
            server.remoteConfig = document
            let client = try start()
            client.refreshConfig()
            client.flush(timeout: 5)
            for i in 0..<5 { Traceway.log("record \(i)") }
            assertStillWorks(client, "after \(document.prefix(12))")
        }
    }

    /// A trigger that streams on every record, and an emit that a rule
    /// answers with another emit: bounded, and the client keeps working.
    func testTriggersThatFireOnEverythingStayBounded() throws {
        let client = try start(TracewayOptions(collection: ["triggers": [
            ["id": "all", "steps": [["match": ["key": "signal", "op": "exists"]]],
             "actions": [["type": "stream", "durationSeconds": 3600], ["type": "startReplay", "durationSeconds": 60]]],
            ["id": "echo", "steps": [["match": ["key": "event.name", "op": "exists"]]],
             "actions": [["type": "emit", "eventName": "echo"]]],
        ]]))
        for i in 0..<500 { Traceway.log("line \(i)") }
        Traceway.track("start")
        client.flush(timeout: 5)
        XCTAssertLessThanOrEqual(client.onQueueSync { client.control.activeOverrideCount }, 2)
        assertStillWorks(client, "after triggers on everything")
    }

    /// The app's callbacks throw, recurse, or capture from inside: the
    /// capture goes on, and so does the SDK.
    func testCallbacksOfTheAppThatFailDoNotBreakCapturing() throws {
        struct Broken: Error {}
        let lock = NSLock()
        var depth = 0
        let client = try start(TracewayOptions(beforeCapture: { captured in
            lock.lock()
            depth += 1
            let n = depth
            lock.unlock()
            if n < 100 { Traceway.captureMessage("inner \(n)") }
            if captured.message.hasPrefix("throw") { throw Broken() }
            return true
        }))
        Traceway.captureMessage("throw from the callback")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually(timeout: 15) { self.sent("throw from the callback") },
                      "a callback that throws keeps the record")
        lock.lock()
        XCTAssertEqual(depth, 1, "a capture inside the callback does not call it again")
        lock.unlock()
        assertStillWorks(client, "after the callbacks")
    }

    /// A replay source that has nothing to give: the exception is still
    /// reported.
    func testAReplaySourceWithNothingToGiveDoesNotStopTheReport() throws {
        final class EmptySource: ReplaySource {
            var isRunning = false
            func start() { isRunning = true }
            func stop() { isRunning = false }
            func clearBuffer() {}
            func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool { true }
            func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload? { nil }
        }
        let client = try start(TracewayOptions(screenCapture: true), replay: EmptySource())
        struct Boom: Error {}
        Traceway.captureException(Boom())
        client.flush(timeout: 5)
        XCTAssertTrue(eventually(timeout: 15) { self.sent("Boom") })
        assertStillWorks(client, "after an empty clip")
    }

    /// Two binary-image scans at once, as the first issues while the SDK
    /// starts (IOS-6): one result for all, no race.
    func testBinaryImagesAreScannedOnceUnderConcurrentCaptures() {
        BinaryImages.resetForTesting()
        let lock = NSLock()
        var counts = Set<Int>()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let images = BinaryImages.capture()
            let trace = CrashRecordStore.renderWireTrace(header: "x", arch: "", images: images, addresses: [1, 2])
            lock.lock()
            counts.insert(images.count)
            lock.unlock()
            XCTAssertTrue(trace.hasPrefix("x"))
        }
        XCTAssertEqual(counts.count, 1)
    }

    /// CONTRACT §14's hooks with everything broken inside: a unified log
    /// that cannot be read, a main thread whose stack cannot be taken,
    /// MetricKit payloads of any shape, state files nobody can read, lines
    /// of any size. Reports still leave, and after `shutdown` the hooks do
    /// nothing.
    func testTheExitHangAndLogHooksContainWhatBreaksInside() throws {
        let state = temporaryDirectory().appendingPathComponent("traceway_v2")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: state.appendingPathComponent(AppHangMonitor.fileName))
        try Data("not a marker".utf8).write(to: state.appendingPathComponent(ExitMarker.fileName))
        let source = FakeOSLogSource()
        source.failNext(1000)
        let host = FakeVitalsHost()
        let scheduler = ManualMetricsScheduler(nowMs: Clock.nowMs())
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(recordAllSessions: true, exportDelayMs: 50, appHangThresholdMs: 1000),
            overrides: TracewayTestOverrides(
                transport: server, stateDirectory: state,
                deviceAttributes: ["os.name": "ios", "device.model": "iPhone15,2"],
                metricsScheduler: scheduler, vitalsHost: host, captureMainStack: { nil }, osLogSource: source
            )
        )
        struct Boom: Error {}
        Traceway.captureException(Boom())
        for payload in [Data(), Data("{".utf8), Data((0..<4096).map { UInt8($0 % 256) }),
                        Data(#"{"crashDiagnostics":[1,"x",null,{"diagnosticMetaData":[]}]}"#.utf8),
                        Data(#"{"timeStampBegin":"2026-11-20 10:49:00","crashDiagnostics":[{"callStackTree":{"callStacks":[[]]}}]}"#.utf8)] {
            client.receiveDiagnosticPayload(payload, begin: nil, end: nil)
        }
        client.recordStdLines([String(repeating: "z", count: 1_000_000), "", "\u{0}"], stream: "stdout")
        client.recordStdLines(["odd stream"], stream: "")
        // A hang whose stack cannot be taken.
        host.runMain()
        scheduler.advance(500)
        for _ in 0..<6 { scheduler.advance(500) }
        host.runMain()
        client.appHangs?.settle()
        assertStillWorks(client, "after the §14 hooks broke")
        XCTAssertTrue(sent("Boom"), "an exception goes out though the log could not be read")
        XCTAssertFalse(sent("Main thread blocked"))
        client.shutdown()

        let before = server.requests.count
        client.receiveDiagnosticPayload(try metricKitFixture("crash-signal"), begin: Date(), end: Date())
        client.recordStdLines(["late"], stream: "stdout")
        client.runForeground(true)
        client.appTerminating()
        client.reportAppHang(AppHangReport(blockedMs: 3000, startedAtMs: 0, traceBody: "", attributes: [:],
                                           resource: [:], fatal: false))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.requests.count, before, "nothing after shutdown")
    }

    // MARK: - The app's crashes reach the handlers before Traceway's (§13.3)

    #if canImport(ObjectiveC)
    /// IOS-11: Crashlytics-like C, then Traceway, then Sentry-like S that
    /// chains back; the SDK restarts. C must still get the exception, and
    /// each handler runs once.
    func testAnUncaughtExceptionStillReachesTheHandlerBeforeTracewayAfterARestart() {
        let original = NSGetUncaughtExceptionHandler()
        NSExceptionHandler.resetForTesting()
        defer {
            NSExceptionHandler.resetForTesting()
            NSSetUncaughtExceptionHandler(original)
            SignalHandler.uninstallForTesting()
        }
        handlerCalls = []
        NSSetUncaughtExceptionHandler(firstHandler)
        NSExceptionHandler.install { _ in handlerCalls.append("traceway 1") }
        handlerBeforeLater = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(laterHandler)
        NSExceptionHandler.install { _ in handlerCalls.append("traceway 2") }
        NSGetUncaughtExceptionHandler()?(NSException(name: .genericException, reason: "boom", userInfo: nil))
        XCTAssertEqual(handlerCalls, ["later", "traceway 2", "first"])
    }
    #endif

    #if canImport(Darwin)
    /// A fatal signal is recorded, then handed once to the handler that was
    /// installed before Traceway's.
    func testAFatalSignalIsRecordedAndReachesTheHandlerBeforeTraceway() throws {
        SignalHandler.uninstallForTesting()
        var original = sigaction()
        var previous = sigaction()
        sigemptyset(&previous.sa_mask)
        previous.sa_flags = SA_SIGINFO
        previous.__sigaction_u.__sa_sigaction = previousSignalHandler
        sigaction(SIGFPE, &previous, &original)
        defer {
            SignalHandler.uninstallForTesting()
            sigaction(SIGFPE, &original, nil)
        }
        let path = scratchDirectory(self).appendingPathComponent("crash.tw").path
        SignalHandler.install(crashPath: path, metadata: Array("attr.user.id=u1\n".utf8))
        previousSignalCalls = 0
        raise(SIGFPE)
        XCTAssertEqual(previousSignalCalls, 1)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("TRACEWAY_SIGNAL_V1\nsignal=8\ntime="), text)
        XCTAssertTrue(text.contains("attr.user.id=u1\n---FRAMES---\n"), text)
        let record = try XCTUnwrap(CrashRecordStore.parse(text: text))
        XCTAssertEqual(record.header, "Fatal Signal SIGFPE (8)")
        XCTAssertEqual(record.attributes?["user.id"], "u1")
    }

    /// IOS-15: a smashed frame pointer used to be read straight, faulting
    /// inside the crash handler.
    func testTheFrameWalkStopsAtMemoryItCannotRead() throws {
        let path = scratchDirectory(self).appendingPathComponent("frames.txt").path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        // Page zero is never mapped.
        SignalHandler.writeFrameChainForTesting(fd, framePointer: 0x1000)
        let records = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { records.deallocate() }
        let words = records.bindMemory(to: UInt.self, capacity: 8)
        words[0] = UInt(bitPattern: records.advanced(by: 32))
        words[1] = 0xaaa0
        words[4] = 0
        words[5] = 0xbbb0
        SignalHandler.writeFrameChainForTesting(fd, framePointer: UInt(bitPattern: records))
        close(fd)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "0xaaa0\n0xbbb0\n")
    }

    /// IOS-16: every metadata update allocated a buffer that was never
    /// freed; updates now reuse two.
    func testCrashMetadataUpdatesReuseTheirBuffers() {
        SignalHandler.uninstallForTesting()
        defer { SignalHandler.uninstallForTesting() }
        // Before the handlers are installed, updates are ignored.
        let ignored = SignalHandler.metadataAllocationsForTesting
        SignalHandler.setMetadata([1, 2, 3])
        XCTAssertEqual(SignalHandler.metadataAllocationsForTesting, ignored)
        SignalHandler.install(crashPath: scratchDirectory(self).appendingPathComponent("crash.tw").path, metadata: [1])
        let before = SignalHandler.metadataAllocationsForTesting
        var last: [UInt8] = []
        for i in 0..<10_000 {
            last = [UInt8](repeating: 65, count: 2048) + [UInt8(i % 251)]
            SignalHandler.setMetadata(last)
        }
        XCTAssertLessThanOrEqual(SignalHandler.metadataAllocationsForTesting - before, 2)
        XCTAssertEqual(SignalHandler.publishedMetadataForTesting, last)
    }

    /// §14.1: the handler runs on a stack of its own, so a stack overflow,
    /// which leaves no room on the thread's stack, is still recorded. A
    /// recursion to death would end the test run, so the setup is checked:
    /// every handled signal's action asks for the alternate stack, the
    /// thread has one, and a signal is handled on it. (`SIGFPE` is raised:
    /// a raised `SIGSEGV` carries a fault's `si_code` on Darwin, so the
    /// handler leaves it to fault again, which a raise never does.)
    func testTheSignalHandlerHasAStackOfItsOwn() throws {
        SignalHandler.uninstallForTesting()
        var original = sigaction()
        var probe = sigaction()
        sigemptyset(&probe.sa_mask)
        probe.sa_flags = SA_SIGINFO | SA_ONSTACK
        probe.__sigaction_u.__sa_sigaction = stackProbeHandler
        sigaction(SIGFPE, &probe, &original)
        defer {
            SignalHandler.uninstallForTesting()
            sigaction(SIGFPE, &original, nil)
        }
        let path = scratchDirectory(self).appendingPathComponent("crash.tw").path
        SignalHandler.install(crashPath: path, metadata: [])
        for signal in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP] {
            XCTAssertNotEqual(SignalHandler.actionFlagsForTesting(signal) & SA_ONSTACK, 0, "signal \(signal)")
        }
        let alt = SignalHandler.altStackForTesting()
        XCTAssertTrue(alt.enabled)
        XCTAssertGreaterThanOrEqual(alt.size, Int(MINSIGSTKSZ))
        probedStackAddress = 0
        raise(SIGFPE)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Traceway's handler recorded it")
        XCTAssertGreaterThanOrEqual(probedStackAddress, alt.base, "handled on the alternate stack")
        XCTAssertLessThan(probedStackAddress, alt.base + UInt(alt.size))
        print("traceway-alt-stack main base=\(alt.base) size=\(alt.size) MINSIGSTKSZ=\(MINSIGSTKSZ) probe=\(probedStackAddress)")

        // A thread that has an alternate stack of its own keeps it; one
        // without gets Traceway's. (Each in a fresh thread: Darwin does not
        // take back a thread's alternate stack for a bare `SS_DISABLE`.)
        let size = 128 * 1024
        let own = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let kept = onFreshThread { () -> (base: UInt, size: Int, enabled: Bool) in
            var mine = stack_t()
            mine.ss_sp = own
            mine.ss_size = size
            mine.ss_flags = 0
            sigaltstack(&mine, nil)
            SignalHandler.installAltStackForTesting()
            return SignalHandler.altStackForTesting()
        }
        let given = onFreshThread { () -> (base: UInt, size: Int, enabled: Bool) in
            let before = SignalHandler.altStackForTesting()
            SignalHandler.installAltStackForTesting()
            let after = SignalHandler.altStackForTesting()
            return before.enabled ? (0, 0, false) : after
        }
        print("traceway-alt-stack threads kept=\(String(describing: kept)) given=\(String(describing: given))")
        XCTAssertEqual(kept?.base, UInt(bitPattern: own), "the thread's own alternate stack is kept")
        XCTAssertEqual(kept?.size, size)
        XCTAssertEqual(given?.enabled, true, "a thread without one gets Traceway's")
        XCTAssertGreaterThanOrEqual(given?.size ?? 0, Int(MINSIGSTKSZ))
        XCTAssertNotEqual(given?.base, UInt(bitPattern: own))
    }

    /// Runs `body` on a new thread and returns what it returned.
    private func onFreshThread<T>(_ body: @escaping () -> T) -> T? {
        let result = Locked<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.value = body()
            done.signal()
        }
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        return result.value
    }

    /// What a raised `SIGSEGV` carries on this platform (logged for the
    /// report: the handler tells a fault from a sent signal by it).
    func testWhatARaisedSegmentationFaultCarries() {
        var original = sigaction()
        var probe = sigaction()
        sigemptyset(&probe.sa_mask)
        probe.sa_flags = SA_SIGINFO
        probe.__sigaction_u.__sa_sigaction = siginfoProbeHandler
        sigaction(SIGSEGV, &probe, &original)
        defer { sigaction(SIGSEGV, &original, nil) }
        probedSiginfo = (-1, -1)
        raise(SIGSEGV)
        print("traceway-raised-sigsegv si_code=\(probedSiginfo.code) si_pid=\(probedSiginfo.pid) pid=\(getpid())")
        XCTAssertNotEqual(probedSiginfo.code, -1, "the probe ran")
    }

    /// §14.2: from another thread, the main thread's stack while it is
    /// blocked, inside this test's binary, without touching it otherwise.
    func testTheMainThreadsStackIsTakenWhileItIsBlocked() throws {
        guard Thread.isMainThread else { throw XCTSkip("the test runs off the main thread here") }
        MainThreadStack.prepare()
        XCTAssertTrue(MainThreadStack.isPrepared)
        XCTAssertNil(MainThreadStack.capture(), "not from the main thread itself")
        let taken = Locked<[UInt]?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            taken.value = MainThreadStack.capture()
            done.signal()
        }
        blockTheMainThread(seconds: 1)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let frames = try XCTUnwrap(taken.value)
        XCTAssertLessThanOrEqual(frames.count, MainThreadStack.maxFrames)
        BinaryImages.resetForTesting()
        let images = BinaryImages.capture()
        let mine = try XCTUnwrap(images.first { $0.loadAddr == UInt(bitPattern: #dsohandle) }, "this test's image")
        XCTAssertTrue(frames.contains { BinaryImages.map(address: $0, images: images)?.image.name == mine.name },
                      "a frame of the blocked test function")
    }

    /// The suspended walk reads the registers at fixed offsets of the thread
    /// state, without the C struct: they are the SDK headers' fields.
    func testTheRegisterOffsetsAreTheThreadStateFields() throws {
        let layout = try XCTUnwrap(MainThreadStack.layout)
        func read(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
            bytes.load(fromByteOffset: offset, as: UInt64.self)
        }
        #if arch(arm64)
        var state = arm_thread_state64_t()
        state.__pc = 0x1111_2222_3333_4444
        state.__fp = 0x5555_6666_7777_8888
        state.__lr = 0x9999_aaaa_bbbb_cccc
        XCTAssertEqual(withUnsafeBytes(of: &state) { read($0, layout.pc) }, 0x1111_2222_3333_4444)
        XCTAssertEqual(withUnsafeBytes(of: &state) { read($0, layout.fp) }, 0x5555_6666_7777_8888)
        XCTAssertEqual(withUnsafeBytes(of: &state) { read($0, layout.lr ?? 0) }, 0x9999_aaaa_bbbb_cccc)
        XCTAssertEqual(Int(layout.words), MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        XCTAssertEqual(layout.flavor, thread_state_flavor_t(ARM_THREAD_STATE64))
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        state.__rip = 0x1111_2222_3333_4444
        state.__rbp = 0x5555_6666_7777_8888
        XCTAssertEqual(withUnsafeBytes(of: &state) { read($0, layout.pc) }, 0x1111_2222_3333_4444)
        XCTAssertEqual(withUnsafeBytes(of: &state) { read($0, layout.fp) }, 0x5555_6666_7777_8888)
        XCTAssertNil(layout.lr)
        XCTAssertEqual(Int(layout.words), MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        XCTAssertEqual(layout.flavor, thread_state_flavor_t(x86_THREAD_STATE64))
        #endif
    }

    /// §14.2 end to end on a real main thread: blocked for 2.5 s (past a
    /// 1 s threshold, so a busy runner's late timers still see it), it is
    /// one `AppHang` issue whose stack is inside this test's binary.
    func testABlockedMainThreadIsOneAppHangWithItsStack() throws {
        guard Thread.isMainThread else { throw XCTSkip("the test runs off the main thread here") }
        MainThreadStack.prepare()
        BinaryImages.resetForTesting()
        let images = BinaryImages.capture()
        let mine = try XCTUnwrap(images.first { $0.loadAddr == UInt(bitPattern: #dsohandle) }?.name)
        let client = try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(exportDelayMs: 50, reportHangsInDebug: true, appHangThresholdMs: 1000),
            overrides: TracewayTestOverrides(
                transport: server,
                deviceAttributes: ["os.name": "ios", "device.model": "iPhone15,2"],
                vitalsHost: MainQueueVitalsHost()
            )
        )
        runMainLoop(for: 0.6)
        blockTheMainThread(seconds: 2.5)
        runMainLoop(for: 0.5)
        client.appHangs?.settle()
        let deadline = Date().addingTimeInterval(15)
        while !sent("Main thread blocked for") && Date() < deadline {
            runMainLoop(for: 0.2)
            client.flush(timeout: 1)
        }
        XCTAssertTrue(sent("Main thread blocked for"), "an AppHang was sent")
        let hangs = server.requests(to: "/api/otel/v1/logs").filter { request in
            var body = request.body
            if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(body) { body = plain }
            return body.range(of: Data("Main thread blocked for".utf8)) != nil
        }
        XCTAssertEqual(hangs.count, 1, "one AppHang")
        XCTAssertTrue(sent("AppHang"))
        XCTAssertTrue(sent(" \(mine)"), "a frame inside \(mine)")
    }
    #endif
}

#if canImport(ObjectiveC)
private var handlerCalls: [String] = []
private var handlerBeforeLater: (@convention(c) (NSException) -> Void)?
private let firstHandler: @convention(c) (NSException) -> Void = { _ in handlerCalls.append("first") }
private let laterHandler: @convention(c) (NSException) -> Void = { exception in
    handlerCalls.append("later")
    handlerBeforeLater?(exception)
}
#endif

#if canImport(Darwin)
private var previousSignalCalls = 0
private func previousSignalHandler(
    _ signo: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?
) {
    previousSignalCalls += 1
}

/// Where the probe handler's stack was when it ran.
private var probedStackAddress: UInt = 0
/// `si_code` and `si_pid` of the signal the siginfo probe got.
private var probedSiginfo: (code: Int32, pid: Int32) = (-1, -1)
private func siginfoProbeHandler(
    _ signo: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?
) {
    if let info = info { probedSiginfo = (info.pointee.si_code, info.pointee.si_pid) }
}
private func stackProbeHandler(
    _ signo: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?
) {
    var marker: UInt8 = 0
    withUnsafeMutablePointer(to: &marker) { probedStackAddress = UInt(bitPattern: $0) }
}

/// Blocks the calling (main) thread inside this binary.
@inline(never)
private func blockTheMainThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// Runs the main run loop for `seconds`.
private func runMainLoop(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

/// The hang watchdog's platform side on the real main queue.
private final class MainQueueVitalsHost: VitalsHost {
    func install(_ vitals: AppVitals) {}
    func uninstall() {}
    func requestDraw() {}
    func cancelDraw() {}
    func postToMain(_ task: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async(execute: task)
        return true
    }
    func checkLaunch(_ result: @escaping (LaunchInfo) -> Void) {}
    func debuggerAttached() -> Bool { false }
}
#endif

/// Finds the traps §13.4 bans in Swift source. Comments and the text of
/// string literals are blanked first (interpolated code is kept), so only
/// code is read.
enum SourceTraps {
    struct Result {
        var problems: [String] = []
        /// `as!` casts marked as CF bridging.
        var bridgingCasts = 0
    }

    private static let rules: [(String, NSRegularExpression?)] = [
        ("try!", try? NSRegularExpression(pattern: #"\btry!"#)),
        ("force unwrap", try? NSRegularExpression(pattern: #"[\w\)\]>](?<!\btry)(?<!\bas)!(?!=)"#)),
        ("trap", try? NSRegularExpression(
            pattern: #"(?<![.\w])(fatalError|precondition|preconditionFailure|assert|assertionFailure|abort|exit)\s*\("#
        )),
        ("unowned", try? NSRegularExpression(pattern: #"\bunowned\b"#)),
        ("unsafelyUnwrapped", try? NSRegularExpression(pattern: #"\bunsafelyUnwrapped\b"#)),
        ("unarchiver", try? NSRegularExpression(pattern: #"\bunarchiveObject\b"#)),
    ]
    private static let cast = try? NSRegularExpression(pattern: #"\bas!"#)

    static func scan(_ source: String) -> Result {
        var result = Result()
        let originals = source.components(separatedBy: "\n")
        let code = blankedCode(source)
        func has(_ regex: NSRegularExpression?, _ line: String) -> Bool {
            regex?.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
        }
        func recent(_ index: Int, contains text: String) -> Bool {
            code[max(0, index - 3)...index].contains { $0.contains(text) }
        }
        for (index, line) in code.enumerated() {
            let number = index + 1
            for (name, regex) in rules where has(regex, line) {
                result.problems.append("\(number): \(name): \(originals[index].trimmingCharacters(in: .whitespaces))")
            }
            if has(cast, line) {
                if originals[index].contains("// CF bridging:") {
                    result.bridgingCasts += 1
                } else {
                    result.problems.append("\(number): as!: \(originals[index].trimmingCharacters(in: .whitespaces))")
                }
            }
            // Foundation raises instead of throwing here.
            if line.contains("JSONSerialization.data(withJSONObject"), !recent(index, contains: "isValidJSONObject") {
                result.problems.append("\(number): unchecked JSONSerialization")
            }
            if line.contains(".value(forKey:"), !recent(index, contains: "responds(to:") {
                result.problems.append("\(number): unchecked KVC")
            }
        }
        return result
    }

    /// `source` with comments and literal text turned into spaces, line by
    /// line.
    static func blankedCode(_ source: String) -> [String] {
        let b = Array(source.utf8)
        var out = b
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), slash = UInt8(ascii: "/")
        let star = UInt8(ascii: "*"), backslash = UInt8(ascii: "\\"), open = UInt8(ascii: "(")
        let close = UInt8(ascii: ")"), newline = UInt8(ascii: "\n"), space = UInt8(ascii: " ")
        struct Literal { var hashes: Int; var multiline: Bool }
        var literal: Literal?
        // The literals around the interpolation being read, and the
        // parentheses open in each.
        var outer: [(literal: Literal, depth: Int)] = []
        var depth = 0
        var i = 0
        func at(_ k: Int) -> UInt8 { k < b.count ? b[k] : 0 }
        func blank(_ from: Int, _ to: Int) {
            var k = from
            while k < to && k < b.count {
                if out[k] != newline { out[k] = space }
                k += 1
            }
        }
        while i < b.count {
            if let current = literal {
                let c = b[i]
                if c == backslash {
                    var k = i + 1
                    var h = 0
                    while h < current.hashes && at(k) == hash { k += 1; h += 1 }
                    if h == current.hashes {
                        if at(k) == open {
                            blank(i, k + 1)
                            outer.append((current, depth))
                            depth = 0
                            literal = nil
                            i = k + 1
                            continue
                        }
                        blank(i, k + 1)
                        i = k + 1
                        continue
                    }
                }
                if c == quote {
                    let quotes = current.multiline ? 3 : 1
                    var k = i
                    var q = 0
                    while q < quotes && at(k) == quote { k += 1; q += 1 }
                    var h = 0
                    while q == quotes && h < current.hashes && at(k) == hash { k += 1; h += 1 }
                    if q == quotes && h == current.hashes {
                        blank(i, k)
                        literal = nil
                        i = k
                        continue
                    }
                }
                blank(i, i + 1)
                i += 1
                continue
            }
            let c = b[i]
            if c == slash && at(i + 1) == slash {
                var k = i
                while k < b.count && b[k] != newline { k += 1 }
                blank(i, k)
                i = k
                continue
            }
            if c == slash && at(i + 1) == star {
                var nesting = 0
                var k = i
                repeat {
                    if at(k) == slash && at(k + 1) == star {
                        nesting += 1
                        k += 2
                    } else if at(k) == star && at(k + 1) == slash {
                        nesting -= 1
                        k += 2
                    } else {
                        k += 1
                    }
                } while nesting > 0 && k < b.count
                blank(i, k)
                i = k
                continue
            }
            if c == hash || c == quote {
                var k = i
                var h = 0
                while at(k) == hash { k += 1; h += 1 }
                if at(k) == quote {
                    let multiline = at(k + 1) == quote && at(k + 2) == quote
                    let end = k + (multiline ? 3 : 1)
                    blank(i, end)
                    literal = Literal(hashes: h, multiline: multiline)
                    i = end
                    continue
                }
                i = max(k, i + 1)
                continue
            }
            if !outer.isEmpty {
                if c == open {
                    depth += 1
                } else if c == close {
                    if depth == 0 {
                        blank(i, i + 1)
                        let resumed = outer.removeLast()
                        literal = resumed.literal
                        depth = resumed.depth
                        i += 1
                        continue
                    }
                    depth -= 1
                }
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self).components(separatedBy: "\n")
    }
}

#if canImport(UIKit)
// MARK: - UIKit hooks (Simulator)

/// Stands in for `UIApplication`'s background tasks.
private final class FakeBackgroundTasks: BackgroundTasks {
    var begun = 0
    var ended: [UIBackgroundTaskIdentifier] = []
    var expirations: [() -> Void] = []

    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        begun += 1
        expirations.append(expiration)
        return UIBackgroundTaskIdentifier(rawValue: 100 + begun)
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        ended.append(task)
    }
}

/// A controller with its own `viewDidAppear`, to swizzle without touching
/// `UIViewController` itself.
private class SwizzleProbeController: UIViewController {
    var appeared = 0

    @objc override dynamic func viewDidAppear(_ animated: Bool) {
        appeared += 1
        super.viewDidAppear(animated)
    }
}

private final class PlainController: UIViewController {
    var calls = 0

    override func viewWillAppear(_ animated: Bool) {
        calls += 1
        super.viewWillAppear(animated)
    }
}

/// A hook installed before Traceway's that needs its own `_cmd`, the way
/// Aspects (forwarding) or a selector-keyed swizzler does.
private var hostSelector: Selector?
private var hostCalls = 0
private var hostOriginal: IMP?
private let hostHook: @convention(c) (AnyObject, Selector, Bool) -> Void = { object, selector, animated in
    hostSelector = selector
    hostCalls += 1
    if let original = hostOriginal {
        typealias Call = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(original, to: Call.self)(object, selector, animated)
    }
}

extension CrashSafetyTests {
    /// Runs the main run loop until `condition` holds.
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// IOS-5: the swizzled method gets its own selector and runs once, and
    /// swizzling twice changes nothing.
    func testSwizzlesCallTheMethodTheyReplaceOnceWithItsOwnSelector() throws {
        let selector = #selector(UIViewController.viewDidAppear(_:))
        let method = try XCTUnwrap(class_getInstanceMethod(SwizzleProbeController.self, selector))
        hostOriginal = method_setImplementation(method, unsafeBitCast(hostHook, to: IMP.self))
        hostCalls = 0
        UIViewController.tracewaySwizzleViewDidAppear(on: SwizzleProbeController.self)
        UIViewController.tracewaySwizzleViewDidAppear(on: SwizzleProbeController.self)
        let probe = SwizzleProbeController()
        let controller: UIViewController = probe
        controller.viewDidAppear(true)
        XCTAssertEqual(hostSelector, selector)
        XCTAssertEqual(hostCalls, 1)
        XCTAssertEqual(probe.appeared, 1)

        // The real swizzles, installed twice: an app's controller still runs
        // its own method once per call.
        UIViewController.tracewaySwizzleViewDidAppear()
        UIViewController.tracewaySwizzleViewDidAppear()
        UIViewController.tracewaySwizzleDisplayStart()
        UIApplication.tracewaySwizzleSendEvent()
        UIApplication.tracewaySwizzleSendEvent()
        let plain = PlainController()
        let asController: UIViewController = plain
        asController.viewWillAppear(false)
        asController.viewDidAppear(false)
        XCTAssertEqual(plain.calls, 1)
    }

    /// IOS-4: a background flush's task ends even when the hooks are gone
    /// first, and only once.
    func testABackgroundFlushEndsItsTaskWhenTheHooksAreGoneFirst() throws {
        let fake = FakeBackgroundTasks()
        let saved = PlatformHooks.backgroundTasks
        PlatformHooks.backgroundTasks = fake
        defer { PlatformHooks.backgroundTasks = saved }
        let client = try start(TracewayOptions(captureMetrics: false))
        PlatformHooks.install(client)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(spin { fake.begun == 1 })
        PlatformHooks.uninstall(for: ObjectIdentifier(client))
        XCTAssertTrue(spin { fake.ended.count == 1 }, "the task ended")
        for expire in fake.expirations { expire() }
        XCTAssertEqual(fake.ended.count, 1, "ended once")
    }

    /// IOS-9: device information read off the main thread while the main
    /// thread waits for it (an app that starts SDKs in parallel).
    func testDeviceInformationOffTheMainThreadNeverWaitsForIt() {
        XCTAssertTrue(Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        let info = Locked<[String: String]>([:])
        DispatchQueue.global().async {
            info.value = DeviceInfoCollector.collectSync()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "no deadlock")
        XCTAssertEqual(info.value["os.name"], "ios")
    }
}

/// The wireframe with what an app can put on screen: megabytes of text,
/// absurd sizes, a grid of large photos.
final class CrashSafetyWireframeTests: WireframeViewTestCase {
    /// IOS-13: a log console's whole text was copied, masked and kept in
    /// every frame.
    func testMegabytesOfTextKeepAShortNode() throws {
        let console = UITextView(frame: CGRect(x: 0, y: 100, width: 390, height: 400))
        console.text = String(repeating: "log line 0123456789\n", count: 50_000)
        let label = UILabel(frame: CGRect(x: 0, y: 520, width: 390, height: 20))
        label.text = String(repeating: "x", count: 100_000)
        let field = UITextField(frame: CGRect(x: 0, y: 560, width: 390, height: 40))
        field.text = String(repeating: "y", count: 100_000)
        show(console, label, field)
        let lengths = allTexts(try screen()).map { $0.utf16.count }
        XCTAssertLessThanOrEqual(lengths.max() ?? 0, WireframeCSS.maxTextLength)
        XCTAssertGreaterThan(lengths.max() ?? 0, 1000)
    }

    /// IOS-20: sizes past what an `Int` holds once scaled.
    func testAbsurdButFiniteSizesDoNotTrap() throws {
        let symbol = try XCTUnwrap(UIImage(systemName: "star"))
        let huge = CGSize(width: 1e300, height: 1e300)
        // Too large to draw: the glyph stays an empty shape.
        let glyph = WireframeGlyphs().lookup(symbol, size: huge, contentMode: .scaleAspectFit, color: false)
        XCTAssertNil(glyph?.css)
        _ = WireframeImages().picture(symbol, displayed: huge, nowMs: 0)
    }

    /// IOS-17: every new picture queued an encode holding its full bitmap;
    /// at most a few wait now, the rest are placeholders until there is room.
    func testPendingPictureEncodesAreCapped() {
        let images = WireframeImages()
        final class Weak { weak var image: UIImage? }
        var held: [Weak] = []
        var shown = 0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        for i in 0..<64 {
            autoreleasepool {
                let image = renderer.image { context in
                    UIColor(white: CGFloat(i) / 64, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
                }
                let ref = Weak()
                ref.image = image
                held.append(ref)
                if images.picture(image, displayed: CGSize(width: 100, height: 75), nowMs: 0) != nil { shown += 1 }
            }
        }
        XCTAssertLessThanOrEqual(images.pendingEncodes, WireframeImages.maxPendingEncodes)
        XCTAssertLessThanOrEqual(shown, WireframeImages.maxPendingEncodes)
        XCTAssertLessThanOrEqual(held.filter { $0.image != nil }.count, WireframeImages.maxPendingEncodes)
        settle(0.05)
        let deadline = Date().addingTimeInterval(5)
        while images.pendingEncodes > 0 && Date() < deadline { settle(0.05) }
        XCTAssertEqual(images.pendingEncodes, 0)
        let later = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        XCTAssertNotNil(images.picture(later, displayed: CGSize(width: 100, height: 75), nowMs: 1))
    }

    /// §14.5: past 128 pictures a new one evicts the one shown longest ago,
    /// instead of staying a placeholder until pictures age out.
    func testPicturesPastTheLimitEvictTheOneShownLongestAgo() {
        let images = WireframeImages()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        var shown: [UIImage] = []
        var first: WireframeImages.Picture?
        for i in 0..<(WireframeImages.maxPictures + 2) {
            let image = renderer.image { context in
                UIColor(red: CGFloat(i % 16) / 16, green: CGFloat(i / 16) / 16, blue: 0.5, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            shown.append(image)
            let deadline = Date().addingTimeInterval(5)
            while images.pendingEncodes >= WireframeImages.maxPendingEncodes && Date() < deadline { settle(0.01) }
            let picture = images.picture(image, displayed: CGSize(width: 8, height: 8), nowMs: Int64(i))
            XCTAssertNotNil(picture, "picture \(i)")
            if i == 0 { first = picture }
        }
        XCTAssertEqual(images.all.count, WireframeImages.maxPictures)
        XCTAssertFalse(images.all.contains { $0 === first }, "the oldest went")
        XCTAssertTrue(images.all.contains { $0.cls == "p\(WireframeImages.maxPictures + 1)" }, "the newest is in")
        XCTAssertEqual(shown.count, WireframeImages.maxPictures + 2)
    }
}
#endif
