import Foundation
import XCTest
@testable import Traceway

/// The codec against opamp-go v0.25.0, the protobufs the Traceway backend
/// uses, in both directions. The goldens are opamp-go's bytes for the
/// messages below, made by the Android SDK's `scripts/opamp-golden` (Go):
///
///     cd scripts/opamp-golden && GOFLAGS=-mod=mod go run . golden
///
/// Every AgentToServer here encodes to opamp-go's exact bytes, and every
/// ServerToAgent golden decodes to what the backend meant. To also feed this
/// encoder's output to opamp-go's decoder, run this suite with
/// `TRACEWAY_OPAMP_GOLDEN_OUT=<file>` and then `go run . check <file>` there;
/// it reports `values` (a JSON number cannot hold Int64.max, and 0.0 is the
/// integer 0 in JSON) and `helperError` (written here by `opampErrorAnswer`,
/// under the same name) as the only differences it should find.
enum OpampGoldens {
    static let a2sShared =
        "0a100195f2a000007000800000000000000110031a6f0a1a0a0c736572766963652e6e616d65120a0a0873686f702d776562121a0a0f736572766963652e76657273696f6e12070a05322e332e3112140a0e62726f777365722e6d6f62696c6512021001120b0a0573656174731202180c12120a05726174696f120921000000000000d03f2083603a060a02abcd100162370a19696f2e74726163657761792e73646b2e6275666665722f76310a1a696f2e74726163657761792e73646b2e636170747572652f7631"
    static let a2sFirstPoll =
        "0a100195f2a00000700080000000000000011aae020a1e0a0c736572766963652e6e616d65120e0a0c73686f702d616e64726f69640a3d0a13736572766963652e696e7374616e63652e696412260a2430313935663261302d303030302d373030302d383030302d303030303030303030303031121a0a0f736572766963652e76657273696f6e12070a05342e312e3012140a076f732e6e616d6512090a07416e64726f696412120a0a6f732e76657273696f6e12040a023134121f0a136465766963652e6d616e75666163747572657212080a06476f6f676c65121e0a116465766963652e6d6f64656c2e6e616d6512090a07506978656c203812100a096170702e6275696c641203189c0312340a0a73657373696f6e2e696412260a2430313935663261312d313131312d373232322d383333332d343434343535353536363636208360625d0a19696f2e74726163657761792e73646b2e6275666665722f76310a1a696f2e74726163657761792e73646b2e636170747572652f76310a24696f2e74726163657761792e73646b2e73657175656e63652d74726967676572732f7631"
    static let a2sApplied =
        "0a100195f2a000007000800000000000000110011a200a1e0a0c736572766963652e6e616d65120e0a0c73686f702d616e64726f69642083603a240a20c3f44f966202ed22ad36795acbb7b563354ac8d99eb69913820d2de3db6801fe1001625d0a19696f2e74726163657761792e73646b2e6275666665722f76310a1a696f2e74726163657761792e73646b2e636170747572652f76310a24696f2e74726163657761792e73646b2e73657175656e63652d74726967676572732f7631"
    static let a2sFailed =
        "0a100195f2a000007000800000000000000110021a200a1e0a0c736572766963652e6e616d65120e0a0c73686f702d616e64726f69642083603a250a010910031a1e6261643a20736368656d6156657273696f6e203920e289a0203120e29c97"
    static let a2sValues =
        "0a100195f2a000007000800000000000000110ac021ae4010a220a0c736572766963652e6e616d6512120a10c3bc6ec3af63c3b864c3a920f09f9a80120a0a04666c61671202100012070a016e12021800120e0a0362696712071880808080802012110a036d6178120a18ffffffffffffffff7f12100a036e656712092100000000000014c012110a047a65726f120921000000000000000012110a0468616c66120921000000000000e0bf12120a05666c6f6174120921000000000000f83f12140a046c697374120c2a0a0a030a01610a030a0162120a0a046e6f6e6512022a00120b0a05656d70747912020a00120b12090a076b65796c657373208360"
    static let a2sEmptyDescription = "0a100195f2a000007000800000000000000110051a00208360"
    static let a2sMinimal = "0a100195f2a0000070008000000000000001"
    static let s2aShared =
        "0a100195f2a00000700080000000000000011a570a500a4e0a08747261636577617912420a2e7b22736368656d6156657273696f6e223a312c227265706c6179223a7b226d6f6465223a2273747265616d227d7d12106170706c69636174696f6e2f6a736f6e120301020322080a0109120320ac023001382342120a10ffeeddccbbaa99887766554433221100"
    static let s2aSharedError = "121108021204627573791a070880b09dc2df01"
    static let s2aRemoteConfig =
        "0a100195f2a00000700080000000000000011a740a500a4e0a08747261636577617912420a2e7b22736368656d6156657273696f6e223a312c227265706c6179223a7b226d6f6465223a2273747265616d227d7d12106170706c69636174696f6e2f6a736f6e1220c3f44f966202ed22ad36795acbb7b563354ac8d99eb69913820d2de3db6801fe22270a20983bd614bb5afece5ab3b6023f71147cd7b6bc2314f9d27af7422541c6558389120320ac023823"
    static let s2aHeartbeat =
        "0a100195f2a000007000800000000000000122260a2039fa9ec190eee7b6f4dff1100d6343e10918d044c75eac8f9e9a2596173f80c91202203c3823"
    static let s2aReportFullState = "0a100195f2a000007000800000000000000130013823"
    static let s2aUnavailable =
        "0a100195f2a000007000800000000000000112350802122872656d6f746520636f6e6669672069732074656d706f726172696c7920756e617661696c61626c651a070880b09dc2df013823"
    static let s2aBadRequest =
        "124908011245696e7374616e63655f756964206d75737420626520313620627974657320616e64206d6174636820746865204f70414d502d496e7374616e63652d55494420686561646572"
    static let s2aNewInstanceUid =
        "0a100195f2a000007000800000000000000122270a20983bd614bb5afece5ab3b6023f71147cd7b6bc2314f9d27af7422541c6558389120320ac02382342120a10ffeeddccbbaa99887766554433221100"
    static let s2aTwoConfigs =
        "0a100195f2a00000700080000000000000011a530a4c0a150a056f74686572120c120a746578742f706c61696e0a330a08747261636577617912270a137b22736368656d6156657273696f6e223a317d12106170706c69636174696f6e2f6a736f6e12030a0b0c"
    static let s2aIgnoredFields =
        "0a100195f2a00000700080000000000000011a320a2d0a2b0a087472616365776179121f0a027b7d12106170706c69636174696f6e2f6a736f6e1a077072696d61727912010d224a0a01ee122d0a1f68747470733a2f2f656c736577686572652e746573742f76312f6f70616d7012080a060a016b120176202d1a160a1468747470733a2f2f6d6574726963732e746573742a140a0f0a0170120a08011203312e302201011201023003387f4a0052080a06782e792f76315a0f0a06782e792f76311201741a020102"
}

