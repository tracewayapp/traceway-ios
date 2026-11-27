import Foundation

/// The data of an rrweb mutation event (`IncrementalSource.Mutation`) that
/// turns the screen `before` into `after`, or nil when both show the same.
/// Both trees are rooted at the same node.
///
/// rrweb's replayer applies the removes first, then the adds, then text and
/// attribute changes. An add builds only its own node, never the node's
/// children, so a new subtree is added node by node, parent first, and
/// siblings from the last to the first: each add's `nextId` names a node
/// that is already on the page. A node that moved, to another parent or
/// among its siblings, is removed and added again with its whole subtree.
func diffScreens(_ before: VNode, _ after: VNode) -> JSON? {
    if before === after { return nil }
    let diff = WireframeDiff()
    diff.node(before, after)
    if diff.isEmpty { return nil }
    return [
        "source": 0,
        "texts": .array(diff.texts),
        "attributes": .array(diff.attributes),
        "removes": .array(diff.removes),
        "adds": .array(diff.adds),
    ]
}

private final class WireframeDiff {
    var texts: [JSON] = []
    var attributes: [JSON] = []
    var removes: [JSON] = []
    var adds: [JSON] = []

    var isEmpty: Bool {
        texts.isEmpty && attributes.isEmpty && removes.isEmpty && adds.isEmpty
    }

    /// `before` and `after` are the same node (same id and kind) in the two
    /// frames.
    func node(_ before: VNode, _ after: VNode) {
        if before === after { return }
        if after.isText {
            if before.text != after.text {
                texts.append(["id": JSON(after.id), "value": .string(after.text ?? "")])
            }
            return
        }
        changedAttributes(before, after)
        changedChildren(before, after)
    }

    private func changedAttributes(_ before: VNode, _ after: VNode) {
        var changed: [String: JSON] = [:]
        for (key, value) in after.attributes where before.attributes[key] != value {
            changed[key] = .string(value)
        }
        for key in before.attributes.keys where after.attributes[key] == nil {
            changed[key] = .null
        }
        if !changed.isEmpty {
            attributes.append(["id": JSON(after.id), "attributes": .object(changed)])
        }
    }

    private func changedChildren(_ before: VNode, _ after: VNode) {
        let oldChildren = before.children
        let newChildren = after.children

        var oldIndex: [Int: Int] = [:]
        for (i, child) in oldChildren.enumerated() { oldIndex[child.id] = i }
        // The children that are still here, as their old positions in their
        // new order. The longest increasing run of those stays in place;
        // every other one moved.
        var keptNew: [Int] = []
        var keptOld: [Int] = []
        for (i, child) in newChildren.enumerated() {
            if let at = oldIndex[child.id], oldChildren[at].tag == child.tag {
                keptNew.append(i)
                keptOld.append(at)
            }
        }
        var inPlace = Set<Int>()
        for k in longestIncreasing(keptOld) {
            inPlace.insert(newChildren[keptNew[k]].id)
        }

        for child in oldChildren where !inPlace.contains(child.id) {
            removes.append(["parentId": JSON(before.id), "id": JSON(child.id)])
        }
        for child in newChildren where inPlace.contains(child.id) {
            if let index = oldIndex[child.id] { node(oldChildren[index], child) }
        }
        var i = newChildren.count - 1
        while i >= 0 {
            let child = newChildren[i]
            if !inPlace.contains(child.id) {
                add(child, parentId: after.id, nextId: i + 1 < newChildren.count ? newChildren[i + 1].id : nil)
            }
            i -= 1
        }
    }

    private func add(_ node: VNode, parentId: Int, nextId: Int?) {
        adds.append([
            "parentId": JSON(parentId),
            "nextId": nextId.map { JSON($0) } ?? .null,
            "node": node.serialize(withChildren: false),
        ])
        let children = node.children
        var i = children.count - 1
        while i >= 0 {
            add(children[i], parentId: node.id, nextId: i + 1 < children.count ? children[i + 1].id : nil)
            i -= 1
        }
    }
}

/// Positions in `values` of one longest strictly increasing subsequence.
func longestIncreasing(_ values: [Int]) -> [Int] {
    if values.isEmpty { return [] }
    // tails[k]: position of the smallest last value of a run of length k + 1.
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: values.count)
    for i in 0..<values.count {
        var lo = 0
        var hi = tails.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if values[tails[mid]] < values[i] {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 { previous[i] = tails[lo - 1] }
        if lo == tails.count {
            tails.append(i)
        } else {
            tails[lo] = i
        }
    }
    var out = [Int](repeating: 0, count: tails.count)
    var k = tails[tails.count - 1]
    var i = tails.count - 1
    while i >= 0 {
        out[i] = k
        k = previous[k]
        i -= 1
    }
    return out
}
