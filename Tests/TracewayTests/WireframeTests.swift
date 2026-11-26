import XCTest
@testable import Traceway

// MARK: - A replayer, close enough to rrweb's to tell whether events rebuild the screen

/// A mirror of ids to nodes: a full snapshot builds the whole tree, a
/// mutation applies removes, then adds (each built without its children and
/// inserted before `nextId`), then texts and attributes. Stricter than
/// rrweb: an add whose parent or next sibling is not on the page fails
/// instead of waiting in a queue, and an id already on the page fails.
private final class DomNode {
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

private final class Mirror {
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

private func dump(_ n: VNode) -> String {
    if n.isText { return "#\(n.id)\"\(n.text ?? "")\"" }
    let attrs = n.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    return "#\(n.id)<\(n.tag!) \(attrs)>[\(n.children.map(dump).joined(separator: ","))]"
}

private func allNodes(_ n: VNode) -> [VNode] {
    [n] + n.children.flatMap(allNodes)
}

private func fullSnapshot(of screen: VNode) -> JSON {
    ["type": 2, "data": ["node": serializeDocument(screen)]]
}

// MARK: - Random trees for the diff

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class TreeGen {
    var random: SeededRandom
    var nextId = 100
    static let tags = ["div", "span", "img"]

    init(_ random: SeededRandom) { self.random = random }

    func int(_ n: Int) -> Int { Int.random(in: 0..<n, using: &random) }

    func node(_ depth: Int) -> VNode {
        if depth > 0 && int(4) == 0 {
            defer { nextId += 1 }
            return VNode(text: nextId, text: "text\(int(50))")
        }
        var children: [VNode] = []
        if depth < 4 {
            for _ in 0..<int(4) { children.append(node(depth + 1)) }
        }
        defer { nextId += 1 }
        return VNode(element: nextId, tag: TreeGen.tags[int(3)], attributes: ["style": "left:\(int(9))px"], children: children)
    }

    func screen() -> VNode {
        var children: [VNode] = []
        for _ in 0..<(1 + int(4)) { children.append(node(1)) }
        return VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw"], children: children)
    }

    /// `tree` with one random edit, sharing every subtree the edit does not
    /// touch.
    func edit(_ tree: VNode) -> VNode {
        let nodes = allNodes(tree)
        let target = nodes[int(nodes.count)]
        switch int(7) {
        case 0:
            if target.isText { return replace(tree, target, VNode(text: target.id, text: "edited\(int(9))")) }
            var attributes = ["style": "left:\(int(99))px"]
            if Bool.random(using: &random) { attributes["class"] = "c" }
            return replace(tree, target, VNode(element: target.id, tag: target.tag!, attributes: attributes, children: target.children))
        case 1:
            if target.isText { return tree }
            var children = target.children
            children.insert(node(2), at: int(children.count + 1))
            return replace(tree, target, with(target, children))
        case 2:
            if target === tree { return tree }
            return remove(tree, target)
        case 3:
            if target.isText || target.children.count < 2 { return tree }
            var children = target.children
            children.shuffle(using: &random)
            return replace(tree, target, with(target, children))
        case 4:
            if target === tree { return tree }
            let without = remove(tree, target)
            let hosts = allNodes(without).filter { !$0.isText }
            let host = hosts[int(hosts.count)]
            var children = host.children
            children.insert(target, at: int(children.count + 1))
            return replace(without, host, with(host, children))
        case 5:
            if target.isText || target === tree { return tree }
            return replace(tree, target, VNode(
                element: target.id, tag: target.tag == "div" ? "span" : "div",
                attributes: target.attributes, children: target.children
            ))
        default:
            if !target.isText { return tree }
            return replace(tree, target, VNode(element: target.id, tag: "div", attributes: [:], children: []))
        }
    }

    func with(_ n: VNode, _ children: [VNode]) -> VNode {
        VNode(element: n.id, tag: n.tag!, attributes: n.attributes, children: children)
    }

    func replace(_ tree: VNode, _ target: VNode, _ replacement: VNode) -> VNode {
        if tree === target { return replacement }
        if tree.isText { return tree }
        var changed = false
        let children = tree.children.map { c -> VNode in
            let r = replace(c, target, replacement)
            if r !== c { changed = true }
            return r
        }
        return changed ? with(tree, children) : tree
    }

    func remove(_ tree: VNode, _ target: VNode) -> VNode {
        if tree.isText { return tree }
        var changed = false
        var children: [VNode] = []
        for c in tree.children {
            if c === target {
                changed = true
                continue
            }
            let r = remove(c, target)
            if r !== c { changed = true }
            children.append(r)
        }
        return changed ? with(tree, children) : tree
    }
}

// MARK: - Tests

final class WireframeDiffTests: XCTestCase {
    func testNoDiffBetweenTheSameScreen() {
        let a = TreeGen(SeededRandom(state: 1)).screen()
        XCTAssertNil(diffScreens(a, a))
        // Equal content in different objects is no change either.
        let b = VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw"], children: a.children)
        XCTAssertNil(diffScreens(a, b))
    }

