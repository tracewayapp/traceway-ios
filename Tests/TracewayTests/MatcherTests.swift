import XCTest
@testable import Traceway

func lookupOf(_ values: [String: JSON]) -> FieldLookup {
    { values[$0] }
}

func observed(
    _ timeMs: Int64,
    _ values: [String: JSON],
    sequence: String? = nil,
    targetMatches: ((String) -> Bool)? = nil
) -> ObservedEvent {
    ObservedEvent(timeMs: timeMs, lookup: lookupOf(values), sequence: sequence, targetMatches: targetMatches)
}

final class MatcherTests: XCTestCase {
    func testOperators() {
        let event = observed(0, [
            "event.name": "checkout_failed",
            "attributes.status": 503,
            "resource.service.version": "2.3.1",
            "body": "Payment FAILED hard",
            "flag": true,
            "empty": "",
        ])
        func m(_ key: String, _ op: String, _ value: JSON? = nil, values: [JSON]? = nil) -> Bool {
            matches(.condition(Condition(key: key, op: op, value: value, values: values)), event)
        }
        XCTAssertTrue(m("event.name", "eq", "checkout_failed"))
        XCTAssertTrue(m("event.name", "neq", "x"))
        XCTAssertTrue(m("attributes.status", "eq", "503"))
        XCTAssertTrue(m("attributes.status", "eq", " 503.0 "))
        XCTAssertTrue(m("attributes.status", "gte", 500))
        XCTAssertTrue(m("attributes.status", "gt", "500"))
        XCTAssertFalse(m("attributes.status", "lt", 500))
        XCTAssertTrue(m("attributes.status", "lte", 503))
        XCTAssertTrue(m("attributes.status", "in", values: [500, 503]))
        XCTAssertFalse(m("attributes.status", "not_in", values: [500, 503]))
        XCTAssertTrue(m("body", "contains", "FAILED"))
        XCTAssertFalse(m("body", "contains", "failed"))
        XCTAssertTrue(m("body", "icontains", "failed"))
        XCTAssertTrue(m("body", "starts_with", "Payment"))
        XCTAssertTrue(m("body", "glob", "pay*fail?d*"))
        XCTAssertFalse(m("body", "glob", "pay*fail?d"))
        XCTAssertFalse(m("missing", "exists"))
        XCTAssertFalse(m("empty", "exists"))
        XCTAssertTrue(m("missing", "not_exists"))
        XCTAssertTrue(m("flag", "eq", true))
        XCTAssertTrue(m("flag", "eq", "true"))
        XCTAssertFalse(m("flag", "eq", 1))
        XCTAssertTrue(m("resource.service.version", "version", ">=2.1 <3"))
        XCTAssertTrue(m("resource.service.version", "version", ">=2.1,<3"))
        XCTAssertFalse(m("resource.service.version", "version", "<2.3"))
        XCTAssertTrue(m("resource.service.version", "version", "!=2.3"))
        XCTAssertFalse(m("missing", "version", ">=1"))
        XCTAssertFalse(m("body", "nope", "x"))
        // A missing value equals a missing expectation, as in Dart.
        XCTAssertTrue(m("missing", "eq"))
        XCTAssertFalse(m("event.name", "eq"))
        XCTAssertFalse(m("missing", "eq", "x"))
    }

    func testVersions() {
        XCTAssertEqual(compareVersions("v1.2", "1.2.0"), 0)
        XCTAssertEqual(compareVersions("1.10", "1.9"), 1)
        XCTAssertEqual(compareVersions("1.2.3-beta", "1.2.4"), -1)
        XCTAssertNil(compareVersions("beta", "1"))
        XCTAssertTrue(satisfiesVersion("2.0.0.1", ">2"))
        XCTAssertTrue(satisfiesVersion("2", "==2.0"))
        XCTAssertTrue(satisfiesVersion("2", "=2"))
        XCTAssertTrue(satisfiesVersion("2", "2.0"))
        XCTAssertFalse(satisfiesVersion("2", " "))
        XCTAssertFalse(satisfiesVersion("2", ">=x"))
    }

    func testAVersionPartTooLongForAnIntIsNotAVersion() {
        XCTAssertFalse(satisfiesVersion("1.99999999999999999999", ">=1"))
        XCTAssertFalse(satisfiesVersion("2.0", ">=1.99999999999999999999"))
        XCTAssertNil(compareVersions("12345678901234567890", "1"))
    }

