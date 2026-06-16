import XCTest
@testable import Traceway

final class CrashRecordConversionTests: XCTestCase {

    func testParsesRawSignalRecord() throws {
        let raw = """
        TRACEWAY_SIGNAL_V1
        signal=11
        time=1700000000
        appVersion=1.2.3
        attr.device.model=iPhone14,3
        attr.os.version=iOS 17.5
        ---FRAMES---
        0   MyApp   0x0000000100000000 main + 10
        1   MyApp   0x0000000100000001 foo + 20
        """

        let record = try XCTUnwrap(CrashRecordStore.parse(text: raw))
        XCTAssertTrue(record.stackTrace.hasPrefix("Fatal Signal SIGSEGV (11)"), record.stackTrace)
        XCTAssertTrue(record.stackTrace.contains("main + 10"))
        XCTAssertTrue(record.stackTrace.contains("foo + 20"))
        XCTAssertEqual(record.attributes?["device.model"], "iPhone14,3")
        XCTAssertEqual(record.attributes?["os.version"], "iOS 17.5")
        XCTAssertEqual(record.recordedAtMs, 1_700_000_000_000)
        XCTAssertFalse(record.isMessage)
    }

    func testRejectsRecordWithoutMagic() {
        XCTAssertNil(CrashRecordStore.parse(text: "signal=11\n---FRAMES---\nframe"))
    }

    func testBuildMetadataRoundTrips() throws {
        let metadata = CrashRecordStore.buildMetadata(
            attributes: ["device.model": "iPhone14,3", "os.version": "iOS 17.5"],
            appVersion: "9.9.9"
        )
        let metaText = String(decoding: metadata, as: UTF8.self)

        let raw = "TRACEWAY_SIGNAL_V1\nsignal=6\ntime=1700000000\n" + metaText + "---FRAMES---\n0 frame"
        let record = try XCTUnwrap(CrashRecordStore.parse(text: raw))
        XCTAssertEqual(record.attributes?["device.model"], "iPhone14,3")
        XCTAssertEqual(record.attributes?["os.version"], "iOS 17.5")
        XCTAssertTrue(record.stackTrace.hasPrefix("Fatal Signal SIGABRT (6)"))
    }

    func testEndToEndConvertPendingFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tw-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw = "TRACEWAY_SIGNAL_V1\nsignal=11\ntime=1700000000\nattr.device.model=iPhone14,3\n---FRAMES---\n0 main"
        try Data(raw.utf8).write(to: dir.appendingPathComponent("crash-123.tw"))

        let records = CrashRecordStore.convertPending(dir: dir)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].stackTrace.contains("SIGSEGV"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("crash-123.tw").path))
    }
}
