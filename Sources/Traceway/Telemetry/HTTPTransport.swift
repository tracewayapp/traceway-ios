import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The answer to one request. `statusCode` is 0 when no answer came
/// (offline, timed out, cancelled).
struct HTTPResult {
    var statusCode: Int
    /// Lowercased header names.
    var headers: [String: String] = [:]
    var body: Data = Data()

    static let noAnswer = HTTPResult(statusCode: 0)

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// No answer, throttled or a server error: worth sending again later.
    var isTransientFailure: Bool {
        statusCode == 0 || statusCode == 408 || statusCode == 429 || statusCode >= 500
    }

    /// The longest `Retry-After` honoured: a day.
    static let maxRetryAfterMs: Int64 = 86_400_000

    /// `Retry-After` in milliseconds, when the server sent seconds; at most
    /// a day, whatever a proxy or captive portal answers.
    var retryAfterMs: Int64? {
        guard let raw = headers["retry-after"], let seconds = Int64(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return nil }
        return min(seconds, HTTPResult.maxRetryAfterMs / 1000) * 1000
    }
}

/// How the SDK's own requests leave the device: OpAMP polls, recording
/// uploads and queued OTLP batches. Tests replace it with a fake server.
/// The completion may run on any thread.
protocol HTTPTransport: AnyObject {
    func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval,
        completion: @escaping (HTTPResult) -> Void
    )
}

/// The URLSession the SDK sends with. Ephemeral and without a cache, so
/// request bodies are not kept in memory or on disk by the system, and
/// marked so the SDK's network instrumentation leaves these requests out.
final class URLSessionTransport: HTTPTransport {
    static let shared = URLSessionTransport()

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval,
        completion: @escaping (HTTPResult) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(TracewaySDK.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        let task = session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(.noAnswer)
                return
            }
            var lowered: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    lowered[name.lowercased()] = text
                }
            }
            completion(HTTPResult(statusCode: http.statusCode, headers: lowered, body: data ?? Data()))
        }
        task.resume()
    }
}

/// The name and version the SDK reports itself as.
enum TracewaySDK {
    static let name = "traceway-ios"
    static let version = "2.1.0"
    static let userAgent = "\(name)/\(version)"
}

/// Passes every request on, and says once per process, whatever `debug`
/// says, when the Traceway server at `base` rejects the project token or
/// does not take iOS 2.x telemetry: both leave the dashboard empty, and
/// nothing else would tell the developer why.
final class ServerAnswerWatch: HTTPTransport {
    private let inner: HTTPTransport
    private let base: String

    init(inner: HTTPTransport, base: String) {
        self.inner = inner
        self.base = base
    }

    func post(
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval,
        completion: @escaping (HTTPResult) -> Void
    ) {
        let base = self.base
        inner.post(url: url, headers: headers, body: body, timeout: timeout) { result in
            if result.statusCode == 401 || result.statusCode == 404 {
                ServerAnswerWatch.observe(result.statusCode, url: url, base: base)
            }
            completion(result)
        }
    }

    static func observe(_ status: Int, url: URL, base: String) {
        let text = url.absoluteString
        guard text.hasPrefix(base + "/api/") else { return }
        if status == 401 {
            Log.once("token rejected", "the server rejected the project token (HTTP 401) at \(base). "
                + "Copy the token from the project's Connection page.")
        } else if status == 404, text == base + "/api/otel/v1/logs" {
            Log.once("no otlp", "\(base) does not accept iOS 2.x telemetry (HTTP 404 on /api/otel/v1/logs): "
                + "the server needs OTLP support; on an older server stay on 0.1.x.")
        }
    }
}
