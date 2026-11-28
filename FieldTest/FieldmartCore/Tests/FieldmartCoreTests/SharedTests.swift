import Foundation
import XCTest
@testable import FieldmartCore

/// The vendored shared files (`FieldTest/shared/`, from `tools/bin/sync-shared`):
/// the app's texts against `labels.json`, the tick model against
/// `reference/ticks.json`, and the decoders against the data API's real
/// answers (`FM_SAMPLES`, written by `harness/test/fixture-samples.mjs`).
final class SharedTests: XCTestCase {
    private func shared(_ name: String) throws -> JSONValue {
        let url = JourneyTests.sharedDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no shared/\(name) (run tools/bin/sync-shared)")
        }
        return try JSONValue.parse(Data(contentsOf: url))
    }

    func testTextsAreTheSharedLabels() throws {
        let labels = try shared("labels.json")
        func label(_ path: String) -> String? {
            var node: JSONValue? = labels
            for key in path.split(separator: ".") { node = node?[String(key)] }
            return node?.string
        }
        func list(_ path: String) -> [String] {
            var node: JSONValue? = labels
            for key in path.split(separator: ".") { node = node?[String(key)] }
            return (node?.array ?? []).compactMap { $0.string }
        }
        let expected: [(String, String)] = [
            ("app.name", FMText.appName),
            ("nav.home", FMText.tabs["fm-nav-home"]!), ("nav.markets", FMText.tabs["fm-nav-markets"]!),
            ("nav.feed", FMText.tabs["fm-nav-feed"]!), ("nav.checkout", FMText.tabs["fm-nav-checkout"]!),
            ("nav.more", FMText.tabs["fm-nav-more"]!), ("nav.back", FMText.back),
            ("home.title", FMText.appName), ("home.search", FMText.Home.search), ("home.deals", FMText.Home.deals),
            ("home.grid", FMText.Home.grid), ("home.new", FMText.Home.new), ("home.sale", FMText.Home.sale),
            ("home.reviews", FMText.Home.reviews(0).replacingOccurrences(of: "0", with: "{n}")),
            ("product.galleryCounter", FMText.Product.galleryCounter(1, of: 2)
                .replacingOccurrences(of: "1", with: "{i}").replacingOccurrences(of: "2", with: "{total}")),
            ("product.readMore", FMText.Product.readMore), ("product.readLess", FMText.Product.readLess),
            ("product.size", FMText.Product.size), ("product.colour", FMText.Product.colour),
            ("product.quantity", FMText.Product.quantity(0).replacingOccurrences(of: "0", with: "{n}")),
            ("product.stock", FMText.Product.stock(0).replacingOccurrences(of: "0", with: "{n}")),
            ("product.reviews", FMText.Product.reviews), ("product.helpful", FMText.Product.helpful),
            ("product.add", FMText.Product.add), ("product.added", FMText.Product.added),
            ("markets.title", FMText.Markets.title),
            ("markets.polls", FMText.Markets.polls(0).replacingOccurrences(of: "0", with: "{n}")),
            ("markets.watchlist", FMText.Markets.watchlist), ("markets.orderBook", FMText.Markets.orderBook),
            ("markets.openBook", FMText.Markets.openBook), ("markets.bids", FMText.Markets.bids),
            ("markets.asks", FMText.Markets.asks), ("markets.close", FMText.Markets.close),
            ("feed.title", FMText.Feed.title), ("feed.jumpEnd", FMText.Feed.jumpEnd),
            ("feed.jumpStart", FMText.Feed.jumpStart), ("feed.goTo", FMText.Feed.goTo), ("feed.go", FMText.Feed.go),
            ("feed.refresh", FMText.Feed.refresh),
            ("feed.header", FMText.Feed.header(0).replacingOccurrences(of: "0", with: "{n}")),
            ("checkout.title", FMText.Checkout.title), ("checkout.name", FMText.Checkout.name),
            ("checkout.email", FMText.Checkout.email), ("checkout.phone", FMText.Checkout.phone),
            ("checkout.account", FMText.Checkout.account), ("checkout.password", FMText.Checkout.password),
            ("checkout.address", FMText.Checkout.address), ("checkout.city", FMText.Checkout.city),
            ("checkout.postcode", FMText.Checkout.postcode), ("checkout.country", FMText.Checkout.country),
            ("checkout.countryPicker", FMText.Checkout.countryPicker), ("checkout.date", FMText.Checkout.date),
            ("checkout.datePicker", FMText.Checkout.datePicker), ("checkout.window", FMText.Checkout.window),
            ("checkout.door", FMText.Checkout.door), ("checkout.gift", FMText.Checkout.gift),
            ("checkout.giftNote", FMText.Checkout.giftNote), ("checkout.card", FMText.Checkout.card),
            ("checkout.expiry", FMText.Checkout.expiry), ("checkout.cvv", FMText.Checkout.cvv),
            ("checkout.cardName", FMText.Checkout.cardName), ("checkout.saveCard", FMText.Checkout.saveCard),
            ("checkout.tip", FMText.Checkout.tip),
            ("checkout.tipValue", FMText.Checkout.tipValue(0).replacingOccurrences(of: "0", with: "{n}")),
            ("checkout.promo", FMText.Checkout.promo), ("checkout.summary", FMText.Checkout.summary),
            ("checkout.loyalty", FMText.Checkout.loyalty), ("checkout.terms", FMText.Checkout.terms),
            ("checkout.agree", FMText.Checkout.agree), ("checkout.menu", FMText.Checkout.menu),
            ("checkout.edit", FMText.Checkout.edit), ("checkout.done", FMText.Checkout.done),
            ("checkout.rating", FMText.Checkout.rating), ("checkout.notes", FMText.Checkout.notes),
            ("checkout.place", FMText.Checkout.place), ("checkout.success", FMText.Checkout.success),
            ("checkout.successDetail", FMText.Checkout.successDetail("{order}")),
            ("search.title", FMText.Search.title), ("search.field", FMText.Search.field),
            ("search.recent", FMText.Search.recent), ("search.empty", FMText.Search.empty),
            ("more.title", FMText.More.title), ("more.diagnostics", FMText.More.diagnostics),
            ("diag.title", FMText.Diag.title), ("diag.run", FMText.Diag.run), ("diag.variant", FMText.Diag.variant),
            ("diag.scenario", FMText.Diag.scenario), ("diag.build", FMText.Diag.build),
            ("diag.session", FMText.Diag.session),
        ]
        for (path, text) in expected {
            XCTAssertEqual(label(path), text, path)
        }
        XCTAssertEqual(list("markets.timeframes"), FMText.Markets.timeframes)
        XCTAssertEqual(list("checkout.sections"), FMText.Checkout.sections)
        XCTAssertEqual(list("checkout.windows"), FMText.Checkout.windows)
        XCTAssertEqual(list("checkout.menuItems"), FMText.Checkout.menuItems)
        for (id, text) in FMText.Diag.buttons {
            XCTAssertEqual(labels["diag"]?["buttons"]?[id]?.string, text, id)
        }
        // The loyalty number is a sentinel of the journey.
        let journey = try shared("journey.json")
        XCTAssertTrue((journey["sentinels"]?.array ?? []).contains(.string(FMText.loyaltyNumber)))
    }

    func testTicksMatchTheReference() throws {
        let reference = try shared("reference/ticks.json")
        let seed = try XCTUnwrap(reference["seed"]?.int)
        XCTAssertEqual(UInt32(seed), TickModel.baseSeed)
        let symbols = try XCTUnwrap(reference["symbols"]?.array)
        XCTAssertEqual(symbols.count, 3)
        for symbol in symbols {
            let k = try XCTUnwrap(symbol["k"]?.int)
            let start = try XCTUnwrap(symbol["startCents"]?.int)
            let ticks = (symbol["ticks"]?.array ?? []).compactMap { $0.int }
            XCTAssertEqual(ticks.count, 200)
            XCTAssertEqual(TickModel.series(symbol: k, startCents: start, count: ticks.count), ticks, "symbol \(k)")
        }
    }

    /// The data API's answers, decoded as the app decodes them.
    func testDecodersReadTheDataAPI() throws {
        guard let dir = ProcessInfo.processInfo.environment["FM_SAMPLES"] else {
            throw XCTSkip("FM_SAMPLES not set (node harness/test/fixture-samples.mjs <dir>)")
        }
        func sample(_ name: String) throws -> JSONValue {
            try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".json")))
        }
        let page = try sample("products-0")
        let products = Fixtures.products(page)
        XCTAssertEqual(products.count, 40)
        XCTAssertEqual(products.first?.id, 1)
        XCTAssertEqual(products[16].id, 17)
        XCTAssertEqual(Fixtures.total(page), 2000)
        let category = Fixtures.products(try sample("products-cat3-0"))
        XCTAssertTrue(category.allSatisfy { $0.categoryId == 3 })

        let detail = try XCTUnwrap(ProductDetail(json: try sample("product-17")))
        XCTAssertEqual(detail.product.title, "Cedar Oak Desk Lamp")
        XCTAssertEqual(detail.product.brand, "Vellowmark")
        XCTAssertEqual(FMFormat.price(detail.product.priceCents), "$104.00")
        XCTAssertEqual(detail.product.imageCount, 8)
        XCTAssertEqual(detail.sizes.count, 6)
        XCTAssertEqual(detail.colours.count, 8)
        XCTAssertEqual(detail.colourHex.count, 8)
        XCTAssertTrue(detail.colourHex.allSatisfy { $0.hasPrefix("#") && $0.count == 7 })
        XCTAssertGreaterThan(detail.stock, 0)
        XCTAssertGreaterThan(detail.description.count, 600)

        let reviews = Fixtures.reviews(try sample("reviews-17-0"))
        XCTAssertEqual(reviews.count, 50)
        XCTAssertEqual(reviews.first?.id, "r17-0")
        XCTAssertEqual(Fixtures.reviews(try sample("reviews-17-9")).last?.id, "r17-499")

        let categories = Fixtures.categories(try sample("categories"))
        XCTAssertEqual(categories.map(\.id), Array(0..<12))
        XCTAssertEqual(categories.first?.name, "Outdoor")
        XCTAssertEqual(categories[7].name, "Lighting")

        let deals = Fixtures.deals(try sample("deals"))
        XCTAssertEqual(deals.count, 20)
        XCTAssertEqual(deals.first, Deal(productId: 17, discountPercent: 25, badge: "pct-25"))

        let hero = Fixtures.hero(try sample("hero"))
        XCTAssertEqual(hero.count, 8)
        XCTAssertEqual(hero.first?.image, "img/hero/1/1600.jpg")

        let feed = Fixtures.feed(try sample("feed-0"), cursor: 0)
        XCTAssertEqual(feed.count, 100)
        XCTAssertEqual(feed.map(\.index), Array(0..<100))
        XCTAssertEqual(feed[0].kind, .header)
        XCTAssertEqual(feed[0].title, "Week 1")
        XCTAssertEqual(feed[50].kind, .header)
        XCTAssertEqual(feed[1].title, "HARS moved up 0.18 %")
        XCTAssertEqual(feed[1].kind, .alert)
        XCTAssertEqual(feed[1].spark.count, 16)
        XCTAssertEqual(feed[2].title, "Payment received for FM-977457")
        XCTAssertTrue(feed.filter { $0.kind == .shipment }.allSatisfy { $0.progress >= 0 && $0.progress <= 1 && $0.productId != nil })
        let middle = Fixtures.feed(try sample("feed-5000"), cursor: 5000)
        XCTAssertEqual(middle[0].index, 5000)
        XCTAssertEqual(middle[0].title, "Week 101")
        XCTAssertEqual(middle[1].title, "Message from Tomas V.")
        XCTAssertEqual(middle[1].kind, .message)
        XCTAssertGreaterThanOrEqual(middle[1].lines.count, 3)
        XCTAssertEqual(Fixtures.feed(try sample("feed-9900"), cursor: 9900).last?.index, 9999)

        let symbols = Fixtures.symbols(try sample("symbols"))
        XCTAssertEqual(symbols.count, 300)
        XCTAssertEqual(symbols.first?.symbol, "HEAM")
        let candles = Fixtures.candles(try sample("candles-0-1H"))
        XCTAssertEqual(candles.count, 5000)
        XCTAssertEqual(candles.last?.close, symbols.first?.startCents)

        let search = Fixtures.products(try sample("search-trail"))
        XCTAssertEqual(search.count, 50)
        let promos = Fixtures.promos(try sample("promos-FIELD1"))
        XCTAssertEqual(promos.prefix(2).map(\.code), ["FIELD10", "FIELD15"])
        XCTAssertEqual(promos.first?.label, "10 % off your order")
        let countries = Fixtures.countries(try sample("countries"))
        XCTAssertEqual(countries.count, 200)
        XCTAssertTrue(countries.contains("Norway"))
        let terms = try XCTUnwrap(Fixtures.terms(try sample("terms")))
        XCTAssertEqual(terms.title, "Terms and conditions")
        XCTAssertGreaterThan(terms.text.count, 2900)
    }
}
