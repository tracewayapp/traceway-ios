import Foundation
import XCTest
@testable import Traceway

// Produced by opamp-go v0.25.0's generated types (proto.Marshal,
// deterministic) for the same messages; shared with the browser and Flutter
// SDKs' tests.
private let goAgentToServer =
    "0a100195f2a000007000800000000000000110031a6f0a1a0a0c736572766963652e6e616d65120a0a0873686f702d776562121a0a0f736572766963652e76657273696f6e12070a05322e332e3112140a0e62726f777365722e6d6f62696c6512021001120b0a0573656174731202180c12120a05726174696f120921000000000000d03f2083603a060a02abcd100162370a19696f2e74726163657761792e73646b2e6275666665722f76310a1a696f2e74726163657761792e73646b2e636170747572652f7631"
private let goServerToAgent =
    "0a100195f2a00000700080000000000000011a570a500a4e0a08747261636577617912420a2e7b22736368656d6156657273696f6e223a312c227265706c6179223a7b226d6f6465223a2273747265616d227d7d12106170706c69636174696f6e2f6a736f6e120301020322080a0109120320ac023001382342120a10ffeeddccbbaa99887766554433221100"
private let goServerError = "121108021204627573791a070880b09dc2df01"

private func hex(_ bytes: [UInt8]) -> String { Ids.hex(bytes) }
private func hex(_ data: Data) -> String { Ids.hex(Array(data)) }
private func fromHex(_ text: String) -> [UInt8] { Ids.bytes(hex: text)! }

private let uid = fromHex("0195f2a0000070008000000000000001")

final class OpampCodecTests: XCTestCase {
    func testEncodesAgentToServerByteForByteLikeOpampGo() {
        let bytes = encodeAgentToServer(AgentToServer(
            instanceUid: uid,
            sequenceNum: 3,
            agentDescription: AgentDescription(
                identifying: ["service.name": "shop-web"],
                nonIdentifying: [
                    "service.version": "2.3.1",
                    "browser.mobile": true,
                    "seats": 12,
                    "ratio": 0.25,
                ]
            ),
            capabilities: 0x1 | 0x2 | 0x1000 | 0x2000,
            remoteConfigStatus: RemoteConfigStatus(
                lastRemoteConfigHash: fromHex("abcd"),
                status: RemoteConfigStatuses.applied
            ),
            customCapabilities: ["io.traceway.sdk.buffer/v1", "io.traceway.sdk.capture/v1"]
        ))
        XCTAssertEqual(hex(bytes), goAgentToServer)
    }

    func testWritesFalseZeroAndEmptyValuesExplicitly() {
        let bytes = encodeAgentToServer(AgentToServer(
            instanceUid: uid,
            sequenceNum: 0,
            agentDescription: AgentDescription(
                identifying: [:],
                nonIdentifying: ["flag": false, "n": 0, "empty": ""]
            ),
            capabilities: 0
        ))
        // KeyValue{key:"flag", value:AnyValue{bool_value:false}}
        XCTAssertTrue(hex(bytes).contains("0a04666c616712021000"))
        // KeyValue{key:"n", value:AnyValue{int_value:0}}
        XCTAssertTrue(hex(bytes).contains("0a016e12021800"))
        // KeyValue{key:"empty", value:AnyValue{string_value:""}}
        XCTAssertTrue(hex(bytes).contains("0a05656d70747912020a00"))
    }

    func testEncodesNegativeAndFractionalNumbersAsDoublesAndArraysOfStrings() {
        let bytes = encodeAgentToServer(AgentToServer(
            instanceUid: uid,
            sequenceNum: 0,
            agentDescription: AgentDescription(
                identifying: [:],
                nonIdentifying: ["neg": -1, "tags": .array(["a", "b"])]
            ),
            capabilities: 0
        ))
        // AnyValue{double_value: -1}
        XCTAssertTrue(hex(bytes).contains("0a036e6567120921000000000000f0bf"))
        // AnyValue{array_value: {values: [{string_value:"a"}, {string_value:"b"}]}}
        XCTAssertTrue(hex(bytes).contains("0a0474616773120c2a0a0a030a01610a030a0162"))
    }

