import Foundation

/// What a selector can see of one view.
final class ViewNodeInfo {
    /// The class name without module or generic arguments.
    let type: String
    let ids: [String]
    let roles: Set<String>
    let values: [String: String]

    private let labelSource: () -> String?
    private let textSource: () -> String?
    private var labelRead = false
    private var labelValue: String?
    private var textRead = false
    private var textValue: String?

    init(
        type: String,
        ids: [String] = [],
        roles: Set<String> = [],
        values: [String: String] = [:],
        label: @escaping () -> String? = { nil },
        text: @escaping () -> String? = { nil }
    ) {
        self.type = type
        self.ids = ids
        self.roles = roles
        self.values = values
        labelSource = label
        textSource = text
    }

    /// The accessibility label of this view, else the first one below it
    /// (as long as the hierarchy does not branch).
    var label: String? {
        if !labelRead {
            labelRead = true
            labelValue = values["label"] ?? labelSource()
        }
        return labelValue
    }

    /// The text this view shows; never the content of an input field.
    var text: String? {
        if !textRead {
            textRead = true
            textValue = textSource()
        }
        return textValue
    }

    func attribute(_ name: String) -> String? {
        switch name {
        case "text": return text
        case "type": return type
        case "id": return ids.first
        case "label": return label
        default: return values[name]
        }
    }
}

/// The view under the pointer and its ancestors, deepest first.
protocol SelectorPath {
    associatedtype Node: AnyObject
    var count: Int { get }
    /// 0 is the deepest view.
    func node(at index: Int) -> Node
    func info(_ node: Node) -> ViewNodeInfo
    func children(of node: Node) -> [Node]
}

/// How the SDK names a view for click and hover triggers, with the CSS
/// selector syntax the dashboard already accepts for the browser SDK. A
/// selector runs over the view hierarchy under the pointer:
///
/// | Selector | Matches a view whose |
/// |---|---|
/// | `UIButton` | class is that one (module and generic arguments ignored, any case) |
/// | `#checkout` | `accessibilityIdentifier` is `checkout` |
/// | `.button` | accessibility role is that: `button`, `link`, `header`, `image`, `textField`, `slider`, `checkbox`, `toggle`, `selected` |
/// | `[key="42"]` | `tag` is 42 |
/// | `[identifier="..."]` | `accessibilityIdentifier` |
/// | `[label="Delete"]` | accessibility label, its own or the first below it |
/// | `[text="Pay"]` | shown text: a label's, a button's title, or the labels under it (inputs excluded) |
/// | `[type="_Private"]` | class, for a class that cannot be written as a tag |
///
/// Attribute values support `=`, `~=`, `|=`, `^=`, `$=` and `*=`; a
/// descendant (space), child (`>`), adjacent (`+`) or general (`~`) sibling
/// combinator relates views of the hierarchy. A tap matches a selector when
/// the view under the finger or one of its ancestors does, as a browser
/// click matches its target or an ancestor.
final class ViewSelector {
    private let compounds: [Compound]
    /// `combinators[i]` joins `compounds[i]` and `compounds[i + 1]`.
    private let combinators: [Character]

    fileprivate init(_ compounds: [Compound], _ combinators: [Character]) {
        self.compounds = compounds
        self.combinators = combinators
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: ViewSelector?] = [:]

    /// Parses `text`, or returns nil for a selector this SDK cannot run.
    /// Pseudo-classes, selector lists and escapes are not supported, the
    /// same as for the browser SDK.
    static func parse(_ text: String) -> ViewSelector? {
        cacheLock.lock()
        if let cached = cache[text] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let parsed = SelectorParser(text).parse()
        cacheLock.lock()
        if cache.count > 200 { cache.removeAll() }
        cache[text] = .some(parsed)
        cacheLock.unlock()
        return parsed
    }

    /// Index of the deepest view of `path` the selector matches, or nil.
    func firstMatch<P: SelectorPath>(_ path: P) -> Int? {
        firstMatch(path, where: { _ in true })
    }

    func matches<P: SelectorPath>(_ path: P) -> Bool {
        firstMatch(path) != nil
    }

