import Foundation
import XCTest
@testable import FieldmartCore

final class RandomTests: XCTestCase {
    // Expected values from an independent JavaScript implementation of
    // `02-APP-SPEC.md` §3.4 (Math.imul, >>> 0).
    func testGeneratorMatchesTheReference() {
        var generator = FMRandom(seed: 20_261_128)
        let expected = [0.9627261769492179, 0.18837198405526578, 0.3504589442163706, 0.08788741892203689,
                        0.8811728993896395]
        for value in expected { XCTAssertEqual(generator.next(), value) }

        var zero = FMRandom(seed: 0)
        XCTAssertEqual(zero.next(), 0.26642920868471265)
        XCTAssertEqual(zero.next(), 0.0003297457005828619)
        XCTAssertEqual(zero.next(), 0.2232720274478197)
    }

    func testSymbolSeeds() {
        XCTAssertEqual(TickModel.seed(forSymbol: 0), 20_261_128)
        XCTAssertEqual(TickModel.seed(forSymbol: 1), 2_667_729_081)
        XCTAssertEqual(TickModel.seed(forSymbol: 299), 3_422_423_219)
    }

    func testTickSeries() {
        XCTAssertEqual(TickModel.series(symbol: 0, startCents: 12_345, count: 10),
                       [12368, 12353, 12346, 12326, 12345, 12345, 12343, 12355, 12352, 12339])
        XCTAssertEqual(TickModel.series(symbol: 1, startCents: 500, count: 10),
                       [500, 499, 498, 497, 498, 499, 499, 499, 500, 501])
        XCTAssertEqual(Array(TickModel.series(symbol: 299, startCents: 98_765, count: 200).suffix(10)),
                       [96871, 96678, 96859, 96708, 96521, 96379, 96350, 96257, 96388, 96539])
    }

    func testModelAdvancesEverySymbol() {
        var model = TickModel(startCents: [12_345, 500])
        model.advance(to: 10)
        XCTAssertEqual(model.ticks, 10)
        XCTAssertEqual(model.cents, [12339, 501])
        model.advance(to: 5)
        XCTAssertEqual(model.ticks, 10, "never goes back")
    }

    func testRoundRobinRows() {
        XCTAssertEqual(TickModel.rowsUpdated(onTick: 0, symbolCount: 300), Array(0..<30))
        XCTAssertEqual(TickModel.rowsUpdated(onTick: 9, symbolCount: 300), Array(270..<300))
        XCTAssertEqual(TickModel.rowsUpdated(onTick: 10, symbolCount: 300), Array(0..<30))
        XCTAssertEqual(TickModel.rowsUpdated(onTick: 1, symbolCount: 40), Array(30..<40) + Array(0..<20))
    }
}

final class FormatTests: XCTestCase {
    func testCents() {
        XCTAssertEqual(FMFormat.cents(12_345), "123.45")
        XCTAssertEqual(FMFormat.cents(5), "0.05")
        XCTAssertEqual(FMFormat.cents(100), "1.00")
        XCTAssertEqual(FMFormat.cents(-5), "-0.05")
        XCTAssertEqual(FMFormat.price(1999), "$19.99")
    }

    func testChangePercent() {
        XCTAssertEqual(FMFormat.changePercent(from: 10_000, to: 10_125), "+1.25%")
        XCTAssertEqual(FMFormat.changePercent(from: 10_000, to: 9_960), "-0.40%")
        XCTAssertEqual(FMFormat.changePercent(from: 3, to: 4), "+33.33%")
        XCTAssertEqual(FMFormat.changePercent(from: 10_000, to: 10_000), "+0.00%")
    }

    func testRatingAndCounter() {
        XCTAssertEqual(FMFormat.rating(4.55), "4.6")
        XCTAssertEqual(FMFormat.rating(4), "4.0")
        XCTAssertEqual(FMFormat.pageCounter(2, of: 8), "3 / 8")
    }
}

final class LaunchSettingsTests: XCTestCase {
    func testDefaults() {
        let settings = LaunchSettings(arguments: [])
        XCTAssertEqual(settings.run, "manual")
        XCTAssertEqual(settings.variant, "core")
        XCTAssertEqual(settings.baseUrl, "http://127.0.0.1:18190")
        XCTAssertEqual(settings.fixturesBase, "http://127.0.0.1:18190/fx")
        XCTAssertEqual(settings.token, "ios-dev-token")
        XCTAssertFalse(settings.evidence)
        XCTAssertEqual(settings.toolkit, .uikit)
        XCTAssertNil(settings.fps)
    }

