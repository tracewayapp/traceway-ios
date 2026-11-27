// The ring buffer on disk. Not in the iOS Simulator bundle (OpenTelemetry
// types, see OtlpTestSupport.swift).
#if !os(iOS)
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import XCTest
@testable import Traceway

final class BufferPersistenceTests: XCTestCase {
    private func log(
        _ body: String,
        _ timeMs: Int64,
        signal: String = "console",
        event: String? = nil,
        resource: Resource = testResource
    ) -> BufferEntry<TelemetryItem> {
        BufferEntry(timeMs: timeMs, signal: signal, bytes: 200,
                    item: TelemetryItem(.log(logRecord(body, event: event, atMs: timeMs, resource: resource))))
    }

    private func span(_ name: String, _ timeMs: Int64) -> BufferEntry<TelemetryItem> {
        BufferEntry(timeMs: timeMs, signal: "network", bytes: 200, item: TelemetryItem(.span(endedSpan(name, endMs: timeMs))))
    }

    private func persistence(_ dir: URL?, destination: String = "d1") -> BufferPersistence {
        BufferPersistence(directory: dir, destination: destination)
    }

    private func save(_ dir: URL, _ sessionId: String?, _ entries: [BufferEntry<TelemetryItem>], destination: String = "d1") {
        let p = persistence(dir, destination: destination)
        XCTAssertTrue(completes { done in p.save(sessionId: sessionId, entries: entries, completion: done) })
    }

    private func load(_ dir: URL, _ sessionId: String? = "s1", maxAgeMs: Int64 = 600_000, maxBytes: Int = 2_000_000,
                      destination: String = "d1") -> [BufferEntry<TelemetryItem>] {
        let p = persistence(dir, destination: destination)
        let entries = p.load(sessionId: sessionId, maxAgeMs: maxAgeMs, maxBytes: maxBytes)
        p.waitForWrites()
        return entries
    }

    private func file(_ dir: URL) -> URL { dir.appendingPathComponent("buffer.json") }

    private func bodies(_ entries: [BufferEntry<TelemetryItem>]) -> [String] {
        entries.compactMap { entry in
            if case .log(let record) = entry.item.record, case .string(let body)? = record.body { return body }
            if case .span(let span) = entry.item.record { return span.name }
            return nil
        }
    }

    private func resource(_ entry: BufferEntry<TelemetryItem>) -> Resource {
        switch entry.item.record {
        case .log(let record): return record.resource
        case .span(let span): return span.resource
        }
    }

    func testTheBufferSurvivesARestartWithinTheSession() {
        let dir = scratchDirectory(self)
        let t = Clock.nowMs()
        save(dir, "s1", [log("first", t - 2000), span("GET /a", t - 1000), log("second", t - 500)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(dir).path))

        let restored = load(dir)
        XCTAssertEqual(bodies(restored), ["first", "GET /a", "second"])
        XCTAssertEqual(restored.map(\.signal), ["console", "network", "console"])
        XCTAssertEqual(restored.map(\.timeMs), [t - 2000, t - 1000, t - 500])
        XCTAssertEqual(restored.map(\.bytes), [200, 200, 200])
        XCTAssertEqual(resource(restored[0]).attributes["service.name"], .string("test-app"))
        XCTAssertEqual(resource(restored[1]).attributes["service.name"], .string("test-app"))
        // Loading removes the file: the next save writes what is still held.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))
        XCTAssertTrue(load(dir).isEmpty)
    }

    func testARestoredBufferBelongsToItsSessionAndDestinationOnly() {
        let dir = scratchDirectory(self)
        let t = Clock.nowMs()
        save(dir, "s1", [log("crumb", t)])
        XCTAssertTrue(load(dir, "s2").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))

