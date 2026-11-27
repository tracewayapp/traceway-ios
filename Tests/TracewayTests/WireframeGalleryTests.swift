#if canImport(UIKit)
import UIKit
import XCTest
@testable import Traceway

/// The wireframe replay gallery: the 28 scenarios every Traceway mobile SDK
/// records (CONTRACT §5.2, the same names on Android), real UIKit and
/// SwiftUI screens recorded by a real `WireframeRecorder` on its timer while
/// the scenarios tap, type, scroll, present and navigate.
///
/// At every checkpoint the screen is captured, the window draws its own
/// picture, and the native frames of the labelled views are measured. The
/// test then checks the recording the way rrweb's replayer needs it (a Meta
/// and a full snapshot first, time order, every mutation applies to the page
/// as it is), that each checkpoint's replayed page shows the texts it
/// expects and none it hides, that pictures are inlined only where the
/// images policy allows them, and that no secret appears anywhere in the
/// recording.
///
/// It writes `events.json`, `run.json`, `app/<checkpoint>.png` and
/// `tree/<checkpoint>.txt` to `WIREFRAME_GALLERY_OUT` (default
/// `.build/wireframe-gallery` in the package), the files `CI/wireframe/run.py`
/// renders in rrweb-player and compares with what the app drew, box by box.
/// `WIREFRAME_GALLERY_ONLY` (comma-separated scenario names) runs some.
final class WireframeGalleryTests: XCTestCase {
    func testGallery() throws {
        let only = ProcessInfo.processInfo.environment["WIREFRAME_GALLERY_ONLY"]
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let scenarios = GalleryScenes.all.filter { only == nil || only!.contains($0.id) }
        XCTAssertEqual(Set(GalleryScenes.all.map(\.id)).count, GalleryScenes.all.count, "scenario names are unique")
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
            if let wanted = cp.pictures {
                let shown = mirror.screen.pictureCount()
                if wanted && shown == 0 { XCTFail("\(cp.name): no picture is inlined under replay.images = always") }
                if !wanted && shown > 0 { XCTFail("\(cp.name): \(shown) pictures are inlined under replay.images = off") }
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
    /// The local `collection` settings the scenario records under: pictures
    /// stay placeholders unless a scenario asks for them.
    var collection: [String: Any] = ["replay": ["images": "off"]]
    let build: () -> UIViewController
    let script: (GalleryDriver, UIViewController) -> Void
}

/// Where a labelled view is on screen at a checkpoint: its frame in window
/// points (a transformed view's axis-aligned bounds), which the checker
/// compares with the replayed element whose own text is `text`.
struct GalleryBox {
    let text: String
    let frame: CGRect

    var json: JSON {
        func r(_ v: CGFloat) -> JSON { JSON((Double(v) * 100).rounded() / 100) }
        return ["text": .string(text), "x": r(frame.minX), "y": r(frame.minY), "w": r(frame.width), "h": r(frame.height)]
    }
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
    let boxes: [GalleryBox]
    /// Whether the replay must inline pictures (true), must not (false), or
    /// either (nil). Checked in the test only.
    let pictures: Bool?

    var json: JSON {
        [
            "name": .string(name),
            "scenario": .string(scenario),
            "at": JSON(at),
            "shows": .array(shows.map { .string($0) }),
            "hides": .array(hides.map { .string($0) }),
            "ignore": .array(ignore.map { .array($0.map { JSON($0) }) }),
            "minMutations": JSON(minMutations),
            "boxes": .array(boxes.map(\.json)),
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
    /// The keyboard's frame in the window while it is up, as the recorder
    /// is told it.
    private(set) var keyboardFrame: CGRect?
    private var names = Set<String>()
    private var observers: [NSObjectProtocol] = []
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
        // Key, as an app's window is: a field in it can bring up the keyboard.
        window.makeKeyAndVisible()
        recorder = WireframeRecorder(maxFrames: 100_000, fps: 4)
        let shown = window
        recorder.windows = { [shown] }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let self = self,
                  let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            else { return }
            let local = self.window.convert(frame, from: self.window.screen.coordinateSpace)
            self.keyboardFrame = local.isEmpty || local.minY >= self.window.bounds.maxY ? nil : local
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.keyboardFrame = nil
        })
        recorder.start()
    }

    func finish() {
        recorder.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    var size: CGSize { window.bounds.size }

    func run(_ scenario: GalleryScenario) {
        self.scenario = scenario.id
        starts.append((scenario.id, Clock.nowMs()))
        print("GALLERY_SCENARIO \(scenario.id)")
        window.endEditing(true)
        useCollection(scenario.collection)
        let controller = scenario.build()
        window.rootViewController = controller
        settle()
        scenario.script(self, controller)
        window.endEditing(true)
    }

    // MARK: - Settings

    /// Applies a local `collection` document the way `Traceway.start` does
    /// (`TracewayOptions.collection` over the defaults, held at the ceilings
    /// of an app that captures its screen) and hands the recorder the
    /// replay settings it gives.
    func useCollection(_ collection: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: collection)
            let defaults = applyOverlay(defaultSettings(), try parseSettingsDocument(data))
            let control = ControlState(defaults: defaults, ceilings: ceilingsFrom(screenCapture: true))
            recorder.imagePolicy = control.settings.replayImages
            recorder.maskAllInputs = control.settings.replayMaskAllInputs
        } catch {
            fail("cannot apply the collection settings \(collection): \(error)")
        }
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

    /// Waits until `condition` holds, at most `seconds`.
    @discardableResult
    func wait(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Lays out and lets animations end.
    func settle(_ seconds: TimeInterval = 0.45) {
        window.layoutIfNeeded()
        wait(seconds)
        window.layoutIfNeeded()
    }

    // MARK: - Checkpoints

    /// Captures the screen as it is now, the window's own picture of it and
    /// the frames of its labelled views. A checkpoint taken while something
    /// moves (`measure: false`) has no boxes: it keeps moving until the
    /// replay is looked at.
    func checkpoint(
        _ name: String = "", shows: [String] = [], hides: [String] = [],
        ignore: [CGRect] = [], settle settleSeconds: TimeInterval = 0.45, minMutations: Int = 0,
        measure: Bool = true, unmeasured: Set<String> = [], pictures: Bool? = nil
    ) {
        let full = name.isEmpty ? scenario : "\(scenario)-\(name)"
        if !names.insert(full).inserted { failures.append("checkpoint \(full) twice") }
        settle(settleSeconds)
        recorder.captureNow()
        let at = Clock.nowMs()
        let boxes = measure ? labelledBoxes(leavingOut: unmeasured) : []
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
            minMutations: minMutations, boxes: boxes, pictures: pictures
        ))
        print("GALLERY_CHECKPOINT \(full) \(at) boxes=\(boxes.count)")
        writeTree(full)
        // The next step starts after the moment the replay is looked at.
        wait(Double(GalleryDriver.sampleMs) / 1000 + 0.2)
    }

