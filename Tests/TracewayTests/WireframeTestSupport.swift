import XCTest
@testable import Traceway

// MARK: - A replayer, close enough to rrweb's to tell whether events rebuild the screen

/// A mirror of ids to nodes: a full snapshot builds the whole tree, a
/// mutation applies removes, then adds (each built without its children and
/// inserted before `nextId`), then texts and attributes. Stricter than
/// rrweb: an add whose parent or next sibling is not on the page fails
/// instead of waiting in a queue, and an id already on the page fails.
final class DomNode {
    let id: Int
    let tag: String?
    var text: String?
    var attributes: [String: String]
    var children: [DomNode] = []

    init(id: Int, tag: String?, text: String?, attributes: [String: String]) {
        self.id = id
        self.tag = tag
        self.text = text
        self.attributes = attributes
    }

    func dump() -> String {
        if tag == nil { return "#\(id)\"\(text ?? "")\"" }
        let attrs = attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "#\(id)<\(tag!) \(attrs)>[\(children.map { $0.dump() }.joined(separator: ","))]"
    }

    func texts() -> [String] {
        (text.map { [$0] } ?? []) + children.flatMap { $0.texts() }
    }
}

final class Mirror {
    var byId: [Int: DomNode] = [:]

    func fullSnapshot(_ node: JSON) {
        byId.removeAll()
        _ = build(node, withChildren: true)
    }

    @discardableResult
    func build(_ n: JSON, withChildren: Bool) -> DomNode {
        let id = n["id"]!.int!
        XCTAssertNil(byId[id], "id \(id) added twice")
        let type = n["type"]!.int!
        var attributes: [String: String] = [:]
        if type == 2 {
            for (key, value) in n["attributes"]?.object ?? [:] { attributes[key] = value.string }
        }
        let node = DomNode(
            id: id,
            tag: type == 2 ? n["tagName"]!.string! : (type == 3 ? nil : "#\(type)"),
            text: type == 3 ? n["textContent"]!.string! : nil,
            attributes: attributes
        )
        byId[id] = node
        if withChildren {
            for child in n["childNodes"]?.array ?? [] {
                node.children.append(build(child, withChildren: true))
            }
        }
        return node
    }

    private func unmap(_ node: DomNode) {
        byId.removeValue(forKey: node.id)
        node.children.forEach(unmap)
    }

    func mutation(_ data: JSON) {
        XCTAssertEqual(data["source"]?.int, 0)
        for key in ["removes", "adds", "texts", "attributes"] {
            XCTAssertNotNil(data[key]?.array, "\(key) must be a list")
        }
        for r in data["removes"]!.array! {
            guard let node = byId[r["id"]!.int!], let parent = byId[r["parentId"]!.int!] else {
                return XCTFail("remove of a missing node \(r.encoded())")
            }
            guard let at = parent.children.firstIndex(where: { $0 === node }) else {
                return XCTFail("\(node.id) is not a child of \(parent.id)")
            }
            parent.children.remove(at: at)
            unmap(node)
        }
        for a in data["adds"]!.array! {
            guard let parent = byId[a["parentId"]!.int!] else { return XCTFail("add under a missing parent") }
            let node = build(a["node"]!, withChildren: false)
            if let nextId = a["nextId"]?.int {
                guard let next = byId[nextId], let at = parent.children.firstIndex(where: { $0 === next }) else {
                    return XCTFail("add before \(nextId), which is not a child of \(parent.id)")
                }
                parent.children.insert(node, at: at)
            } else {
                XCTAssertTrue(a["nextId"]?.isNull ?? false, "nextId must be present")
                parent.children.append(node)
            }
        }
        for t in data["texts"]!.array! {
            let node = byId[t["id"]!.int!]
            XCTAssertNotNil(node)
            XCTAssertNil(node?.tag, "text change of a non-text node")
            node?.text = t["value"]!.string
        }
        for a in data["attributes"]!.array! {
            guard let node = byId[a["id"]!.int!] else { return XCTFail("attributes of a missing node") }
            for (key, value) in a["attributes"]!.object! {
                if value.isNull {
                    node.attributes.removeValue(forKey: key)
                } else {
                    node.attributes[key] = value.string
                }
            }
        }
    }

    func play(_ events: [JSON]) {
        for event in events {
            switch event["type"]?.int {
            case 2:
                fullSnapshot(event["data"]!["node"]!)
            case 3:
                let data = event["data"]!
                if data["source"]?.int == 0 { mutation(data) }
                if data["source"]?.int == 2 {
                    XCTAssertNotNil(byId[data["id"]!.int!], "interaction with a node not on the page")
                }
            default:
                break
            }
        }
    }

