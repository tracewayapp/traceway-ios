import Foundation

// The fixture data of `02-APP-SPEC.md` §3.1, read leniently from
// `JSONValue`: a missing field gets a neutral default instead of failing
// the page.

public struct Product: Equatable, Hashable {
    public var id: Int
    public var title: String
    public var brand: String
    public var categoryId: Int
    public var priceCents: Int
    public var compareAtCents: Int?
    public var rating: Double
    public var reviewCount: Int
    public var badges: [String]
    public var imageCount: Int

    public init(id: Int, title: String, brand: String = "", categoryId: Int = 0, priceCents: Int = 0,
                compareAtCents: Int? = nil, rating: Double = 0, reviewCount: Int = 0, badges: [String] = [],
                imageCount: Int = 1) {
        self.id = id
        self.title = title
        self.brand = brand
        self.categoryId = categoryId
        self.priceCents = priceCents
        self.compareAtCents = compareAtCents
        self.rating = rating
        self.reviewCount = reviewCount
        self.badges = badges
        self.imageCount = imageCount
    }

    public init?(json: JSONValue) {
        guard let id = json.first("id", "productId")?.int else { return nil }
        self.init(
            id: id,
            title: json.first("title", "name")?.string ?? "Product \(id)",
            brand: json["brand"]?.string ?? "",
            categoryId: json.first("categoryId", "category")?.int ?? 0,
            priceCents: json.first("priceCents", "price")?.int ?? 0,
            compareAtCents: json.first("compareAtCents", "compareAt")?.int,
            rating: json["rating"]?.double ?? 0,
            reviewCount: json["reviewCount"]?.int ?? 0,
            badges: (json["badges"]?.array ?? []).compactMap { $0.string },
            imageCount: max(1, json["imageCount"]?.int ?? 1)
        )
    }

    /// The badge shown on a grid cell, if any: "New" or "Sale".
    public var badgeText: String? {
        guard let badge = badges.first else { return nil }
        return badge.prefix(1).uppercased() + badge.dropFirst()
    }

    /// Percent off when `compareAtCents` is higher than the price.
    public var discountPercent: Int? {
        guard let compare = compareAtCents, compare > priceCents, compare > 0 else { return nil }
        return Int((Double(compare - priceCents) * 100 / Double(compare)).rounded())
    }
}

public struct ProductDetail: Equatable {
    public var product: Product
    public var description: String
    public var sizes: [String]
    public var colours: [String]
    /// `#rrggbb` per colour (same order as `colours`), when the data has it.
    public var colourHex: [String]
    public var stock: Int

    public init(product: Product, description: String = "", sizes: [String] = [], colours: [String] = [],
                colourHex: [String] = [], stock: Int = 0) {
        self.product = product
        self.description = description
        self.sizes = sizes
        self.colours = colours
        self.colourHex = colourHex
        self.stock = stock
    }

    public init?(json: JSONValue) {
        let source = json["product"] ?? json
        guard let product = Product(json: source) else { return nil }
        func names(_ key: String) -> [String] {
            (source[key]?.array ?? []).compactMap { $0.string ?? $0.first("name", "label", "id")?.string }
        }
        let colourKey = source["colours"] != nil ? "colours" : "colors"
        self.init(
            product: product,
            description: source["description"]?.string ?? "",
            sizes: names("sizes"),
            colours: names(colourKey),
            colourHex: (source[colourKey]?.array ?? []).map { $0["hex"]?.string ?? "" },
            stock: source["stock"]?.int ?? 0
        )
    }
}

public struct Review: Equatable, Hashable {
    /// `r17-0`: the automation id of its Helpful button is `fm-product-helpful-r17-0`.
    public var id: String
    public var author: String
    public var avatarId: Int
    public var date: String
    public var rating: Int
    public var text: String

    public init(id: String, author: String, avatarId: Int, date: String, rating: Int, text: String) {
        self.id = id
        self.author = author
        self.avatarId = avatarId
        self.date = date
        self.rating = rating
        self.text = text
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.string else { return nil }
        self.init(
            id: id,
            author: json.first("author", "name")?.string ?? "",
            avatarId: json.first("avatarId", "avatar")?.int ?? 1,
            date: json["date"]?.string ?? "",
            rating: json["rating"]?.int ?? 0,
            text: json["text"]?.string ?? ""
        )
    }
}

public struct ProductCategory: Equatable, Hashable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.int else { return nil }
        self.init(id: id, name: json.first("name", "title", "label")?.string ?? "Category \(id)")
    }
}