    func testGlob() {
        XCTAssertTrue(globMatch("Hello World", "hello*"))
        XCTAssertTrue(globMatch("abc", "a?c"))
        XCTAssertTrue(globMatch("abc", "***"))
        XCTAssertTrue(globMatch("", "*"))
        XCTAssertFalse(globMatch("abc", "a?"))
        XCTAssertTrue(globMatch("aaab", "*a*b"))
        XCTAssertFalse(globMatch("ab", "*c*"))
    }

    func testAllAnyAndNotCombine() {
        let event = observed(0, ["a": 1, "b": 2])
        let a = Matcher.condition(Condition(key: "a", op: "eq", value: 1))
        let b = Matcher.condition(Condition(key: "b", op: "eq", value: 9))
        XCTAssertFalse(matches(.all([a, b]), event))
        XCTAssertTrue(matches(.any([a, b]), event))
        XCTAssertTrue(matches(.not(b), event))
        XCTAssertTrue(matches(.all([]), event))
        XCTAssertFalse(matches(.any([]), event))
    }

    func testMatchesExactlyOneRouteSegmentAndPreservesCase() {
        let m0 = Matcher.event(EventMatcher(type: "navigation", value: "/users/{id}"))
        let cases: [(String, Bool)] = [
            ("/users/42", true),
            ("/users/42/edit", false),
            ("/Users/42", false),
            ("/users/", false),
            ("users/42", true),
            ("/users/42?tab=1", true),
            ("https://app.test/users/42?secret=hidden", true),
            ("//app.test/users/42#top", true),
            ("/a/../users/42", true),
        ]
        for (url, expected) in cases {
            let event = observed(0, ["event.name": "browser.navigation", "attributes.url.full": .string(url)])
            XCTAssertEqual(matches(m0, event), expected, url)
        }
        XCTAssertFalse(matches(m0, observed(0, ["event.name": "browser.console", "attributes.url.full": "/users/42"])))
        XCTAssertTrue(matchesRoute("/café", "/caf%C3%A9"))
        XCTAssertEqual(pathOf("/café"), "/caf%C3%A9")
        XCTAssertEqual(pathOf("/a%41%2f"), "/aA%2F")
        XCTAssertEqual(pathOf("?tab=1"), "/")
        XCTAssertEqual(pathOf("CheckoutPage"), "/CheckoutPage")
        XCTAssertNil(pathOf(""))
        XCTAssertNil(pathOf(nil))
        XCTAssertTrue(matches(
            .event(EventMatcher(type: "navigation", value: "/caf%C3%A9")),
            observed(0, ["event.name": "browser.navigation", "attributes.url.full": "/café"])
        ))
    }

    func testDistinguishesExactAndContainsLogs() {
        let console = observed(0, ["event.name": "browser.console", "body": "some loaded message"])
        XCTAssertFalse(matches(.event(EventMatcher(type: "log", value: "loaded")), console))
        XCTAssertTrue(matches(.event(EventMatcher(type: "log", value: "loaded", mode: "contains")), console))
        XCTAssertTrue(matches(
            .event(EventMatcher(type: "log", value: "hello")),
            observed(0, ["signal": "messages", "body": "hello"])
        ))
        XCTAssertTrue(matches(
            .event(EventMatcher(type: "log", value: "hello")),
            observed(0, ["event.name": "traceway.message", "body": "hello"])
        ))
        XCTAssertFalse(matches(
            .event(EventMatcher(type: "log", value: "hello")),
            observed(0, ["event.name": "custom", "body": "hello"])
        ))
        XCTAssertTrue(matches(
            .event(EventMatcher(type: "log", value: "")),
            observed(0, ["signal": "console"])
        ))
    }

    func testClickAndHoverAskTheTarget() {
        let click = Matcher.event(EventMatcher(type: "click", value: "#buy"))
        XCTAssertTrue(matches(click, observed(0, [keyPointerAction: "click"], targetMatches: { $0 == "#buy" })))
        XCTAssertFalse(matches(click, observed(0, [keyPointerAction: "click"], targetMatches: { $0 == "#other" })))
        XCTAssertFalse(matches(click, observed(0, [keyPointerAction: "hover"], targetMatches: { _ in true })))
        XCTAssertFalse(matches(click, observed(0, [keyPointerAction: "click"])))
    }

    func testTextConditionsLookAtTheFirst4096CodeUnits() {
        let long = String(repeating: "a", count: 5000) + "needle"
        let event = observed(0, ["body": .string(long)])
        XCTAssertFalse(matches(.condition(Condition(key: "body", op: "contains", value: "needle")), event))
        XCTAssertTrue(matches(.condition(Condition(key: "body", op: "eq", value: .string(long))), event))
        XCTAssertEqual(truncatedUTF16("a😀b", 2), "a\u{FFFD}")
    }
}
