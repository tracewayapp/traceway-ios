import Foundation
import XCTest
@testable import Traceway

/// Answers every request with `status` (OpAMP included), and records them.
final class StatusServer: HTTPTransport {
    private let lock = NSLock()
    private var seen: [FakeServer.Request] = []
    private let status: (URL) -> Int

    init(_ status: @escaping (URL) -> Int) {
        self.status = status
    }

    var requests: [FakeServer.Request] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        seen.append(FakeServer.Request(url: url, headers: headers, body: body))
        lock.unlock()
        let code = status(url)
        DispatchQueue.global().async { completion(HTTPResult(statusCode: code)) }
    }
}

/// Starting with a token and a server URL, the deprecated connection
/// strings, and the lines that tell a developer why nothing arrives. Every
/// request goes to an in-memory server: nothing leaves the test process,
/// whatever host the endpoints name.
final class StartTests: XCTestCase {
    private var server: FakeServer!
    private var lines: Locked<[String]>!

    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
        server = FakeServer()
        let lines = Locked<[String]>([])
        self.lines = lines
        Log.sink = { line in lines.withValue { $0.append(line) } }
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        Log.sink = nil
        Log.debugEnabled = false
        super.tearDown()
    }

    private func overrides(_ transport: HTTPTransport? = nil) -> TracewayTestOverrides {
        TracewayTestOverrides(transport: transport ?? server,
                              deviceAttributes: ["os.name": "ios", "device.model": "iPhone15,2"])
    }

    private func options(_ options: TracewayOptions = TracewayOptions()) -> TracewayOptions {
        var options = options
        options.exportDelayMs = 50
        return options
    }

    private func said(_ text: String) -> [String] {
        lines.value.filter { $0.contains(text) }
    }

    private func hosts() -> Set<String> {
        Set(server.requests.compactMap { $0.url.host })
    }

    // MARK: - token + baseUrl

    func testATokenAloneSendsToTracewayCloud() throws {
        let client = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: nil, options: options(),
                                                  overrides: overrides()))
        XCTAssertEqual(client.endpoints?.base, "https://cloud.tracewayapp.com")
        XCTAssertEqual(Traceway.defaultBaseUrl, "https://cloud.tracewayapp.com")
        Traceway.captureMessage("hello")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { !self.server.requests(to: "/api/otel/v1/opamp").isEmpty })
        XCTAssertTrue(eventually { !self.server.requests(to: "/api/otel/v1/logs").isEmpty })
        XCTAssertEqual(hosts(), ["cloud.tracewayapp.com"])
        for request in server.requests {
            XCTAssertEqual(request.headers["Authorization"], "Bearer tok", request.url.absoluteString)
        }
    }

    func testTheTokenIsTrimmed() throws {
        let client = try XCTUnwrap(Traceway.begin(token: "  tok \n", baseUrl: "https://traceway.example.com",
                                                  options: options(), overrides: overrides()))
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { !self.server.requests.isEmpty })
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["Authorization"] == "Bearer tok" })
    }

    func testABaseUrlIsNormalizedLikeAConnectionString() throws {
        let client = try XCTUnwrap(Traceway.begin(
            token: "tok", baseUrl: "  traceway.example.com/api/report?x=1 ", options: options(),
            overrides: overrides()
        ))
        XCTAssertEqual(client.endpoints?.base, "https://traceway.example.com")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { !self.server.requests(to: "/api/otel/v1/opamp").isEmpty })
        XCTAssertEqual(hosts(), ["traceway.example.com"])
        XCTAssertTrue(server.requests.allSatisfy { $0.url.scheme == "https" })
    }

    func testABlankBaseUrlIsTracewayCloud() throws {
        for blank in ["", "   ", "\n"] {
            let client = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: blank, options: options(),
                                                      overrides: overrides()), "baseUrl \"\(blank)\"")
            XCTAssertEqual(client.endpoints?.base, "https://cloud.tracewayapp.com")
            client.shutdown()
        }
    }

    func testABlankTokenDoesNotStart() {
        for blank in ["", "  ", "\t\n"] {
            XCTAssertNil(Traceway.begin(token: blank, baseUrl: "https://traceway.example.com", options: options(),
                                        overrides: overrides()))
        }
        XCTAssertNil(TracewayClient.shared)
        XCTAssertTrue(server.requests.isEmpty)
        let line = try? XCTUnwrap(said("not started: the token is empty").first)
        XCTAssertEqual(line, "[Traceway] not started: the token is empty. Pass the project token from the "
            + "Connection page: Traceway.initialize(token: \"YOUR_TOKEN\"). With Traceway.xcconfig, check that "
            + "TRACEWAY_TOKEN is set and Info.plist has TracewayToken = $(TRACEWAY_TOKEN).")
        XCTAssertNil(Traceway.begin(token: nil, baseUrl: nil, options: options(), overrides: overrides()))
        XCTAssertEqual(said("not started: there is no token").count, 1)
    }

    func testAnUnusableBaseUrlDoesNotStart() {
        XCTAssertNil(Traceway.begin(token: "tok", baseUrl: "ftp://host", options: options(), overrides: overrides()))
        XCTAssertEqual(lines.value.last, "[Traceway] not started: \"ftp://host\" is not a Traceway server URL; "
            + "expected https://host, e.g. https://cloud.tracewayapp.com")
        XCTAssertNil(TracewayClient.shared)
    }

    func testNoTokenWithTelemetryRunsStandalone() throws {
        for token in [nil, "", " "] as [String?] {
            let client = try XCTUnwrap(Traceway.begin(
                token: token, baseUrl: "https://traceway.example.com",
                options: options(TracewayOptions(telemetry: TracewayTelemetry(url: "https://collector.example.com/otlp"))),
                overrides: overrides()
            ))
            XCTAssertTrue(client.standalone)
            XCTAssertNil(client.endpoints)
            Traceway.captureMessage("standalone")
            client.flush(timeout: 5)
            XCTAssertTrue(eventually { !self.server.requests(to: "/otlp/v1/logs").isEmpty })
            XCTAssertTrue(server.requests(to: "/api/otel/v1/opamp").isEmpty, "no remote config without Traceway")
            XCTAssertTrue(server.requests.allSatisfy { $0.headers["Authorization"] == nil })
            client.shutdown()
        }
    }

    // MARK: - Connection strings (deprecated)

    func testAConnectionStringStillStartsAndWarnsOnce() throws {
        let client = try XCTUnwrap(Traceway.begin(connectionString: "secret@traceway.example.com/api/report",
                                                  options: options(), overrides: overrides()))
        XCTAssertEqual(client.endpoints?.base, "https://traceway.example.com")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { !self.server.requests(to: "/api/otel/v1/opamp").isEmpty })
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["Authorization"] == "Bearer secret" })
        client.shutdown()
        XCTAssertNotNil(Traceway.begin(connectionString: "secret@https://cloud.tracewayapp.com/api/report",
                                       options: options(), overrides: overrides()))
        let warnings = said("connection strings are deprecated")
        XCTAssertEqual(warnings, ["[Traceway] connection strings are deprecated; start with "
            + "Traceway.initialize(token: \"YOUR_TOKEN\", baseUrl: \"https://traceway.example.com\")"],
                       "one warning per process, naming the new form")
        XCTAssertFalse(lines.value.contains { $0.contains("secret") }, "never the token")
    }

    func testAConnectionStringToTracewayCloudNamesNoBaseUrl() {
        XCTAssertNotNil(Traceway.begin(connectionString: "tok@https://cloud.tracewayapp.com/api/report",
                                       options: options(), overrides: overrides()))
        XCTAssertEqual(said("connection strings are deprecated"), ["[Traceway] connection strings are deprecated; "
            + "start with Traceway.initialize(token: \"YOUR_TOKEN\")"])
    }

    func testAConnectionStringItCannotReadDoesNotStart() {
        for bad in ["tok", "tok@", "@https://cloud.tracewayapp.com", "tok@ftp://host"] {
            XCTAssertNil(Traceway.begin(connectionString: bad, options: options(), overrides: overrides()), bad)
        }
        XCTAssertNil(TracewayClient.shared)
        XCTAssertEqual(said("not started").count, 4)
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// No SDK request ever goes to the 1.x `/api/report` endpoint, whatever
    /// form the server URL was given in.
    func testNothingEverRequestsTheReportEndpoint() throws {
        let strings = [
            "tok@https://traceway.example.com/api/report",
            "tok@https://traceway.example.com/api/report/",
            "tok@traceway.example.com/api/report",
            "  tok@https://traceway.example.com/api/report  ",
            "tok@https://traceway.example.com/api/report?x=1",
            "tok@https://traceway.example.com/api/report#frag",
            "tok@http://localhost:8082/api/report",
        ]
        for connection in strings {
            let client = try XCTUnwrap(Traceway.begin(
                connectionString: connection,
                options: options(TracewayOptions(screenCapture: true, recordAllSessions: true)),
                overrides: overrides()
            ), connection)
            struct Failure: Error {}
            Traceway.captureException(Failure())
            Traceway.log("line")
            client.flush(timeout: 5)
            client.shutdown()
        }
        for base in ["https://traceway.example.com/api/report", "traceway.example.com/api/report?x=1"] {
            let client = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: base, options: options(),
                                                      overrides: overrides()))
            Traceway.captureMessage("message")
            client.flush(timeout: 5)
            client.shutdown()
        }
        XCTAssertTrue(eventually { self.server.requests(to: "/api/otel/v1/logs").count >= 9 })
        XCTAssertFalse(server.requests.isEmpty)
        for request in server.requests {
            XCTAssertFalse(request.url.absoluteString.contains("/api/report"), request.url.absoluteString)
            XCTAssertNil(request.url.query, request.url.absoluteString)
        }
    }

    // MARK: - Lines that say why nothing arrives

    func testACallBeforeInitializeSaysOnceThatNothingIsRecorded() throws {
        struct Failure: Error {}
        Traceway.captureException(Failure())
        Traceway.captureMessage("x")
        Traceway.log("y")
        XCTAssertEqual(said("before Traceway.initialize"), [
            "[Traceway] Traceway.captureException was called before Traceway.initialize, so nothing is recorded. "
                + "Call Traceway.initialize in your App's init or in application(_:didFinishLaunchingWithOptions:).",
        ])
        // After a shutdown it was the app's choice: nothing more is said.
        let client = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: "https://traceway.example.com",
                                                  options: options(), overrides: overrides()))
        client.shutdown()
        Log.resetForTesting()
        Traceway.captureMessage("after shutdown")
        XCTAssertEqual(said("before Traceway.initialize").count, 1)
    }

    func testARejectedTokenIsSaidOnce() throws {
        let rejecting = StatusServer { _ in 401 }
        let client = try XCTUnwrap(Traceway.begin(token: "wrong", baseUrl: "https://traceway.example.com",
                                                  options: options(), overrides: overrides(rejecting)))
        Traceway.captureMessage("one")
        Traceway.captureMessage("two")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { !self.said("rejected the project token").isEmpty })
        XCTAssertEqual(said("rejected the project token"), [
            "[Traceway] the server rejected the project token (HTTP 401) at https://traceway.example.com. "
                + "Copy the token from the project's Connection page.",
        ])
        XCTAssertFalse(lines.value.contains { $0.contains("wrong") }, "never the token")
    }

    func testAServerWithoutOTLPIsSaidOnce() throws {
        let old = StatusServer { $0.path == "/api/otel/v1/logs" ? 404 : 200 }
        let client = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: "https://traceway.example.com",
                                                  options: options(TracewayOptions(remoteConfig: false)),
                                                  overrides: overrides(old)))
        Traceway.captureMessage("one")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually { !self.said("does not accept iOS 2.x telemetry").isEmpty })
        XCTAssertEqual(said("does not accept iOS 2.x telemetry"), [
            "[Traceway] https://traceway.example.com does not accept iOS 2.x telemetry (HTTP 404 on "
                + "/api/otel/v1/logs): the server needs OTLP support; on an older server stay on 0.1.x.",
        ])
    }

    /// A pattern that does not compile is a mistake of the app's: said
    /// whatever `debug` says, also before `initialize` set it.
    func testABadPatternIsSaidWithoutDebug() {
        Log.debugEnabled = false
        _ = TracewayErrorPattern.regex("([")
        XCTAssertEqual(said("ignoreErrors"),
                       ["[Traceway] ignoreErrors: \"([\" is not a regular expression; it matches nothing"])
    }

    func testDebugSaysWhyAnIssueWasDropped() throws {
        struct RequestTimeout: Error {}
        let client = try XCTUnwrap(Traceway.begin(
            token: "tok", baseUrl: "https://traceway.example.com",
            options: options(TracewayOptions(debug: true, beforeCapture: { !$0.message.contains("private") })),
            overrides: overrides()
        ))
        Traceway.captureException(RequestTimeout())
        Traceway.captureMessage("private note")
        client.flush(timeout: 5)
        let ignored = try XCTUnwrap(said("it matches ignoreErrors").first)
        XCTAssertTrue(ignored.hasPrefix("[Traceway] dropped "), ignored)
        XCTAssertTrue(ignored.contains("RequestTimeout"), ignored)
        XCTAssertTrue(ignored.hasSuffix("it matches ignoreErrors (defaultIgnoreErrors); pass ignoreErrors: [] "
            + "to report it"), ignored)
        XCTAssertEqual(said("beforeCapture returned false"),
                       ["[Traceway] dropped private note: beforeCapture returned false"])
    }

    func testDebugSaysWhatTheSDKDoesAtStart() throws {
        let client = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: nil,
                                                  options: options(TracewayOptions(debug: true, screenCapture: true)),
                                                  overrides: overrides()))
        XCTAssertEqual(said("started (").first, "[Traceway] started (2.1.0) for https://cloud.tracewayapp.com: "
            + "errors and messages stream; console, network, navigation, userActions and custom wait on the device "
            + "for an error or a capture (recordAllSessions: true streams them); replay on, 4 fps")
        XCTAssertTrue(Traceway.begin(token: "other", baseUrl: nil, options: options(TracewayOptions(debug: true)),
                                     overrides: overrides()) === client)
        XCTAssertEqual(said("already running"),
                       ["[Traceway] already running: the options of this initialize call are ignored; "
                           + "call shutdown() first"])
    }

    func testDebugSaysScreenCaptureIsOffStandalone() throws {
        _ = try XCTUnwrap(Traceway.begin(
            token: nil, baseUrl: nil,
            options: options(TracewayOptions(debug: true, screenCapture: true,
                                             telemetry: TracewayTelemetry(url: "https://collector.example.com"))),
            overrides: overrides()
        ))
        XCTAssertEqual(said("screenCapture is off"), ["[Traceway] screenCapture is off without a token (standalone)"])
        XCTAssertTrue(said("started (").first?.contains("standalone (telemetry only)") == true)
    }

    func testWithoutDebugTheSDKSaysNothingAtStart() throws {
        _ = try XCTUnwrap(Traceway.begin(token: "tok", baseUrl: "traceway.example.com", options: options(),
                                         overrides: overrides()))
        XCTAssertEqual(lines.value, [])
    }
}

