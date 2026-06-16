import XCTest
@testable import Traceway

final class ConnectionStringTests: XCTestCase {

    func testParsesValidConnectionString() throws {
        let parsed = try parseConnectionString("abc-123@https://example.com/api/report")
        XCTAssertEqual(parsed.token, "abc-123")
        XCTAssertEqual(parsed.apiUrl, "https://example.com/api/report")
    }

    func testParsesUrlContainingAtSign() throws {

        let parsed = try parseConnectionString("token@https://user@example.com/api")
        XCTAssertEqual(parsed.token, "token")
        XCTAssertEqual(parsed.apiUrl, "https://user@example.com/api")
    }

    func testRejectsMissingAtSign() {
        XCTAssertThrowsError(try parseConnectionString("no-at-sign-here")) { error in
            XCTAssertTrue("\(error)".contains("must be in format"))
        }
    }

    func testRejectsEmptyToken() {
        XCTAssertThrowsError(try parseConnectionString("@https://example.com/api"))
    }

    func testRejectsEmptyApiUrl() {
        XCTAssertThrowsError(try parseConnectionString("token@"))
    }
}
