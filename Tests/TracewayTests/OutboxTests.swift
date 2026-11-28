import Foundation
import XCTest
@testable import Traceway

final class OutboxTests: XCTestCase {
    private let logsURL = URL(string: "https://traceway.test/api/otel/v1/logs")!
    private let tracesURL = URL(string: "https://traceway.test/api/otel/v1/traces")!

    private func destinations(_ token: String = "test-token") -> [String: OtlpDestination] {
        [
            "logs": OtlpDestination(url: logsURL, headers: ["Authorization": "Bearer \(token)"]),
            "traces": OtlpDestination(url: tracesURL, headers: ["Authorization": "Bearer \(token)"]),
        ]
    }

    private func outbox(_ dir: URL?, _ http: FakeHTTP, token: String = "test-token", claim: Bool = true) -> Outbox {
        let outbox = Outbox(directory: dir, destinations: destinations(token), transport: http)
        if claim { outbox.claim() }
        addTeardownBlock { outbox.dispose() }
        return outbox
    }

    private func queued(_ dir: URL) -> [String] { fileNames(dir).filter { $0.hasSuffix(".pb") } }

    private func drained(_ outbox: Outbox, within timeout: TimeInterval = 5) -> Bool {
        completes(within: timeout) { done in outbox.drain(completion: done) }
    }

    private func bodies(_ requests: [FakeHTTP.Seen]) -> [String] {
        requests.map { String(decoding: $0.plain, as: UTF8.self) }
    }

