import XCTest
@testable import Traceway

final class IOSSymbolicationTests: XCTestCase {

    func testCaptureReturnsImagesWithUUIDs() {
        let images = BinaryImages.capture()
        XCTAssertFalse(images.isEmpty, "expected at least the test runner's images")
        for img in images.prefix(8) {
            XCTAssertEqual(img.uuid.count, 32, "uuid should be 32 hex chars: \(img.uuid)")
            XCTAssertGreaterThan(img.loadAddr, 0)
        }
        XCTAssertFalse(BinaryImages.currentArch().isEmpty)
    }

    func testMapAddressToImage() {
        let images = [
            BinaryImages.LoadedImage(loadAddr: 0x1000, size: 0x1000, uuid: String(repeating: "a", count: 32), name: "AppA"),
            BinaryImages.LoadedImage(loadAddr: 0x4000, size: 0x1000, uuid: String(repeating: "b", count: 32), name: "AppB"),
        ]
        let hit = BinaryImages.map(address: 0x1234, images: images)
        XCTAssertEqual(hit?.image.name, "AppA")
        XCTAssertEqual(hit?.offset, 0x234)
        XCTAssertNil(BinaryImages.map(address: 0x2500, images: images), "address in a gap must not match")
    }

    func testEncodeBlobRoundTrips() {
        let images = [
            BinaryImages.LoadedImage(loadAddr: 0x100000000, size: 0x4000, uuid: "2dd71042118432be8f92dd4e3d3fe24a", name: "sample"),
        ]
        let blob = String(decoding: BinaryImages.encodeBlob(images), as: UTF8.self)
        let parsed = blob.split(separator: "\n").compactMap { BinaryImages.parseImageLine($0) }
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].loadAddr, 0x100000000)
        XCTAssertEqual(parsed[0].size, 0x4000)
        XCTAssertEqual(parsed[0].uuid, "2dd71042118432be8f92dd4e3d3fe24a")
        XCTAssertEqual(parsed[0].name, "sample")
    }

    func testWireTraceFromImageRecord() throws {
        let raw = [
            "TRACEWAY_SIGNAL_V1",
            "signal=11",
            "time=1700000000",
            "attr.device.model=iPhone14,3",
            "arch=arm64",
            "---IMAGES---",
            "100000000 4000 2dd71042118432be8f92dd4e3d3fe24a sample",
            "200000000 4000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa OtherLib",
            "---FRAMES---",
            "0x100000460",
            "0x100000478",
            "0xdeadbeef",
        ].joined(separator: "\n")

        let record = try XCTUnwrap(CrashRecordStore.parse(text: raw))
        let st = record.stackTrace
        XCTAssertTrue(st.hasPrefix("Fatal Signal SIGSEGV (11)"), st)
        XCTAssertTrue(st.contains("os: ios arch: arm64"), st)
        XCTAssertTrue(st.contains("#00 2dd71042118432be8f92dd4e3d3fe24a 0x460 sample"), st)
        XCTAssertTrue(st.contains("#01 2dd71042118432be8f92dd4e3d3fe24a 0x478 sample"), st)

        XCTAssertTrue(st.contains("0xdeadbeef <unknown>"), st)
        XCTAssertEqual(record.attributes?["device.model"], "iPhone14,3")
    }

    func testErrorHeaderHasNoFrames() {
        let header = StackTraceFormatter.errorHeader(SampleError.boom(7))
        XCTAssertTrue(header.contains("boom(7)"), header)
        XCTAssertFalse(header.contains("\n"), "header must be a single line")
    }

    func testRenderWireTraceFromErrorAndAddresses() {
        let uuid = String(repeating: "c", count: 32)
        let images = [BinaryImages.LoadedImage(loadAddr: 0x1000, size: 0x1000, uuid: uuid, name: "App")]
        let wire = CrashRecordStore.renderWireTrace(
            header: StackTraceFormatter.errorHeader(SampleError.boom(7)),
            arch: "arm64",
            images: images,
            addresses: [0x1234, 0x9999]
        )
        XCTAssertTrue(wire.contains("boom(7)"), wire)
        XCTAssertTrue(wire.contains("os: ios arch: arm64"), wire)
        XCTAssertTrue(wire.contains("#00 \(uuid) 0x234 App"), wire)
        XCTAssertTrue(wire.contains("#01 \(String(repeating: "0", count: 32)) 0x9999 <unknown>"), wire)
    }

    private enum SampleError: Error { case boom(Int) }

    func testNSExceptionHeaderRendersWireTrace() {

        let header = StackTraceFormatter.format(
            type: "NSRangeException", message: "index 5 beyond bounds", frames: []
        )
        let uuid = String(repeating: "d", count: 32)
        let images = [BinaryImages.LoadedImage(loadAddr: 0x4000, size: 0x1000, uuid: uuid, name: "App")]
        let wire = CrashRecordStore.renderWireTrace(header: header, arch: "arm64", images: images, addresses: [0x4123])
        XCTAssertTrue(wire.hasPrefix("NSRangeException: index 5 beyond bounds"), wire)
        XCTAssertTrue(wire.contains("os: ios arch: arm64"), wire)
        XCTAssertTrue(wire.contains("#00 \(uuid) 0x123 App"), wire)
    }

    func testLegacyRecordWithoutImagesStillTextual() throws {
        let raw = "TRACEWAY_SIGNAL_V1\nsignal=6\ntime=1\n---FRAMES---\n0 main + 10"
        let record = try XCTUnwrap(CrashRecordStore.parse(text: raw))
        XCTAssertTrue(record.stackTrace.contains("main + 10"))
        XCTAssertFalse(record.stackTrace.contains("os: ios"))
        XCTAssertTrue(record.stackTrace.hasPrefix("Fatal Signal SIGABRT (6)"))
    }
}