    func testEveryRandomEditReplaysAsRrwebWouldApplyIt() {
        var random = SeededRandom(state: 42)
        for round in 0..<400 {
            let gen = TreeGen(SeededRandom(state: random.next()))
            gen.nextId = 100 + round * 1000
            let before = gen.screen()
            var after = before
            for _ in 0..<(gen.int(6) + 1) { after = gen.edit(after) }
            let mirror = Mirror()
            mirror.play([fullSnapshot(of: before)])
            XCTAssertEqual(mirror.screen.dump(), dump(before))
            guard let mutation = diffScreens(before, after) else {
                XCTAssertEqual(dump(after), dump(before), "round \(round)")
                continue
            }
            mirror.mutation(mutation)
            XCTAssertEqual(mirror.screen.dump(), dump(after), "round \(round)")
        }
    }

    func testOneAttributeChangesWithoutTouchingTheRest() {
        let text = VNode(text: 101, text: "hi")
        let a = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [
            VNode(element: 100, tag: "div", attributes: ["style": "left:1px"], children: [text]),
        ])
        let b = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [
            VNode(element: 100, tag: "div", attributes: ["style": "left:2px"], children: [text]),
        ])
        let m = diffScreens(a, b)!
        XCTAssertEqual(m["source"], 0)
        XCTAssertEqual(m["adds"], [])
        XCTAssertEqual(m["removes"], [])
        XCTAssertEqual(m["texts"], [])
        XCTAssertEqual(m["attributes"], [["id": 100, "attributes": ["style": "left:2px"]]])
    }