/// What ships with the package: its version where SwiftPM, the CHANGELOG and
/// the server read it, the privacy manifest, and the order of the options.
final class PackageTests: XCTestCase {
    private func packageFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("the package sources are not readable here")
        }
        return url
    }

    /// IOS2-3: the version `traceway.sdk.version` reports is the
    /// CHANGELOG's newest release and the one the README installs.
    func testTheSDKVersionIsTheChangelogsNewestRelease() throws {
        XCTAssertEqual(TracewaySDK.version, "2.1.0")
        let changelog = try String(contentsOf: packageFile("CHANGELOG.md"), encoding: .utf8)
        let heading = try XCTUnwrap(changelog.components(separatedBy: "\n").first { $0.hasPrefix("## ") })
        XCTAssertTrue(heading.hasPrefix("## \(TracewaySDK.version) "), heading)
        let readme = try String(contentsOf: packageFile("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("traceway-ios.git\", from: \"\(TracewaySDK.version)\")"),
                      "the README installs \(TracewaySDK.version)")
        XCTAssertFalse(readme.contains("beta"), "no beta left in the README")
        XCTAssertEqual(TracewaySDK.userAgent, "traceway-ios/\(TracewaySDK.version)")
    }

    /// IOS2-12: the privacy manifest Xcode adds to the app's privacy report.
    func testThePrivacyManifestDeclaresWhatTheSDKUsesAndCollects() throws {
        let data = try Data(contentsOf: packageFile("Sources/Traceway/PrivacyInfo.xcprivacy"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for api in apis {
            reasons[api["NSPrivacyAccessedAPIType"] as? String ?? ""] = api["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }), [
            "NSPrivacyCollectedDataTypeCrashData",
            "NSPrivacyCollectedDataTypePerformanceData",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypeUserID",
        ])
        for type in collected {
            XCTAssertEqual(type["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(type["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
        // The package ships it as a resource of the library.
        let manifest = try String(contentsOf: packageFile("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(#"resources: [.copy("PrivacyInfo.xcprivacy")]"#))
    }

    /// IOS2-17: the hang and exit options in Android's order. (In any other
    /// order this does not compile.)
    func testTheHangAndExitOptionsAreInAndroidsOrder() {
        let options = TracewayOptions(
            beforeCapture: nil,
            captureExitReasons: false,
            captureAppHangs: true,
            appHangThresholdMs: 3000,
            reportHangsInDebug: true,
            captureStdout: false
        )
        XCTAssertFalse(options.captureExitReasons)
        XCTAssertEqual(options.appHangThresholdMs, 3000)
        XCTAssertTrue(options.reportHangsInDebug)
    }
}