    func testArguments() {
        let settings = LaunchSettings(arguments: [
            "/path/Fieldmart", "-fmRun", "ios-S6-stream-img-b01-1a2b", "-fmVariant", "stream-img",
            "-fmScenario", "S6", "-fmEvidence", "1", "-fmFps", "15", "-fmToolkit", "stack",
            "-fmFixtures", "http://127.0.0.1:18190/fx/", "-fmAutopilot", "1", "-fmMarkers", "/tmp/m.jsonl",
        ])
        XCTAssertEqual(settings.run, "ios-S6-stream-img-b01-1a2b")
        XCTAssertEqual(settings.variant, "stream-img")
        XCTAssertEqual(settings.scenario, "S6")
        XCTAssertTrue(settings.evidence)
        XCTAssertEqual(settings.fps, 15)
        XCTAssertEqual(settings.toolkit, .stack)
        XCTAssertEqual(settings.fixturesBase, "http://127.0.0.1:18190/fx")
        XCTAssertTrue(settings.autopilot)
        XCTAssertEqual(settings.markersPath, "/tmp/m.jsonl")
        XCTAssertEqual(settings.attributes(target: "sim")["fm.run"], "ios-S6-stream-img-b01-1a2b")
        XCTAssertEqual(settings.attributes(target: "sim")["fm.scenario"], "S6")
    }

    func testRunIdIsChecked() {
        XCTAssertEqual(LaunchSettings(arguments: ["-fmRun", "bad id!"]).run, "manual")
        XCTAssertTrue(LaunchSettings.isValidRunId("ios-S0-off-b00-ffff"))
        XCTAssertFalse(LaunchSettings.isValidRunId("a_b"))
    }

    func testVariantPlans() {
        let core = SDKPlan.forVariant("core", evidence: false, remote: false, fps: nil)
        XCTAssertFalse(core.screenCapture)
        XCTAssertNil(core.collection)
        let buffer = SDKPlan.forVariant("buffer", evidence: false, remote: false, fps: nil)
        XCTAssertTrue(buffer.screenCapture)
        XCTAssertFalse(buffer.recordAllSessions)
        XCTAssertEqual(buffer.replayImages, "always")
        let stream = SDKPlan.forVariant("stream-img", evidence: true, remote: false, fps: 4)
        XCTAssertTrue(stream.screenCapture && stream.recordAllSessions && stream.debug)
        XCTAssertEqual((stream.collection?["replay"] as? [String: String])?["images"], "always")
        XCTAssertEqual(SDKPlan.forVariant("stream-noimg", evidence: false, remote: false, fps: nil).replayImages, "off")
        XCTAssertNil(SDKPlan.forVariant("buffer-nopin", evidence: false, remote: false, fps: nil).replayImages)
        XCTAssertFalse(SDKPlan.forVariant("nonsense", evidence: false, remote: false, fps: nil).known)
    }
}

final class ModelTests: XCTestCase {
    private func json(_ text: String) -> JSONValue {
        try! JSONValue.parse(Data(text.utf8))
    }

    func testProductsPage() {
        let page = json("""
        {"page":0,"size":2,"total":2000,"items":[
          {"id":17,"title":"Trail Runner 2","brand":"Northpeak","categoryId":3,"priceCents":12900,
           "compareAtCents":15900,"rating":4.4,"reviewCount":500,"badges":["sale"],"imageCount":8},
          {"id":18,"title":"Camp Mug","brand":"Ember","categoryId":5,"priceCents":1450,"compareAtCents":null,
           "rating":3.9,"reviewCount":20,"badges":[],"imageCount":3}]}
        """)
        let products = Fixtures.products(page)
        XCTAssertEqual(products.count, 2)
        XCTAssertEqual(products[0].id, 17)
        XCTAssertEqual(products[0].badgeText, "Sale")
        XCTAssertEqual(products[0].discountPercent, 19)
        XCTAssertNil(products[1].compareAtCents)
        XCTAssertEqual(Fixtures.total(page), 2000)
        XCTAssertEqual(Fixtures.products(json("[{\"id\":1,\"title\":\"A\"}]")).count, 1)
    }