/// A ServerToAgent that carries only an error response, as the fake servers
/// of the client tests answer.
func opampErrorAnswer(type: UInt64, message: String = "", retryAfterMs: UInt64? = nil) -> [UInt8] {
    let w = ProtoWriter()
    w.message(2) { error in
        error.uint(1, type)
        error.string(2, message)
        if let retryAfterMs = retryAfterMs {
            error.message(3) { retry in retry.uint(1, retryAfterMs * 1_000_000) }
        }
    }
    return w.buffer
}

private func hex(_ bytes: [UInt8]) -> String { Ids.hex(bytes) }
private func hex(_ data: Data) -> String { Ids.hex(Array(data)) }
private func fromHex(_ text: String) -> [UInt8] { Ids.bytes(hex: text)! }

private let testUid = fromHex("0195f2a0000070008000000000000001")
private let newUid = fromHex("ffeeddccbbaa99887766554433221100")
private let settingsDocument = #"{"schemaVersion":1,"replay":{"mode":"stream"}}"#
/// SHA-256 of `settingsDocument`, the hash the backend sends with it.
private let settingsHash = fromHex("c3f44f966202ed22ad36795acbb7b563354ac8d99eb69913820d2de3db6801fe")
private let capabilities = AgentCapabilities.reportsStatus | AgentCapabilities.acceptsRemoteConfig
    | AgentCapabilities.reportsRemoteConfig | AgentCapabilities.reportsHeartbeat
private let customCapabilities = [
    "io.traceway.sdk.buffer/v1",
    "io.traceway.sdk.capture/v1",
    "io.traceway.sdk.sequence-triggers/v1",
]