    func testAttributesFromADictionaryEncodeInKeyOrder() {
        var attributes = OpampAttributes(["b": "2", "a": "1"])
        XCTAssertEqual(attributes.entries.map { $0.key }, ["a", "b"])
        attributes["c"] = "3"
        attributes["a"] = "one"
        attributes["b"] = nil
        XCTAssertEqual(attributes.entries.map { $0.key }, ["a", "c"])
        XCTAssertEqual(attributes["a"], "one")
    }

    func testDecodesAServerToAgentWrittenByOpampGo() throws {
        let msg = try decodeServerToAgent(fromHex(goServerToAgent))
        XCTAssertEqual(hex(msg.instanceUid!), hex(uid))
        XCTAssertEqual(msg.flags, 1)
        XCTAssertEqual(msg.capabilities, 0x23)
        XCTAssertEqual(msg.heartbeatIntervalSeconds, 300)
        XCTAssertEqual(hex(msg.newInstanceUid!), "ffeeddccbbaa99887766554433221100")
        XCTAssertEqual(hex(msg.remoteConfig!.configHash), "010203")
        let doc = msg.remoteConfig!.configMap["traceway"]!
        XCTAssertEqual(doc.contentType, "application/json")
        let parsed = try JSON.parse(Data(doc.body))
        XCTAssertEqual(parsed, ["schemaVersion": 1, "replay": ["mode": "stream"]])
    }

    func testDecodesAnErrorResponseWithRetryInfo() throws {
        let error = try decodeServerToAgent(fromHex(goServerError)).errorResponse!
        XCTAssertEqual(error.type, ServerErrorTypes.unavailable)
        XCTAssertEqual(error.message, "busy")
        XCTAssertEqual(error.retryAfterMs, 60_000)
    }

    func testSkipsFieldsItDoesNotKnow() throws {
        XCTAssertEqual(try decodeServerToAgent(fromHex("f801073001")).flags, 1)
    }

    func testRejectsAMessageCutOffInsideAFieldItSkips() {
        // Field 31 as fixed32 and fixed64, with fewer bytes than they take.
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("fd010000")))
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("f901000000")))
        // A length-delimited field longer than the message.
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("1a05010203")))
    }

    func testRejectsAVarintLongerThanTenBytes() {
        let tooLong = "f801" + String(repeating: "ff", count: 10) + "01"
        XCTAssertThrowsError(try decodeServerToAgent(fromHex(tooLong)))
        // Ten bytes is the most a uint64 takes, and is fine.
        let longest = "30" + String(repeating: "ff", count: 9) + "01"
        XCTAssertEqual(try decodeServerToAgent(fromHex(longest)).flags, UInt64.max)
    }

    func testRejectsTruncatedAndUnsupportedFields() {
        // instance_uid claims 16 bytes, carries 2.
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("0a100102")))
        // A varint that never ends.
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("3080")))
        // Wire type 3 (start group) cannot be skipped.
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("fb01")))
        // A huge length must not overflow the bounds check.
        XCTAssertThrowsError(try decodeServerToAgent(fromHex("0a" + "ffffffffffffffff7f" + "00")))
    }

    func testAFieldOfTheWrongWireTypeIsSkippedNotMisread() throws {
        // flags (6) as length-delimited, then capabilities (7) = 5.
        let msg = try decodeServerToAgent(fromHex("32020101" + "3805"))
        XCTAssertEqual(msg.flags, 0)
        XCTAssertEqual(msg.capabilities, 5)
    }

    func testVarintsRoundTripAtTheirEdges() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_383, 16_384, 1 << 35, UInt64(Int64.max), UInt64.max] {
            let w = ProtoWriter()
            w.varint(value)
            XCTAssertEqual(try ProtoReader(w.buffer).varint(), value)
        }
        let w = ProtoWriter()
        w.varint(300)
        XCTAssertEqual(hex(w.buffer), "ac02")
    }

    func testDoublesAreLittleEndianFixed64() {
        let w = ProtoWriter()
        w.float64(4, 0.25)
        XCTAssertEqual(hex(w.buffer), "21000000000000d03f")
    }

    func testEncodeServerToAgentRoundTripsThroughTheDecoder() throws {
        let msg = try decodeServerToAgent(encodeServerToAgent(
            remoteConfig: RemoteConfig(
                configMap: [
                    "traceway": AgentConfigObject(
                        body: Array("{\"schemaVersion\":1}".utf8),
                        contentType: "application/json"
                    ),
                ],
                configHash: fromHex("0a0b")
            ),
            heartbeatIntervalSeconds: 120,
            flags: 1,
            capabilities: 0x23,
            newInstanceUid: fromHex("00112233445566778899aabbccddeeff")
        ))
        XCTAssertEqual(msg.flags, 1)
        XCTAssertEqual(msg.capabilities, 0x23)
        XCTAssertEqual(msg.heartbeatIntervalSeconds, 120)
        XCTAssertEqual(hex(msg.remoteConfig!.configHash), "0a0b")
        XCTAssertEqual(
            String(decoding: msg.remoteConfig!.configMap["traceway"]!.body, as: UTF8.self),
            "{\"schemaVersion\":1}"
        )
        XCTAssertEqual(hex(msg.newInstanceUid!), "00112233445566778899aabbccddeeff")
    }

    func testDecodesAnEmptyBodyAsAnEmptyMessage() throws {
        XCTAssertEqual(try decodeServerToAgent([]), ServerToAgent())
    }
}

