import XCTest
@testable import Traceway

final class JSONTests: XCTestCase {
    func testJSONKeepsBooleansAndNumbersApart() throws {
        let parsed = try JSON.parse(#"{"t":true,"one":1,"f":1.5,"s":"1","n":null,"a":[false,0]}"#)
        XCTAssertEqual(parsed["t"], .bool(true))
        XCTAssertNil(parsed["t"]?.number)
        XCTAssertEqual(parsed["one"], .number(1))
        XCTAssertNil(parsed["one"]?.bool)
        XCTAssertEqual(parsed["one"]?.int, 1)
        XCTAssertNil(parsed["f"]?.int)
        XCTAssertEqual(parsed["s"]?.string, "1")
        XCTAssertEqual(parsed["n"], .null)
        XCTAssertEqual(parsed["a"], .array([.bool(false), .number(0)]))
        XCTAssertThrowsError(try JSON.parse("nope"))
    }

    func testJSONEncodesStablyWithSortedKeys() {
        let value: JSON = ["b": 1, "a": [true, nil, "x\"y\n"], "c": 1.5]
        XCTAssertEqual(value.encoded(sortedKeys: true), #"{"a":[true,null,"x\"y\n"],"b":1,"c":1.5}"#)
    }

    func testRoundTripsNestedValues() throws {
        let value: JSON = [
            "z": 1,
            "a": [true, false, nil, "x", 2.5, ["k": []]],
            "m": [:],
            "s": "",
        ]
        let text = value.encoded(sortedKeys: true)
        XCTAssertEqual(text, #"{"a":[true,false,null,"x",2.5,{"k":[]}],"m":{},"s":"","z":1}"#)
        XCTAssertEqual(try JSON.parse(text), value)
        XCTAssertEqual(try JSON.parse(value.encoded()), value)
        XCTAssertEqual(try JSON.parse(value.encodedData()), value)
    }

    func testParsesWhitespaceAroundAndBetweenTokens() throws {
        XCTAssertEqual(try JSON.parse(" \n\t{ \"a\" : [ 1 , 2 ] }\r\n"), ["a": [1, 2]])
        XCTAssertEqual(try JSON.parse("[ ]"), [])
        XCTAssertEqual(try JSON.parse("{ }"), [:])
        XCTAssertEqual(try JSON.parse("null"), .null)
        XCTAssertEqual(try JSON.parse(" true "), true)
        XCTAssertEqual(try JSON.parse("\"top\""), "top")
    }

    func testEscapesWhatJSONRequiresAndReadsEveryEscape() throws {
        let s = "q\" b\\ s/ n\n r\r t\t b\u{08} f\u{0C} c\u{01} u\u{1f} ls\u{2028} ps\u{2029} é 😀"
        let text = JSON.string(s).encoded()
        XCTAssertEqual(
            text,
            "\"q\\\" b\\\\ s/ n\\n r\\r t\\t b\\b f\\f c\\u0001 u\\u001f ls\\u2028 ps\\u2029 é 😀\""
        )
        XCTAssertEqual(try JSON.parse(text), .string(s))
        XCTAssertEqual(try JSON.parse(#""\/\u00e9\ud83d\uDE00\u0041""#), "/é😀A")
        XCTAssertEqual(JSON.object(["k\"ey": "v"]).encoded(), #"{"k\"ey":"v"}"#)
    }

    func testNumbersParseAsFiniteDoublesAndIntsWhenIntegral() throws {
        XCTAssertEqual(try JSON.parse("0").int, 0)
        XCTAssertEqual(try JSON.parse("-12").int, -12)
        XCTAssertEqual(try JSON.parse("9007199254740992").int, 9_007_199_254_740_992)
        XCTAssertNil(try JSON.parse("1e300").int)
        XCTAssertEqual(try JSON.parse("1.5").number, 1.5)
        XCTAssertNil(try JSON.parse("1.5").int)
        XCTAssertEqual(try JSON.parse("1e5").int, 100_000)
        XCTAssertEqual(try JSON.parse("1E-7").number, 1.0e-7)
        XCTAssertEqual(try JSON.parse("2.5e+2").number, 250)
        XCTAssertEqual(try JSON.parse("-0.5").number, -0.5)
        XCTAssertNil(JSON.number(.nan).number)
        XCTAssertNil(JSON.number(.infinity).int)
    }

    func testNumbersAreWrittenAsJSONNumbers() throws {
        let values: [Double] = [1, -2, 600, 0.5, 1e-7, 1e21, .nan, .infinity, -.infinity]
        XCTAssertEqual(
            JSON.array(values.map(JSON.number)).encoded(),
            "[1,-2,600,0.5,1e-07,1e+21,null,null,null]"
        )
        XCTAssertEqual(JSON(Int64(1_700_000_000_123)).encoded(), "1700000000123")
        // Every written number reads back.
        for d in [0.1, 1e-7, 1e15, 1e21, -3.25e300, 123_456.789, Double(Int64.max)] {
            XCTAssertEqual(try JSON.parse(JSON.number(d).encoded()).number, d, "\(d)")
        }
    }

    func testRejectsWhatIsNotOneJSONValue() {
        // Foundation's parser takes a trailing comma (`[1,]`), so that is not
        // asserted either way.
        for bad in [
            "",
            " ",
            "nul",
            "tru",
            "{",
            "[1,",
            "[1 2]",
            "{\"a\" 1}",
            "{a:1}",
            "'a'",
            "\"open",
            "\"bad \\x escape\"",
            "\"\\u12\"",
            "\"\\u12G4\"",
            "\"raw\nnewline\"",
            "01",
            "-",
            "+1",
            ".5",
            "1.",
            "1.e5",
            "1e",
            "1e+",
            "--1",
            "0x10",
            "1.2.3",
            "NaN",
            "Infinity",
            "[1]x",
            "{} {}",
            String(repeating: "[", count: 600) + String(repeating: "]", count: 600),
        ] {
            XCTAssertThrowsError(try JSON.parse(bad), "accepted <\(bad)>") { error in
                XCTAssertTrue(error is JSON.ParseError)
            }
        }
    }

    func testAcceptsDeepButBoundedNesting() throws {
        var value = try JSON.parse(String(repeating: "[", count: 500) + String(repeating: "]", count: 500))
        var depth = 0
        while let items = value.array, let first = items.first {
            value = first
            depth += 1
        }
        XCTAssertEqual(depth, 499)
    }

    func testHelpersReadNumbersContainersAndText() throws {
        let parsed = try JSON.parse(#"{"a":1,"l":[1],"s":"x","b":false,"f":2.5,"o":{"z":1,"y":[true]}}"#)
        XCTAssertEqual(parsed["a"]?.number, 1)
        XCTAssertNil(parsed["s"]?.number)
        XCTAssertNil(parsed["b"]?.number)
        XCTAssertNil(parsed["s"]?.object)
        XCTAssertEqual(parsed["l"]?.array, [1])
        XCTAssertNil(parsed["o"]?.array)
        XCTAssertNil(parsed["missing"])
        XCTAssertNil(JSON.string("x")["key"])
        XCTAssertEqual(parsed["a"]?.text, "1")
        XCTAssertEqual(parsed["f"]?.text, "2.5")
        XCTAssertEqual(parsed["b"]?.text, "false")
        XCTAssertEqual(parsed["s"]?.text, "x")
        XCTAssertEqual(parsed["o"]?.text, #"{"y":[true],"z":1}"#)
        XCTAssertEqual(JSON.null.text, "null")
        XCTAssertTrue(parsed["s"]!.isScalar && parsed["a"]!.isScalar && parsed["b"]!.isScalar)
        XCTAssertFalse(parsed["l"]!.isScalar || JSON.null.isScalar)
        XCTAssertEqual(JSON(nil as String?), .null)
        XCTAssertEqual(JSON(["a", "b"]), ["a", "b"])
        XCTAssertEqual(JSON(["k": "v"]), ["k": "v"])
    }
}
