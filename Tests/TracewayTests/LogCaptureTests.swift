import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import Traceway

/// Stands in for the unified log: the lines a test adds.
final class FakeOSLogSource: OSLogEntrySource {
    private let lock = NSLock()
    private var lines: [CapturedLogLine] = []
    private var failures = 0
    private(set) var reads = 0

    func add(_ message: String, at date: Date, level: TracewayLogLevel = .info, subsystem: String = "",
             category: String = "") {
        lock.lock()
        lines.append(CapturedLogLine(date: date, level: level, message: message, subsystem: subsystem, category: category))
        lock.unlock()
    }

    func failNext(_ count: Int = 1) {
        lock.lock()
        failures = count
        lock.unlock()
    }

    func entries(since: Date) throws -> [CapturedLogLine] {
        struct Unreadable: Error {}
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        if failures > 0 {
            failures -= 1
            throw Unreadable()
        }
        return lines.filter { $0.date >= since }.sorted { $0.date < $1.date }
    }
}

/// Writes all of `text` to `fd`.
func writeAll(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
        }
        if written <= 0 { return }
        offset += written
    }
}

/// CONTRACT §14.3: the unified-log reader and the standard output tee.
final class LogCaptureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheReaderReturnsEachLineOnce() {
        let source = FakeOSLogSource()
        source.add("before the start", at: t0.addingTimeInterval(-1))
        source.add("one", at: t0.addingTimeInterval(1))
        source.add("two", at: t0.addingTimeInterval(2))
        source.add("two too", at: t0.addingTimeInterval(2))
        let reader = OSLogReader(source: source, since: t0)
        XCTAssertEqual(reader.read().map { $0.message }, ["one", "two", "two too"])
        XCTAssertEqual(reader.read(), [], "nothing new")
        // A line logged in the same instant as the last one read is new too.
        source.add("two as well", at: t0.addingTimeInterval(2))
        source.add("three", at: t0.addingTimeInterval(3), level: .error)
        let next = reader.read()
        XCTAssertEqual(next.map { $0.message }, ["two as well", "three"])
        XCTAssertEqual(next.last?.level, .error)
    }

    func testTheSDKsOwnLinesAndTheSystemsAreLeftOut() {
        let source = FakeOSLogSource()
        source.add("[Traceway] started, instance 1", at: t0)
        source.add("2026-11-27 10:00:00.1+0000 Shop[1:2] [Traceway] WARN x", at: t0)
        source.add("Task <1> finished", at: t0, subsystem: "com.apple.CFNetwork")
        source.add("", at: t0)
        source.add("checkout started", at: t0, subsystem: "com.example.shop", category: "checkout")
        let lines = OSLogReader(source: source, since: t0).read()
        XCTAssertEqual(lines.map { $0.message }, ["checkout started"])
        XCTAssertEqual(lines.first?.subsystem, "com.example.shop")
        XCTAssertEqual(lines.first?.category, "checkout")
    }

    func testAReadKeepsTheNewestLinesAndCutsLongOnes() {
        let source = FakeOSLogSource()
        for i in 0..<1500 { source.add("line \(i)", at: t0.addingTimeInterval(Double(i) / 1000)) }
        source.add(String(repeating: "é", count: 20_000), at: t0.addingTimeInterval(2))
        let lines = OSLogReader(source: source, since: t0).read()
        XCTAssertEqual(lines.count, OSLogReader.maxLinesPerRead)
        XCTAssertEqual(lines.first?.message, "line 501", "the newest are kept")
        let long = lines.last?.message ?? ""
        XCTAssertLessThanOrEqual(long.utf8.count, OSLogReader.maxMessageBytes)
        XCTAssertGreaterThan(long.utf8.count, OSLogReader.maxMessageBytes - 2)
        XCTAssertTrue(long.allSatisfy { $0 == "é" }, "cut at a character")
    }

    func testASourceThatFailsGivesNothingAndTheNextReadCatchesUp() {
        let source = FakeOSLogSource()
        source.add("kept", at: t0.addingTimeInterval(1))
        source.failNext()
        let reader = OSLogReader(source: source, since: t0)
        XCTAssertEqual(reader.read(), [])
        XCTAssertEqual(reader.read().map { $0.message }, ["kept"])
    }

    func testUnifiedLogLevelsBecomeLogLevels() {
        XCTAssertEqual((0...5).map { OSLogReader.level(osLogLevel: $0) }, [.info, .debug, .info, .info, .error, .fatal])
        XCTAssertEqual(OSLogReader.level(osLogLevel: 99), .info)
        XCTAssertTrue(TracewayClient.isNSLogLine("2024-05-01 10:00:00.123456+0200 Shop[1234:56789a] saved"))
        XCTAssertFalse(TracewayClient.isNSLogLine("saved 2024-05-01"))
    }

    // MARK: - The standard output tee

    private func openFile() throws -> (path: String, fd: Int32) {
        let path = temporaryDirectory().appendingPathComponent("out.txt").path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        return (path, fd)
    }

    func testATeeWritesEveryByteToTheOriginalAndCutsLines() throws {
        let (path, fd) = try openFile()
        let lines = Locked<[String]>([])
        let tee = try XCTUnwrap(StreamTee(fd: fd, name: "stdout", onLines: { new in lines.withValue { $0 += new } }))
        let text = "first\nsecond\r\n\nthird"
        writeAll(fd, text)
        writeAll(fd, "\n")
        XCTAssertTrue(eventually { lines.value == ["first", "second", "third"] }, "\(lines.value)")
        tee.stop()
        close(fd)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text + "\n", "every byte, unchanged")
    }

    func testASlowSinkNeverHoldsTheWriterUp() throws {
        let (path, fd) = try openFile()
        let received = Locked(0)
        let tee = try XCTUnwrap(StreamTee(fd: fd, name: "stderr", onLines: { new in
            Thread.sleep(forTimeInterval: 0.3)
            received.withValue { $0 += new.count }
        }))
        let line = String(repeating: "x", count: 99) + "\n"
        let started = Date()
        for _ in 0..<20_000 { writeAll(fd, line) }
        // Were the lines handed over on the reader's thread, the pipe would
        // fill at every pause of the sink and the writer wait for it.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        tee.stop()
        close(fd)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 2_000_000, "the original got everything")
        XCTAssertTrue(eventually(timeout: 10) { received.value > 0 })
        XCTAssertLessThanOrEqual(received.value, 20_000)
    }

    func testALineLongerThanTheLimitIsCut() throws {
        let (_, fd) = try openFile()
        let lines = Locked<[String]>([])
        let tee = try XCTUnwrap(StreamTee(fd: fd, name: "stdout", onLines: { new in lines.withValue { $0 += new } }))
        writeAll(fd, String(repeating: "y", count: 100_000) + "\nshort\n")
        XCTAssertTrue(eventually { lines.value.count == 2 })
        XCTAssertEqual(lines.value.first?.utf8.count, StreamTee.maxLineBytes)
        XCTAssertEqual(lines.value.last, "short")
        // Without a handler the bytes still go through.
        tee.setHandler(nil)
        writeAll(fd, "dropped\n")
        tee.stop()
        close(fd)
        XCTAssertEqual(lines.value.count, 2)
    }
}
