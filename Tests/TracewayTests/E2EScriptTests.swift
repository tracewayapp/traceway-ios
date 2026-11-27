import Foundation
import XCTest
@testable import Traceway

/// The scripted app of the end-to-end check, `CI/e2e/run.py`: the real
/// client, sending to a running Traceway, through the phases the harness
/// checks on the server. It runs only when the harness sets
/// `TRACEWAY_E2E_DSN`, on Linux or macOS (no UIKit: taps come with a view
/// path of their own, the screen from the wireframe gallery's recording).
///
/// Prints `E2E_PHASE <name> key=value…` at each phase and then waits for
/// the harness to create `<E2E_CONTROL_DIR>/<name>.go`.
final class E2EScriptTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testScript() throws {
        guard let dsn = env["TRACEWAY_E2E_DSN"], !dsn.isEmpty else {
            throw XCTSkip("the end-to-end script runs from CI/e2e/run.py")
        }
        let script = E2EScript(
            dsn: dsn,
            control: URL(fileURLWithPath: try XCTUnwrap(env["E2E_CONTROL_DIR"]), isDirectory: true),
            state: URL(fileURLWithPath: try XCTUnwrap(env["E2E_STATE_DIR"]), isDirectory: true),
            gallery: env["E2E_GALLERY"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            otlp: env["E2E_OTLP"]
        )
        switch env["E2E_SCENARIO"] ?? "main" {
        case "main": try script.main()
        case "resume": try script.resume()
        case "standalone": try script.standalone()
        default: XCTFail("unknown scenario")
        }
    }
}

/// The phases, in the order the harness expects them.
final class E2EScript {
    let dsn: String
    let control: URL
    let state: URL
    let gallery: URL?
    let otlp: String?

    init(dsn: String, control: URL, state: URL, gallery: URL?, otlp: String?) {
        self.dsn = dsn
        self.control = control
        self.state = state
        self.gallery = gallery
        self.otlp = otlp
    }

    private var stateDirectory: URL { state.appendingPathComponent("traceway_v2", isDirectory: true) }

    // MARK: - Harness