/// The `values` golden without the description attributes named `keys`,
/// framed again: what opamp-go writes for the same message without them.
private func withoutAttributes(_ keys: Set<String>, in text: String) throws -> String {
    var top: [(field: Int, wireType: Int, varint: UInt64, bytes: [UInt8])] = []
    try eachProtoField(fromHex(text)) { field, wireType, reader in
        if wireType == ProtoWireType.varint {
            top.append((field, wireType, try reader.varint(), []))
        } else {
            top.append((field, wireType, 0, try reader.bytes()))
        }
        return true
    }
    let w = ProtoWriter()
    for entry in top {
        if entry.wireType == ProtoWireType.varint {
            w.uint(entry.field, entry.varint, always: true)
            continue
        }
        var body = entry.bytes
        if entry.field == 3 {
            let description = ProtoWriter()
            try eachProtoField(entry.bytes) { field, _, reader in
                let keyValue = try reader.bytes()
                var key = ""
                try eachProtoField(keyValue) { f, _, r in
                    guard f == 1 else { return false }
                    key = try r.string()
                    return true
                }
                if !keys.contains(key) { description.bytes(field, keyValue) }
                return true
            }
            body = description.buffer
        }
        w.bytes(entry.field, body)
    }
    return hex(w.buffer)
}

final class OpampInteropTests: XCTestCase {
    /// The same messages, by the same names, as agentToServer() in main.go.
    private func agentToServer() -> [(name: String, message: AgentToServer, golden: String)] {
        [
            ("shared", AgentToServer(
                instanceUid: testUid,
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
                capabilities: capabilities,
                remoteConfigStatus: RemoteConfigStatus(
                    lastRemoteConfigHash: fromHex("abcd"), status: RemoteConfigStatuses.applied
                ),
                customCapabilities: Array(customCapabilities.prefix(2))
            ), OpampGoldens.a2sShared),
            ("firstPoll", AgentToServer(
                instanceUid: testUid,
                sequenceNum: 0,
                agentDescription: AgentDescription(
                    identifying: [
                        "service.name": "shop-android",
                        "service.instance.id": .string(Ids.uuidString(testUid)),
                    ],
                    nonIdentifying: [
                        "service.version": "4.1.0",
                        "os.name": "Android",
                        "os.version": "14",
                        "device.manufacturer": "Google",
                        "device.model.name": "Pixel 8",
                        "app.build": 412,
                        "session.id": "0195f2a1-1111-7222-8333-444455556666",
                    ]
                ),
                capabilities: capabilities,
                customCapabilities: customCapabilities
            ), OpampGoldens.a2sFirstPoll),
            ("applied", AgentToServer(
                instanceUid: testUid,
                sequenceNum: 1,
                agentDescription: AgentDescription(identifying: ["service.name": "shop-android"], nonIdentifying: [:]),
                capabilities: capabilities,
                remoteConfigStatus: RemoteConfigStatus(
                    lastRemoteConfigHash: settingsHash, status: RemoteConfigStatuses.applied
                ),
                customCapabilities: customCapabilities
            ), OpampGoldens.a2sApplied),
            ("failed", AgentToServer(
                instanceUid: testUid,
                sequenceNum: 2,
                agentDescription: AgentDescription(identifying: ["service.name": "shop-android"], nonIdentifying: [:]),
                capabilities: capabilities,
                remoteConfigStatus: RemoteConfigStatus(
                    lastRemoteConfigHash: fromHex("09"),
                    status: RemoteConfigStatuses.failed,
                    errorMessage: "bad: schemaVersion 9 ≠ 1 ✗"
                )
            ), OpampGoldens.a2sFailed),
            ("emptyDescription", AgentToServer(
                instanceUid: testUid,
                sequenceNum: 5,
                agentDescription: AgentDescription(identifying: [:], nonIdentifying: [:]),
                capabilities: capabilities
            ), OpampGoldens.a2sEmptyDescription),
            ("minimal", AgentToServer(instanceUid: testUid, sequenceNum: 0, capabilities: 0), OpampGoldens.a2sMinimal),
        ]
    }

    /// main.go's `values` message, but for `max` (Int64.max) and `zero`
    /// (the double 0.0), which a JSON number cannot tell from a double and
    /// from the integer 0.
    private func values() -> AgentToServer {
        AgentToServer(
            instanceUid: testUid,
            sequenceNum: 300,
            agentDescription: AgentDescription(
                identifying: ["service.name": "ünïcødé 🚀"],
                nonIdentifying: [
                    "flag": false,
                    "n": 0,
                    "big": .number(Double(1 << 40)),
                    "neg": -5,
                    "half": -0.5,
                    "float": 1.5,
                    "list": ["a", "b"],
                    "none": .array([]),
                    "empty": "",
                    "": "keyless",
                ]
            ),
            capabilities: capabilities
        )
    }

