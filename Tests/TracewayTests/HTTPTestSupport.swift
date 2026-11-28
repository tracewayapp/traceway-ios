import Foundation
import XCTest
@testable import Traceway

/// Answers every request with `handler`, on another thread as a real network
/// would, and records the requests. Thread-safe.
final class FakeHTTP: HTTPTransport {
    struct Seen {
        let url: URL
        let headers: [String: String]
        let body: Data

        /// The body, gunzipped when it was sent compressed.
        var plain: Data {
            headers["Content-Encoding"] == "gzip" ? (Gzip.decompress(body) ?? Data()) : body
        }
    }

    private let lock = NSLock()
    private var seen: [Seen] = []
    private var _handler: (Seen) -> HTTPResult

    init(_ handler: @escaping (Seen) -> HTTPResult = { _ in HTTPResult(statusCode: 200) }) {
        _handler = handler
    }

    /// Answers with `statuses` in turn, then `then`.
    static func sequence(_ statuses: Int..., then: Int = 200) -> FakeHTTP {
        let lock = NSLock()
        var queue = statuses
        return FakeHTTP { _ in
            lock.lock(); defer { lock.unlock() }
            return HTTPResult(statusCode: queue.isEmpty ? then : queue.removeFirst())
        }
    }

    var handler: (Seen) -> HTTPResult {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    var requests: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func requests(to url: URL) -> [Seen] { requests.filter { $0.url == url } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        let request = Seen(url: url, headers: headers, body: body)
        lock.lock()
        seen.append(request)
        let handler = _handler
        lock.unlock()
        DispatchQueue.global().async { completion(handler(request)) }
    }
}

/// Time that moves only when a test moves it.
final class ManualClock {
    /// 2026-01-01T12:00:00Z.
    static let noon: Int64 = 1_767_268_800_000

    private let lock = NSLock()
    private var ms: Int64

    init(_ ms: Int64 = ManualClock.noon) { self.ms = ms }

    func now() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return ms
    }

    func advance(_ deltaMs: Int64) {
        lock.lock()
        ms += deltaMs
        lock.unlock()
    }
}

/// Runs `start` and waits up to `timeout` for it to call its completion.
func completes(within timeout: TimeInterval = 5, _ start: (@escaping () -> Void) -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    start { done.signal() }
    return done.wait(timeout: .now() + timeout) == .success
}

/// The recording segments of one upload to `/api/recordings`.
func segments(of request: FakeHTTP.Seen) -> [[String: JSON]] {
    ((try? JSON.parse(request.plain))?["segments"]?.array ?? []).compactMap { $0.object }
}

/// A scratch directory of its own, removed when the test ends.
func scratchDirectory(_ test: XCTestCase) -> URL {
    let url = temporaryDirectory()
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// The names of the files in `directory`, sorted.
func fileNames(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}