    func testRemovedAttributesAreNullAndTextChangesAreTexts() {
        let a = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [
            VNode(element: 100, tag: "div", attributes: ["style": "a", "class": "t"], children: [VNode(text: 101, text: "one")]),
        ])
        let b = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [
            VNode(element: 100, tag: "div", attributes: ["style": "a"], children: [VNode(text: 101, text: "two")]),
        ])
        let m = diffScreens(a, b)!
        XCTAssertEqual(m["attributes"], [["id": 100, "attributes": ["class": nil]]])
        XCTAssertEqual(m["texts"], [["id": 101, "value": "two"]])
    }

    func testANewSubtreeIsAddedParentFirstAndSiblingsLastToFirst() {
        let kept = VNode(element: 100, tag: "div", attributes: [:], children: [])
        let a = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [kept])
        let added = VNode(element: 200, tag: "div", attributes: [:], children: [
            VNode(element: 201, tag: "div", attributes: [:], children: []),
            VNode(element: 202, tag: "div", attributes: [:], children: []),
        ])
        let b = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [added, kept])
        let adds = diffScreens(a, b)!["adds"]!.array!
        XCTAssertEqual(adds.map { $0["node"]!["id"]!.int! }, [200, 202, 201])
        XCTAssertEqual(adds[0]["nextId"], 100)
        XCTAssertEqual(adds[0]["parentId"]?.int, screenNodeId)
        XCTAssertEqual(adds[1]["nextId"], .null)
        XCTAssertEqual(adds[2]["nextId"], 202)
        XCTAssertEqual(adds[0]["node"]!["childNodes"], [], "an add carries no children")
    }

    func testOnlyTheChildrenOutsideTheLongestRunMove() {
        func child(_ id: Int) -> VNode { VNode(element: id, tag: "div", attributes: [:], children: []) }
        let c = (100...104).map(child)
        let a = VNode(element: screenNodeId, tag: "div", attributes: [:], children: c)
        // 104 moves to the front; the other four keep their order.
        let b = VNode(element: screenNodeId, tag: "div", attributes: [:], children: [c[4], c[0], c[1], c[2], c[3]])
        let m = diffScreens(a, b)!
        XCTAssertEqual(m["removes"], [["parentId": JSON(screenNodeId), "id": 104]])
        XCTAssertEqual(m["adds"]!.array!.map { $0["node"]!["id"]!.int! }, [104])
        XCTAssertEqual(longestIncreasing([3, 1, 2, 0, 4]), [1, 2, 4])
        XCTAssertEqual(longestIncreasing([]), [])
    }
}

final class WireframeVNodeTests: XCTestCase {
    func testNodesSerializeAsRrwebNodes() {
        let node = VNode(element: 20, tag: "div", attributes: ["style": "left:1px"], children: [VNode(text: 21, text: "hi")])
        XCTAssertEqual(node.serialize(), [
            "type": 2, "tagName": "div", "attributes": ["style": "left:1px"], "id": 20,
            "childNodes": [["type": 3, "textContent": "hi", "id": 21]],
        ])
        XCTAssertEqual(node.serialize(withChildren: false)["childNodes"], [])
    }

    func testSameAsComparesChildrenByIdentity() {
        let child = VNode(text: 21, text: "hi")
        let a = VNode(element: 20, tag: "div", attributes: ["a": "1"], children: [child])
        XCTAssertTrue(a.sameAs(VNode(element: 20, tag: "div", attributes: ["a": "1"], children: [child])))
        XCTAssertFalse(a.sameAs(VNode(element: 20, tag: "div", attributes: ["a": "1"], children: [VNode(text: 21, text: "hi")])))
        XCTAssertFalse(a.sameAs(VNode(element: 20, tag: "div", attributes: ["a": "2"], children: [child])))
        XCTAssertFalse(a.sameAs(VNode(element: 20, tag: "span", attributes: ["a": "1"], children: [child])))
    }

    func testTheDocumentHoldsTheStyleAndTheScreen() {
        let screen = VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw"], children: [])
        let doc = serializeDocument(screen)
        XCTAssertEqual(doc["type"], 0)
        XCTAssertEqual(doc["id"]?.int, documentNodeId)
        let children = doc["childNodes"]!.array!
        XCTAssertEqual(children[0]["type"], 1)
        XCTAssertEqual(children[0]["name"], "html")
        let html = children[1]
        XCTAssertEqual(html["tagName"], "html")
        let head = html["childNodes"]!.array![0]
        let style = head["childNodes"]!.array![1]
        XCTAssertEqual(style["tagName"], "style")
        let css = style["attributes"]!["_cssText"]!.string!
        for rule in ["#tw{", ".t{", ".n{", ".e{", ".k{", ".im{", ".ic::before{", ".cp{", ".mk{", ".pv{"] {
            XCTAssertTrue(css.contains(rule), rule)
        }
        let body = html["childNodes"]!.array![1]
        XCTAssertEqual(body["tagName"], "body")
        XCTAssertEqual(body["childNodes"]!.array![0]["id"]?.int, screenNodeId)
        // Every skeleton id is below the first captured one.
        var ids: [Int] = []
        func collect(_ n: JSON) {
            if let id = n["id"]?.int { ids.append(id) }
            n["childNodes"]?.array?.forEach(collect)
        }
        collect(doc)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0 < firstCapturedNodeId })
    }
}

