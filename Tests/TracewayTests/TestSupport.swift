import Foundation
import XCTest
@testable import Traceway

/// A Traceway server in memory: answers OpAMP polls with `remoteConfig`
/// and records every request.
final class FakeServer: HTTPTransport {
    struct Request {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    /// The settings document the OpAMP endpoint serves, if any.
    var remoteConfig: String?
    var recordingsStatus = 200

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func requests(to path: String) -> [Request] { requests.filter { $0.url.path == path } }

    /// The recording segments uploaded so far.
    var segments: [[String: JSON]] {
        requests(to: "/api/recordings").flatMap { request -> [[String: JSON]] in
            var body = request.body
            if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(body) { body = plain }
            return (try? JSON.parse(body))?["segments"]?.array?.compactMap { $0.object } ?? []
        }
    }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval,
              completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        _requests.append(Request(url: url, headers: headers, body: body))
        let config = remoteConfig
        let recordingsStatus = self.recordingsStatus
        lock.unlock()
        DispatchQueue.global().async {
            switch url.path {
            case "/api/otel/v1/opamp":
                var remote: RemoteConfig?
                if let config = config {
                    remote = RemoteConfig(
                        configMap: ["traceway": AgentConfigObject(body: Array(config.utf8), contentType: "application/json")],
                        configHash: Array(Ids.fingerprint64(config).utf8)
                    )
                }
                let reply = encodeServerToAgent(remoteConfig: remote, heartbeatIntervalSeconds: 300)
                completion(HTTPResult(statusCode: 200, body: Data(reply)))
            case "/api/recordings":
                completion(HTTPResult(statusCode: recordingsStatus))
            default:
                completion(HTTPResult(statusCode: 200))
            }
        }
    }
}

/// Stands in for the wireframe recorder: every window has one frame.
final class FakeReplaySource: ReplaySource {
    private let lock = NSLock()
    private var running = false
    private(set) var clips: [String] = []

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() { lock.lock(); running = true; lock.unlock() }
    func stop() { lock.lock(); running = false; lock.unlock() }
    func clearBuffer() {}

    func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool { isRunning }

    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload? {
        lock.lock()
        clips.append(clipId)
        lock.unlock()
        let start = sinceMs ?? Clock.nowMs()
        return SessionRecordingPayload(
            clipId: clipId,
            events: [["type": 4, "data": ["href": "/", "width": 390, "height": 844], "timestamp": JSON(start)]],
            startedAtMs: start,
            endedAtMs: untilMs,
            approxBytes: 64
        )
    }
}

/// Waits until `condition` holds, polling the run loop.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("traceway-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
