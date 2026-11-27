import XCTest
@testable import Traceway

final class IdsTests: XCTestCase {
    func testUuidv7CarriesTheTimestampVersionAndVariant() {
        let id = Ids.uuidv7(nowMs: 0x0195_f2a0_0000)
        XCTAssertTrue(id.hasPrefix("0195f2a0-0000-7"), id)
        XCTAssertTrue("89ab".contains(Array(id)[19]))
        XCTAssertEqual(id.count, 36)
        let bytes = Ids.uuidBytes(id)
        XCTAssertEqual(bytes?.count, 16)
        XCTAssertEqual(Ids.uuidString(bytes!), id)
        XCTAssertTrue(Ids.uuidv7(nowMs: -5).hasPrefix("00000000-0000-7"))
        XCTAssertNotEqual(Ids.uuidv7(nowMs: 1), Ids.uuidv7(nowMs: 1))
    }

    func testUuidv4CarriesVersionAndVariant() {
        let id = Array(Ids.uuidv4())
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(id[14], "4")
        XCTAssertTrue("89ab".contains(id[19]))
        XCTAssertEqual(id.filter { $0 == "-" }.count, 4)
        XCTAssertNotEqual(Ids.uuidv4(), Ids.uuidv4())
    }

    func testHexRoundTripsAndRejectsWhatIsNotHex() {
        let bytes: [UInt8] = [0, 1, 0x7f, 0x80, 0xff]
        XCTAssertEqual(Ids.hex(bytes), "00017f80ff")
        XCTAssertEqual(Ids.bytes(hex: "00017F80ff"), bytes)
        XCTAssertEqual(Ids.bytes(hex: ""), [])
        XCTAssertNil(Ids.bytes(hex: "abc"))
        XCTAssertNil(Ids.bytes(hex: "zz"))
        // Full-width and Arabic-Indic digits are digits, but not hex.
        XCTAssertNil(Ids.bytes(hex: "０１"))
        XCTAssertNil(Ids.bytes(hex: "١٢"))
        XCTAssertNil(Ids.uuidBytes("0195f2a0-0000-7"))
        XCTAssertEqual(Ids.uuidString([1, 2]), "0102", "not 16 bytes: plain hex")
    }

    /// Expected values from the browser SDK's `unitHash` (js-client
    /// packages/core/src/ids.ts), as the Android suite has them.
    func testUnitHashMatchesTheBrowserSDK() {
        XCTAssertEqual(Ids.unitHash(""), Double(0x811c_9dc5) / 4_294_967_296, accuracy: 1e-12)
        XCTAssertEqual(Ids.unitHash("a"), Double(0xe40c_292c) / 4_294_967_296, accuracy: 1e-12)
        XCTAssertEqual(Ids.unitHash("session"), Double(0xc35f_4cf7) / 4_294_967_296, accuracy: 1e-12)
        // UTF-16 code units, as JavaScript and Dart read strings.
        XCTAssertEqual(Ids.unitHash("é😀"), Double(0x44cc_4da1) / 4_294_967_296, accuracy: 1e-12)
        XCTAssertEqual(
            Ids.unitHash("0195f2a0-0000-7000-8000-000000000000"),
            Double(0x0a21_31ae) / 4_294_967_296, accuracy: 1e-12
        )
        let expected: [(String, Double)] = [
            ("", 2_166_136_261),
            ("a", 3_826_002_220),
            ("foobar", 3_214_735_720),
            ("session-1", 1_936_347_597),
            ("0190d1c2-3e4f-7a5b-8c6d-9e0f1a2b3c4d", 2_764_980_149),
            ("é€😀", 207_495_949),
        ]
        for (value, hash) in expected {
            XCTAssertEqual(Ids.unitHash(value), hash / 4_294_967_296, value)
        }
        XCTAssertEqual(Ids.unitHash(""), 0.50434289989061654)
        XCTAssertEqual(Ids.unitHash("session-1"), 0.45084105734713376)
    }

    func testFingerprintsAreStableAndFixedWidth() {
        XCTAssertEqual(Ids.fingerprint(""), "811c9dc5")
        XCTAssertEqual(Ids.fingerprint("a"), "e40c292c")
        XCTAssertEqual(Ids.fingerprint64(""), "cbf29ce484222325")
        XCTAssertEqual(Ids.fingerprint64("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(Ids.fingerprint64("Bearer secret").count, 16)
        XCTAssertNotEqual(Ids.fingerprint64("Bearer one"), Ids.fingerprint64("Bearer two"))
    }
}