final class WireframeCSSTests: XCTestCase {
    func testLengthsAreRoundedToATenth() {
        XCTAssertEqual(WireframeCSS.px(12), "12px")
        XCTAssertEqual(WireframeCSS.px(12.34), "12.3px")
        XCTAssertEqual(WireframeCSS.px(12.35), "12.4px")
        XCTAssertEqual(WireframeCSS.px(-0.04), "0px")
        XCTAssertEqual(WireframeCSS.px(-1.25), "-1.3px")
        XCTAssertEqual(WireframeCSS.px(.nan), "0px")
        XCTAssertEqual(WireframeCSS.rect(left: 1.04, top: -2, width: 10, height: 0.5), "left:1px;top:-2px;width:10px;height:0.5px;")
        XCTAssertEqual(WireframeCSS.num3(0.5), "0.5")
        XCTAssertEqual(WireframeCSS.num3(1), "1")
        XCTAssertEqual(WireframeCSS.num3(0.33333), "0.333")
    }

    func testColors() {
        XCTAssertEqual(WireframeCSS.color(WireframeColor(r: 1, g: 0, b: 0)), "#ff0000")
        XCTAssertEqual(WireframeCSS.color(WireframeColor(r: 0, g: 0.5, b: 1, a: 0.5)), "rgba(0,128,255,0.502)")
        XCTAssertEqual(WireframeCSS.fill(WireframeColor(r: 1, g: 1, b: 1, a: 0)), "")
        XCTAssertEqual(WireframeCSS.fill(nil), "")
        XCTAssertEqual(WireframeCSS.fill(.white), "background-color:#ffffff;")
    }

    func testCornersBordersAndShadows() {
        XCTAssertEqual(WireframeCSS.radius(0), "")
        XCTAssertEqual(WireframeCSS.radius(8), "border-radius:8px;")
        XCTAssertEqual(WireframeCSS.radius(topLeft: 8, topRight: 8, bottomRight: 0, bottomLeft: 0),
                       "border-radius:8px 8px 0px 0px;")
        XCTAssertEqual(WireframeCSS.insetBorder(width: 1, color: .black), "inset 0 0 0 1px #000000")
        XCTAssertNil(WireframeCSS.insetBorder(width: 0, color: .black))
        XCTAssertNil(WireframeCSS.insetBorder(width: 1, color: nil))
        XCTAssertEqual(WireframeCSS.insetSide(width: 2, color: .black, dx: 0, dy: 1), "inset 0 2px 0 0 #000000")
        XCTAssertEqual(WireframeCSS.boxShadow(dx: 0, dy: 2, blur: 4, color: WireframeColor(r: 0, g: 0, b: 0, a: 0.2)),
                       "0px 2px 4px 0px rgba(0,0,0,0.2)")
        XCTAssertEqual(WireframeCSS.shadow([]), "")
        XCTAssertEqual(WireframeCSS.shadow(["a", "b"]), "box-shadow:a,b;")
    }

    func testGradients() {
        let colors = [WireframeColor.black, WireframeColor.white]
        // Top to bottom is 180deg in CSS.
        XCTAssertEqual(
            WireframeCSS.linearGradient(colors: colors, locations: nil, startX: 0.5, startY: 0, endX: 0.5, endY: 1, width: 10, height: 10),
            "background-image:linear-gradient(180deg,#000000,#ffffff);"
        )
        XCTAssertEqual(
            WireframeCSS.linearGradient(colors: colors, locations: [0, 0.25], startX: 0, startY: 0.5, endX: 1, endY: 0.5, width: 10, height: 10),
            "background-image:linear-gradient(90deg,#000000 0%,#ffffff 25%);"
        )
    }