    /// Text the app shows that must never reach the recording.
    func secret(_ text: String) { secrets.append(text) }

    func fail(_ message: String) { failures.append("\(scenario): \(message)") }

    /// The visible labels (and text layers, and the placeholders of empty
    /// fields) whose text no other visible label shows, with their frames on
    /// screen. Left out: text under a privacy mask, typed text, text views,
    /// controls the wireframe draws from their state (a segmented control's
    /// titles), SwiftUI, secrets, and `leavingOut`.
    private func labelledBoxes(leavingOut: Set<String>) -> [GalleryBox] {
        let root = window.layer.presentation() ?? window.layer
        var found: [GalleryBox] = []
        var counts: [String: Int] = [:]

        func frame(of model: CALayer) -> CGRect {
            let layer = model.presentation() ?? model
            return layer.convert(layer.bounds, to: root)
        }

        func consider(_ text: String, _ rect: CGRect, clip: CGRect, measured: Bool) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rect.width > 0, rect.height > 0, rect.intersects(clip) else { return }
            counts[text, default: 0] += 1
            if measured { found.append(GalleryBox(text: text, frame: rect)) }
        }

        func walk(_ view: UIView, clip: CGRect, measured: Bool) {
            let layer = view.layer.presentation() ?? view.layer
            guard !view.isHidden, view.alpha > 0.01, !layer.isHidden, layer.opacity > 0.01 else { return }
            let rect = frame(of: view.layer)
            let unmasked = measured && view.tracewayPrivacyMask == nil
            var clip = clip
            if view.clipsToBounds || layer.masksToBounds { clip = clip.intersection(rect) }
            if let field = view as? UITextField {
                // An empty field shows its placeholder where it draws text;
                // what is typed is masked. Its side views are views of the app.
                let placeholder = field.attributedPlaceholder?.string ?? field.placeholder ?? ""
                if (field.text ?? "").isEmpty, !placeholder.isEmpty {
                    let local = field.isEditing ? field.editingRect(forBounds: field.bounds) : field.textRect(forBounds: field.bounds)
                    consider(placeholder, field.convert(local, to: window), clip: clip, measured: unmasked)
                }
                for side in [field.leftView, field.rightView] {
                    if let side = side, side.superview === field { walk(side, clip: clip, measured: unmasked) }
                }
                return
            }
            let measured = unmasked
                && !(view is UITextView || view is UISegmentedControl || view is UIStepper
                    || view is UISwitch || view is UIPageControl || view is UISlider)
                && !NSStringFromClass(Swift.type(of: view)).contains("Hosting")
            if let label = view as? UILabel {
                consider(label.attributedText?.string ?? label.text ?? "", rect, clip: clip, measured: measured)
            }
            for sublayer in view.layer.sublayers ?? [] where sublayer.delegate == nil {
                guard let text = sublayer as? CATextLayer, !text.isHidden, text.opacity > 0.01 else { continue }
                let raw = (text.string as? String) ?? (text.string as? NSAttributedString)?.string ?? ""
                consider(raw, frame(of: text), clip: clip, measured: measured)
            }
            for subview in view.subviews { walk(subview, clip: clip, measured: measured) }
        }

