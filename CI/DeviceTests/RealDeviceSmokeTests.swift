import XCTest
@testable import Traceway

final class RealDeviceSmokeTests: XCTestCase {

    func testRealHardwareAttributes() {
        let info = DeviceInfoCollector.collectSync()
        XCTAssertEqual(info["os.name"], "ios")
        XCTAssertEqual(info["device.manufacturer"], "Apple")
        XCTAssertEqual(info["device.brand"], "Apple")
        XCTAssertTrue(info["os.version"]?.hasPrefix("iOS") == true)
        XCTAssertFalse((info["device.model"] ?? "").isEmpty)

        XCTAssertNotNil(info["screen.resolution"])
        XCTAssertNotNil(info["screen.density"])
    }

    func testStartCaptureFlushOnDevice() {

        let dsn = resolvedDSN() ?? "ci-token@http://127.0.0.1:9/api/report"

        let client = Traceway.initialize(
            connectionString: dsn,
            options: TracewayOptions(debug: true, version: "ci-device", screenCapture: true)
        )
        XCTAssertNotNil(client, "Traceway.initialize should succeed on-device")
        XCTAssertNotNil(TracewayClient.shared)
        XCTAssertEqual(client?.instanceId.count, 36)
        XCTAssertNotNil(client?.currentSessionId)

        struct DeviceSmokeError: Error {}
        Traceway.log("device smoke breadcrumb")
        Traceway.captureMessage("device smoke message")
        Traceway.captureException(DeviceSmokeError())
        Traceway.flush(timeout: 8)

        XCTAssertNotNil(TracewayClient.shared)
        Traceway.shutdown()
        XCTAssertNil(TracewayClient.shared)
    }

    /// Walks the host app's real windows with the wireframe recorder.
    func testWireframeCapturesTheHostApp() throws {
        let frame = try XCTUnwrap(WireframeCapture().captureScreen(
            timestampMs: Clock.nowMs(), href: "/", keyboardFrame: nil
        ), "the host app has a window")
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        let screen = try XCTUnwrap(frame.screen)
        XCTAssertFalse(screen.children.isEmpty, "the window has content")
        let document = serializeDocument(screen).encoded()
        XCTAssertTrue(document.contains("\"tw\""))

        // A second capture of an unchanged screen shares its nodes.
        let capture = WireframeCapture()
        let first = try XCTUnwrap(capture.captureScreen(timestampMs: Clock.nowMs(), href: "/", keyboardFrame: nil))
        let second = try XCTUnwrap(capture.captureScreen(timestampMs: Clock.nowMs(), href: "/", keyboardFrame: nil))
        XCTAssertNil(diffScreens(first.screen!, second.screen!))
    }

    func testBackendReachableDiagnostic() throws {
        guard let dsn = resolvedDSN() else {
            throw XCTSkip("no TRACEWAY_DSN configured")
        }
        let at = dsn.firstIndex(of: "@")!
        let token = String(dsn[dsn.startIndex..<at])
        let urlString = String(dsn[dsn.index(after: at)...])
        let url = try XCTUnwrap(URL(string: urlString))

        // An empty OTLP logs request: valid protobuf, and nothing to store.
        var request = URLRequest(url: try resolveEndpoints(url.absoluteString).logs)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data()

        let exp = expectation(description: "request")
        var status = -1
        var errorText = "none"
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse { status = http.statusCode }
            if let error = error { errorText = "\(error)" }
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 15)

        print("TWDIAG url=\(urlString) status=\(status) error=\(errorText)")
        XCTAssertEqual(status, 200, "url=\(urlString) status=\(status) error=\(errorText)")
    }

    private func resolvedDSN() -> String? {
        if let env = ProcessInfo.processInfo.environment["TRACEWAY_DSN"], !env.isEmpty {
            return env
        }
        if let plist = Bundle(for: Self.self).object(forInfoDictionaryKey: "TRACEWAY_DSN") as? String,
           !plist.isEmpty, plist.contains("@") {
            return plist
        }
        return nil
    }

    func testGzipUsesDeviceZlib() throws {
        let payload = Data(#"{"segments":[]}"#.utf8)
        let compressed = try XCTUnwrap(Gzip.compress(payload))
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(Gzip.decompress(compressed), payload)
    }
}
