import XCTest
@testable import Traceway

final class GzipTests: XCTestCase {

    func testGzipMagicBytes() throws {
        let input = Data("hello traceway".utf8)
        let compressed = try XCTUnwrap(Gzip.compress(input))
        XCTAssertGreaterThanOrEqual(compressed.count, 2)
        XCTAssertEqual(compressed[compressed.startIndex], 0x1f)
        XCTAssertEqual(compressed[compressed.index(after: compressed.startIndex)], 0x8b)
    }

    func testRoundTrip() throws {
        let input = Data(#"{"collectionFrames":[],"appVersion":"1.0.0","serverName":""}"#.utf8)
        let compressed = try XCTUnwrap(Gzip.compress(input))
        let restored = try XCTUnwrap(Gzip.decompress(compressed))
        XCTAssertEqual(restored, input)
    }

    func testRoundTripLargePayload() throws {
        let big = String(repeating: "The quick brown fox. ", count: 5000)
        let input = Data(big.utf8)
        let compressed = try XCTUnwrap(Gzip.compress(input))
        XCTAssertLessThan(compressed.count, input.count, "should actually compress")
        let restored = try XCTUnwrap(Gzip.decompress(compressed))
        XCTAssertEqual(restored, input)
    }
}
