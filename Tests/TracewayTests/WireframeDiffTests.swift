import XCTest
@testable import Traceway

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

private func box(_ id: Int, _ children: [VNode] = [], style: String? = nil) -> VNode {
    VNode(element: id, tag: "div", attributes: style.map { ["style": $0] } ?? [:], children: children)
}

private func screenOf(_ children: [VNode]) -> VNode {
    VNode(element: screenNodeId, tag: "div", attributes: [:], children: children)
}

// MARK: - Tests

/// The rrweb mutation between two frames (`diffScreens`), replayed through
/// the strict mirror of rrweb's replayer.
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

    func testANodeMovedToTheEndIsTheOnlyOneRemovedAndAdded() {
        let kids = (0..<6).map { box(200 + $0, style: "top:\($0)px") }
        let a = screenOf(kids)
        let b = screenOf(Array(kids.dropFirst()) + [kids[0]])
        let m = diffScreens(a, b)!
        XCTAssertEqual(m["removes"], [["parentId": JSON(screenNodeId), "id": 200]])
        let adds = m["adds"]!.array!
        XCTAssertEqual(adds.count, 1)
        XCTAssertEqual(adds[0]["node"]!["id"], 200)
        XCTAssertEqual(adds[0]["nextId"], .null, "the last child has no next sibling")
        XCTAssertEqual(m["attributes"], [])
        let mirror = Mirror()
        mirror.play([fullSnapshot(of: a)])
        mirror.mutation(m)
        XCTAssertEqual(mirror.screen.dump(), dump(b))
    }

    func testANodeMovedToAnotherParentIsAddedAgainWithItsSubtree() {
        let label = VNode(text: 301, text: "moved")
        let moving = box(300, [label, box(302)])
        let from = box(100, [moving])
        let to = box(200)
        let a = screenOf([from, to])
        let b = screenOf([box(100), box(200, [moving])])
        let m = diffScreens(a, b)!
        XCTAssertEqual(m["removes"], [["parentId": 100, "id": 300]])
        // The subtree is built node by node under its new parent.
        XCTAssertEqual(m["adds"]!.array!.map { $0["parentId"]!.int! }, [200, 300, 300])
        XCTAssertEqual(m["adds"]!.array!.map { $0["node"]!["id"]!.int! }, [300, 302, 301])
        XCTAssertEqual(m["texts"], [], "a text that moved with its parent is added, not changed")
        let mirror = Mirror()
        mirror.play([fullSnapshot(of: a)])
        mirror.mutation(m)
        XCTAssertEqual(mirror.screen.dump(), dump(b))
    }

    func testTheLongestIncreasingRunIsStrictlyIncreasing() {
        let values = [3, 1, 2, 5, 4, 6]
        let run = longestIncreasing(values).map { values[$0] }
        XCTAssertEqual(run.count, 4)
        XCTAssertEqual(run, run.sorted())
        XCTAssertEqual(Set(run).count, run.count)
        XCTAssertEqual(longestIncreasing([5, 5, 5]).count, 1, "equal values do not extend a run")
        XCTAssertEqual(longestIncreasing([0, 1, 2, 3]), [0, 1, 2, 3])
        XCTAssertEqual(longestIncreasing([3, 2, 1]).count, 1)
    }
}

/// The node model the diff and the snapshots are made of.
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

    func testTextNodesCarryNoTagAttributesOrChildren() {
        let text = VNode(text: 30, text: "")
        XCTAssertTrue(text.isText)
        XCTAssertNil(text.tag)
        XCTAssertEqual(text.attributes, [:])
        XCTAssertEqual(text.serialize(), ["type": 3, "textContent": "", "id": 30])
        XCTAssertEqual(text.serialize(withChildren: false), text.serialize())
        XCTAssertFalse(text.sameAs(VNode(text: 31, text: "")), "another id is another node")
        XCTAssertFalse(text.sameAs(VNode(element: 30, tag: "div", attributes: [:], children: [])))
    }
}