public struct Deal: Equatable, Hashable {
    public var productId: Int
    public var discountPercent: Int
    /// The badge picture, `/fx/img/badge/<badge>.png` (`pct-25`).
    public var badge: String

    public init(productId: Int, discountPercent: Int, badge: String = "sale") {
        self.productId = productId
        self.discountPercent = discountPercent
        self.badge = badge
    }

    public init?(json: JSONValue) {
        guard let id = json.first("productId", "id")?.int else { return nil }
        let percent = json.first("pct", "discountPercent", "discount", "percent")?.int ?? 0
        self.init(productId: id, discountPercent: percent, badge: json["badge"]?.string ?? "pct-\(percent)")
    }
}

/// A hero slide (`GET /fx/api/hero`).
public struct HeroSlide: Equatable {
    public var id: Int
    public var title: String
    public var subtitle: String
    /// Relative to `fmFixtures` (`img/hero/1/1600.jpg`).
    public var image: String

    public init(id: Int, title: String, subtitle: String, image: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.image = image
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.int else { return nil }
        self.init(id: id, title: json["title"]?.string ?? "", subtitle: json["subtitle"]?.string ?? "",
                  image: json["image"]?.string ?? "img/hero/\(id)/1600.jpg")
    }
}

/// One row of the Feed (`02-APP-SPEC.md` §2.4).
public struct FeedRow: Equatable, Hashable {
    public enum Kind: String {
        case order, shipment, alert, message, header
    }

    public var index: Int
    public var kind: Kind
    public var title: String
    public var text: String
    public var time: String
    public var productId: Int?
    public var progress: Double
    public var symbol: String?
    public var priceCents: Int?
    public var avatarId: Int?
    public var lines: [String]
    public var week: Int?
    /// A price alert's sparkline, in cents.
    public var spark: [Int]
    /// An order update's icon name (`check`, `truck` …).
    public var icon: String?

    public init(index: Int, kind: Kind, title: String = "", text: String = "", time: String = "",
                productId: Int? = nil, progress: Double = 0, symbol: String? = nil, priceCents: Int? = nil,
                avatarId: Int? = nil, lines: [String] = [], week: Int? = nil, spark: [Int] = [], icon: String? = nil) {
        self.index = index
        self.kind = kind
        self.title = title
        self.text = text
        self.time = time
        self.productId = productId
        self.progress = progress
        self.symbol = symbol
        self.priceCents = priceCents
        self.avatarId = avatarId
        self.lines = lines
        self.week = week
        self.spark = spark
        self.icon = icon
    }

    public static func kind(_ raw: String) -> Kind {
        let value = raw.lowercased()
        if value.hasPrefix("order") { return .order }
        if value.hasPrefix("ship") { return .shipment }
        if value.contains("alert") || value.hasPrefix("price") { return .alert }
        if value.hasPrefix("message") || value.hasPrefix("msg") { return .message }
        if value.contains("header") || value.hasPrefix("section") || value.hasPrefix("week") { return .header }
        return .order
    }

    /// Feed rows have no index of their own: it is their position.
    public init?(json: JSONValue, fallbackIndex: Int) {
        let index = json.first("index", "i", "row")?.int ?? fallbackIndex
        let kind = FeedRow.kind(json.first("type", "kind")?.string ?? "order")
        var lines = (json["lines"]?.array ?? []).compactMap { $0.string }
        let text = json.first("detail", "text", "body", "message")?.string ?? ""
        if lines.isEmpty, kind == .message, !text.isEmpty { lines = text.components(separatedBy: "\n") }
        // `progress` is a percentage (0–100) in the data.
        var progress = json["progress"]?.double ?? 0
        if progress > 1 { progress /= 100 }
        self.init(
            index: index,
            kind: kind,
            title: json.first("label", "title", "headline")?.string ?? "",
            text: text,
            time: json.first("time", "timestamp", "date", "at")?.string ?? "",
            productId: json["productId"]?.int,
            progress: progress,
            symbol: json["symbol"]?.string,
            priceCents: json.first("priceCents", "price")?.int,
            avatarId: json.first("avatarId", "avatar")?.int,
            lines: lines,
            week: json["week"]?.int,
            spark: (json["spark"]?.array ?? []).compactMap { $0.int },
            icon: json["icon"]?.string
        )
    }
}

public struct MarketSymbol: Equatable, Hashable {
    public var symbol: String
    public var name: String
    public var seedIndex: Int
    public var startCents: Int