    func testABatchIsOnDiskBeforeAddReturnsAndIsSentOnce() throws {
        let dir = scratchDirectory(self)
        let http = FakeHTTP()
        let outbox = outbox(dir, http)
        XCTAssertTrue(outbox.add(kind: "logs", body: Data("last error".utf8), gzipped: false))
        let saved = queued(dir)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasPrefix(outbox.destinationKey + "-"), saved[0])
        XCTAssertTrue(saved[0].hasSuffix("-0.logs.pb"), saved[0])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(saved[0])), Data("last error".utf8))
        XCTAssertTrue(http.requests.isEmpty)

        XCTAssertTrue(drained(outbox))
        XCTAssertTrue(drained(outbox))
        XCTAssertEqual(http.requests.count, 1)
        let sent = http.requests[0]
        XCTAssertEqual(sent.url, logsURL)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(sent.headers["Content-Type"], "application/x-protobuf")
        XCTAssertNil(sent.headers["Content-Encoding"])
        XCTAssertEqual(bodies(http.requests), ["last error"])
        XCTAssertTrue(queued(dir).isEmpty)
        XCTAssertEqual(outbox.pendingCount, 0)
    }

    func testAddSchedulesADrain() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP()
        let outbox = outbox(dir, http)
        outbox.add(kind: "traces", body: Data("GET /x".utf8), gzipped: false)
        // Not at once: the first drain waits 5 s.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(eventually(timeout: 8) { http.requests.count == 1 })
        XCTAssertEqual(http.requests.first?.url, tracesURL)
        XCTAssertTrue(eventually { outbox.pendingCount == 0 })
    }

    func testATransientFailureKeepsTheBatchAndStopsTheDrain() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP { _ in HTTPResult(statusCode: 503) }
        let outbox = outbox(dir, http)
        outbox.add(kind: "logs", body: Data("one".utf8), gzipped: false)
        outbox.add(kind: "logs", body: Data("two".utf8), gzipped: false)
        XCTAssertTrue(drained(outbox))
        // Stops at the first failure: the server is not reachable.
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(outbox.pendingCount, 2)
        // It backs off instead of trying again at once.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(http.requests.count, 1)
        http.handler = { _ in HTTPResult(statusCode: 200) }
        XCTAssertTrue(drained(outbox))
        XCTAssertEqual(bodies(Array(http.requests.dropFirst())), ["one", "two"])
        XCTAssertEqual(outbox.pendingCount, 0)
    }

    func testARejectedBatchIsDeleted() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP { _ in HTTPResult(statusCode: 400) }
        let outbox = outbox(dir, http)
        outbox.add(kind: "logs", body: Data([1, 2, 3]), gzipped: false)
        XCTAssertTrue(drained(outbox))
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(outbox.pendingCount, 0)
    }

    func testClaimRemovesHalfWrittenAndForeignBatches() throws {
        let dir = scratchDirectory(self)
        let outbox = outbox(dir, FakeHTTP(), claim: false)
        let key = outbox.destinationKey
        let partial = dir.appendingPathComponent("\(key)-1-0.logs.pb.tmp")
        let unmarked = dir.appendingPathComponent("1-0.logs.pb")
        let own = dir.appendingPathComponent("\(key)-00000000000000000001-0.logs.pb")
        let other = dir.appendingPathComponent("notes.txt")
        for file in [partial, unmarked, own, other] { try Data([1]).write(to: file) }
        outbox.claim()
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
        XCTAssertFalse(fm.fileExists(atPath: unmarked.path))
        XCTAssertTrue(fm.fileExists(atPath: own.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("destination"), encoding: .utf8), key)
        XCTAssertEqual(outbox.pendingCount, 1)
    }

    func testAQueueForAnotherProjectsTokenIsDroppedNotSent() {
        let dir = scratchDirectory(self)
        let other = outbox(dir, FakeHTTP(), token: "other-token")
        other.add(kind: "logs", body: Data("other project".utf8), gzipped: false)
        other.dispose()
        XCTAssertEqual(queued(dir).count, 1)

        let http = FakeHTTP()
        let outbox = outbox(dir, http)
        XCTAssertNotEqual(outbox.destinationKey, other.destinationKey)
        XCTAssertTrue(drained(outbox))
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(queued(dir).isEmpty)
    }

    func testOldAndExcessBatchesArePruned() throws {
        let dir = scratchDirectory(self)
        // Unreachable, so the drain an add schedules keeps what it finds.
        let outbox = outbox(dir, FakeHTTP { _ in .noAnswer })
        outbox.add(kind: "logs", body: Data([1]), gzipped: false)
        let old = dir.appendingPathComponent(queued(dir)[0])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Outbox.maxAge - 60)], ofItemAtPath: old.path
        )
        outbox.add(kind: "logs", body: Data([2]), gzipped: false)
        XCTAssertEqual(outbox.pendingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        // A full queue, written as an earlier run left it (older names first).
        for i in 0..<Outbox.maxBatches {
            let name = "\(outbox.destinationKey)-\(String(format: "%020ld", i + 1))-0.logs.pb"
            try Data([3]).write(to: dir.appendingPathComponent(name))
        }
        for _ in 0..<5 { outbox.add(kind: "logs", body: Data([4]), gzipped: false) }
        XCTAssertEqual(outbox.pendingCount, Outbox.maxBatches)
        // The oldest went; the newest five are kept.
        let names = queued(dir)
        XCTAssertFalse(names.contains { $0.contains(String(format: "-%020ld-", 1)) })
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(names.last!)), Data([4]))
        XCTAssertFalse(outbox.add(kind: "logs", body: Data(count: Outbox.maxBatchBytes + 1), gzipped: false))
        XCTAssertFalse(outbox.add(kind: "profiles", body: Data([1]), gzipped: false))
        XCTAssertFalse(outbox.add(kind: "logs", body: Data(), gzipped: false))
        XCTAssertEqual(outbox.pendingCount, Outbox.maxBatches)
    }

    func testBatchesAreSentOldestFirst() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP()
        let outbox = outbox(dir, http)
        for i in 0..<12 { outbox.add(kind: "logs", body: Data("n\(i)".utf8), gzipped: false) }
        XCTAssertTrue(drained(outbox))
        XCTAssertEqual(bodies(http.requests), (0..<12).map { "n\($0)" })
    }

    func testWithoutADirectoryOrClaimNothingIsKept() {
        let noDir = outbox(nil, FakeHTTP())
        XCTAssertFalse(noDir.add(kind: "logs", body: Data([1]), gzipped: false))
        XCTAssertEqual(noDir.pendingCount, 0)
        let unclaimed = outbox(scratchDirectory(self), FakeHTTP(), claim: false)
        XCTAssertFalse(unclaimed.add(kind: "logs", body: Data([1]), gzipped: false))
        XCTAssertTrue(drained(noDir, within: 1))
        XCTAssertTrue(drained(unclaimed, within: 1))
    }

    func testDisposeStopsSendingAndKeepsTheBatches() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP()
        let outbox = outbox(dir, http)
        outbox.add(kind: "logs", body: Data([1]), gzipped: false)
        outbox.dispose()
        XCTAssertTrue(drained(outbox))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(outbox.add(kind: "logs", body: Data([1]), gzipped: false))
        XCTAssertEqual(queued(dir).count, 1)
    }

    func testADrainEndsOnlyOnceTheServerAnswered() {
        let dir = scratchDirectory(self)
        let release = DispatchSemaphore(value: 0)
        let http = FakeHTTP { _ in
            _ = release.wait(timeout: .now() + 5)
            return HTTPResult(statusCode: 200)
        }
        let outbox = outbox(dir, http)
        outbox.add(kind: "logs", body: Data([1]), gzipped: false)
        let done = DispatchSemaphore(value: 0)
        outbox.drain { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outbox.pendingCount, 0)
    }

    func testGzippedBatchesKeepTheirEncodingAndEachKindItsDestination() {
        let dir = scratchDirectory(self)
        let http = FakeHTTP()
        let outbox = outbox(dir, http)
        outbox.add(kind: "traces", body: Data([0x1f, 0x8b, 9]), gzipped: true)
        outbox.add(kind: "logs", body: Data([7]), gzipped: false)
        XCTAssertTrue(queued(dir)[0].hasSuffix(".traces.gz.pb"), queued(dir)[0])
        XCTAssertTrue(drained(outbox))
        XCTAssertEqual(http.requests.map(\.url), [tracesURL, logsURL])
        XCTAssertEqual(http.requests.map { $0.headers["Content-Encoding"] }, ["gzip", nil])
        XCTAssertEqual(http.requests.map(\.body), [Data([0x1f, 0x8b, 9]), Data([7])])
    }

    func testTheDestinationKeyNamesTheCredentialsWithoutHoldingThem() {
        let a = Outbox(directory: nil, destinations: destinations("one"), transport: FakeHTTP())
        let b = Outbox(directory: nil, destinations: destinations("one"), transport: FakeHTTP())
        let c = Outbox(directory: nil, destinations: destinations("two"), transport: FakeHTTP())
        XCTAssertEqual(a.destinationKey, b.destinationKey)
        XCTAssertNotEqual(a.destinationKey, c.destinationKey)
        XCTAssertEqual(a.destinationKey.count, 16)
        XCTAssertFalse(a.destinationKey.contains("one"))
    }
}

