import Foundation
import XCTest
@testable import Traceway

/// `ignoreErrors`: what each pattern matches and the line it is matched
/// against. The client applies them, and `beforeCapture`, in
/// `TracewayClientTests.testIgnoreErrorsAndBeforeCaptureDecideWhatIsReported`.
final class ErrorFilterTests: XCTestCase {
    private func ignoredByDefault(_ type: String?, _ message: String) -> Bool {
        let line = ignoreLine(type: type, message: message)
        return TracewayOptions.defaultIgnoreErrors.contains { $0.matches(line) }
    }

    func testTheLineIsTypeColonMessageFirstLineOnly() {
        XCTAssertEqual(ignoreLine(type: "Shop.CheckoutError", message: "card declined"), "Shop.CheckoutError: card declined")
        XCTAssertEqual(ignoreLine(type: "E", message: "E: boom\nframe"), "E: boom")
        XCTAssertEqual(ignoreLine(type: "E", message: ""), "E")
        XCTAssertEqual(ignoreLine(type: nil, message: "plain\nsecond"), "plain")
        XCTAssertEqual(ignoreLine(type: "", message: "no type"), "no type")
        XCTAssertEqual(ignoreLine(type: nil, message: ""), "")
    }

    func testAStringMatchesAsASubstringAndARegexSearches() {
        let text: TracewayErrorPattern = "declined"
        XCTAssertTrue(text.matches("Shop.CheckoutError: card declined"))
        XCTAssertFalse(text.matches("Shop.CheckoutError: card Declined"))
        XCTAssertTrue(TracewayErrorPattern.contains("Error: c").matches("Shop.CheckoutError: card"))
        let anchored = TracewayErrorPattern.regex(#"^Noise\b"#)
        XCTAssertTrue(anchored.matches("Noise level high"))
        XCTAssertFalse(anchored.matches("More Noise"))
        XCTAssertTrue(TracewayErrorPattern.regex("noise", options: [.caseInsensitive]).matches("LOUD NOISE"))
        let compiled = try! NSRegularExpression(pattern: #"code \d+"#)
        XCTAssertTrue(TracewayErrorPattern.regex(compiled).matches("failed with code 42"))
        // Non-ASCII text keeps its ranges right.
        XCTAssertTrue(TracewayErrorPattern.regex("ü$").matches("Grüße: ü"))
    }

    func testAPatternThatDoesNotCompileMatchesNothing() {
        let broken = TracewayErrorPattern.regex("(unclosed")
        XCTAssertFalse(broken.matches("(unclosed"))
        XCTAssertFalse(broken.matches(""))
    }

    func testTheDefaultsIgnoreNetworkNoise() {
        for (code, text) in [
            (-1001, "The request timed out."),
            (-1003, "A server with the specified hostname could not be found."),
            (-1004, "Could not connect to the server."),
            (-1005, "Lost it."),
            (-1009, "The Internet connection appears to be offline."),
        ] {
            XCTAssertTrue(ignoredByDefault("NSURLErrorDomain", "\(text) (code \(code))"), "\(code)")
            XCTAssertTrue(
                ignoredByDefault("Foundation.URLError", "Error Domain=NSURLErrorDomain Code=\(code) \"(null)\""),
                "URLError \(code)"
            )
        }
        XCTAssertTrue(ignoredByDefault(nil, "The network connection was lost."))
        XCTAssertTrue(ignoredByDefault(nil, "Gateway Timeout"))
        XCTAssertTrue(ignoredByDefault(nil, "Response status code of 404"))
        XCTAssertTrue(ignoredByDefault(nil, "Request failed with status code 401"))
        XCTAssertTrue(ignoredByDefault(nil, "Upload failed: 413"))
    }

    func testTheDefaultsReportRealErrors() {
        XCTAssertFalse(ignoredByDefault("NSURLErrorDomain", "The server returned a bad response. (code -1011)"))
        XCTAssertFalse(ignoredByDefault("NSURLErrorDomain", "Cancelled (code -1010)"))
        XCTAssertFalse(ignoredByDefault("NSURLErrorDomain", "Bad URL (code -1000)"))
        XCTAssertFalse(ignoredByDefault(nil, "Upload failed: 500"))
        XCTAssertFalse(ignoredByDefault(nil, "status code 500"))
        XCTAssertFalse(ignoredByDefault("Shop.CheckoutError", "card declined"))
        // Only the first line counts: a stack frame named like a pattern does not silence the error.
        XCTAssertFalse(ignoredByDefault("Shop.CheckoutError", "card declined\nat retryTimeoutHandler()"))
    }
}
