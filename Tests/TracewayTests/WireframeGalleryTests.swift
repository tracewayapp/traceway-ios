#if canImport(UIKit)
import UIKit
import XCTest
@testable import Traceway

/// The wireframe replay gallery: every kind of UIKit and SwiftUI view the
/// recorder converts, recorded by a real `WireframeRecorder` on its timer
/// while the scenarios take their screens through their states, like the
/// Flutter SDK's wireframe suite.
///
/// At every checkpoint the screen is captured and the window draws its own
/// picture. The test then checks the recording the way rrweb's replayer
/// needs it (a Meta and a full snapshot first, time order, every mutation
/// applies to the page as it is), that each checkpoint's replayed page shows
/// the texts it expects and none it hides, and that no secret appears
/// anywhere in the recording.
///
/// It writes `events.json`, `run.json` and `app/<checkpoint>.png` to
/// `WIREFRAME_GALLERY_OUT` (default `.build/wireframe-gallery` in the
/// package), the files `CI/wireframe/run.py` renders in rrweb-player and
/// compares with what the app drew.
final class WireframeGalleryTests: XCTestCase {
    func testGallery() throws {
        let only = ProcessInfo.processInfo.environment["WIREFRAME_GALLERY_ONLY"]
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let scenarios = GalleryScenes.all.filter { only == nil || only!.contains($0.id) }
        let driver = try GalleryDriver(outDir: GalleryDriver.outputDirectory())
        defer { driver.finish() }
        for scenario in scenarios {
            driver.run(scenario)
        }
        driver.wait(0.5)
        let clip = try XCTUnwrap(
            driver.recorder.captureRecording(clipId: "gallery", sinceMs: nil, untilMs: nil),
            "the gallery recorded its screens"
        )
        try driver.write(events: clip.events)
        check(clip.events, driver)
    }

    private func check(_ events: [JSON], _ driver: GalleryDriver) {
        // 1. rrweb's order and every mutation applying to the page as it is.
        _ = replay(events)

        // 2. What each checkpoint's replayed page shows.
        for cp in driver.checkpoints {
            let mirror = Mirror()
            mirror.play(events.filter { Int64($0["timestamp"]?.int ?? 0) <= cp.at + GalleryDriver.sampleMs })
            let texts = mirror.screen.texts().joined(separator: "\u{1F}")
            for expected in cp.shows where !texts.contains(expected) {
                XCTFail("\(cp.name): the replay does not show \"\(expected)\"")
            }
            for hidden in cp.hides where texts.contains(hidden) {
                XCTFail("\(cp.name): the replay shows \"\(hidden)\", which it must hide")
            }
        }

        // 3. No secret anywhere in what would be uploaded.
        let all = JSON.array(events).encoded()
        for secret in driver.secrets where all.contains(secret) {
            XCTFail("the recording holds the secret \"\(secret)\"")
        }
        for failure in driver.failures { XCTFail(failure) }
    }
}

/// One screen of the gallery and the steps that take it through its states.
struct GalleryScenario {
    let id: String
    let title: String
    let build: () -> UIViewController
    let script: (GalleryDriver, UIViewController) -> Void
}

struct GalleryCheckpoint {
    let name: String
    let scenario: String
    let at: Int64
    let shows: [String]
    let hides: [String]
    /// Areas left out of every picture comparison (x, y, width, height),
    /// such as a spinner that never stops.
    let ignore: [[Double]]
    let minMutations: Int

    var json: JSON {
        [
            "name": .string(name),
            "scenario": .string(scenario),
            "at": JSON(at),
            "shows": .array(shows.map { .string($0) }),
            "hides": .array(hides.map { .string($0) }),
            "ignore": .array(ignore.map { .array($0.map { JSON($0) }) }),
            "minMutations": JSON(minMutations),
        ]
    }
}

/// Shows the scenarios in a window of their own, records it and takes the
/// checkpoints.
final class GalleryDriver {
    /// The replay of a checkpoint is looked at this long after it.
    static let sampleMs: Int64 = 150