#if !os(iOS)
// Writing log records takes OpenTelemetry types, which the iOS Simulator
// bundle cannot link (see OtlpTestSupport.swift).
extension OutboxTests {
    func testACapturedExceptionIsDurableBeforePersistReturnsAndIsSentOnce() throws {
        let dir = scratchDirectory(self)
        let http = FakeHTTP()
        let outbox = Outbox(directory: dir, destinations: destinations(), transport: http)
        outbox.claim()
        defer { outbox.dispose() }
        XCTAssertTrue(outbox.persist(logs: [logRecord("last error", event: Events.exception)]))
        XCTAssertFalse(outbox.persist(logs: []))
        let saved = queued(dir)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasPrefix(outbox.destinationKey + "-"))
        XCTAssertTrue(saved[0].hasSuffix(".logs.pb") || saved[0].hasSuffix(".logs.gz.pb"), saved[0])
        XCTAssertEqual(Otlp.logs(outboxBody(dir.appendingPathComponent(saved[0]))).map(\.eventName), [Events.exception])
        XCTAssertTrue(http.requests.isEmpty)

        XCTAssertTrue(drained(outbox))
        XCTAssertTrue(drained(outbox))
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].url, logsURL)
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer test-token")
        XCTAssertEqual(Otlp.logs(http.requests[0].plain).map(\.body), ["last error"])
        XCTAssertTrue(queued(dir).isEmpty)
    }
}
#endif