    public init(symbol: String, name: String, seedIndex: Int, startCents: Int) {
        self.symbol = symbol
        self.name = name
        self.seedIndex = seedIndex
        self.startCents = startCents
    }

    public init?(json: JSONValue, fallbackIndex: Int) {
        guard let symbol = json["symbol"]?.string else { return nil }
        self.init(
            symbol: symbol,
            name: json["name"]?.string ?? symbol,
            seedIndex: json["seedIndex"]?.int ?? fallbackIndex,
            startCents: max(1, json.first("startCents", "priceCents", "price")?.int ?? 10_000)
        )
    }
}

/// `[t, o, h, l, c]`, prices in cents.
public struct Candle: Equatable {
    public var t: Int64
    public var open: Int
    public var high: Int
    public var low: Int
    public var close: Int

    public init(t: Int64, open: Int, high: Int, low: Int, close: Int) {
        self.t = t
        self.open = open
        self.high = high
        self.low = low
        self.close = close
    }

    public init?(json: JSONValue) {
        if let parts = json.array, parts.count >= 5,
           let t = parts[0].int64, let o = parts[1].int, let h = parts[2].int, let l = parts[3].int,
           let c = parts[4].int {
            self.init(t: t, open: o, high: h, low: l, close: c)
            return
        }
        guard let t = json["t"]?.int64, let o = json["o"]?.int, let h = json["h"]?.int, let l = json["l"]?.int,
              let c = json["c"]?.int else { return nil }
        self.init(t: t, open: o, high: h, low: l, close: c)
    }

    /// Folds a new price into this candle.
    public mutating func update(price: Int) {
        close = price
        high = max(high, price)
        low = min(low, price)
    }
}

public struct Promo: Equatable, Hashable {
    public var code: String
    public var label: String

    public init(code: String, label: String) {
        self.code = code
        self.label = label
    }

    public init?(json: JSONValue) {
        if let code = json.string {
            self.init(code: code, label: code)
            return
        }
        guard let code = json.first("code", "id")?.string else { return nil }
        self.init(code: code, label: json.first("label", "title", "description")?.string ?? code)
    }
}

/// Parsers for whole responses.
public enum Fixtures {
    public static func products(_ json: JSONValue) -> [Product] {
        json.items("products").compactMap(Product.init(json:))
    }

    public static func reviews(_ json: JSONValue) -> [Review] {
        json.items("reviews").compactMap(Review.init(json:))
    }

    public static func categories(_ json: JSONValue) -> [ProductCategory] {
        json.items("categories").compactMap(ProductCategory.init(json:))
    }

    public static func deals(_ json: JSONValue) -> [Deal] {
        json.items("deals").compactMap(Deal.init(json:))
    }

    public static func feed(_ json: JSONValue, cursor: Int) -> [FeedRow] {
        json.items("rows", "feed").enumerated().compactMap { FeedRow(json: $0.element, fallbackIndex: cursor + $0.offset) }
    }

    public static func symbols(_ json: JSONValue) -> [MarketSymbol] {
        json.items("symbols").enumerated().compactMap { MarketSymbol(json: $0.element, fallbackIndex: $0.offset) }
    }

    public static func candles(_ json: JSONValue) -> [Candle] {
        json.items("candles").compactMap(Candle.init(json:))
    }

    public static func promos(_ json: JSONValue) -> [Promo] {
        json.items("promos", "codes").compactMap(Promo.init(json:))
    }

    public static func countries(_ json: JSONValue) -> [String] {
        json.items("countries").compactMap { $0.string ?? $0.first("name", "label")?.string }
    }

    public static func hero(_ json: JSONValue) -> [HeroSlide] {
        json.items("slides", "hero").compactMap(HeroSlide.init(json:))
    }

    /// `{title, text}` of the terms dialog.
    public static func terms(_ json: JSONValue) -> (title: String, text: String)? {
        guard let text = json["text"]?.string else { return nil }
        return (json["title"]?.string ?? "", text)
    }

    /// `{ "n": <server tick>, "count": 300 }`.
    public static func quoteTick(_ json: JSONValue) -> Int? {
        json["n"]?.int
    }

    /// `{ "order": "FM-123456" }`.
    public static func orderNumber(_ json: JSONValue) -> String? {
        json.first("order", "orderNumber", "id")?.string
    }

    /// The total a page response reports, if any.
    public static func total(_ json: JSONValue) -> Int? {
        json.first("total", "count", "totalCount")?.int
    }
}
