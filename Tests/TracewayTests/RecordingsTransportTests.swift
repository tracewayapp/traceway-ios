import Foundation
import XCTest
@testable import Traceway

final class RecordingsTransportTests: XCTestCase {
    private let url = URL(string: "https://h/api/recordings")!

    private func segment(_ exceptionId: String? = "e1") -> RecordingSegment {
        RecordingSegment(
            exceptionId: exceptionId,
            events: [["type": 2, "data": "AAAA", "timestamp": 1]],
            startedAtMs: ISO8601.parseMillis("2026-01-01T00:00:00.000Z"),
            endedAtMs: ISO8601.parseMillis("2026-01-01T00:00:10.000Z")
        )
    }

    private func flushed(_ transport: RecordingsTransport) -> Bool {
        completes { done in transport.flush(done) }
    }

    func testPostsGzippedJsonWithTheBearerToken() {
        let http = FakeHTTP()
        let transport = RecordingsTransport(url: url, token: "tok", transport: http)
        transport.send([segment()])
        XCTAssertTrue(flushed(transport))
        XCTAssertEqual(http.requests.count, 1)
        let seen = http.requests[0]
        XCTAssertEqual(seen.url, url)
        XCTAssertEqual(seen.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(seen.headers["Content-Type"], "application/json")
        // zlib ships with the Apple SDKs; elsewhere the body goes plain.
        XCTAssertEqual(seen.headers["Content-Encoding"], Gzip.compress(Data("x".utf8)) == nil ? nil : "gzip")
        let sent = segments(of: seen)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["exceptionId"], "e1")
        XCTAssertEqual(sent.first?["startedAt"], "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(sent.first?["endedAt"], "2026-01-01T00:00:10.000Z")
        XCTAssertNil(sent.first?["sessionId"])
        XCTAssertNil(sent.first?["segmentIndex"])
        XCTAssertEqual(transport.sentSegments, 1)
    }

    func testASessionSegmentCarriesItsSessionIndexAndEvents() {
        let http = FakeHTTP()
        let transport = RecordingsTransport(url: url, token: "tok", transport: http)
        var part = segment(nil)
        part.sessionId = "s1"
        part.segmentIndex = 3
        transport.send([part])
        XCTAssertTrue(flushed(transport))
        let sent = segments(of: http.requests[0])
        XCTAssertEqual(sent.first?["sessionId"], "s1")
        XCTAssertEqual(sent.first?["segmentIndex"], 3)
        XCTAssertNil(sent.first?["exceptionId"])
        XCTAssertEqual(sent.first?["events"], [["type": 2, "data": "AAAA", "timestamp": 1]])
    }

    func testRetriesATransientFailureAndThenDelivers() {
        let http = FakeHTTP.sequence(503, 503)
        let transport = RecordingsTransport(url: url, token: "tok", transport: http, retryDelaysMs: [1, 1, 1])
        transport.send([segment()])
        XCTAssertTrue(eventually { transport.sentSegments == 1 })
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(transport.pending, 0)
        XCTAssertEqual(transport.failedSegments, 0)
    }

    func testHonoursRetryAfter() {
        let lock = NSLock()
        var calls = 0
        let http = FakeHTTP { _ in
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return HTTPResult(statusCode: calls < 2 ? 429 : 200, headers: ["retry-after": "1"])
        }
        let transport = RecordingsTransport(url: url, token: "tok", transport: http, retryDelaysMs: [1, 1, 1])
        let started = Date()
        transport.send([segment()])
        XCTAssertTrue(eventually { transport.pending == 1 && http.requests.count == 1 })
        // A new segment waits for the retry, it does not jump the queue.
        transport.send([segment("e2")])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertTrue(eventually { transport.sentSegments == 2 })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.95)
        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(http.requests.map { segments(of: $0).compactMap { $0["exceptionId"]?.string } }, [["e1"], ["e1"], ["e2"]])
    }

    func testKeepsAtMostMaxQueuedBytesWaitingDroppingTheOldest() {
        let gate = DispatchSemaphore(value: 0)
        let http = FakeHTTP { _ in
            gate.wait()
            return HTTPResult(statusCode: 200)
        }
        let transport = RecordingsTransport(url: url, token: "tok", transport: http, maxQueuedBytes: 10)
        transport.send([segment("first")])
        XCTAssertTrue(eventually { http.requests.count == 1 })
        // Each segment alone is over the limit: only the newest waits.
        for i in 0..<5 { transport.send([segment("e\(i)")]) }
        XCTAssertEqual(transport.pending, 1)
        XCTAssertEqual(transport.failedSegments, 4)
        gate.signal()
        gate.signal()
        XCTAssertTrue(eventually { transport.sentSegments == 2 })
        XCTAssertEqual(http.requests.map { segments(of: $0).compactMap { $0["exceptionId"]?.string } }, [["first"], ["e4"]])
    }

    func testGivesUpAfterTheRetryBudgetAndAtOnceOnAPermanentError() {
        let failing = FakeHTTP { _ in HTTPResult(statusCode: 500) }
        let transport = RecordingsTransport(url: url, token: "tok", transport: failing, retryDelaysMs: [1, 1, 1])
        var failures = 0
        transport.onFailure = { failures += 1 }
        transport.send([segment()])
        XCTAssertTrue(eventually { transport.failedSegments == 1 })
        XCTAssertEqual(failing.requests.count, 4)
        XCTAssertEqual(transport.pending, 0)
        XCTAssertTrue(flushed(transport))
        XCTAssertEqual(failures, 1)

        let rejecting = FakeHTTP { _ in HTTPResult(statusCode: 413) }
        let rejected = RecordingsTransport(url: url, token: "tok", transport: rejecting)
        rejected.send([segment()])
        XCTAssertTrue(flushed(rejected))
        XCTAssertEqual(rejecting.requests.count, 1)
        XCTAssertEqual(rejected.failedSegments, 1)
        XCTAssertEqual(RecordingsTransport.permanentFailures, [400, 401, 403, 404, 413, 422])
    }

    func testDiscardDropsWhatWaits() {
        let http = FakeHTTP { _ in HTTPResult(statusCode: 503) }
        let transport = RecordingsTransport(url: url, token: "tok", transport: http, retryDelaysMs: [300, 300, 300])
        transport.send([segment()])
        XCTAssertTrue(eventually { http.requests.count == 1 && transport.pending == 1 })
        transport.discard()
        XCTAssertEqual(transport.pending, 0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(transport.failedSegments, 0)
    }

    func testFlushReturnsWhileABatchWaitsToBeRetried() {
        let http = FakeHTTP { _ in HTTPResult(statusCode: 0) }
        let transport = RecordingsTransport(url: url, token: "tok", transport: http)
        transport.send([segment()])
        XCTAssertTrue(completes(within: 2) { done in transport.flush(done) })
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(transport.pending, 1)
        transport.discard()
    }

    func testWithoutAnEndpointNothingIsQueued() {
        let http = FakeHTTP()
        let transport = RecordingsTransport(url: nil, token: "tok", transport: http)
        transport.send([segment()])
        transport.send([])
        XCTAssertEqual(transport.pending, 0)
        XCTAssertTrue(flushed(transport))
        XCTAssertTrue(http.requests.isEmpty)
    }
}
