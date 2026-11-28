import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The routes of the data API and the pictures (`02-APP-SPEC.md` §3.1, §3.2),
/// under the `fmFixtures` base (`http://127.0.0.1:18190/fx`).
public struct FixtureURLs {
    public let base: String

    public init(base: String) {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.base = trimmed
    }

    private func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    public func products(page: Int, size: Int = 40, category: Int? = nil) -> URL {
        var query = [("page", String(page)), ("size", String(size))]
        if let category = category { query.append(("category", String(category))) }
        return url("/api/products", query)
    }

    public func product(_ id: Int) -> URL { url("/api/products/\(id)") }

    public func reviews(product id: Int, page: Int, size: Int = 50) -> URL {
        url("/api/products/\(id)/reviews", [("page", String(page)), ("size", String(size))])
    }

    public var categories: URL { url("/api/categories") }
    public var deals: URL { url("/api/deals") }

    public func feed(cursor: Int, size: Int = 100) -> URL {
        url("/api/feed", [("cursor", String(cursor)), ("size", String(size))])
    }

    public var symbols: URL { url("/api/symbols") }

    public func candles(symbol: String, timeframe: String) -> URL {
        url("/api/candles", [("symbol", symbol), ("tf", timeframe)])
    }

    public func quotes(since: Int) -> URL { url("/api/quotes", [("since", String(since))]) }
    public func search(_ text: String) -> URL { url("/api/search", [("q", text)]) }
    public func promos(_ text: String) -> URL { url("/api/promos", [("q", text)]) }
    public var countries: URL { url("/api/countries") }
    public var heroSlides: URL { url("/api/hero") }
    public var terms: URL { url("/api/terms") }

    /// A path the data gives relative to the fixture base (`img/hero/1/1600.jpg`).
    public func relative(_ path: String) -> URL {
        url("/" + path.drop(while: { $0 == "/" }))
    }
    public var checkout: URL { url("/api/checkout") }
    public var fail500: URL { url("/api/fail/500") }
    public func slow(ms: Int) -> URL { url("/api/slow", [("ms", String(ms))]) }

    /// Product `id`'s picture `index` at 160, 320 or 800 pixels.
    public func productImage(_ id: Int, index: Int = 0, size: Int = 320) -> URL {
        url("/img/p/\(id)/\(index)/\(size).jpg")
    }

    /// Hero slide 1…8 at 1600 × 900.
    public func hero(_ slide: Int) -> URL { url("/img/hero/\(slide)/1600.jpg") }

    /// Avatar 1…64 at 96 pixels.
    public func avatar(_ id: Int) -> URL {
        let clamped = ((max(1, id) - 1) % 64) + 1
        return url("/img/avatar/\(clamped)/96.jpg")
    }

    public func badge(_ name: String) -> URL { url("/img/badge/\(name).png") }
}

/// The fixture data over HTTP. Completions run on the main queue; a failed
/// request completes with nil (the screen keeps what it has).
public final class FixtureClient {
    public let urls: FixtureURLs
    public let session: URLSession

    public init(urls: FixtureURLs, session: URLSession) {
        self.urls = urls
        self.session = session
    }

    /// A session without any HTTP cache, so every request the app makes
    /// reaches the gateway (and its client span matches the gateway's log).
    public static func makeSession(maxConnections: Int = 6) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = maxConnections
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    /// GET returning the body and status. `completion` on the main queue.
    @discardableResult
    public func get(_ url: URL, completion: @escaping (Data?, Int) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: url) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion(data, status) }
        }
        task.resume()
        return task
    }

    @discardableResult
    public func json(_ url: URL, completion: @escaping (JSONValue?) -> Void) -> URLSessionDataTask {
        get(url) { data, status in
            guard let data = data, (200..<300).contains(status), let value = try? JSONValue.parse(data) else {
                completion(nil)
                return
            }
            completion(value)
        }
    }

    /// POST a JSON body; `completion` gets the parsed answer.
    public func post(_ url: URL, body: [String: Any], completion: @escaping (JSONValue?, Int) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        session.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = data.flatMap { try? JSONValue.parse($0) }
            DispatchQueue.main.async { completion(value, status) }
        }.resume()
    }
}
