import Foundation
import XCTest
@testable import Traceway

final class SessionManagerTests: XCTestCase {
    private let clock = ManualClock(1_000_000)
    private let queue = DispatchQueue(label: "test.sessions")
    private var events: [String] = []

    private func manager(
        _ store: StateStore,
        inactivityMs: Int64 = SessionManager.defaultInactivityMs,
        maxDurationMs: Int64 = SessionManager.defaultMaxDurationMs
    ) -> SessionManager {
        SessionManager(
            store: store,
            queue: queue,
            inactivityMs: inactivityMs,
            maxDurationMs: maxDurationMs,
            now: clock.now,
            onStart: { session, resumed in self.events.append("\(resumed ? "resume" : "start"):\(session.id)") },
            onEnd: { session, endedAt in self.events.append("end:\(session.id)@\(endedAt)") }
        )
    }

    func testWaitsForActivityAfterTimeoutEvenAcrossAnIdleHour() throws {
        let m = manager(StateStore(directory: nil))
        m.start()
        defer { m.stop() }
        let first = try XCTUnwrap(m.currentId)
        clock.advance(60_000)
        m.markActivity()
        let lastActivity = clock.now()
        clock.advance(SessionManager.defaultInactivityMs)
        m.check()
        for _ in 0..<120 {
            clock.advance(30_000)
            m.check()
        }
        XCTAssertNil(m.currentId)
        XCTAssertEqual(events, ["start:\(first)", "end:\(first)@\(lastActivity)"])
        m.markActivity()
        let next = try XCTUnwrap(m.currentId)
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(events, ["start:\(first)", "end:\(first)@\(lastActivity)", "start:\(next)"])
    }

    func testEndsAtTheMaximumDurationEvenWithActivity() throws {
        let m = manager(StateStore(directory: nil))
        m.start()
        defer { m.stop() }
        let first = try XCTUnwrap(m.currentId)
        for _ in 0..<13 {
            clock.advance(5 * 60_000)
            m.markActivity()
        }
        XCTAssertNotEqual(m.currentId, first)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[1], "end:\(first)@\(1_000_000 + SessionManager.defaultMaxDurationMs)")
        XCTAssertEqual(m.current?.startedAtMs, 1_000_000 + SessionManager.defaultMaxDurationMs)
    }

    func testARestartInsideTheInactivityWindowResumesTheSession() throws {
        let store = StateStore(directory: nil)
        let a = manager(store)
        a.start()
        let id = try XCTUnwrap(a.currentId)
        XCTAssertEqual(a.nextSegmentIndex(), 0)
        a.stop()
        XCTAssertNil(a.currentId)
        clock.advance(60_000)
        let b = manager(store)
        b.start()
        XCTAssertEqual(b.currentId, id)
        XCTAssertEqual(b.nextSegmentIndex(), 1)
        XCTAssertEqual(events.last, "resume:\(id)")
        b.stop()
        clock.advance(SessionManager.defaultInactivityMs)
        let c = manager(store)
        c.start()
        XCTAssertNotEqual(c.currentId, id)
        XCTAssertEqual(c.nextSegmentIndex(), 0)
        c.stop()
    }

    func testTheSessionIsResumedFromDiskAfterAProcessRestart() throws {
        let dir = scratchDirectory(self)
        let first = StateStore(directory: dir)
        first.load()
        let a = manager(first)
        a.start()
        let id = try XCTUnwrap(a.currentId)
        _ = a.nextSegmentIndex()
        _ = a.nextSegmentIndex()
        first.flush()
        // The process dies without stop().
        clock.advance(120_000)
        let second = StateStore(directory: dir)
        second.load()
        let b = manager(second)
        b.start()
        defer { b.stop() }
        XCTAssertEqual(b.currentId, id)
        XCTAssertEqual(b.nextSegmentIndex(), 2)
        XCTAssertEqual(b.current?.startedAtMs, 1_000_000)
    }

    func testARestartPastTheMaximumDurationStartsANewSession() throws {
        let store = StateStore(directory: nil)
        let a = manager(store)
        a.start()
        let id = try XCTUnwrap(a.currentId)
        for _ in 0..<11 {
            clock.advance(5 * 60_000)
            a.markActivity()
        }
        XCTAssertEqual(a.currentId, id)
        a.stop()
        // Recently active, but an hour old.
        clock.advance(6 * 60_000)
        let b = manager(store)
        b.start()
        defer { b.stop() }
        XCTAssertNotEqual(b.currentId, id)
        XCTAssertEqual(events.last, "start:\(b.currentId!)")
    }

    func testActivityBeforeStartIsIgnored() {
        let m = manager(StateStore(directory: nil))
        m.markActivity()
        XCTAssertNil(m.currentId)
        m.start()
        XCTAssertNotNil(m.currentId)
        m.start()
        XCTAssertEqual(events.count, 1)
        m.stop()
    }

    func testTheLimitsAreConfigurable() throws {
        let m = manager(StateStore(directory: nil), inactivityMs: 1000, maxDurationMs: 5000)
        m.start()
        defer { m.stop() }
        let first = try XCTUnwrap(m.currentId)
        clock.advance(999)
        m.check()
        XCTAssertEqual(m.currentId, first)
        m.markActivity()
        clock.advance(1000)
        m.check()
        XCTAssertNil(m.currentId)
        XCTAssertEqual(events.last, "end:\(first)@\(1_000_999)")
    }
}
