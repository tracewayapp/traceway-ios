import XCTest
@testable import Traceway

final class ISO8601Tests: XCTestCase {

    func testGoldenTimestamp() {

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

    func testFormatsUTCWithMillisecondsAtTheEdges() {
        XCTAssertEqual(ISO8601.format(millis: 1_795_687_200_123), "2026-11-26T10:00:00.123Z")
        XCTAssertEqual(ISO8601.format(millis: 0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(ISO8601.format(millis: -1), "1969-12-31T23:59:59.999Z")
        XCTAssertEqual(ISO8601.format(millis: 253_402_300_799_999), "9999-12-31T23:59:59.999Z")
        for ms: Int64 in [0, 1, 999, 1_795_687_200_123, 1_709_251_199_999] {
            XCTAssertEqual(ISO8601.parseMillis(ISO8601.format(millis: ms)), ms, "\(ms)")
        }
    }

    /// Capture deadlines (`until`) as the server writes them, Go's
    /// `time.RFC3339` in UTC, and the offsets and fractions RFC 3339 allows.
    /// Expected values computed with JavaScript's `Date.parse`.
    func testCaptureDeadlinesParseWithOffsetsAndFractions() {
        func ms(_ text: String) -> Int64? {
            parseRFC3339(text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        }
        XCTAssertEqual(ms("2026-11-26T10:00:00Z"), 1_795_687_200_000)
        XCTAssertEqual(ms("2026-11-26T10:00:00.5Z"), 1_795_687_200_500)
        XCTAssertEqual(ms("2026-11-26T10:00:00.123456789Z"), 1_795_687_200_123)
        XCTAssertEqual(ms("2026-11-26T10:00:00.12z"), 1_795_687_200_120)
        XCTAssertEqual(ms("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(ms("2024-02-29T23:59:59.999Z"), 1_709_251_199_999)
        XCTAssertEqual(ms("2026-11-01T13:00:00Z"), 1_793_538_000_000)
        XCTAssertEqual(ms("2026-11-26T12:30:00+02:30"), 1_795_687_200_000)
        XCTAssertEqual(ms("2026-11-26T05:00:00-0500"), 1_795_687_200_000)
        XCTAssertEqual(ms("2026-11-26T10:00:00+00:00"), 1_795_687_200_000)
        XCTAssertEqual(ms("2026-11-26 10:00:00Z"), 1_795_687_200_000)
        for bad in ["", "not a date", "2026-11-26T10:00:00.Z", "2026-11-26T10:00:00+5", "2026-11-26T10:00:00Zjunk"] {
            XCTAssertNil(parseRFC3339(bad), bad)
        }
    }

    func testParseInvalidReturnsZero() {
        XCTAssertEqual(ISO8601.parseMillis("not-a-date"), 0)
    }
}
