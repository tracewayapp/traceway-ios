import XCTest
@testable import Traceway

final class RingBufferTests: XCTestCase {
    func testEvictsBySizeAndByAgeOldestFirst() {
        var now: Int64 = 1000
        let buffer = RingBuffer<String>(maxBytes: 30, maxAgeMs: 1000, now: { now })
        for i in 0..<4 {
            buffer.push(BufferEntry(timeMs: now, signal: "console", bytes: 10, item: "e\(i)"))
        }
        XCTAssertEqual(buffer.snapshot().map(\.item), ["e1", "e2", "e3"])
        XCTAssertEqual(buffer.evictedCount, 1)
        now = 2500
        XCTAssertTrue(buffer.snapshot().isEmpty)
        XCTAssertEqual(buffer.totalBytes, 0)
        XCTAssertEqual(buffer.evictedCount, 4)
    }

    func testTakeRemovesOnlyTheSelectedWindowAndSignals() {
        let buffer = RingBuffer<String>(maxBytes: 1000, maxAgeMs: 100_000, now: { 10000 })
        buffer.push(BufferEntry(timeMs: 1000, signal: "console", bytes: 1, item: "old"))
        buffer.push(BufferEntry(timeMs: 9000, signal: "console", bytes: 1, item: "log"))
        buffer.push(BufferEntry(timeMs: 9500, signal: "network", bytes: 1, item: "net"))
        XCTAssertEqual(buffer.take(sinceMs: 8000, signals: ["console"]).map(\.item), ["log"])
        XCTAssertTrue(buffer.take(sinceMs: 8000, signals: []).isEmpty)
        XCTAssertEqual(buffer.take(sinceMs: 0, signals: nil, untilMs: 5000).map(\.item), ["old"])
        XCTAssertEqual(buffer.totalBytes, 1)
        XCTAssertEqual(buffer.take(sinceMs: 0, signals: nil).map(\.item), ["net"])
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.totalBytes, 0)
    }

    func testConfigureTrimsRetainFiltersAndClearEmpties() {
        let buffer = RingBuffer<Int>(maxBytes: 100, maxAgeMs: 100_000, now: { 0 })
        for i in 0..<5 {
            buffer.push(BufferEntry(timeMs: 0, signal: i % 2 == 0 ? "console" : "network", bytes: 10, item: i))
        }
        buffer.retain { $0.signal == "console" }
        XCTAssertEqual(buffer.snapshot().map(\.item), [0, 2, 4])
        XCTAssertEqual(buffer.totalBytes, 30)
        buffer.configure(maxBytes: 15, maxAgeMs: 100_000)
        XCTAssertEqual(buffer.snapshot().map(\.item), [4])
        XCTAssertEqual(buffer.evictedCount, 2)
        buffer.clear()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.totalBytes, 0)
    }
}