    /// What helperServerToAgent() in main.go expects `helperAll` to decode to.
    private func helperAll() -> [UInt8] {
        encodeServerToAgent(
            instanceUid: testUid,
            remoteConfig: RemoteConfig(
                configMap: ["traceway": AgentConfigObject(
                    body: Array(#"{"schemaVersion":1}"#.utf8), contentType: "application/json"
                )],
                configHash: fromHex("0a0b")
            ),
            heartbeatIntervalSeconds: 120,
            flags: serverFlagReportFullState,
            capabilities: 0x23,
            newInstanceUid: newUid
        )
    }

    func testEncodesEveryAgentToServerExactlyAsOpampGo() throws {
        for (name, message, golden) in agentToServer() {
            XCTAssertEqual(hex(encodeAgentToServer(message)), golden, name)
        }
        XCTAssertEqual(
            hex(encodeAgentToServer(values())),
            try withoutAttributes(["max", "zero"], in: OpampGoldens.a2sValues),
            "values"
        )
    }

    func testTheTestServersAnswersAreOpampGos() {
        XCTAssertEqual(
            hex(opampErrorAnswer(type: ServerErrorTypes.unavailable, message: "busy", retryAfterMs: 60_000)),
            OpampGoldens.s2aSharedError
        )
        XCTAssertEqual(
            hex(encodeServerToAgent(instanceUid: testUid, flags: serverFlagReportFullState, capabilities: 0x23)),
            OpampGoldens.s2aReportFullState
        )
    }

    func testWritesTheEncodersOutputForTheGoCheck() throws {
        guard let path = ProcessInfo.processInfo.environment["TRACEWAY_OPAMP_GOLDEN_OUT"] else { return }
        var lines = agentToServer().map { "a2s \($0.name) \(hex(encodeAgentToServer($0.message)))" }
        lines.append("a2s values \(hex(encodeAgentToServer(values())))")
        lines.append("s2a helperAll \(hex(helperAll()))")
        lines.append("s2a helperError \(hex(opampErrorAnswer(type: ServerErrorTypes.unavailable, message: "busy", retryAfterMs: 60_000)))")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testDecodesTheBackendsConfigAnswer() throws {
        let msg = try decodeServerToAgent(fromHex(OpampGoldens.s2aRemoteConfig))
        XCTAssertEqual(msg.instanceUid, testUid)
        XCTAssertEqual(msg.capabilities, 0x23)
        XCTAssertEqual(msg.flags, 0)
        XCTAssertEqual(msg.heartbeatIntervalSeconds, 300)
        XCTAssertNil(msg.errorResponse)
        XCTAssertNil(msg.newInstanceUid)
        let config = try XCTUnwrap(msg.remoteConfig)
        XCTAssertEqual(config.configHash, settingsHash)
        XCTAssertEqual(Array(config.configMap.keys), ["traceway"])
        XCTAssertEqual(String(decoding: config.configMap["traceway"]!.body, as: UTF8.self), settingsDocument)
        XCTAssertEqual(config.configMap["traceway"]?.contentType, "application/json")
    }

    func testDecodesAHeartbeatOnlyAnswer() throws {
        let msg = try decodeServerToAgent(fromHex(OpampGoldens.s2aHeartbeat))
        XCTAssertEqual(msg.heartbeatIntervalSeconds, 60)
        XCTAssertNil(msg.remoteConfig)
        XCTAssertEqual(msg.flags, 0)
    }

    func testDecodesReportFullState() throws {
        let msg = try decodeServerToAgent(fromHex(OpampGoldens.s2aReportFullState))
        XCTAssertEqual(msg.flags, serverFlagReportFullState)
        XCTAssertNil(msg.heartbeatIntervalSeconds)
        XCTAssertNil(msg.remoteConfig)
    }

    func testDecodesTheErrorResponses() throws {
        let unavailable = try decodeServerToAgent(fromHex(OpampGoldens.s2aUnavailable))
        XCTAssertEqual(unavailable.capabilities, 0x23)
        XCTAssertEqual(unavailable.errorResponse?.type, ServerErrorTypes.unavailable)
        XCTAssertEqual(unavailable.errorResponse?.message, "remote config is temporarily unavailable")
        XCTAssertEqual(unavailable.errorResponse?.retryAfterMs, 60_000)

        let bad = try decodeServerToAgent(fromHex(OpampGoldens.s2aBadRequest))
        XCTAssertNil(bad.instanceUid)
        XCTAssertEqual(bad.errorResponse?.type, ServerErrorTypes.badRequest)
        XCTAssertEqual(
            bad.errorResponse?.message,
            "instance_uid must be 16 bytes and match the OpAMP-Instance-UID header"
        )
        XCTAssertNil(bad.errorResponse?.retryAfterMs)
    }

    func testDecodesANewInstanceUid() throws {
        let msg = try decodeServerToAgent(fromHex(OpampGoldens.s2aNewInstanceUid))
        XCTAssertEqual(msg.newInstanceUid, newUid)
        XCTAssertEqual(msg.instanceUid, testUid)
        XCTAssertEqual(msg.heartbeatIntervalSeconds, 300)
    }

    func testDecodesEveryEntryOfTheConfigMap() throws {
        let config = try XCTUnwrap(try decodeServerToAgent(fromHex(OpampGoldens.s2aTwoConfigs)).remoteConfig)
        XCTAssertEqual(config.configMap.keys.sorted(), ["other", "traceway"])
        XCTAssertEqual(config.configMap["other"]?.body, [])
        XCTAssertEqual(config.configMap["other"]?.contentType, "text/plain")
        XCTAssertEqual(
            String(decoding: config.configMap["traceway"]!.body, as: UTF8.self),
            #"{"schemaVersion":1}"#
        )
        XCTAssertEqual(hex(config.configHash), "0a0b0c")
    }

    func testReadsWhatItNeedsFromAnAnswerFullOfFieldsItIgnores() throws {
        let msg = try decodeServerToAgent(fromHex(OpampGoldens.s2aIgnoredFields))
        XCTAssertEqual(msg.heartbeatIntervalSeconds, 45)
        XCTAssertEqual(msg.flags, 3)
        XCTAssertEqual(msg.capabilities, 0x7f)
        XCTAssertNil(msg.errorResponse)
        XCTAssertNil(msg.newInstanceUid)
        let config = try XCTUnwrap(msg.remoteConfig)
        XCTAssertEqual(hex(config.configHash), "0d")
        XCTAssertEqual(String(decoding: config.configMap["traceway"]!.body, as: UTF8.self), "{}")
        XCTAssertEqual(config.configMap["traceway"]?.contentType, "application/json")
    }

    func testAPollCycleAgainstTheBackendsAnswersSendsOpampGosBytes() {
        let queue = DispatchQueue(label: "opamp-interop")
        let server = GoldenServer { index in
            fromHex(index == 0 ? OpampGoldens.s2aRemoteConfig : OpampGoldens.s2aHeartbeat)
        }
        var applied: String?
        let client = OpampClient(
            endpoint: URL(string: "https://traceway.test/api/otel/v1/opamp")!,
            headers: [:],
            instanceUid: testUid,
            capabilities: capabilities,
            customCapabilities: customCapabilities,
            describe: { AgentDescription(identifying: ["service.name": "shop-android"], nonIdentifying: [:]) },
            onRemoteConfig: { config in
                applied = config.configMap["traceway"].map { String(decoding: $0.body, as: UTF8.self) }
                return .applied
            },
            transport: server,
            queue: queue
        )
        let reported = expectation(description: "the applied config is reported")
        server.onAnswer = { index in if index == 1 { reported.fulfill() } }
        queue.async { client.start() }
        wait(for: [reported], timeout: 5)
        queue.sync { client.stop() }

        XCTAssertEqual(queue.sync { applied }, settingsDocument)
        let bodies = server.bodies
        XCTAssertEqual(bodies.count, 2)
        // The report of the applied config, byte for byte.
        XCTAssertEqual(hex(bodies[1]), OpampGoldens.a2sApplied)
        XCTAssertEqual(queue.sync { client.pollIntervalMs }, 60_000)
        // The first poll: no status yet.
        let first = AgentToServer(
            instanceUid: testUid,
            sequenceNum: 0,
            agentDescription: AgentDescription(identifying: ["service.name": "shop-android"], nonIdentifying: [:]),
            capabilities: capabilities,
            customCapabilities: customCapabilities
        )
        XCTAssertEqual(hex(bodies[0]), hex(encodeAgentToServer(first)))
    }
}

/// Answers the n-th request with `answer(n)`, on another thread.
private final class GoldenServer: HTTPTransport {
    private let lock = NSLock()
    private var recorded: [Data] = []
    private let answer: (Int) -> [UInt8]
    var onAnswer: ((Int) -> Void)?

    init(answer: @escaping (Int) -> [UInt8]) {
        self.answer = answer
    }

    var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        recorded.append(body)
        let index = recorded.count - 1
        lock.unlock()
        let reply = answer(index)
        DispatchQueue.global().async {
            completion(HTTPResult(statusCode: 200, body: Data(reply)))
            self.onAnswer?(index)
        }
    }
}