    func phase(_ name: String, _ values: [String: String] = [:], wait: Bool = true) {
        let extra = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("E2E_PHASE \(name)\(extra.isEmpty ? "" : " " + extra)")
        fflush(stdout)
        guard wait else { return }
        let go = control.appendingPathComponent("\(name).go")
        let deadline = Date().addingTimeInterval(600)
        while !FileManager.default.fileExists(atPath: go.path) {
            if Date() > deadline {
                print("E2E_TIMEOUT \(name)")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: - The app

    static let journeyCaptureSeconds = 20

    static let journeyTrigger: JSON = [
        "id": "e2e-open-profile",
        "name": "Open profile",
        "cooldownSeconds": 0,
        "maxPerSession": 1,
        "steps": [
            ["match": ["event": ["type": "navigation", "value": "/users/{id}"]]],
            ["match": ["event": ["type": "click", "value": "#open-profile"]], "withinSeconds": 30],
            ["match": ["event": ["type": "log", "value": "Profile loaded", "mode": "contains"]], "withinSeconds": 10],
        ],
        "actions": [
            ["type": "capture", "durationSeconds": JSON(journeyCaptureSeconds), "lookbackSeconds": 30, "replay": true],
        ],
    ]

    private func options(collection: [String: Any]? = nil, telemetry: TracewayTelemetry? = nil) -> TracewayOptions {
        TracewayOptions(
            debug: true,
            version: "e2e-1.0.0",
            environment: "e2e",
            screenCapture: true,
            collection: collection,
            telemetry: telemetry
        )
    }

    private func start(_ options: TracewayOptions, dsn: String?) throws -> TracewayClient {
        let replay: ReplaySource = gallery.flatMap { try? GalleryReplaySource(directory: $0) } ?? SyntheticScreenSource()
        return try TracewayClient.start(
            connectionString: dsn,
            options: options,
            overrides: TracewayTestOverrides(
                stateDirectory: stateDirectory,
                deviceAttributes: [
                    "os.name": "ios", "os.version": "iOS 26.1", "os.major": "26",
                    "device.manufacturer": "Apple", "device.brand": "Apple", "device.model": "iPhone17,1",
                    "device.form_factor": "phone", "screen.resolution": "1206x2622", "screen.density": "3",
                ],
                opampMinPollIntervalMs: 1000,
                replaySource: replay
            )
        )
    }

    /// A tap on a button of this screen, through the selector machinery the
    /// UIKit path uses.
    private func tap(_ client: TracewayClient, id: String, text: String, screen: String) {
        let window = FakeView("UIWindow", boundary: true)
        let root = window.add(FakeView("UIView"))
        let button = root.add(FakeView("UIButton", id: id, roles: ["button"], control: true))
        let label = button.add(FakeView("UIButtonLabel", text: text, content: true))
        let path = FakePath(label)
        let (recordTaps, selectors) = client.interaction.snapshot
        let target = recordTaps ? path.describe() : nil
        var matched: Set<String> = []
        for selector in selectors where ViewSelector.parse(selector)?.matches(path) == true { matched.insert(selector) }
        client.recordTap(target: target, x: 120, y: 400, matched: matched)
    }

    /// An HTTP request as URLSessionInstrumentation reports it on iOS.
    private func request(_ url: String, status: Int) {
        guard let tracer = Traceway.tracer else { return }
        let span = tracer.spanBuilder(spanName: "GET").setSpanKind(spanKind: .client).startSpan()
        span.setAttribute(key: "http.request.method", value: "GET")
        span.setAttribute(key: "url.full", value: url)
        span.setAttribute(key: "server.address", value: URL(string: url)?.host ?? "")
        span.setAttribute(key: "http.response.status_code", value: status)
        pause(0.05)
        span.end()
    }

    struct CheckoutError: Error, CustomStringConvertible {
        let amount: Int
        var description: String { "CheckoutError: payment of \(amount) declined" }
    }

    // MARK: - Scenarios

    /// 1-5 and 7: buffered breadcrumbs, the exception, a trigger, a capture
    /// from the dashboard, remote rules, app-defined metrics; then the
    /// buffer is saved and the app is killed.
    func main() throws {
        let client = try start(options(collection: ["triggers": [E2EScript.journeyTrigger.anyValue]]), dsn: dsn)
        Traceway.setAttribute("user.id", "e2e-user")
        phase("start", ["instance": client.instanceId, "session": client.currentSessionId ?? ""], wait: false)

        // 1. Breadcrumbs stay on the device until something needs them.
        Traceway.log("e2e breadcrumb log")
        client.recordNavigation("/checkout", action: "push", from: "/")
        tap(client, id: "pay", text: "Pay now", screen: "/checkout")
        Traceway.recordAction(category: "checkout", name: "submit", data: ["step": 1])
        Traceway.track("e2e_event", attributes: ["cart.items": 3])
        request("https://api.example.com/v1/cart?id=42", status: 200)
        client.recordNavigation("/", action: "pop", from: "/checkout")
        phase("breadcrumbs_done")

        // 2. The exception brings them up, with a replay clip.
        Traceway.captureException(CheckoutError(amount: 1999))
        Traceway.flush(timeout: 10)
        phase("exception_sent")

        // 3. The trigger from the app's own settings: a navigation, a tap
        // and a log line start a capture that streams logs and replay.
        client.recordNavigation("/users/42", action: "push", from: "/")
        tap(client, id: "open-profile", text: "Open profile", screen: "/users/42")
        Traceway.log("Profile loaded for 42")
        phase("journey_started", wait: false)
        for i in 0..<(E2EScript.journeyCaptureSeconds + 6) {
            Traceway.log("e2e journey tick \(i)")
            pause(1)
        }
        Traceway.log("e2e after journey")
        Traceway.flush(timeout: 10)
        phase("journey_done")

        // 4. A capture the dashboard starts for this instance.
        for i in 0..<3 { Traceway.log("e2e pre-capture tick \(i)") }
        phase("await_capture")
        client.refreshConfig()
        for i in 0..<12 {
            Traceway.log("e2e remote tick \(i)")
            pause(0.5)
        }
        Traceway.flush(timeout: 10)
        phase("capture_running")
        client.refreshConfig()
        pause(2)
        Traceway.log("e2e after cancel")
        Traceway.flush(timeout: 10)
        phase("capture_cancelled")

        // 5. A rule from the dashboard whose click step is the selector the
        // server recorded for the tap, and one that turns replay images off.
        client.refreshConfig()
        pause(2)
        tap(client, id: "pay", text: "Pay now", screen: "/checkout")
        // 7. App-defined metrics, uploaded with the SDK's own `app.*` ones.
        Traceway.metric("e2e.checkout", value: 1234, dimensions: ["plan": "pro"])
        Traceway.count("e2e.cart_add", n: 3)
        Traceway.flush(timeout: 10)
        phase("rule_tapped")

        // 6. Going to the background saves the buffer; the app is then
        // killed without uploading it.
        Traceway.log("e2e before kill")
        let saved = DispatchSemaphore(value: 0)
        client.appPaused { saved.signal() }
        _ = saved.wait(timeout: .now() + 10)
        client.killForTesting()
        phase("killed", ["session": client.currentSessionId ?? ""], wait: false)
    }

    /// 6: the next start continues the session, a crash of the earlier run
    /// is reported, and its first error brings up the killed run's buffer.
    func resume() throws {
        writeCrashRecord()
        let client = try start(options(), dsn: dsn)
        phase("resumed", ["instance": client.instanceId, "session": client.currentSessionId ?? ""], wait: false)
        pause(1)
        Traceway.captureMessage("e2e after restart")
        Traceway.captureException(CheckoutError(amount: 5))
        Traceway.flush(timeout: 10)
        phase("resume_done")
        Traceway.shutdown()
    }

    /// 7: with another OpenTelemetry backend and no connection string.
    func standalone() throws {
        guard let otlp = otlp else { return }
        let client = try start(options(telemetry: TracewayTelemetry(url: otlp)), dsn: nil)
        phase("standalone", ["instance": client.instanceId], wait: false)
        Traceway.log("e2e standalone log")
        Traceway.captureException(CheckoutError(amount: 7))
        Traceway.flush(timeout: 10)
        phase("standalone_done")
        Traceway.shutdown()
    }

    /// A fatal signal of the earlier run, as the signal handler writes it on
    /// a device: the binary images and the addresses the server symbolicates.
    private func writeCrashRecord() {
        let dir = state.appendingPathComponent(CrashRecordStore.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = [
            "TRACEWAY_SIGNAL_V1",
            "signal=11",
            "time=\(Int(Date().timeIntervalSince1970) - 30)",
            "appVersion=e2e-1.0.0",
            "attr.device.model=iPhone17,1",
            "attr.os.name=ios",
            "arch=arm64",
            "---IMAGES---",
            "100000000 4000 2dd71042118432be8f92dd4e3d3fe24a TracewayExample",
            "1a0000000 80000 4c4c44f855553144a1f4b5f0d3a1c2d3 UIKitCore",
            "---FRAMES---",
            "0x100000460",
            "0x100000478",
            "0x1a0001234",
        ].joined(separator: "\n")
        try? record.write(to: dir.appendingPathComponent("crash-1.tw"), atomically: true, encoding: .utf8)
    }
}

// MARK: - Screens without UIKit

/// The wireframe gallery's recording, played back as if this were the
/// screen: a clip is a full snapshot of the page at the clip's start, then
/// the recording's events up to its end, moved to now. The recording
/// repeats.
final class GalleryReplaySource: ReplaySource {
    private let events: [JSON]
    private let first: Int64
    private let length: Int64
    private let origin = Clock.nowMs()
    private let lock = NSLock()
    private var running = false

    init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("events.json"))
        events = try JSON.parse(data).array ?? []
        first = Int64(events.first?["timestamp"]?.int ?? 0)
        let last = Int64(events.last?["timestamp"]?.int ?? 0)
        length = max(1, last - first)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() { lock.lock(); running = true; lock.unlock() }
    func stop() { lock.lock(); running = false; lock.unlock() }
    func clearBuffer() {}
    func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool { isRunning && !events.isEmpty }

    /// Where `ms` falls in the recording.
    private func recordingTime(_ ms: Int64) -> Int64 { first + ((ms - origin) % length + length) % length }

    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload? {
        guard !events.isEmpty else { return nil }
        let end = untilMs ?? Clock.nowMs()
        let start = max(sinceMs ?? end - 10_000, end - 60_000)
        let from = recordingTime(start)
        // The page as it is at `from`.
        let mirror = Mirror()
        var meta: JSON?
        var index = 0
        while index < events.count, Int64(events[index]["timestamp"]?.int ?? 0) <= from {
            let event = events[index]
            if event["type"]?.int == 4 { meta = event["data"] }
            mirror.play([event])
            index += 1
        }
        guard let document = mirror.byId[documentNodeId] else { return nil }
        var out: [JSON] = [
            ["type": 4, "data": meta ?? ["href": "/", "width": 390, "height": 844], "timestamp": JSON(start)],
            ["type": 2, "data": ["node": document.serialized(), "initialOffset": ["left": 0, "top": 0]],
             "timestamp": JSON(start)],
        ]
        let shift = start - from
        while index < events.count {
            let event = events[index]
            let ts = Int64(event["timestamp"]?.int ?? 0) + shift
            if ts >= end { break }
            if var object = event.object, event["type"]?.int == 3 {
                object["timestamp"] = JSON(ts)
                out.append(.object(object))
            }
            index += 1
        }
        out.append(["type": 5, "data": ["tag": "traceway.end", "payload": [:]], "timestamp": JSON(end)])
        return SessionRecordingPayload(clipId: clipId, events: out, startedAtMs: start, endedAtMs: end,
                             approxBytes: JSON.array(out).encoded().utf8.count)
    }
}

/// A screen made of wireframe nodes, for runs without the gallery: a list
/// whose clock ticks every second.
final class SyntheticScreenSource: ReplaySource {
    private let recorder = WireframeRecorder(maxFrames: 400, fps: 2)
    private var timer: DispatchSourceTimer?

    var isRunning: Bool { recorder.isRunning }

    func start() {
        #if canImport(UIKit)
        recorder.windows = { [] }
        #endif
        recorder.start()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        recorder.stop()
    }

    func clearBuffer() { recorder.clearBuffer() }
    func hasFrames(sinceMs: Int64?, untilMs: Int64?) -> Bool { recorder.hasFrames(sinceMs: sinceMs, untilMs: untilMs) }
    func captureRecording(clipId: String, sinceMs: Int64?, untilMs: Int64?) -> SessionRecordingPayload? {
        recorder.captureRecording(clipId: clipId, sinceMs: sinceMs, untilMs: untilMs)
    }

    private func tick() {
        let now = Clock.nowMs()
        let text = VNode(element: 20, tag: "div", attributes: [
            "style": "left:20px;top:80px;width:350px;height:24px;font-size:17px;", "class": "t n",
        ], children: [VNode(text: 21, text: "Checkout · \(now / 1000 % 60)s")])
        let button = VNode(element: 22, tag: "div", attributes: [
            "style": "left:20px;top:380px;width:350px;height:50px;background-color:#007aff;border-radius:12px;"
                + "color:#ffffff;font-size:17px;line-height:50px;justify-content:center;", "class": "t n",
        ], children: [VNode(text: 23, text: "Pay now")])
        let screen = VNode(element: screenNodeId, tag: "div", attributes: [
            "id": "tw", "style": "width:390px;height:844px;background-color:#ffffff;",
        ], children: [text, button])
        recorder.push(WireframeFrame(screen: screen, width: 390, height: 844, timestampMs: now, href: "/checkout"))
    }
}

extension DomNode {
    /// This node and what is below it as an rrweb node.
    func serialized() -> JSON {
        var node: [String: JSON] = ["id": JSON(id)]
        if let tag = tag, !tag.hasPrefix("#") {
            node["type"] = 2
            node["tagName"] = .string(tag)
            node["attributes"] = .object(attributes.mapValues { .string($0) })
            node["childNodes"] = .array(children.map { $0.serialized() })
        } else if tag == nil {
            node["type"] = 3
            node["textContent"] = .string(text ?? "")
        } else {
            node["type"] = JSON(Int(tag!.dropFirst()) ?? 0)
            if tag == "#1" {
                node["name"] = "html"
                node["publicId"] = ""
                node["systemId"] = ""
            }
            if tag == "#0" { node["childNodes"] = .array(children.map { $0.serialized() }) }
        }
        return .object(node)
    }
}

extension JSON {
    /// The value as Foundation objects, as `TracewayOptions.collection` takes
    /// a settings document.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map { $0.anyValue }
        case .object(let members): return members.mapValues { $0.anyValue }
        }
    }
}