    var screen: DomNode { byId[screenNodeId]! }
}

func dump(_ n: VNode) -> String {
    if n.isText { return "#\(n.id)\"\(n.text ?? "")\"" }
    let attrs = n.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    return "#\(n.id)<\(n.tag!) \(attrs)>[\(n.children.map(dump).joined(separator: ","))]"
}

func allNodes(_ n: VNode) -> [VNode] {
    [n] + n.children.flatMap(allNodes)
}

func fullSnapshot(of screen: VNode) -> JSON {
    ["type": 2, "data": ["node": serializeDocument(screen)]]
}

// MARK: - Looking into captured screens

/// Every text the tree shows, in document order.
func allTexts(_ n: VNode) -> [String] {
    allNodes(n).filter { $0.isText }.compactMap { $0.text }
}

/// The element whose own text child is `text`.
func element(withText text: String, in root: VNode) -> VNode? {
    allNodes(root).first { node in
        !node.isText && node.children.contains { $0.isText && $0.text == text }
    }
}

/// The inline style of `n` as a dictionary of property to value.
func styleMap(_ n: VNode) -> [String: String] {
    var out: [String: String] = [:]
    for part in (n.attributes["style"] ?? "").split(separator: ";") {
        guard let colon = part.firstIndex(of: ":") else { continue }
        out[String(part[..<colon])] = String(part[part.index(after: colon)...])
    }
    return out
}

/// A length property of `n` in CSS pixels, nil when it has none.
func styleNumber(_ n: VNode, _ property: String) -> Double? {
    guard let value = styleMap(n)[property], value.hasSuffix("px") else { return nil }
    return Double(value.dropLast(2))
}

/// The CSS classes of `n`.
func classes(_ n: VNode) -> Set<String> {
    Set((n.attributes["class"] ?? "").split(separator: " ").map(String.init))
}

/// Where `node` is on the screen, summing the `left`/`top` of it and its
/// ancestors (translations only; a node under a matrix is not supported).
func screenPosition(_ root: VNode, _ node: VNode) -> (x: Double, y: Double)? {
    func walk(_ at: VNode, _ x: Double, _ y: Double) -> (x: Double, y: Double)? {
        let here = (x: x + (styleNumber(at, "left") ?? 0), y: y + (styleNumber(at, "top") ?? 0))
        if at === node { return here }
        for child in at.children {
            if let found = walk(child, here.x, here.y) { return found }
        }
        return nil
    }
    return walk(root, 0, 0)
}

/// The chain of elements from `root` down to `node`, both included.
func ancestry(_ root: VNode, _ node: VNode) -> [VNode]? {
    if root === node { return [root] }
    for child in root.children {
        if let path = ancestry(child, node) { return [root] + path }
    }
    return nil
}

extension DomNode {
    /// The first element below (or at) this node whose own text is `text`.
    func element(withText text: String) -> DomNode? {
        if tag != nil && children.contains(where: { $0.tag == nil && $0.text == text }) { return self }
        for child in children {
            if let found = child.element(withText: text) { return found }
        }
        return nil
    }
}

/// Plays a recording's events through the mirror after checking the order
/// rrweb's replayer needs: time never goes back, a Meta and a full snapshot
/// come first, and every interaction names a node on the page.
func replay(_ events: [JSON], file: StaticString = #filePath, line: UInt = #line) -> Mirror {
    let mirror = Mirror()
    XCTAssertEqual(events.first?["type"]?.int, 4, "a recording starts with a Meta event", file: file, line: line)
    XCTAssertEqual(events.dropFirst().first?["type"]?.int, 2, "then a full snapshot", file: file, line: line)
    var last: Int64 = 0
    for event in events {
        let ts = Int64(event["timestamp"]?.int ?? 0)
        XCTAssertGreaterThanOrEqual(ts, last, "events in time order", file: file, line: line)
        last = ts
    }
    mirror.play(events)
    return mirror
}

#if canImport(UIKit)
import UIKit

