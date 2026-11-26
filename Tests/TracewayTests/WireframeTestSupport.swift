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
