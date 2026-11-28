import Foundation
import XCTest
@testable import Traceway

final class CollectionBudgetTests: XCTestCase {
    func testTheDefaultsAreTheBrowserSDKs() {
        let budget = CollectionBudget()
        XCTAssertEqual(budget.maxBytes, 50 * 1024 * 1024)
        XCTAssertEqual(budget.maxEvents, 10_000)
        XCTAssertEqual(budget.maxImageBytes, 4 * 1024 * 1024)
        XCTAssertEqual(budget.snapshot("s1"), [
            "traceway.collection.bytes": 0,
            "traceway.collection.events": 0,
            "traceway.collection.dropped": 0,
            "traceway.collection.max_bytes": 50 * 1024 * 1024,
            "traceway.collection.max_events": 10_000,
            "traceway.replay.image_bytes": 0,
        ])
    }

    func testEventsAreCountedNotSegments() {
        let budget = CollectionBudget(maxEvents: 10)
        XCTAssertTrue(budget.admit("s1", bytes: 1, events: 6))
        XCTAssertFalse(budget.admit("s1", bytes: 1, events: 5))
        XCTAssertTrue(budget.admit("s1", bytes: 1, events: 4))
        XCTAssertFalse(budget.admit("s1", bytes: 1, events: 1))
        let snapshot = budget.snapshot("s1")
        XCTAssertEqual(snapshot["traceway.collection.events"], 10)
        XCTAssertEqual(snapshot["traceway.collection.bytes"], 2)
        XCTAssertEqual(snapshot["traceway.collection.dropped"], 6)
    }

    func testTheBudgetKeepsCountingAcrossARestartOfTheSession() {
        let store = StateStore(directory: nil)
        let a = CollectionBudget(maxBytes: 1000, store: store)
        XCTAssertTrue(a.admit("s1", bytes: 600))
        let b = CollectionBudget(maxBytes: 1000, store: store)
        XCTAssertFalse(b.admit("s1", bytes: 600))
        XCTAssertTrue(b.hasUploaded("s1"))
        XCTAssertTrue(b.admit("s2", bytes: 600))
        XCTAssertFalse(b.hasUploaded("s3"))
    }

    func testTheCountsAreKeptOnDiskWithTheState() {
        let dir = scratchDirectory(self)
        let first = StateStore(directory: dir, destination: "d1")
        let a = CollectionBudget(maxBytes: 1000, store: first)
        XCTAssertTrue(a.admit("s1", bytes: 700))
        first.flush()
        let next = StateStore(directory: dir, destination: "d1")
        next.load()
        let b = CollectionBudget(maxBytes: 1000, store: next)
        XCTAssertFalse(b.admit("s1", bytes: 400))
        XCTAssertEqual(b.snapshot("s1")["traceway.collection.bytes"], 700)
        XCTAssertEqual(b.snapshot("s1")["traceway.collection.dropped"], 1)
    }

    func testPicturesHaveABudgetOfTheirOwnThatOutlivesARestart() {
        let store = StateStore(directory: nil)
        let a = CollectionBudget(maxBytes: 1000, maxImageBytes: 100, store: store)
        a.use("s1")
        XCTAssertEqual(a.currentSession, "s1")
        XCTAssertTrue(a.admitImage(bytes: 60))
        XCTAssertFalse(a.admitImage(bytes: 60), "past the image budget")
        XCTAssertTrue(a.admitImage(bytes: 40))
        XCTAssertFalse(a.admitImage(bytes: 1))
        XCTAssertEqual(a.snapshot("s1")["traceway.replay.image_bytes"], 100)
        // Segment bytes are counted apart.
        XCTAssertTrue(a.admit("s1", bytes: 900))
        XCTAssertFalse(a.admit("s1", bytes: 200))

        let b = CollectionBudget(maxBytes: 1000, maxImageBytes: 100, store: store)
        b.use("s1")
        XCTAssertFalse(b.admitImage(bytes: 1), "a restart inside the session goes on counting")
        b.use("s2")
        XCTAssertTrue(b.admitImage(bytes: 1))
        XCTAssertEqual(b.snapshot("s2")["traceway.replay.image_bytes"], 1)
    }

    func testWithoutASessionPicturesAreRefusedAndNothingIsSaved() {
        let store = StateStore(directory: nil)
        let budget = CollectionBudget(maxBytes: 1000, store: store)
        XCTAssertNil(budget.currentSession)
        XCTAssertFalse(budget.admitImage(bytes: 1))
        XCTAssertTrue(budget.admit(nil, bytes: 10))
        XCTAssertNil(store.get("budget"))
        XCTAssertTrue(budget.admit("s1", bytes: 10))
        XCTAssertEqual(store.get("budget")?["sessionId"], "s1")
        XCTAssertEqual(store.get("budget")?["bytes"], 10)
    }

    func testAStoreSetLaterIsReadBeforeTheNextCount() {
        let store = StateStore(directory: nil)
        store.set("budget", ["sessionId": "s1", "bytes": 900, "events": 3, "dropped": 1, "imageBytes": 5])
        let budget = CollectionBudget(maxBytes: 1000)
        XCTAssertTrue(budget.admit("s1", bytes: 900))
        budget.store = store
        XCTAssertFalse(budget.admit("s1", bytes: 200))
        let snapshot = budget.snapshot("s1")
        XCTAssertEqual(snapshot["traceway.collection.events"], 3)
        XCTAssertEqual(snapshot["traceway.collection.dropped"], 2)
        XCTAssertEqual(snapshot["traceway.replay.image_bytes"], 5)
    }
}