    func testCandlesAndOthers() {
        XCTAssertEqual(Fixtures.candles(json("[[1700000000,100,110,90,105],[1700000060,105,107,101,102]]")),
                       [Candle(t: 1_700_000_000, open: 100, high: 110, low: 90, close: 105),
                        Candle(t: 1_700_000_060, open: 105, high: 107, low: 101, close: 102)])
        XCTAssertEqual(Fixtures.symbols(json("[{\"symbol\":\"FMA\",\"name\":\"Fieldmart A\",\"seedIndex\":0,\"startCents\":12345}]")),
                       [MarketSymbol(symbol: "FMA", name: "Fieldmart A", seedIndex: 0, startCents: 12_345)])
        XCTAssertEqual(Fixtures.quoteTick(json("{\"n\":42,\"count\":300}")), 42)
        XCTAssertEqual(Fixtures.orderNumber(json("{\"order\":\"FM-123456\"}")), "FM-123456")
        XCTAssertEqual(Fixtures.countries(json("[\"Norway\",\"Peru\"]")), ["Norway", "Peru"])
        XCTAssertEqual(Fixtures.promos(json("[{\"code\":\"FIELD10\",\"label\":\"10% off\"},\"FIELD1\"]")).map(\.code),
                       ["FIELD10", "FIELD1"])
        let rows = Fixtures.feed(json("{\"cursor\":100,\"rows\":[{\"type\":\"shipment\",\"title\":\"Parcel\",\"productId\":4,\"progress\":0.5},{\"type\":\"message\",\"text\":\"a\\nb\"}]}"), cursor: 100)
        XCTAssertEqual(rows.map(\.index), [100, 101])
        XCTAssertEqual(rows.map(\.kind), [.shipment, .message])
        XCTAssertEqual(rows[1].lines, ["a", "b"])
    }

    func testUrls() {
        let urls = FixtureURLs(base: "http://127.0.0.1:18190/fx/")
        XCTAssertEqual(urls.products(page: 2, category: 7).absoluteString,
                       "http://127.0.0.1:18190/fx/api/products?page=2&size=40&category=7")
        XCTAssertEqual(urls.productImage(17, index: 3, size: 800).absoluteString,
                       "http://127.0.0.1:18190/fx/img/p/17/3/800.jpg")
        XCTAssertEqual(urls.avatar(65).absoluteString, "http://127.0.0.1:18190/fx/img/avatar/1/96.jpg")
        XCTAssertEqual(urls.search("trail run").absoluteString, "http://127.0.0.1:18190/fx/api/search?q=trail%20run")
    }
}

final class MarkerTests: XCTestCase {
    func testLinesRoundTrip() {
        let markers = [
            Marker(.ready, epochMs: 1_795_000_000_000),
            Marker(.screen, epochMs: 1_795_000_000_500, detail: "home"),
            Marker(.session, epochMs: 0, detail: "0f9e"),
            Marker(.checkpoint, epochMs: 1_795_000_001_000, detail: "s6-home"),
        ]
        XCTAssertEqual(markers.map(\.line), ["FM_READY 1795000000000", "FM_SCREEN home 1795000000500",
                                             "FM_SESSION 0f9e", "FM_CP s6-home 1795000001000"])
        for marker in markers {
            XCTAssertEqual(Marker(line: marker.line), marker)
            XCTAssertEqual(Marker(jsonLine: marker.jsonLine)?.kind, marker.kind)
        }
        let file = markers.map(\.jsonLine).joined(separator: "\n") + "\n"
        XCTAssertEqual(Marker.parseFile(file).map(\.detail), [nil, "home", "0f9e", "s6-home"])
        XCTAssertEqual(Marker.quote("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
    }

    func testProbeLine() {
        let sample = ProbeSample(t: 1000, epochMs: 5, cpuUserMs: 12.3456, cpuSysMs: 0.5, mainUserMs: 0,
                                 mainSysMs: 1, threads: 9, footprintKb: 100, residentKb: 200, frames: [16667, 16666])
        let line = sample.jsonLine
        XCTAssertEqual(line, "{\"t\":1000,\"epochMs\":5,\"cpuUserMs\":12.346,\"cpuSysMs\":0.500,\"mainUserMs\":0.000,"
            + "\"mainSysMs\":1.000,\"threads\":9,\"footprintKb\":100,\"residentKb\":200,\"frames\":[16667,16666]}")
        XCTAssertNotNil(try? JSONValue.parse(Data(line.utf8)))
        XCTAssertNotNil(try? JSONValue.parse(Data(ProbeHeader(run: "r", variant: "v", scenario: "S0", build: "b",
                                                               startEpochMs: 1, processStartEpochMs: nil,
                                                               maxFramesPerSecond: 60).jsonLine.utf8)))
    }
}