/// A window to show real views in and the capture that turns them into
/// wireframe frames, for the UIKit and SwiftUI component tests. Positions
/// are checked against the native frames (`convert(_:to:)` the window).
class WireframeViewTestCase: XCTestCase {
    var window: UIWindow!
    var capture: WireframeCapture!
    var clock: Int64 = 1_800_000_000_000

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .light
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 5)
        window.isHidden = false
        capture = WireframeCapture()
    }

    override func tearDown() {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        UIView.setAnimationsEnabled(true)
        super.tearDown()
    }

    /// A controller whose view holds `views` at the frames they have.
    @discardableResult
    func show(_ views: UIView..., background: UIColor = .white) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = background
        for view in views { controller.view.addSubview(view) }
        window.rootViewController = controller
        settle()
        return controller
    }

    func show(_ controller: UIViewController) {
        window.rootViewController = controller
        settle()
    }

    func settle(_ seconds: TimeInterval = 0.05) {
        window.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    func frame(keyboard: CGRect? = nil) throws -> WireframeFrame {
        settle()
        clock += 250
        return try XCTUnwrap(capture.capture(windows: [window], timestampMs: clock, href: "/test", keyboardFrame: keyboard))
    }

    func screen() throws -> VNode {
        try XCTUnwrap(try frame().screen)
    }

    /// A recorder fed by hand with this test's frames and clock.
    func recorder() -> WireframeRecorder {
        WireframeRecorder(maxFrames: 50, fps: 4, now: { [unowned self] in self.clock })
    }

    /// Replays what `recorder` holds and checks the replay ends on `last`.
    @discardableResult
    func replayEnds(_ recorder: WireframeRecorder, on last: WireframeFrame,
                    file: StaticString = #filePath, line: UInt = #line) throws -> Mirror {
        let clip = try XCTUnwrap(recorder.captureRecording(clipId: "c", sinceMs: nil, untilMs: clock + 1), file: file, line: line)
        let mirror = replay(clip.events, file: file, line: line)
        XCTAssertEqual(mirror.screen.dump(), dump(try XCTUnwrap(last.screen)), "the replay ends on the last screen",
                       file: file, line: line)
        return mirror
    }

    func node(_ text: String, in screen: VNode, file: StaticString = #filePath, line: UInt = #line) throws -> VNode {
        try XCTUnwrap(element(withText: text, in: screen), "no node shows \"\(text)\" in \(allTexts(screen))",
                      file: file, line: line)
    }

    func label(_ text: String, _ frame: CGRect, size: CGFloat = 17) -> UILabel {
        let label = UILabel(frame: frame)
        label.text = text
        label.font = .systemFont(ofSize: size)
        label.textColor = .black
        return label
    }

    /// `view`'s frame in the window.
    func nativeFrame(_ view: UIView) -> CGRect {
        view.convert(view.bounds, to: window)
    }

    /// Checks that `node` covers on screen what `view` covers, within
    /// `accuracy` points: for a transformed view, the bounds of both.
    func assertPlaced(_ node: VNode, in screen: VNode, like view: UIView, accuracy: Double = 0.11,
                      file: StaticString = #filePath, line: UInt = #line) {
        let native = nativeFrame(view)
        guard let box = screenBox(screen, node) else { return XCTFail("the node is not on the screen", file: file, line: line) }
        XCTAssertEqual(Double(box.minX), Double(native.minX), accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(Double(box.minY), Double(native.minY), accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(Double(box.width), Double(native.width), accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(Double(box.height), Double(native.height), accuracy: accuracy, "height", file: file, line: line)
    }
}

/// The bounds `node` covers on the replayed screen: its `left`/`top` or
/// `transform:matrix(…)` (about its top left corner) and those of its
/// ancestors applied to its `width` and `height`, as the browser's
/// `getBoundingClientRect` gives them.
func screenBox(_ root: VNode, _ node: VNode) -> CGRect? {
    guard let path = ancestry(root, node) else { return nil }
    var t = CGAffineTransform.identity
    for n in path {
        let style = styleMap(n)
        let local: CGAffineTransform
        if let m = style["transform"], m.hasPrefix("matrix("), m.hasSuffix(")") {
            let v = m.dropFirst(7).dropLast().split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            guard v.count == 6 else { return nil }
            local = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        } else {
            local = CGAffineTransform(translationX: CGFloat(styleNumber(n, "left") ?? 0), y: CGFloat(styleNumber(n, "top") ?? 0))
        }
        t = local.concatenating(t)
    }
    let w = CGFloat(styleNumber(node, "width") ?? 0), h = CGFloat(styleNumber(node, "height") ?? 0)
    return CGRect(x: 0, y: 0, width: w, height: h).applying(t)
}
#endif