    /// Like `firstMatch`, among the views `accept` allows.
    func firstMatch<P: SelectorPath>(_ path: P, where accept: (P.Node) -> Bool) -> Int? {
        let budget = Budget()
        for i in 0..<path.count {
            let node = path.node(at: i)
            if accept(node) && matchesNode(path, node, i + 1, budget) { return i }
            if budget.exhausted { return nil }
        }
        return nil
    }

    private func matchesNode<P: SelectorPath>(
        _ path: P, _ node: P.Node, _ parentIndex: Int, _ budget: Budget
    ) -> Bool {
        let last = compounds.count - 1
        return compounds[last].test(path.info(node), budget)
            && matchLeft(path, last, node, parentIndex, budget)
    }

    /// `node` matched compound `ci`; checks the compounds to its left.
    /// `parentIndex` is where `node`'s ancestors start in `path`.
    private func matchLeft<P: SelectorPath>(
        _ path: P, _ ci: Int, _ node: P.Node, _ parentIndex: Int, _ budget: Budget
    ) -> Bool {
        if ci == 0 { return true }
        if budget.exhausted { return false }
        let left = compounds[ci - 1]
        switch combinators[ci - 1] {
        case ">":
            guard parentIndex < path.count else { return false }
            let parent = path.node(at: parentIndex)
            return left.test(path.info(parent), budget)
                && matchLeft(path, ci - 1, parent, parentIndex + 1, budget)
        case "+", "~":
            guard parentIndex < path.count else { return false }
            let siblings = path.children(of: path.node(at: parentIndex))
            guard let index = siblings.firstIndex(where: { $0 === node }), index > 0 else { return false }
            let lowest = combinators[ci - 1] == "+" ? index - 1 : 0
            var k = index - 1
            while k >= lowest {
                let sibling = siblings[k]
                if left.test(path.info(sibling), budget)
                    && matchLeft(path, ci - 1, sibling, parentIndex, budget) {
                    return true
                }
                k -= 1
            }
            return false
        default:
            var j = parentIndex
            while j < path.count {
                let ancestor = path.node(at: j)
                if left.test(path.info(ancestor), budget)
                    && matchLeft(path, ci - 1, ancestor, j + 1, budget) {
                    return true
                }
                if budget.exhausted { return false }
                j += 1
            }
            return false
        }
    }
}

/// Bounds the work of one match, so a selector with many descendant
/// combinators cannot stall a tap on a deep hierarchy.
private final class Budget {
    var remaining = 20_000
    var exhausted: Bool { remaining <= 0 }
}

private struct AttributeTest {
    let name: String
    let op: String?
    let value: String?

    func test(_ actual: String?) -> Bool {
        guard let actual = actual else { return false }
        guard let op = op, let value = value else { return true }
        switch op {
        case "=":
            return actual == value
        case "~=":
            return !value.isEmpty && actual.split(whereSeparator: { $0.isWhitespace }).contains { $0 == value }
        case "|=":
            return actual == value || actual.hasPrefix(value + "-")
        case "^=":
            return !value.isEmpty && actual.hasPrefix(value)
        case "$=":
            return !value.isEmpty && actual.hasSuffix(value)
        case "*=":
            return !value.isEmpty && actual.contains(value)
        default:
            return false
        }
    }
}

private final class Compound {
    var tag: String?
    var ids: [String] = []
    var classes: [String] = []
    var attributes: [AttributeTest] = []

    var isEmpty: Bool { tag == nil && ids.isEmpty && classes.isEmpty && attributes.isEmpty }

    func test(_ info: ViewNodeInfo, _ budget: Budget) -> Bool {
        budget.remaining -= 1
        if let tag = tag, tag != "*", info.type.lowercased() != tag.lowercased() { return false }
        for id in ids where !info.ids.contains(id) { return false }
        for role in classes where !info.roles.contains(role) { return false }
        for attribute in attributes where !attribute.test(info.attribute(attribute.name)) { return false }
        return true
    }
}

private func isAsciiLetter(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return (a >= 65 && a <= 90) || (a >= 97 && a <= 122)
}

