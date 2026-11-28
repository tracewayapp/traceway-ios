import Foundation

/// Photos and glyphs each occupy a separate rrweb style node. Both full
/// snapshots and mutations serialize its rule in an `_cssText` attribute.
/// Emptying only that rule leaves the base wireframe styles, node IDs,
/// geometry, mask placeholders and interactions intact.
enum WireframeRasterBudget {
    static let maxBytes = 128 * 1024

    static func layoutOnlyIfNeeded(_ events: [JSON]) -> [JSON]? {
        var remaining = maxBytes
        guard events.contains(where: { exceeds($0, remaining: &remaining) }) else { return nil }
        return events.map(withoutRaster)
    }

    private static func exceeds(_ value: JSON, remaining: inout Int) -> Bool {
        switch value {
        case .array(let items):
            return items.contains { exceeds($0, remaining: &remaining) }
        case .object(let fields):
            if let css = fields["_cssText"]?.string {
                let size = rasterBytes(in: css)
                if size > remaining { return true }
                remaining -= size
            }
            return fields.values.contains { exceeds($0, remaining: &remaining) }
        default:
            return false
        }
    }

    private static func withoutRaster(_ value: JSON) -> JSON {
        switch value {
        case .array(let items):
            return .array(items.map(withoutRaster))
        case .object(let fields):
            var layout = fields.mapValues(withoutRaster)
            if let css = fields["_cssText"]?.string, rasterBytes(in: css) > 0 {
                layout["_cssText"] = .string("")
            }
            return .object(layout)
        default:
            return value
        }
    }

    /// Data URL bytes as they appear in the uncompressed recording, including
    /// the media type, base64 prefix and padding. The SDK generates unquoted
    /// JPEG and PNG URLs; their ASCII bytes are unchanged by JSON encoding.
    static func rasterBytes(in css: String) -> Int {
        var remaining = css[...]
        var bytes = 0
        while let marker = remaining.range(of: "url(data:image/"),
              let end = remaining[marker.upperBound...].firstIndex(of: ")") {
            let start = remaining.index(marker.lowerBound, offsetBy: 4)
            let url = remaining[start..<end]
            if url.hasPrefix("data:image/jpeg;base64,") || url.hasPrefix("data:image/png;base64,") {
                bytes += url.utf8.count
            }
            remaining = remaining[remaining.index(after: end)...]
        }
        return bytes
    }
}

/// The picture and glyph rules of one captured screen: the style nodes
/// among its children whose rule holds a data URL, and which of them a
/// node of the screen shows. A frame holds the rule of every picture shown
/// in the last 30 s, so that one that comes back is not sent again; most of
/// them show nothing.
struct FrameRasters {
    /// By style node id: the class the rule draws (`p12` for
    /// `.im.p12{…}`, `g3` for `.ic.g3::before{…}`), its data URL bytes and
    /// the rule.
    let styles: [Int: (cls: String, bytes: Int, css: String)]
    /// The style nodes whose class a node of the screen has.
    let shown: Set<Int>

    init(_ screen: VNode) {
        var styles: [Int: (cls: String, bytes: Int, css: String)] = [:]
        for child in screen.children where child.tag == "style" {
            guard let css = child.attributes["_cssText"] else { continue }
            let bytes = WireframeRasterBudget.rasterBytes(in: css)
            guard bytes > 0, let cls = FrameRasters.drawnClass(css) else { continue }
            styles[child.id] = (cls, bytes, css)
        }
        self.styles = styles
        guard !styles.isEmpty else {
            shown = []
            return
        }
        var used = Set<String>()
        var stack = screen.children.filter { styles[$0.id] == nil }
        while let node = stack.popLast() {
            if let cls = node.attributes["class"] {
                for name in cls.split(separator: " ") { used.insert(String(name)) }
            }
            stack.append(contentsOf: node.children)
        }
        shown = Set(styles.filter { used.contains($0.value.cls) }.keys)
    }

    /// The last class of the rule's selector, before any pseudo-element.
    static func drawnClass(_ css: String) -> String? {
        guard let brace = css.firstIndex(of: "{") else { return nil }
        var selector = css[..<brace]
        if let colon = selector.firstIndex(of: ":") { selector = selector[..<colon] }
        guard let dot = selector.lastIndex(of: "."), selector.index(after: dot) < selector.endIndex else { return nil }
        return String(selector[selector.index(after: dot)...])
    }
}

/// The rules a clip carries, frame by frame, and their data URL bytes. A
/// clip opens with the rules of what its first frame shows, adds a rule
/// when a later frame first shows its picture, and keeps it while the
/// frames still hold it (a picture that comes back within the clip is not
/// sent again). A rule that changes is sent again. Rules nothing in the
/// clip showed are left out.
struct ClipRasters {
    /// The next frame of the clip: the screen as the clip shows it, the
    /// rules it carries and the bytes they add.
    struct Step {
        let view: VNode
        let included: [Int: String]
        let added: Int
    }

    /// The rules carried, by style node id.
    private(set) var included: [Int: String] = [:]
    /// Data URL bytes the clip carries so far.
    private(set) var bytes = 0

    /// `fresh`: the frame is a full snapshot, which carries its rules again.
    func step(_ screen: VNode, _ rasters: FrameRasters, fresh: Bool) -> Step {
        var next: [Int: String] = [:]
        var added = 0
        for (id, style) in rasters.styles where rasters.shown.contains(id) || (!fresh && included[id] != nil) {
            next[id] = style.css
            if fresh || included[id] != style.css { added += style.bytes }
        }
        if next.count == rasters.styles.count { return Step(view: screen, included: next, added: added) }
        let children = screen.children.filter { rasters.styles[$0.id] == nil || next[$0.id] != nil }
        let view = VNode(element: screen.id, tag: screen.tag ?? "div", attributes: screen.attributes, children: children)
        return Step(view: view, included: next, added: added)
    }

    mutating func take(_ step: Step) {
        included = step.included
        bytes += step.added
    }

    /// A frame without a screen: the next one is a full snapshot.
    mutating func clearScreen() { included = [:] }
}