    func testMaskKeepsWhitespace() {
        XCTAssertEqual(WireframeCSS.mask("4242 4242\nab"), "**** ****\n**")
    }

    func testGeometryIsAnOffsetOrAMatrix() {
        let origin = WireframeAffine.translation(10, 20)
        XCTAssertEqual(
            wireframeGeometry(origin: origin, transform: .translation(15, 22.04), width: 100, height: 50),
            "left:5px;top:2px;width:100px;height:50px;"
        )
        // Rotated by 90 degrees around the node's corner.
        let rotated = WireframeAffine(a: 0, b: 1, c: -1, d: 0, tx: 30, ty: 40)
        XCTAssertEqual(
            wireframeGeometry(origin: origin, transform: rotated, width: 10, height: 10),
            "transform:matrix(0,1,-1,0,20,20);transform-origin:0 0;width:10px;height:10px;"
        )
        let t = WireframeAffine(a: 2, b: 0, c: 0, d: 3, tx: 1, ty: 2)
        let back = t.relative(to: t)
        XCTAssertTrue(back.isTranslation)
        XCTAssertEqual(back.tx, 0, accuracy: 1e-9)
        XCTAssertEqual(t.boundingBox(width: 10, height: 10), WireframeRect(x: 1, y: 2, width: 20, height: 30))
        XCTAssertTrue(WireframeAffine(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0).isDegenerate)
    }
}

final class WireframeRecorderTests: XCTestCase {
    private var clock: Int64 = 1_767_268_800_000