private func isAsciiDigit(_ c: Character) -> Bool {
    guard let a = c.asciiValue else { return false }
    return a >= 48 && a <= 57
}

/// `[A-Za-z0-9_-]`
private func isNameChar(_ c: Character) -> Bool {
    isAsciiLetter(c) || isAsciiDigit(c) || c == "_" || c == "-"
}

/// Whole-string checks of the selector grammar, for building selectors.
enum SelectorSyntax {
    /// `(?:-?[A-Za-z_]|--)[A-Za-z0-9_-]*`
    static func isIdent(_ text: String) -> Bool {
        let chars = Array(text)
        return identLength(chars, 0) == chars.count && !chars.isEmpty
    }

    /// `[A-Za-z][A-Za-z0-9_-]*`
    static func isTag(_ text: String) -> Bool {
        let chars = Array(text)
        return tagLength(chars, 0) == chars.count && !chars.isEmpty
    }

    /// Length of the identifier at `i`, 0 when there is none.
    static func identLength(_ chars: [Character], _ i: Int) -> Int {
        var j = i
        guard j < chars.count else { return 0 }
        if chars[j] == "-" {
            guard j + 1 < chars.count else { return 0 }
            let next = chars[j + 1]
            if next == "-" || isAsciiLetter(next) || next == "_" {
                j += 2
            } else {
                return 0
            }
        } else if isAsciiLetter(chars[j]) || chars[j] == "_" {
            j += 1
        } else {
            return 0
        }
        while j < chars.count && isNameChar(chars[j]) { j += 1 }
        return j - i
    }

    static func tagLength(_ chars: [Character], _ i: Int) -> Int {
        guard i < chars.count, isAsciiLetter(chars[i]) else { return 0 }
        var j = i + 1
        while j < chars.count && isNameChar(chars[j]) { j += 1 }
        return j - i
    }
}

private final class SelectorParser {
    private let source: String
    private let chars: [Character]
    private var i = 0

    init(_ text: String) {
        source = text
        chars = Array(text)
    }

    private var done: Bool { i >= chars.count }
    private var char: Character { chars[i] }

    private func skipSpace() {
        while !done && (char == " " || char == "\t" || char == "\n" || char == "\r" || char == "\u{0C}") {
            i += 1
        }
    }

    private func readIdent() -> String? {
        let length = SelectorSyntax.identLength(chars, i)
        guard length > 0 else { return nil }
        defer { i += length }
        return String(chars[i..<(i + length)])
    }

    private func readTag() -> String? {
        let length = SelectorSyntax.tagLength(chars, i)
        guard length > 0 else { return nil }
        defer { i += length }
        return String(chars[i..<(i + length)])
    }

    func parse() -> ViewSelector? {
        if source.utf16.count > 256 || chars.contains(where: { $0 == ":" || $0 == "," || $0 == "\\" }) {
            return nil
        }
        var compounds: [Compound] = []
        var combinators: [Character] = []
        skipSpace()
        while true {
            guard let compound = readCompound() else { return nil }
            compounds.append(compound)
            let before = i
            skipSpace()
            if done { break }
            if char == ">" || char == "+" || char == "~" {
                combinators.append(char)
                i += 1
                skipSpace()
            } else if i > before {
                combinators.append(" ")
            } else {
                return nil
            }
        }
        if compounds.isEmpty { return nil }
        return ViewSelector(compounds, combinators)
    }

    private func readCompound() -> Compound? {
        let compound = Compound()
        if !done && char == "*" {
            compound.tag = "*"
            i += 1
        } else {
            compound.tag = readTag()
        }
        while !done {
            let c = char
            if c == "#" || c == "." {
                i += 1
                guard let name = readIdent() else { return nil }
                if c == "#" { compound.ids.append(name) } else { compound.classes.append(name) }
            } else if c == "[" {
                i += 1
                guard let attribute = readAttribute() else { return nil }
                compound.attributes.append(attribute)
            } else {
                break
            }
        }
        return compound.isEmpty ? nil : compound
    }

