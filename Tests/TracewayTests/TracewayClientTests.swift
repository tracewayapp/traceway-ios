import XCTest
@testable import Traceway

private final class FakeSender: ReportSender {
    private let lock = NSLock()
    private var _bodies: [String] = []
    private var _succeed = true

    func setSucceed(_ value: Bool) {
        lock.lock(); _succeed = value; lock.unlock()
    }

    func send(apiUrl: String, token: String, jsonBody: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _bodies.append(jsonBody)
        return _succeed
    }

    var bodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }
}

final class TracewayClientTests: XCTestCase {

    private let connectionString = "tok@https://example.com/api/report"

    override func tearDown() {
        TracewayClient.resetForTest()
        super.tearDown()
    }

    private func makeClient(_ options: TracewayOptions, sender: ReportSender) -> TracewayClient {
        try! TracewayClient.initializeForTesting(
            connectionString: connectionString,
            options: options,
            persistDir: nil,
            sender: sender
        )
    }

    func testSuccessfulFlushSendsPayloadAndClears() {
        let sender = FakeSender()
        let client = makeClient(TracewayOptions(version: "1.0.0", debounceMs: 50), sender: sender)

        client.capture(message: "hello world")
        client.flush(timeout: 5)

        XCTAssertEqual(client.pendingExceptionCount(), 0)
        let body = try! XCTUnwrap(sender.bodies.last)
        XCTAssertTrue(body.contains("hello world"))
        XCTAssertTrue(body.contains("\"isMessage\":true"))
        XCTAssertTrue(body.contains("\"appVersion\":\"1.0.0\""))
    }

    func testCapturedErrorPayloadShape() {
        let sender = FakeSender()
        let client = makeClient(TracewayOptions(debounceMs: 50), sender: sender)

        struct Boom: Error {}
        client.capture(Boom())
        client.flush(timeout: 5)

        let body = try! XCTUnwrap(sender.bodies.last)
        XCTAssertTrue(body.contains("\"isMessage\":false"))
        XCTAssertTrue(body.contains("Boom"))
        XCTAssertTrue(body.contains("\"collectionFrames\""))
    }

    func testFailedSendRequeues() {
        let sender = FakeSender()
        sender.setSucceed(false)
        // High debounce/retry so only the explicit flush triggers a send.
        let client = makeClient(TracewayOptions(debounceMs: 100_000, retryDelayMs: 100_000), sender: sender)

        client.capture(message: "x")
        client.flush(timeout: 5)

        XCTAssertEqual(client.pendingExceptionCount(), 1)
        XCTAssertEqual(sender.bodies.count, 1)
    }

    func testDropsOldestWhenBufferFull() {
        let sender = FakeSender()
        // No auto-sync during the test.
        let client = makeClient(TracewayOptions(debounceMs: 100_000, maxPendingExceptions: 2), sender: sender)

        client.capture(message: "a")
        client.capture(message: "b")
        client.capture(message: "c")

        XCTAssertEqual(client.pendingExceptionCount(), 2)
        let snapshot = client.pendingExceptionsSnapshot()
        XCTAssertEqual(snapshot.first?.stackTrace, "b") // oldest "a" dropped
        XCTAssertEqual(snapshot.last?.stackTrace, "c")
    }

    func testSampleRateZeroDropsEverything() {
        let sender = FakeSender()
        let client = makeClient(TracewayOptions(sampleRate: 0, debounceMs: 100_000), sender: sender)
        client.capture(message: "x")
        XCTAssertEqual(client.pendingExceptionCount(), 0)
    }

    func testDeviceAttributesMergedIntoExceptions() {
        let sender = FakeSender()
        let client = makeClient(TracewayOptions(debounceMs: 50), sender: sender)
        client.setDeviceAttributes(["os.name": "ios", "device.model": "iPhone14,3"])

        client.capture(message: "x")
        client.flush(timeout: 5)

        let body = try! XCTUnwrap(sender.bodies.last)
        XCTAssertTrue(body.contains("\"os.name\":\"ios\""))
        XCTAssertTrue(body.contains("\"device.model\":\"iPhone14,3\""))
    }
}
