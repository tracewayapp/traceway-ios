import XCTest
@testable import Traceway

final class ISO8601Tests: XCTestCase {

    func testGoldenTimestamp() {
        // Same assertion as Android's WireFormatJvmTest.
        XCTAssertEqual(ISO8601.format(millis: 1_700_000_000_000), "2023-11-14T22:13:20.000Z")
    }

    func testMillisecondPrecision() {
        XCTAssertEqual(ISO8601.format(millis: 1_700_000_000_500), "2023-11-14T22:13:20.500Z")
    }

    func testParseRoundTrip() {
        let millis: Int64 = 1_700_000_000_123
        let formatted = ISO8601.format(millis: millis)
        XCTAssertEqual(ISO8601.parseMillis(formatted), millis)
    }

    func testParseInvalidReturnsZero() {
        XCTAssertEqual(ISO8601.parseMillis("not-a-date"), 0)
    }
}