    private func readAttribute() -> AttributeTest? {
        skipSpace()
        guard let name = readIdent() else { return nil }
        skipSpace()
        if done { return nil }
        if char == "]" {
            i += 1
            return AttributeTest(name: name, op: nil, value: nil)
        }
        let op: String
        if char == "=" {
            op = "="
            i += 1
        } else if i + 1 < chars.count && "~|^$*".contains(char) && chars[i + 1] == "=" {
            op = String(char) + "="
            i += 2
        } else {
            return nil
        }
        skipSpace()
        if done { return nil }
        let value: String
        if char == "\"" || char == "'" {
            let quote = char
            var end = i + 1
            while end < chars.count && chars[end] != quote { end += 1 }
            guard end < chars.count else { return nil }
            let quoted = String(chars[(i + 1)..<end])
            if quoted.contains("\n") || quoted.contains("\r") { return nil }
            value = quoted
            i = end + 1
        } else {
            guard let ident = readIdent() else { return nil }
            value = ident
        }
        skipSpace()
        if done || char != "]" { return nil }
        i += 1
        return AttributeTest(name: name, op: op, value: value)
    }
}

// MARK: - Describing a tap

/// The view a tap landed on, as the `browser.user_action.click` record
/// names it.
struct TapTarget: Equatable {
    /// A selector that matches the tap, preferring the most stable naming.
    var selector: String
    /// The class of the view that handled the tap.
    var tag: String
    var id: String?
    var text: String?
    var label: String?
}

/// How a platform classifies the views of a tap's path, for `describeTap`.
struct TapClassifier<Node> {
    /// The path ends below the first such view (a window); everything from
    /// it up is left out. When the deepest view is one, the whole path is
    /// used.
    var isBoundary: (Node) -> Bool
    /// A view that names itself as what was tapped (a control, a cell).
    var isControl: (Node) -> Bool
    /// A view that handles taps without being a named control; the named
    /// control above it, if any, is preferred.
    var isTapHandler: (Node) -> Bool = { _ in false }
    /// Plumbing such a handler sits in (the outermost one near the handler
    /// is named when no control is found).
    var isPrimitive: (Node) -> Bool = { _ in false }
    /// Content that names a tap nothing handles: a label, an image.
    var isContent: (Node) -> Bool
    /// Whether the view at this index of the path is inside a privacy mask.
    var isMasked: (Int) -> Bool
    /// The text a view shows, masked views and inputs excluded.
    var shownText: (Node) -> String?
}

private let unsafeSelectorCharacters: Set<Character> = [":", ",", "\\", "\"", "\r", "\n"]

private func quotedSelectorValue(_ value: String) -> String? {
    if value.isEmpty || value.contains(where: { unsafeSelectorCharacters.contains($0) }) { return nil }
    return "\"\(value)\""
}

