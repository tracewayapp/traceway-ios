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

        let client = Traceway.start(
            connectionString: dsn,
            options: TracewayOptions(debug: true, version: "ci-device")
        )
        XCTAssertNotNil(client, "Traceway.start should succeed on-device")
        XCTAssertNotNil(TracewayClient.shared)

        XCTAssertEqual(client?.currentDeviceAttributes()["os.name"], "ios")

        struct DeviceSmokeError: Error {}
        Traceway.capture(message: "device smoke message")
        Traceway.capture(DeviceSmokeError())
        Traceway.flush(timeout: 8)

        XCTAssertNotNil(TracewayClient.shared)
    }

    func testBackendReachableDiagnostic() throws {
        guard let dsn = resolvedDSN() else {
            throw XCTSkip("no TRACEWAY_DSN configured")
        }
        let at = dsn.firstIndex(of: "@")!
        let token = String(dsn[dsn.startIndex..<at])
        let urlString = String(dsn[dsn.index(after: at)...])
        let url = try XCTUnwrap(URL(string: urlString))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"collectionFrames":[],"appVersion":"diag","serverName":""}"#.utf8)

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
        let payload = Data(#"{"collectionFrames":[],"appVersion":"ci","serverName":""}"#.utf8)
        let compressed = try XCTUnwrap(Gzip.compress(payload))
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(Gzip.decompress(compressed), payload)
    }

    func testWireFormatOnDevice() {
        let exception = ExceptionStackTrace(stackTrace: "boom", recordedAtMs: 1_700_000_000_000)
        let json = exception.toJSON().serialize()
        XCTAssertTrue(json.contains("\"recordedAt\":\"2023-11-14T22:13:20.000Z\""))
        XCTAssertTrue(json.contains("\"traceId\":null"))
    }
}
