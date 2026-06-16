import XCTest
@testable import Traceway

final class StackTraceFormatterTests: XCTestCase {

    func testTypeMessageAndFrames() {
        let result = StackTraceFormatter.format(type: "MyError", message: "boom", frames: ["frame a", "frame b"])
        XCTAssertEqual(result, "MyError: boom\nframe a\nframe b")
    }

    func testEmptyMessageOmitted() {
        XCTAssertEqual(StackTraceFormatter.format(type: "MyError", message: "", frames: []), "MyError")
        XCTAssertEqual(StackTraceFormatter.format(type: "MyError", message: nil, frames: []), "MyError")
    }

    func testNilMessageWithFrames() {
        XCTAssertEqual(StackTraceFormatter.format(type: "MyError", message: nil, frames: ["a"]), "MyError\na")
    }

    func testTrailingWhitespaceTrimmed() {
        let result = StackTraceFormatter.format(type: "E", message: "m", frames: ["a", "", "  "])
        XCTAssertEqual(result, "E: m\na")
    }

    enum SampleError: Error { case notFound(id: Int) }

    func testFormatsSwiftError() {
        let result = StackTraceFormatter.format(SampleError.notFound(id: 42), callStack: ["#0 main"])

        XCTAssertTrue(result.contains("StackTraceFormatterTests.SampleError"), result)
        XCTAssertTrue(result.contains("notFound(id: 42)"), result)
        XCTAssertTrue(result.contains("#0 main"))
    }

    func testFormatsNSError() {
        let error = NSError(domain: "com.example.Net", code: 7, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        let result = StackTraceFormatter.format(error, callStack: [])
        XCTAssertTrue(result.hasPrefix("com.example.Net"), result)
        XCTAssertTrue(result.contains("timeout"))
        XCTAssertTrue(result.contains("code 7"))
    }
}