        save(dir, "s1", [log("crumb", t)])
        XCTAssertTrue(load(dir, "s1", destination: "d2").isEmpty)
        save(dir, "s1", [log("crumb", t)])
        XCTAssertTrue(load(dir, nil).isEmpty)
        save(dir, "s1", [log("crumb", t)])
        XCTAssertEqual(bodies(load(dir, "s1")), ["crumb"])
    }

    func testOldRecordsAndRecordsOverTheSizeAreDroppedNewestKept() {
        let dir = scratchDirectory(self)
        let t = Clock.nowMs()
        let ten = (0..<10).map { log("n\($0)", t - 10_000 + Int64($0) * 1000) }
        save(dir, "s1", ten)
        XCTAssertEqual(bodies(load(dir, maxAgeMs: 5500)), (5..<10).map { "n\($0)" })

        save(dir, "s1", ten)
        XCTAssertEqual(bodies(load(dir, maxBytes: 3 * 200)), ["n7", "n8", "n9"])
    }

    func testRestoredRecordsKeepTheResourceTheyWereRecordedWith() {
        let dir = scratchDirectory(self)
        let t = Clock.nowMs()
        let old = Resource(attributes: ["service.version": .string("0.9")])
        save(dir, "s1", [log("before update", t - 2000, resource: old)])
        let restored = load(dir)
        // The next run saves its own records next to the restored ones.
        save(dir, "s1", restored + [log("after update", t - 1000)])
        let again = load(dir)
        XCTAssertEqual(bodies(again), ["before update", "after update"])
        XCTAssertEqual(resource(again[0]).attributes["service.version"], .string("0.9"))
        XCTAssertEqual(resource(again[1]).attributes["service.version"], .string("1.0"))
        XCTAssertNil(resource(again[0]).attributes["service.name"])
    }

    func testRecordsKeepTheirEventSeverityAndAttributes() {
        let dir = scratchDirectory(self)
        let t = Clock.nowMs()
        let record = logRecord("boom", event: Events.exception, atMs: t, severity: .error,
                             attributes: ["exception.type": .string("E"), "count": .int(3)])
        save(dir, "s1", [
            BufferEntry(timeMs: t, signal: "errors", bytes: 300, item: TelemetryItem(.log(record))),
            BufferEntry(timeMs: t, signal: "network", bytes: 100,
                        item: TelemetryItem(.span(endedSpan("GET /a", endMs: t, attributes: ["http.status_code": .int(500)])))),
        ])
        let restored = load(dir)
        guard restored.count == 2, case .log(let log) = restored[0].item.record,
              case .span(let span) = restored[1].item.record
        else { return XCTFail("restored \(restored.count) entries") }
        XCTAssertEqual(log.eventName, Events.exception)
        XCTAssertEqual(log.severity, .error)
        XCTAssertEqual(log.attributes["exception.type"], .string("E"))
        XCTAssertEqual(log.attributes["count"], .int(3))
        XCTAssertEqual(log.timestamp, record.timestamp)
        XCTAssertEqual(span.name, "GET /a")
        XCTAssertEqual(span.kind, .client)
        XCTAssertEqual(span.attributes["http.status_code"], .int(500))
        XCTAssertEqual(restored.map(\.signal), ["errors", "network"])
    }

    func testLaterSavesWinAndAnEmptyBufferRemovesTheFile() {
        let dir = scratchDirectory(self)
        let t = Clock.nowMs()
        let p = persistence(dir)
        p.save(sessionId: "s1", entries: [log("old", t)])
        p.save(sessionId: "s1", entries: [log("new", t)])
        p.waitForWrites()
        XCTAssertEqual(bodies(load(dir)), ["new"])

        p.save(sessionId: "s1", entries: [log("x", t)])
        p.save(sessionId: "s1", entries: [])
        p.waitForWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))
        p.save(sessionId: "s1", entries: [log("x", t)])
        p.save(sessionId: nil, entries: [log("y", t)])
        p.waitForWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))
    }

    func testACorruptFileOnlyCostsItsRecords() throws {
        let dir = scratchDirectory(self)
        try Data([0x54, 0x57, 0x42, 0x31, 0, 9, 1]).write(to: file(dir))
        XCTAssertTrue(load(dir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))
        // Another version of the format is not read either.
        try Data(#"{"v":2,"sessionId":"s1","d":"d1","resources":[],"entries":[]}"#.utf8).write(to: file(dir))
        XCTAssertTrue(load(dir).isEmpty)
    }

    func testClearRemovesWhatWasSaved() {
        let dir = scratchDirectory(self)
        save(dir, "s1", [log("a", Clock.nowMs())])
        let p = persistence(dir)
        p.clear()
        p.waitForWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(dir).path))
    }

    func testWithoutADirectoryNothingIsKept() {
        let p = persistence(nil)
        XCTAssertTrue(completes { done in p.save(sessionId: "s1", entries: [log("a", Clock.nowMs())], completion: done) })
        XCTAssertTrue(p.load(sessionId: "s1", maxAgeMs: 600_000, maxBytes: 2_000_000).isEmpty)
    }
}
#endif
