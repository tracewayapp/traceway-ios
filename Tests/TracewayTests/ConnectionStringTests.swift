import XCTest
@testable import Traceway

/// The old connection strings, `token@https://host[/api[/report]]`, read the
/// way every Traceway SDK reads them. The strings are the 2.0 form on
/// purpose: they are what apps still pass to the deprecated entry points.
final class ConnectionStringTests: XCTestCase {
    func testAPIHostnameIsPreservedWhenStrippingLegacyPaths() throws {
        for url in ["http://api", "http://api/api", "http://api/api/report/", "http://api?project=1"] {
            XCTAssertEqual(try normalizeBaseUrl(url), "http://api", url)
        }
        XCTAssertEqual(try normalizeBaseUrl("http://api/report"), "http://api/report")
    }



    /// Every row of the table the SDKs share; nil is "not started".
    func testEveryConnectionStringFormOfTheContract() {
        let rows: [(String, (token: String, baseUrl: String)?)] = [
            ("tok@https://cloud.tracewayapp.com", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@https://cloud.tracewayapp.com/", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@https://cloud.tracewayapp.com/api", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@https://cloud.tracewayapp.com/api/", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@https://cloud.tracewayapp.com/api/report", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@https://cloud.tracewayapp.com/api/report/", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@cloud.tracewayapp.com", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@cloud.tracewayapp.com/api/report", ("tok", "https://cloud.tracewayapp.com")),
            ("  tok@https://cloud.tracewayapp.com/api/report  ", ("tok", "https://cloud.tracewayapp.com")),
            ("tok@http://localhost:8082/api/report", ("tok", "http://localhost:8082")),
            ("tok@localhost:8082", ("tok", "http://localhost:8082")),
            ("tok@https://corp.example/traceway/api/report", ("tok", "https://corp.example/traceway")),
            ("tok@https://cloud.tracewayapp.com/api/report?x=1", ("tok", "https://cloud.tracewayapp.com")),
            ("@https://cloud.tracewayapp.com", nil),
            ("tok", nil),
            ("tok@", nil),
            ("tok@ftp://host", nil),
        ]
        for (input, expected) in rows {
            let parsed = try? parseConnectionString(input)
            XCTAssertEqual(parsed?.token, expected?.token, "token of \"\(input)\"")
            XCTAssertEqual(parsed?.baseUrl, expected?.baseUrl, "baseUrl of \"\(input)\"")
            if let parsed = parsed {
                // What the SDK then talks to: never the 1.x endpoint.
                let endpoints = try? resolveEndpoints(parsed.baseUrl)
                XCTAssertEqual(endpoints?.base, expected?.baseUrl, input)
                XCTAssertFalse(endpoints?.logs.absoluteString.contains("/api/report") ?? true, input)
            }
        }
    }

    func testTheTokenIsTrimmedAndTheFirstAtSignSplits() throws {
        let parsed = try parseConnectionString(" tok @https://user@example.com/api")
        XCTAssertEqual(parsed.token, "tok")
        XCTAssertEqual(parsed.baseUrl, "https://user@example.com")
        XCTAssertEqual(try parseConnectionString("abc-123_def@https://api.example.com/report").baseUrl,
                       "https://api.example.com/report", "another path is kept")
    }

    func testOnlyOneSuffixIsDropped() throws {
        XCTAssertEqual(try parseConnectionString("tok@https://h/api/api/report").baseUrl, "https://h/api")
        XCTAssertEqual(try parseConnectionString("tok@https://h/api/report/api").baseUrl, "https://h/api/report")
        XCTAssertEqual(try parseConnectionString("tok@https://h/x/api//").baseUrl, "https://h/x")
    }

    /// The message says what is wrong and what to pass, never the token.
    func testAStringItCannotReadSaysWhyWithoutTheToken() {
        for input in ["secret-token", "@https://cloud.tracewayapp.com", "secret-token@ftp://host", "secret-token@"] {
            XCTAssertThrowsError(try parseConnectionString(input), input) { error in
                let text = "\(error)"
                XCTAssertFalse(text.contains("secret-token"), text)
                XCTAssertTrue(text.contains("YOUR_TOKEN") || text.contains("https://host"), text)
            }
        }
    }

    /// Garbage never traps: a NUL, a megabyte, odd schemes and brackets.
    func testGarbageIsRejectedWithoutATrap() {
        let huge = String(repeating: "a", count: 1_000_000)
        for input in ["\u{0}", "tok@\u{0}", "tok@" + huge, huge + "@https://h", "tok@[", "tok@[::1", "tok@:",
                      "tok@https://", "tok@http://:80", "tok@javascript:alert(1)", "tok@//host", "tok@?#"] {
            _ = try? parseConnectionString(input)
        }
        XCTAssertNil(try? parseConnectionString("tok@https://"))
        XCTAssertEqual(try? parseConnectionString(huge + "@https://h").baseUrl, "https://h")
    }
}