        walk(window, clip: window.bounds, measured: true)
        return found.filter { box in
            counts[box.text] == 1 && !leavingOut.contains(box.text)
                && !secrets.contains { box.text.contains($0) }
        }
    }

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
            if field.isFirstResponder {
                field.insertText(String(character))
            } else {
                field.text = (field.text ?? "") + String(character)
                field.sendActions(for: .editingChanged)
            }
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
            if layer.zPosition != 0 { parts.append(String(format: "z=%.1f", layer.zPosition)) }
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
        let environment = ProcessInfo.processInfo.environment
        let run: JSON = [
            "platform": "ios",
            "device": .string(environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.model),
            "model": .string(environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""),
            "os": .string(UIDevice.current.systemVersion),
            "width": JSON(Double(size.width)),
            "height": JSON(Double(size.height)),
            "density": JSON(Double(window.screen.scale)),
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

extension DomNode {
    /// How many inlined pictures the page shows: elements with a picture
    /// class (`im p<N>`) whose rule is on the page.
    func pictureCount() -> Int {
        var rules = Set<String>()
        var shown: [String] = []
        func walk(_ node: DomNode) {
            if node.tag == "style", let css = node.attributes["_cssText"], css.hasPrefix(".im.p"),
               let end = css.firstIndex(of: "{") {
                rules.insert(String(css[css.index(css.startIndex, offsetBy: 4)..<end]))
            }
            let classes = (node.attributes["class"] ?? "").split(separator: " ").map(String.init)
            if classes.contains("im") { shown.append(contentsOf: classes.filter { $0.hasPrefix("p") }) }
            node.children.forEach(walk)
        }
        walk(self)
        return shown.filter { rules.contains($0) }.count
    }
}
#endif
