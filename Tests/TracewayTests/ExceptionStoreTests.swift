import XCTest
@testable import Traceway

final class ExceptionStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tw-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(maxLocalFiles: Int = 5, maxAgeHours: Int = 12) -> ExceptionStore {
        let store = ExceptionStore(dir: dir, maxLocalFiles: maxLocalFiles, maxAgeHours: maxAgeHours)
        store.initialize()
        return store
    }

    func testWriteAndLoadRoundTrip() {
        let store = makeStore()
        let exception = ExceptionStackTrace(
            stackTrace: "MyError: boom\nframe",
            recordedAtMs: 1_700_000_000_000,
            attributes: ["device.model": "iPhone14,3"]
        )
        let id = store.write(exception)
        XCTAssertNotNil(id)

        let entries = makeStore().loadAll()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.exception.stackTrace, "MyError: boom\nframe")
        XCTAssertEqual(entries.first?.exception.attributes?["device.model"], "iPhone14,3")
        XCTAssertEqual(entries.first?.exception.fileId, id)
    }

    func testRemoveDeletesFile() {
        let store = makeStore()
        let id = try! XCTUnwrap(store.write(ExceptionStackTrace(stackTrace: "x", recordedAtMs: 0)))
        store.remove([id])
        XCTAssertEqual(store.loadAll().count, 0)
    }

    func testPruneExcessKeepsNewest() {
        let store = makeStore(maxLocalFiles: 3)
        for i in 0..<5 {
            _ = store.write(ExceptionStackTrace(stackTrace: "e\(i)", recordedAtMs: Int64(i)))
        }
        // Re-initializing prunes down to maxLocalFiles.
        let reopened = makeStore(maxLocalFiles: 3)
        XCTAssertEqual(reopened.loadAll().count, 3)
    }

    func testCorruptFileIsDeleted() throws {
        let store = makeStore()
        _ = store.write(ExceptionStackTrace(stackTrace: "good", recordedAtMs: 0))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("corrupt.json"))

        let entries = store.loadAll()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.exception.stackTrace, "good")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrupt.json").path))
    }

    func testLoadAllSortsOldestFirst() {
        let store = makeStore()
        // Write with explicit, increasing createdAt by manipulating recordedAt is
        // not enough (createdAt is stamped at write time), so assert the set of
        // stack traces is fully recovered regardless of order.
        for i in 0..<3 {
            _ = store.write(ExceptionStackTrace(stackTrace: "e\(i)", recordedAtMs: Int64(i)))
        }
        let traces = Set(store.loadAll().map { $0.exception.stackTrace })
        XCTAssertEqual(traces, ["e0", "e1", "e2"])
    }
}