/// A scripted OpAMP server. `respond` gets each request and its index; the
/// answer arrives on another thread, as URLSession's do.
private final class FakeOpampServer: HTTPTransport {
    struct Request {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    var respond: (Request, Int) -> HTTPResult
    /// Called after each answer is handed back, with the request index.
    var onRequest: ((Int) -> Void)?

    init(respond: @escaping (Request, Int) -> HTTPResult) {
        self.respond = respond
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval,
        completion: @escaping (HTTPResult) -> Void
    ) {
        let request = Request(url: url, headers: headers, body: body)
        lock.lock()
        recorded.append(request)
        let index = recorded.count - 1
        lock.unlock()
        let answer = respond(request, index)
        DispatchQueue.global().async {
            completion(answer)
            self.onRequest?(index)
        }
    }
}

private func ok(_ bytes: [UInt8]) -> HTTPResult {
    HTTPResult(statusCode: 200, headers: [:], body: Data(bytes))
}

private func configResponse(_ hash: [UInt8]) -> HTTPResult {
    ok(encodeServerToAgent(
        remoteConfig: RemoteConfig(
            configMap: ["traceway": AgentConfigObject(body: Array("{}".utf8), contentType: "application/json")],
            configHash: hash
        ),
        heartbeatIntervalSeconds: 60
    ))
}

final class OpampClientTests: XCTestCase {
    private let queue = DispatchQueue(label: "opamp-test")
    private var clients: [OpampClient] = []

    override func tearDown() {
        let clients = self.clients
        queue.sync { clients.forEach { $0.stop() } }
        self.clients = []
        super.tearDown()
    }

    private func makeClient(
        _ server: HTTPTransport,
        headers: [String: String] = ["Authorization": "Bearer tok"],
        describe: (() -> AgentDescription)? = nil,
        appliedConfigHash: [UInt8]? = nil,
        onRemoteConfig: ((RemoteConfig) -> ApplyResult)? = nil,
        onInstanceUidChange: (([UInt8]) -> Void)? = nil,
        onStopped: ((Int) -> Void)? = nil,
        defaultPollIntervalMs: Int64 = 300_000,
        requestTimeout: TimeInterval = 2
    ) -> OpampClient {
        let client = OpampClient(
            endpoint: URL(string: "https://traceway.test/api/otel/v1/opamp")!,
            headers: headers,
            instanceUid: uid,
            capabilities: 0x3003,
            customCapabilities: [],
            describe: describe ?? {
                AgentDescription(identifying: ["service.name": "app"], nonIdentifying: [:])
            },
            onRemoteConfig: onRemoteConfig ?? { _ in .applied },
            appliedConfigHash: appliedConfigHash,
            onInstanceUidChange: onInstanceUidChange,
            onStopped: onStopped,
            defaultPollIntervalMs: defaultPollIntervalMs,
            minPollIntervalMs: 50,
            transport: server,
            queue: queue,
            requestTimeout: requestTimeout
        )
        clients.append(client)
        return client
    }