    let window: UIWindow
    let recorder: WireframeRecorder
    let outDir: URL
    private(set) var scenario = ""
    private(set) var checkpoints: [GalleryCheckpoint] = []
    private(set) var secrets: [String] = []
    private(set) var failures: [String] = []
    private(set) var starts: [(id: String, at: Int64)] = []
    private var names = Set<String>()
    private var mutationsAtLast = 0
    private let startedAt = Clock.nowMs()

    static func outputDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["WIREFRAME_GALLERY_OUT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Tests/TracewayTests/<this file> -> the package's .build.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/wireframe-gallery", isDirectory: true)
    }

    init(outDir: URL) throws {
        self.outDir = outDir
        let files = FileManager.default
        try? files.removeItem(at: outDir)
        try files.createDirectory(at: outDir.appendingPathComponent("app"), withIntermediateDirectories: true)
        UIView.setAnimationsEnabled(true)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if let scene = scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 5)
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .systemBackground
        window.rootViewController = UIViewController()
        window.isHidden = false
        recorder = WireframeRecorder(maxFrames: 100_000, fps: 4)
        let shown = window
        recorder.windows = { [shown] }
        recorder.start()
    }

    func finish() {
        recorder.stop()
        window.isHidden = true
        window.rootViewController = nil
    }

    var size: CGSize { window.bounds.size }

    func run(_ scenario: GalleryScenario) {
        self.scenario = scenario.id
        starts.append((scenario.id, Clock.nowMs()))
        print("GALLERY_SCENARIO \(scenario.id)")
        let controller = scenario.build()
        window.rootViewController = controller
        settle()
        scenario.script(self, controller)
    }

    // MARK: - Time

    /// Lets the main run loop run: layout, animations and the recorder's
    /// timer.
    func wait(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: min(until, Date().addingTimeInterval(0.02)))
        }
    }

    /// Lays out and lets animations end.
    func settle(_ seconds: TimeInterval = 0.45) {
        window.layoutIfNeeded()
        wait(seconds)
        window.layoutIfNeeded()
    }

    // MARK: - Checkpoints

    /// Captures the screen as it is now and the window's own picture of it.
    func checkpoint(
        _ name: String = "", shows: [String] = [], hides: [String] = [],
        ignore: [CGRect] = [], settle settleSeconds: TimeInterval = 0.45, minMutations: Int = 0
    ) {
        let full = name.isEmpty ? scenario : "\(scenario)-\(name)"
        if !names.insert(full).inserted { failures.append("checkpoint \(full) twice") }
        settle(settleSeconds)
        recorder.captureNow()
        let at = Clock.nowMs()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // sRGB, as the browser renders the replay.
        format.preferredRange = .standard
        let bounds = window.bounds
        let picture = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { [window] _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        do {
            try picture.write(to: outDir.appendingPathComponent("app/\(full).png"))
        } catch {
            failures.append("cannot save the picture of \(full): \(error)")
        }
        checkpoints.append(GalleryCheckpoint(
            name: full, scenario: scenario, at: at, shows: shows, hides: hides,
            ignore: ignore.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
            minMutations: minMutations
        ))
        print("GALLERY_CHECKPOINT \(full) \(at)")
        writeTree(full)
        // The next step starts after the moment the replay is looked at.
        wait(Double(GalleryDriver.sampleMs) / 1000 + 0.2)
    }

    /// Text the app shows that must never reach the recording.
    func secret(_ text: String) { secrets.append(text) }

    func fail(_ message: String) { failures.append("\(scenario): \(message)") }

    // MARK: - Gestures

    /// Where `view`'s center is in the window.
    func center(of view: UIView) -> CGPoint {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
    }

    private var pointer = 1

    /// A finger taps `view`: the touches go to the recording, then `action`
    /// does what the tap would.
    func tap(_ view: UIView, action: () -> Void = {}) {
        let at = center(of: view)
        tap(at: at, action: action)
    }

    func tap(at point: CGPoint, action: () -> Void = {}) {
        pointer += 1
        recorder.pointerDown(pointer: pointer, x: Double(point.x), y: Double(point.y), touch: true)
        wait(0.08)
        recorder.pointerUp(pointer: pointer, x: Double(point.x), y: Double(point.y), touch: true, tap: true)
        action()
        wait(0.1)
    }

    /// A finger drags from `start` to `end` over `seconds` while `step`
    /// moves the content along (0 to 1).
    func drag(from start: CGPoint, to end: CGPoint, seconds: TimeInterval = 0.5, step: (CGFloat) -> Void) {
        pointer += 1
        recorder.pointerDown(pointer: pointer, x: Double(start.x), y: Double(start.y), touch: true)
        let steps = max(2, Int(seconds * 30))
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * f, y = start.y + (end.y - start.y) * f
            step(f)
            recorder.pointerMove(pointer: pointer, x: Double(x), y: Double(y), touch: true)
            wait(seconds / Double(steps))
        }
        recorder.pointerUp(pointer: pointer, x: Double(end.x), y: Double(end.y), touch: true, tap: false)
    }

    /// Scrolls `scrollView` to `offset` with a finger drag.
    func scroll(_ scrollView: UIScrollView, to offset: CGPoint, seconds: TimeInterval = 0.5) {
        let from = scrollView.contentOffset
        let mid = center(of: scrollView)
        let dx = offset.x - from.x, dy = offset.y - from.y
        let reach = min(abs(dy) > 0 ? scrollView.bounds.height * 0.35 : scrollView.bounds.width * 0.35, 260)
        let start = CGPoint(x: mid.x + (dx > 0 ? reach / 2 : dx < 0 ? -reach / 2 : 0),
                            y: mid.y + (dy > 0 ? reach / 2 : dy < 0 ? -reach / 2 : 0))
        let end = CGPoint(x: start.x - (dx == 0 ? 0 : (dx > 0 ? reach : -reach)),
                          y: start.y - (dy == 0 ? 0 : (dy > 0 ? reach : -reach)))
        drag(from: start, to: end, seconds: seconds) { f in
            scrollView.contentOffset = CGPoint(x: from.x + dx * f, y: from.y + dy * f)
        }
    }

    /// Types `text` into `field` one character at a time.
    func type(_ text: String, into field: UITextField) {
        tap(field)
        for character in text {
            field.text = (field.text ?? "") + String(character)
            field.sendActions(for: .editingChanged)
            wait(0.12)
        }
    }

    func type(_ text: String, into view: UITextView) {
        tap(view)
        for character in text {
            view.text = (view.text ?? "") + String(character)
            wait(0.12)
        }
    }

    // MARK: - The layer tree, for diagnosing a conversion

    /// Writes `tree/<checkpoint>.txt`: every layer of the window with its
    /// class, its view's class, its frame on screen and what it paints.
    private func writeTree(_ name: String) {
        var lines: [String] = []
        let root = window.layer
        func color(_ cg: CGColor?) -> String {
            guard let c = WireframeCapture.color(cg) else { return "-" }
            return WireframeCSS.color(c)
        }
        func walk(_ model: CALayer, _ depth: Int) {
            guard lines.count < 4000, depth < 80 else { return }
            let layer = model.presentation() ?? model
            let frame = layer.convert(layer.bounds, to: root.presentation() ?? root)
            var parts = [String(repeating: " ", count: depth) + NSStringFromClass(Swift.type(of: model))]
            if let view = model.delegate as? UIView {
                parts.append("view=" + NSStringFromClass(Swift.type(of: view)))
                if let image = (view as? UIImageView)?.image {
                    parts.append("image(symbol=\(image.isSymbolImage) mode=\(image.renderingMode.rawValue) size=\(image.size) caps=\(image.capInsets))")
                }
                if let label = view as? UILabel { parts.append("text=\"\(label.text ?? "")\" lines=\(label.numberOfLines)") }
                if view.isHidden { parts.append("HIDDEN-VIEW") }
                if NSStringFromClass(Swift.type(of: view)).contains("Hosting") {
                    parts.append("ax=\(view.accessibilityElements?.count ?? -1)/\(view.accessibilityElementCount())")
                }
                if view.responds(to: NSSelectorFromString("cornerConfiguration")),
                   let corners = view.value(forKey: "cornerConfiguration") {
                    parts.append("corners=\(String(describing: corners).prefix(80))")
                }
            }
            parts.append(String(format: "frame=(%.1f,%.1f %.1fx%.1f)", frame.minX, frame.minY, frame.width, frame.height))
            if layer.isHidden { parts.append("hidden") }
            if layer.opacity < 1 { parts.append(String(format: "opacity=%.2f", layer.opacity)) }
            if layer.backgroundColor != nil { parts.append("bg=" + color(layer.backgroundColor)) }
            if layer.cornerRadius > 0 { parts.append(String(format: "radius=%.1f curve=%@", layer.cornerRadius, layer.cornerCurve.rawValue)) }
            if layer.masksToBounds { parts.append("clips") }
            if let mask = layer.mask { parts.append("mask=" + NSStringFromClass(Swift.type(of: mask))) }
            if layer.borderWidth > 0 { parts.append("border=\(layer.borderWidth) " + color(layer.borderColor)) }
            if layer.shadowOpacity > 0 { parts.append("shadow=\(layer.shadowOpacity)") }
            if !CATransform3DIsIdentity(layer.transform) {
                let t = layer.transform
                parts.append(String(format: "transform=[%.2f %.2f %.2f %.2f | m34=%.4f | t=%.1f,%.1f]", t.m11, t.m12, t.m21, t.m22, t.m34, t.m41, t.m42))
            }
            if !CATransform3DIsIdentity(layer.sublayerTransform) { parts.append("SUBLAYER-TRANSFORM") }
            if layer.contents != nil { parts.append("contents") }
            if let filters = layer.filters, !filters.isEmpty { parts.append("filters=\(filters.count)") }
            if let filters = layer.backgroundFilters, !filters.isEmpty { parts.append("bgfilters=\(filters.count)") }
            if let filter = layer.compositingFilter { parts.append("compositing=\(String(describing: filter).prefix(40))") }
            if let shape = layer as? CAShapeLayer, let path = shape.path {
                parts.append("path=\(path.boundingBox) fill=" + color(shape.fillColor) + " stroke=" + color(shape.strokeColor))
            }
            if NSStringFromClass(Swift.type(of: model)).contains("Portal"),
               model.responds(to: NSSelectorFromString("sourceLayer")),
               let source = model.value(forKey: "sourceLayer") as? CALayer {
                let sourceFrame = source.convert(source.bounds, to: root)
                parts.append("PORTAL source=\(NSStringFromClass(Swift.type(of: source))) at \(sourceFrame)")
            }
            lines.append(parts.joined(separator: " "))
            for sublayer in model.sublayers ?? [] { walk(sublayer, depth + 1) }
        }
        walk(root, 0)
        let dir = outDir.appendingPathComponent("tree")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Output

    func write(events: [JSON]) throws {
        try Data(JSON.array(events).encoded().utf8).write(to: outDir.appendingPathComponent("events.json"))
        let run: JSON = [
            "platform": "ios-simulator",
            "device": .string(UIDevice.current.model),
            "os": .string(UIDevice.current.systemVersion),
            "width": JSON(Double(size.width)),
            "height": JSON(Double(size.height)),
            "startedAt": JSON(startedAt),
            "sampleMs": JSON(GalleryDriver.sampleMs),
            "checkpoints": .array(checkpoints.map { $0.json }),
            "scenarios": .array(starts.map { ["id": .string($0.id), "at": JSON($0.at)] }),
            "secrets": .array(secrets.map { .string($0) }),
        ]
        try Data(run.encoded().utf8).write(to: outDir.appendingPathComponent("run.json"))
        print("GALLERY_OUT \(outDir.path)")
    }
}
#endif