    private func screen(_ rows: [String], from shared: [VNode] = []) -> VNode {
        var children = shared
        for (i, row) in rows.enumerated() where i >= shared.count {
            children.append(VNode(element: 100 + 2 * i, tag: "div", attributes: ["class": "t", "style": "top:\(20 * i)px"],
                                  children: [VNode(text: 101 + 2 * i, text: row)]))
        }
        return VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw", "style": "width:390px;height:844px"],
                     children: children)
    }

    private func recorder(maxFrames: Int = 50) -> WireframeRecorder {
        let r = WireframeRecorder(maxFrames: maxFrames, fps: 10, now: { [unowned self] in self.clock })
        r.screenName = { "/home" }
        return r
    }

    private func frame(_ screen: VNode?, width: Double = 390, height: Double = 844, href: String? = "/home") -> WireframeFrame {
        WireframeFrame(screen: screen, width: width, height: height, timestampMs: clock, href: href)
    }

    func testAClipReplaysToTheLastScreenTouchesIncluded() {
        let r = recorder()
        r.start()
        let start = clock
        var shown = screen(["row 0"])
        r.push(frame(shown))
        for i in 1...3 {
            clock += 500
            shown = screen((0...i).map { "row \($0)" }, from: shown.children)
            r.push(frame(shown))
        }
        r.pointerDown(pointer: 1, x: 10.4, y: 20.6, touch: true)
        r.pointerUp(pointer: 1, x: 10.4, y: 20.6, touch: true, tap: true)
        XCTAssertEqual(r.bufferedFrameCount, 4)
        clock += 2000
        let end = clock

        let clip = r.captureRecording(clipId: "c", sinceMs: start, untilMs: end)!
        let events = clip.events
        XCTAssertEqual(events.map { $0["type"]!.int! }, [4, 2, 3, 3, 3, 3, 3, 3, 5])
        XCTAssertEqual(events[0]["data"], ["href": "/home", "width": 390, "height": 844])
        let times = events.map { $0["timestamp"]!.int! }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Int64(times.first!), start)
        XCTAssertEqual(Int64(times.last!), end)
        XCTAssertEqual(events.last!["data"], ["tag": "traceway.end", "payload": [:]])
        XCTAssertEqual(clip.startedAtMs, start)
        XCTAssertEqual(clip.endedAtMs, end)
        XCTAssertEqual(clip.approxBytes, JSON.array(events).encoded().utf8.count)
        XCTAssertGreaterThan(clip.approxBytes!, 1000)

        // Touches: start, end and a click, on the screen node.
        let touches = events.filter { $0["data"]?["source"]?.int == 2 }.map { $0["data"]! }
        XCTAssertEqual(touches.map { $0["type"]!.int! }, [7, 9, 2])
        XCTAssertEqual(touches[0], ["source": 2, "type": 7, "id": JSON(screenNodeId), "x": 10, "y": 21, "pointerType": 2])

        let mirror = Mirror()
        mirror.play(events)
        XCTAssertEqual(mirror.screen.texts(), ["row 0", "row 1", "row 2", "row 3"])
        // Unchanged rows are shared, so a mutation only adds the new row.
        let mutations = events.filter { $0["data"]?["source"]?.int == 0 }
        XCTAssertEqual(mutations.map { $0["data"]!["adds"]!.array!.count }, [2, 2, 2])

        // A window that starts after the last change still shows the screen.
        let later = end - 1000
        XCTAssertTrue(r.hasFrames(sinceMs: later, untilMs: end))
        let tail = r.captureRecording(clipId: "t", sinceMs: later, untilMs: end)!
        XCTAssertEqual(tail.events.map { $0["type"]!.int! }, [4, 2, 5])
        XCTAssertEqual(tail.startedAtMs, later)
        let tailMirror = Mirror()
        tailMirror.play(tail.events)
        XCTAssertEqual(tailMirror.screen.texts(), ["row 0", "row 1", "row 2", "row 3"])

        // Nothing is on screen once the app is away.
        r.pushBlank()
        clock += 5000
        XCTAssertFalse(r.hasFrames(sinceMs: clock - 1000, untilMs: clock))
        XCTAssertNil(r.captureRecording(clipId: "x", sinceMs: clock - 1000, untilMs: clock))
    }

    func testIdenticalFramesAreSkippedAndTheRingIsBounded() {
        let r = recorder(maxFrames: 3)
        let shown = screen(["a"])
        r.push(frame(shown))
        clock += 100
        r.push(frame(shown))
        XCTAssertEqual(r.bufferedFrameCount, 1)
        // The same screen at another size is a new frame.
        r.push(frame(shown, width: 844, height: 390))
        XCTAssertEqual(r.bufferedFrameCount, 2)
        for i in 0..<5 {
            clock += 100
            r.push(frame(screen(["b\(i)"])))
        }
        XCTAssertEqual(r.bufferedFrameCount, 3)
        r.clearBuffer()
        XCTAssertEqual(r.bufferedFrameCount, 0)
    }

    func testASizeChangeOrABlankFrameStartsANewSnapshot() {
        let r = recorder()
        let start = clock
        r.push(frame(screen(["portrait"])))
        clock += 100
        r.push(frame(screen(["landscape"]), width: 844, height: 390))
        clock += 100
        r.pushBlank()
        clock += 100
        r.push(frame(screen(["back"])))
        clock += 100
        let clip = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock)!
        // Each change of size, and the away screen and the return from it, is
        // a meta event and a full snapshot.
        XCTAssertEqual(clip.events.map { $0["type"]!.int! }, [4, 2, 4, 2, 4, 2, 4, 2, 5])
        XCTAssertEqual(clip.events[2]["data"]!["width"], 844)
        let away = Mirror()
        away.play(Array(clip.events.prefix(6)))
        XCTAssertEqual(away.screen.texts(), ["App in the background"])
        let mirror = Mirror()
        mirror.play(clip.events)
        XCTAssertEqual(mirror.screen.texts(), ["back"])
        // A blank frame repeats only once.
        r.pushBlank()
        r.pushBlank()
        XCTAssertEqual(r.bufferedFrameCount, 5)
    }

    func testAClipStartsAtTheFirstFrameInsideItsWindow() {
        let r = recorder()
        XCTAssertFalse(r.hasFrames(sinceMs: nil, untilMs: nil))
        XCTAssertNil(r.captureRecording(clipId: "none", sinceMs: nil, untilMs: nil))
        clock += 1000
        let first = clock
        r.push(frame(screen(["a"])))
        // From before anything was recorded: the clip starts at the first frame.
        let clip = r.captureRecording(clipId: "c", sinceMs: first - 5000, untilMs: first + 10)!
        XCTAssertEqual(clip.startedAtMs, first)
        XCTAssertFalse(r.hasFrames(sinceMs: first + 10, untilMs: first + 10))
        XCTAssertFalse(r.hasFrames(sinceMs: first - 5000, untilMs: first))
        XCTAssertTrue(r.hasFrames(sinceMs: first - 5000, untilMs: first + 1))
        // A clip whose end is the moment of its only frame ends at once.
        XCTAssertNil(r.captureRecording(clipId: "e", sinceMs: first - 10, untilMs: first))
    }

    func testPointerEventsMapToRrwebAndMovesAreThrottled() {
        let r = recorder()
        // Not recording: pointers are not kept.
        r.pointerDown(pointer: 1, x: 1, y: 1, touch: true)
        r.start()
        let start = clock
        r.push(frame(screen(["a"])))
        r.pointerDown(pointer: 1, x: 1, y: 2, touch: true)
        clock += 10
        r.pointerMove(pointer: 1, x: 3, y: 4, touch: true)
        clock += 10
        r.pointerMove(pointer: 1, x: 5, y: 6, touch: true) // within 50 ms: dropped
        clock += 60
        r.pointerMove(pointer: 1, x: 7, y: 8, touch: true)
        r.pointerUp(pointer: 1, x: 7, y: 8, touch: true, tap: false)
        clock += 10
        r.pointerDown(pointer: 2, x: 9, y: 9, touch: false)
        r.pointerMove(pointer: 2, x: 10, y: 10, touch: false)
        r.pointerUp(pointer: 2, x: 10, y: 10, touch: false, tap: true)
        r.pointerDown(pointer: 3, x: 1, y: 1, touch: true)
        r.pointerCancel(pointer: 3, x: 1, y: 1, touch: true)
        clock += 10
        let events = r.captureRecording(clipId: "c", sinceMs: start, untilMs: clock)!.events
        let input = events.filter { $0["type"]?.int == 3 }.map { $0["data"]! }
        func describe(_ d: JSON) -> String {
            let source = d["source"]!.int!
            if source == 2 { return "i\(d["type"]!.int!)p\(d["pointerType"]!.int!)" }
            let p = d["positions"]!.array![0]
            return "m\(source)@\(p["x"]!.int!),\(p["y"]!.int!)"
        }
        XCTAssertEqual(input.map(describe), [
            "i7p2", "m6@3,4", "m6@7,8", "i9p2",
            "i1p0", "m1@10,10", "i0p0", "i2p0",
            "i7p2", "i10p2",
        ])
        XCTAssertEqual(input[1]["positions"]!.array![0]["id"]?.int, screenNodeId)
        r.stop()
        XCTAssertFalse(r.isRunning)
        // Stopping leaves the screen blank from then on.
        clock += 100
        XCTAssertFalse(r.hasFrames(sinceMs: clock - 10, untilMs: clock))
    }

    func testMaskAllInputsIsOnByDefault() {
        let r = recorder()
        XCTAssertTrue(r.maskAllInputs)
        r.maskAllInputs = false
        XCTAssertFalse(r.maskAllInputs)
    }

    func testTheAwayScreenIsWithinReservedIds() {
        let away = WireframeRecorder.awayScreen(390, 844)
        XCTAssertEqual(away.id, screenNodeId)
        XCTAssertTrue(allNodes(away).allSatisfy { $0.id < firstCapturedNodeId })
        XCTAssertEqual(away.attributes["id"], "tw")
    }
}