    /// Starts the client and waits for the poll that start sends.
    private func startAndWait(_ client: OpampClient) {
        let done = expectation(description: "first poll")
        queue.async {
            client.start()
            client.poll { done.fulfill() }
        }
        wait(for: [done], timeout: 3)
    }

    private func pollAndWait(_ client: OpampClient) {
        let done = expectation(description: "poll")
        queue.async { client.poll { done.fulfill() } }
        wait(for: [done], timeout: 3)
    }

    /// Waits until the server has answered `count` requests and the client
    /// has handled the last answer.
    private func waitForRequests(_ server: FakeOpampServer, _ count: Int) {
        let reached = expectation(description: "\(count) requests")
        reached.assertForOverFulfill = false
        server.onRequest = { index in
            if index + 1 >= count { reached.fulfill() }
        }
        if server.requests.count >= count { reached.fulfill() }
        wait(for: [reached], timeout: 3)
        server.onRequest = nil
        // Let the client handle the last answer.
        Thread.sleep(forTimeInterval: 0.05)
        queue.sync {}
    }

    func testSendsTheProtobufHeadersAndTheInstanceUid() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent(heartbeatIntervalSeconds: 300)) }
        let client = makeClient(server)
        startAndWait(client)
        let request = server.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://traceway.test/api/otel/v1/opamp")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-protobuf")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(request.headers["OpAMP-Instance-UID"], "0195f2a0-0000-7000-8000-000000000001")
        XCTAssertTrue(hex(request.body).hasPrefix("0a10" + hex(uid)))
        XCTAssertEqual(queue.sync { client.pollIntervalMs }, 300_000)
    }

    func testSequenceNumbersCountUp() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent()) }
        let client = makeClient(server)
        startAndWait(client)
        pollAndWait(client)
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        // sequence_num 0 is omitted (the description, field 3, follows the
        // uid), 1 is field 2.
        XCTAssertTrue(hex(requests[0].body).hasPrefix("0a10" + hex(uid) + "1a"))
        XCTAssertTrue(hex(requests[1].body).hasPrefix("0a10" + hex(uid) + "1001"))
    }

    func testAppliesANewConfigAndReportsItOnAnImmediateSecondPoll() {
        var applied: [String] = []
        let server = FakeOpampServer { _, index in
            index == 0 ? configResponse([1, 2, 3]) : ok(encodeServerToAgent(heartbeatIntervalSeconds: 60))
        }
        let client = makeClient(server, onRemoteConfig: { config in
            applied.append(hex(config.configHash))
            return .applied
        })
        queue.async { client.start() }
        waitForRequests(server, 2)
        queue.sync { client.stop() }
        XCTAssertEqual(queue.sync { applied }, ["010203"])
        XCTAssertEqual(server.requests.count, 2)
        // remote_config_status{last_remote_config_hash: 010203, status: APPLIED}
        XCTAssertTrue(hex(server.requests[1].body).contains("3a070a030102031001"))
        XCTAssertEqual(queue.sync { client.pollIntervalMs }, 60_000)
    }

    func testReportsFailedWithTheErrorWhenTheConfigCannotBeApplied() {
        let server = FakeOpampServer { _, index in
            index == 0 ? configResponse([9]) : ok(encodeServerToAgent())
        }
        let client = makeClient(server, onRemoteConfig: { _ in .failed("bad") })
        queue.async { client.start() }
        waitForRequests(server, 2)
        queue.sync { client.stop() }
        XCTAssertTrue(hex(server.requests[1].body).contains("3a0a0a010910031a03" + hex(Array("bad".utf8))))
    }

    func testDoesNotReapplyAConfigWhoseHashIsAlreadyApplied() {
        var applied = 0
        let server = FakeOpampServer { _, _ in configResponse([1, 2, 3]) }
        let client = makeClient(server, appliedConfigHash: [1, 2, 3], onRemoteConfig: { _ in
            applied += 1
            return .applied
        })
        startAndWait(client)
        queue.sync { client.stop() }
        XCTAssertEqual(queue.sync { applied }, 0)
        XCTAssertEqual(server.requests.count, 1)
        // The cached hash is reported from the first poll on.
        XCTAssertTrue(hex(server.requests[0].body).contains("3a070a030102031001"))
    }

    func testStopsForGoodOn401403404405And501() {
        for status in [401, 403, 404, 405, 501] {
            var stopped: Int?
            let server = FakeOpampServer { _, _ in HTTPResult(statusCode: status) }
            let client = makeClient(server, onStopped: { stopped = $0 })
            startAndWait(client)
            XCTAssertEqual(queue.sync { stopped }, status)
            XCTAssertFalse(queue.sync { client.isRunning })
            pollAndWait(client)
            XCTAssertEqual(server.requests.count, 1, "status \(status)")
        }
    }

    func testBacksOffInsteadOfPollingAgainAfterAServerError() {
        let server = FakeOpampServer { _, _ in HTTPResult(statusCode: 503, headers: ["retry-after": "60"]) }
        let client = makeClient(server)
        startAndWait(client)
        pollAndWait(client)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(queue.sync { client.isRunning })
    }

    func testBacksOffAfterNoAnswerAndAfterAnUnavailableErrorResponse() {
        let noAnswer = FakeOpampServer { _, _ in .noAnswer }
        let first = makeClient(noAnswer)
        startAndWait(first)
        pollAndWait(first)
        XCTAssertEqual(noAnswer.requests.count, 1)

        let busy = FakeOpampServer { _, _ in ok(fromHex(goServerError)) }
        let second = makeClient(busy)
        startAndWait(second)
        pollAndWait(second)
        XCTAssertEqual(busy.requests.count, 1)

        let throttled = FakeOpampServer { _, _ in HTTPResult(statusCode: 429) }
        let third = makeClient(throttled)
        startAndWait(third)
        pollAndWait(third)
        XCTAssertEqual(throttled.requests.count, 1)
    }

    func testDoesNotBackOffAfterA413() {
        let server = FakeOpampServer { _, _ in HTTPResult(statusCode: 413) }
        let client = makeClient(server)
        startAndWait(client)
        // Not backing off: an explicit poll goes out at once.
        pollAndWait(client)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(queue.sync { client.isRunning })
    }

    func testAdoptsANewInstanceUidFromTheServer() {
        let newUid = fromHex("ffeeddccbbaa99887766554433221100")
        var changed: [UInt8]?
        let server = FakeOpampServer { _, index in
            ok(index == 0 ? encodeServerToAgent(newInstanceUid: newUid) : encodeServerToAgent())
        }
        let client = makeClient(server, onInstanceUidChange: { changed = $0 })
        startAndWait(client)
        pollAndWait(client)
        XCTAssertEqual(queue.sync { changed }, newUid)
        XCTAssertEqual(queue.sync { client.instanceUid }, newUid)
        XCTAssertEqual(server.requests[1].headers["OpAMP-Instance-UID"], "ffeeddcc-bbaa-9988-7766-554433221100")
        XCTAssertTrue(hex(server.requests[1].body).hasPrefix("0a10" + hex(newUid)))
    }

    func testIgnoresANewInstanceUidThatIsNotSixteenBytes() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent(newInstanceUid: [1, 2, 3])) }
        var changed = false
        let client = makeClient(server, onInstanceUidChange: { _ in changed = true })
        startAndWait(client)
        XCTAssertFalse(queue.sync { changed })
        XCTAssertEqual(queue.sync { client.instanceUid }, uid)
    }

    func testPollsAgainAtOnceWhenTheServerAsksForTheFullState() {
        let server = FakeOpampServer { _, index in
            ok(index == 0 ? encodeServerToAgent(flags: serverFlagReportFullState) : encodeServerToAgent())
        }
        let client = makeClient(server)
        queue.async { client.start() }
        waitForRequests(server, 2)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testKeepsTheHeartbeatAboveTheMinimumInterval() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent(heartbeatIntervalSeconds: 1)) }
        let client = OpampClient(
            endpoint: URL(string: "https://traceway.test/api/otel/v1/opamp")!,
            headers: [:],
            instanceUid: uid,
            capabilities: 0,
            customCapabilities: [],
            describe: { AgentDescription(identifying: [:], nonIdentifying: [:]) },
            onRemoteConfig: { _ in .applied },
            defaultPollIntervalMs: 10,
            minPollIntervalMs: 30_000,
            transport: server,
            queue: queue
        )
        clients.append(client)
        XCTAssertEqual(queue.sync { client.pollIntervalMs }, 30_000)
        startAndWait(client)
        XCTAssertEqual(queue.sync { client.pollIntervalMs }, 30_000)
    }

    func testPollsOnTheHeartbeat() {
        // 50 ms is this test's minimum interval.
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent()) }
        let client = makeClient(server)
        queue.async { client.start() }
        waitForRequests(server, 1)
        XCTAssertEqual(queue.sync { client.pollIntervalMs }, 300_000)

        let fast = FakeOpampServer { _, _ in ok(encodeServerToAgent(heartbeatIntervalSeconds: 0)) }
        let heartbeat = OpampClient(
            endpoint: URL(string: "https://traceway.test/api/otel/v1/opamp")!,
            headers: [:],
            instanceUid: uid,
            capabilities: 0,
            customCapabilities: [],
            describe: { AgentDescription(identifying: [:], nonIdentifying: [:]) },
            onRemoteConfig: { _ in .applied },
            defaultPollIntervalMs: 50,
            minPollIntervalMs: 50,
            transport: fast,
            queue: queue
        )
        clients.append(heartbeat)
        queue.async { heartbeat.start() }
        waitForRequests(fast, 3)
        XCTAssertGreaterThanOrEqual(fast.requests.count, 3)
    }

    func testRefreshWaitsForThePollUnderWayAndPollsAgain() {
        let release = DispatchSemaphore(value: 0)
        let server = FakeOpampServer { _, index in
            if index == 0 { release.wait() }
            return ok(encodeServerToAgent())
        }
        let client = makeClient(server)
        let done = expectation(description: "refresh")
        queue.async {
            client.start()
            client.refresh { done.fulfill() }
        }
        // The first request is held until the refresh is queued behind it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { release.signal() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAStoppedClientSendsNothing() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent()) }
        let client = makeClient(server)
        pollAndWait(client)
        XCTAssertEqual(server.requests.count, 0)
        XCTAssertFalse(queue.sync { client.isRunning })
    }

    func testTheProtocolHeadersWinOverTheCallers() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent(heartbeatIntervalSeconds: 300)) }
        let client = makeClient(server, headers: [
            "Content-Type": "text/plain",
            "OpAMP-Instance-UID": "nope",
            "X-Extra": "1",
        ])
        startAndWait(client)
        XCTAssertEqual(server.requests[0].headers, [
            "X-Extra": "1",
            "Content-Type": "application/x-protobuf",
            "OpAMP-Instance-UID": "0195f2a0-0000-7000-8000-000000000001",
        ])
    }

    /// IOS-2: `Retry-After` from a proxy or captive portal was multiplied
    /// into milliseconds unchecked and trapped the client's queue.
    func testAnAbsurdRetryAfterIsHeldToADayInsteadOfTrapping() {
        let huge = HTTPResult(statusCode: 503, headers: ["retry-after": "99999999999999999"])
        XCTAssertEqual(huge.retryAfterMs, 86_400_000)
        XCTAssertEqual(HTTPResult(statusCode: 503, headers: ["retry-after": " 5 "]).retryAfterMs, 5000)
        XCTAssertNil(HTTPResult(statusCode: 503, headers: ["retry-after": "-5"]).retryAfterMs)

        let server = FakeOpampServer { _, _ in huge }
        let client = makeClient(server)
        startAndWait(client)
        pollAndWait(client)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertTrue(queue.sync { client.isRunning })
    }

    func testTakesTheRetryDelayFromTheErrorResponseWhenThereIsNoHeader() {
        // Without the error response's 1.2 s the client would wait 30 s.
        let server = FakeOpampServer { _, index in
            index == 0
                ? HTTPResult(statusCode: 503, body: Data(opampErrorAnswer(
                    type: ServerErrorTypes.unavailable, retryAfterMs: 1200
                )))
                : ok(encodeServerToAgent(heartbeatIntervalSeconds: 300))
        }
        let client = makeClient(server)
        startAndWait(client)
        pollAndWait(client)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(server.requests.count, 1)
        waitForRequests(server, 2)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testTheRetryAfterHeaderWinsOverTheErrorResponse() {
        let server = FakeOpampServer { _, index in
            index == 0
                ? HTTPResult(statusCode: 429, headers: ["retry-after": "1"], body: Data(opampErrorAnswer(
                    type: ServerErrorTypes.unavailable, retryAfterMs: 60_000
                )))
                : ok(encodeServerToAgent(heartbeatIntervalSeconds: 300))
        }
        let client = makeClient(server)
        startAndWait(client)
        waitForRequests(server, 2)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testABadRequestBacksOffThenAGoodAnswerResetsTheBackoff() {
        let rejected = FakeOpampServer { _, _ in
            HTTPResult(statusCode: 400, body: Data(opampErrorAnswer(
                type: ServerErrorTypes.badRequest, message: "instance_uid must be 16 bytes"
            )))
        }
        let first = makeClient(rejected)
        startAndWait(first)
        pollAndWait(first)
        XCTAssertEqual(rejected.requests.count, 1)
        XCTAssertTrue(queue.sync { first.isRunning })

        let recovering = FakeOpampServer { _, index in
            index == 0
                ? HTTPResult(statusCode: 503, headers: ["retry-after": "1"])
                : ok(encodeServerToAgent(heartbeatIntervalSeconds: 300))
        }
        let second = makeClient(recovering)
        startAndWait(second)
        waitForRequests(recovering, 2)
        // Not backing off any more: an explicit poll goes out at once.
        pollAndWait(second)
        XCTAssertEqual(recovering.requests.count, 3)
    }

    func testConcurrentPollsShareOneRequest() {
        let server = FakeOpampServer { _, _ in ok(encodeServerToAgent(heartbeatIntervalSeconds: 300)) }
        let client = makeClient(server)
        let a = expectation(description: "a")
        let b = expectation(description: "b")
        queue.async {
            client.start()
            client.poll { a.fulfill() }
            client.poll { b.fulfill() }
        }
        wait(for: [a, b], timeout: 3)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheCompletionRunsWhenThereIsNothingToPoll() {
        let server = FakeOpampServer { _, _ in HTTPResult(statusCode: 503) }
        let client = makeClient(server)
        var done = 0
        // Not started.
        queue.sync { client.poll { done += 1 } }
        XCTAssertEqual(done, 1)
        startAndWait(client)
        // Backing off.
        queue.sync { client.poll { done += 1 } }
        XCTAssertEqual(done, 2)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testAnAnswerThatComesAfterStopIsDropped() {
        var applied = 0
        let server = FakeOpampServer { _, _ in configResponse([1]) }
        let client = makeClient(server, onRemoteConfig: { _ in
            applied += 1
            return .applied
        })
        let answered = expectation(description: "answered")
        server.onRequest = { _ in answered.fulfill() }
        queue.async {
            client.start()
            client.stop()
        }
        wait(for: [answered], timeout: 3)
        // The answer is handled on the queue after it arrived.
        queue.sync {}
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(queue.sync { applied }, 0)
        XCTAssertFalse(queue.sync { client.isRunning })
    }

    func testARestartWhileAPollIsUnderWayKeepsPolling() {
        var client: OpampClient!
        let server = FakeOpampServer { _, index in
            // Called on the client's queue, while the first poll is out.
            if index == 0 {
                client.stop()
                client.start()
            }
            return ok(encodeServerToAgent())
        }
        client = makeClient(server, defaultPollIntervalMs: 50)
        queue.async { client.start() }
        waitForRequests(server, 3)
        XCTAssertTrue(queue.sync { client.isRunning })
    }

    func testCallbacksRunOnTheClientsQueue() {
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        var onQueue: [Bool] = []
        func note() { onQueue.append(DispatchQueue.getSpecific(key: key) == true) }
        let server = FakeOpampServer { _, index in
            index == 0 ? configResponse([7]) : ok(encodeServerToAgent(heartbeatIntervalSeconds: 300))
        }
        let client = makeClient(
            server,
            describe: {
                note()
                return AgentDescription(identifying: ["service.name": "app"], nonIdentifying: [:])
            },
            onRemoteConfig: { _ in
                note()
                return .applied
            }
        )
        queue.async { client.start() }
        waitForRequests(server, 2)
        pollAndWait(client)
        let done = expectation(description: "completion")
        queue.async { client.poll { note(); done.fulfill() } }
        wait(for: [done], timeout: 3)
        let seen = queue.sync { onQueue }
        XCTAssertGreaterThanOrEqual(seen.count, 4)
        XCTAssertTrue(seen.allSatisfy { $0 }, "\(seen)")
        // remote_config_status{last_remote_config_hash: 07, status: APPLIED}
        XCTAssertTrue(hex(server.requests[1].body).contains("3a050a01071001"))
    }

    func testPollsFromManyThreadsNeverOverlapAndEveryCompletionRuns() {
        let transport = OverlapCountingTransport()
        let client = makeClient(transport)
        startAndWait(client)
        let done = expectation(description: "every completion")
        done.expectedFulfillmentCount = 8 * 25
        let callers = (1...8).map { n in
            Thread {
                for i in 0..<25 {
                    self.queue.async {
                        if (n + i) % 2 == 0 {
                            client.poll { done.fulfill() }
                        } else {
                            client.refresh { done.fulfill() }
                        }
                    }
                }
            }
        }
        callers.forEach { $0.start() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(transport.maxActive, 1)
        XCTAssertTrue((1...201).contains(transport.sent), "\(transport.sent)")
        XCTAssertTrue(queue.sync { client.isRunning })
    }

    func testATransportThatNeverAnswersEndsThePollAfterItsTimeout() {
        let silent = SilentTransport()
        let client = makeClient(silent, requestTimeout: 0.1)
        let done = expectation(description: "poll ended")
        queue.async {
            client.start()
            client.poll { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(queue.sync { client.isRunning })
        // No answer counts as an error: the client backs off.
        pollAndWait(client)
        XCTAssertEqual(silent.count, 1)
    }
}

/// Answers every poll after a moment and counts how many requests are out at
/// once.
private final class OverlapCountingTransport: HTTPTransport {
    private let lock = NSLock()
    private var active = 0
    private var _maxActive = 0
    private var _sent = 0

    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return _maxActive }
    var sent: Int { lock.lock(); defer { lock.unlock() }; return _sent }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        active += 1
        _maxActive = max(_maxActive, active)
        _sent += 1
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) {
            self.lock.lock()
            self.active -= 1
            self.lock.unlock()
            completion(ok(encodeServerToAgent(heartbeatIntervalSeconds: 300)))
        }
    }
}

/// Takes every request and never answers.
private final class SilentTransport: HTTPTransport {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}