/// Names the view a tap at the deepest view of `path` landed on: the owner
/// is the nearest control, else the nearest handler (or the named control
/// right above it), else the nearest content, else the deepest view. The
/// selector prefers an id, then a key, the shown text, the label, a role,
/// an id further up and the class alone, and is the first of those that
/// parses and matches the path.
func describeTap<P: SelectorPath>(
    _ path: P,
    classifier: TapClassifier<P.Node>,
    includeText: Bool = true
) -> TapTarget? {
    guard path.count > 0 else { return nil }
    var limit = path.count
    for i in 0..<path.count where classifier.isBoundary(path.node(at: i)) {
        limit = i
        break
    }
    if limit == 0 { limit = path.count }

    var owner = -1
    for i in 0..<limit {
        let node = path.node(at: i)
        if classifier.isControl(node) {
            owner = i
            break
        }
        if !classifier.isTapHandler(node) { continue }
        var outermostPrimitive = i
        var j = i + 1
        while j < limit && j <= i + 96 {
            let above = path.node(at: j)
            if classifier.isControl(above) {
                owner = j
                break
            }
            if classifier.isTapHandler(above) && j > i + 1 { break }
            if classifier.isPrimitive(above) && j <= i + 16 { outermostPrimitive = j }
            j += 1
        }
        if owner < 0 { owner = outermostPrimitive }
        break
    }
    if owner < 0 {
        for i in 0..<limit where classifier.isContent(path.node(at: i)) {
            owner = i
            break
        }
    }
    if owner < 0 { owner = 0 }

    let ownerNode = path.node(at: owner)
    let info = path.info(ownerNode)
    let masked = classifier.isMasked(owner)
    let text = includeText && !masked ? classifier.shownText(ownerNode) : nil

    // An id on the target, on a wrapper right above it (the app's own view
    // with an identifier) or inside it.
    var order = [owner]
    var j = owner + 1
    while j < limit && j <= owner + 6 {
        order.append(j)
        j += 1
    }
    j = owner - 1
    while j >= 0 {
        order.append(j)
        j -= 1
    }
    var idIndex: Int?
    for i in order where !path.info(path.node(at: i)).ids.isEmpty {
        idIndex = i
        break
    }

    func tagOf(_ i: Int) -> String {
        let type = path.info(path.node(at: i)).type
        if SelectorSyntax.isTag(type) { return type }
        guard let quoted = quotedSelectorValue(type) else { return "*" }
        return "[type=\(quoted)]"
    }

    func withTag(_ tag: String, _ rest: String) -> String {
        tag == "*" ? rest : tag + rest
    }

    var candidates: [String] = []
    var id: String?
    if let idIndex = idIndex {
        let idInfo = path.info(path.node(at: idIndex))
        let first = idInfo.ids[0]
        id = first
        let tag = tagOf(idIndex)
        if SelectorSyntax.isIdent(first) {
            candidates.append(withTag(tag, "#" + first))
        } else {
            let name = idInfo.values["identifier"] == first ? "identifier" : "key"
            if let quoted = quotedSelectorValue(first) {
                candidates.append(withTag(tag, "[\(name)=\(quoted)]"))
            }
        }
    }
    let tag = tagOf(owner)
    if let key = info.values["key"], key != id, let quoted = quotedSelectorValue(key) {
        candidates.append(withTag(tag, "[key=\(quoted)]"))
    }
    if let text = text, text.count <= 40 {
        if let quoted = quotedSelectorValue(text) {
            candidates.append(withTag(tag, "[text=\(quoted)]"))
        } else {
            let prefix = String(text.prefix(while: { !unsafeSelectorCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespaces)
            if prefix.count >= 2 { candidates.append(withTag(tag, "[text^=\"\(prefix)\"]")) }
        }
    }
    let label = masked ? nil : info.label
    if let label = label, label.count <= 60, let quoted = quotedSelectorValue(label) {
        candidates.append(withTag(tag, "[label=\(quoted)]"))
    }
    if tag == "*" {
        for role in info.roles.sorted() { candidates.append("." + role) }
    }
    j = owner + 1
    while j < limit {
        let ancestor = path.info(path.node(at: j))
        if let first = ancestor.ids.first, SelectorSyntax.isIdent(first) {
            candidates.append("#\(first) \(tag)")
            break
        }
        j += 1
    }
    candidates.append(tag)

    var selector = tag
    for candidate in candidates where candidate.utf16.count <= 256 {
        if let parsed = ViewSelector.parse(candidate), parsed.matches(path) {
            selector = candidate
            break
        }
    }
    return TapTarget(selector: selector, tag: info.type, id: id, text: text, label: label)
}

/// Collapses whitespace and bounds the length of text read from a view;
/// nil when nothing is left.
func cleanShownText(_ text: String) -> String? {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    if collapsed.isEmpty { return nil }
    return collapsed.count > 256 ? String(collapsed.prefix(256)) : collapsed
}

/// A class name as selectors see it: without generic arguments or a module
/// or enclosing type prefix (`Shop.CheckoutButton<Int>` is `CheckoutButton`).
func selectorTypeName(_ className: String) -> String {
    var name = Substring(className)
    if let generic = name.firstIndex(of: "<") { name = name[..<generic] }
    if let dot = name.lastIndex(of: ".") { name = name[name.index(after: dot)...] }
    return String(name)
}
