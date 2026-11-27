#if canImport(UIKit)
import UIKit
import QuartzCore

// The SwiftUI part of `WireframeCapture`'s convert step. SwiftUI draws most
// of its content without views of its own: inside a hosting view the walk
// sees the layers SwiftUI uses for colors, shapes and images, and reads
// text from the hosting view's accessibility elements (at most once a
// second per hosting view), which iOS fills in while an assistive
// technology runs. Without them a `Text` is a neutral bar where its lines
// are (`.sk`, `.sk.sm`), as masked text would be.

extension WireframeCapture {
    final class SwiftUIText {
        let rect: WireframeRect
        let label: String
        let isStatic: Bool
        let isButton: Bool
        var used = false

        init(rect: WireframeRect, label: String, isStatic: Bool, isButton: Bool) {
            self.rect = rect
            self.label = label
            self.isStatic = isStatic
            self.isButton = isButton
        }
    }

    struct CachedTexts {
        weak var host: UIView?
        var ms: Int64
        var items: [(WireframeRect, String, Bool, Bool)]
    }

    /// The text a hosting view shows, as its accessibility elements describe
    /// it: frame, label and whether it is static text or a button. Read at
    /// most once a second per hosting view.
    func swiftUITexts(of host: UIView) -> [SwiftUIText] {
        guard let screen = screenWindow else { return [] }
        let key = ObjectIdentifier(host)
        if let cached = textCache[key], cached.host === host, nowMs - cached.ms < 1000 {
            return cached.items.map { SwiftUIText(rect: $0.0, label: $0.1, isStatic: $0.2, isButton: $0.3) }
        }
        var items: [(WireframeRect, String, Bool, Bool)] = []
        var visitedElements = 0
        let screenSpace = screen.screen.coordinateSpace

        func walk(_ element: Any, depth: Int) {
            guard visitedElements < 400, depth < 10, items.count < 200 else { return }
            visitedElements += 1
            guard let object = element as? NSObject else { return }
            // Real views are walked as views.
            if object is UIView { return }
            if object.isAccessibilityElement {
                let traits = object.accessibilityTraits
                let isStatic = traits.contains(.staticText)
                let isButton = traits.contains(.button) || traits.contains(.link)
                if traits.contains(.image) && !isStatic { return }
                let parts = [object.accessibilityLabel, object.accessibilityValue]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                guard !parts.isEmpty else { return }
                let frame = screen.convert(object.accessibilityFrame, from: screenSpace)
                guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite else { return }
                items.append((
                    WireframeRect(x: Double(frame.minX), y: Double(frame.minY),
                                  width: Double(frame.width), height: Double(frame.height)),
                    parts.joined(separator: " "), isStatic, isButton
                ))
                return
            }
            for child in WireframeCapture.accessibilityChildren(of: object) { walk(child, depth: depth + 1) }
        }

        for child in WireframeCapture.accessibilityChildren(of: host) { walk(child, depth: 0) }
        textCache[key] = CachedTexts(host: host, ms: nowMs, items: items)
        return items.map { SwiftUIText(rect: $0.0, label: $0.1, isStatic: $0.2, isButton: $0.3) }
    }

    private static func accessibilityChildren(of object: NSObject) -> [Any] {
        if let elements = object.accessibilityElements, !elements.isEmpty { return elements }
        let count = object.accessibilityElementCount()
        guard count > 0, count < 500 else { return [] }
        var out: [Any] = []
        for i in 0..<count {
            if let element = object.accessibilityElement(at: i) { out.append(element) }
        }
        return out
    }

    /// The text item best placed at `box`: one whose frame holds the box's
    /// center, static text first, the smallest first.
    private func takeText(at box: WireframeRect) -> SwiftUIText? {
        guard let texts = hostTexts.last else { return nil }
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        var best: SwiftUIText?
        for item in texts where !item.used {
            let r = item.rect
            guard WireframeRect(x: r.x - 2, y: r.y - 2, width: r.width + 4, height: r.height + 4).contains(x: cx, y: cy)
            else { continue }
            if let current = best {
                if item.isStatic != current.isStatic {
                    if item.isStatic { best = item }
                } else if r.width * r.height < current.rect.width * current.rect.height {
                    best = item
                }
            } else {
                best = item
            }
        }
        best?.used = true
        return best
    }

    /// A layer SwiftUI draws one `Text` into. Its words are only known when
    /// the hosting view's accessibility describes them, which iOS does while
    /// an assistive technology runs; otherwise the text is a neutral bar
    /// where its lines are, as a masked text would be.
    func swiftUIText(_ model: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let style = geometry(s, p)
        if let item = takeText(at: p.box), let visible = shown(item.label, p.box, s) {
            let color = screenWindow.map { textColor(for: item, $0) } ?? .black
            out.append(element(
                id(model), style + swiftUITextCss(height: p.height, color: color),
                [textNode(id(model, 1), visible)], cls: p.height < 40 ? "t n" : "t"
            ))
            return
        }
        if privacy(p.box, s) == .hide || p.width < 1 || p.height < 1 { return }
        out.append(element(id(model), style, [], cls: p.height <= 48 ? "sk" : "sk sm"))
    }

    /// The glyph class of a small layer picture that has see-through pixels
    /// (an icon: a photo is opaque and stays a placeholder), drawn as its
    /// shape only.
    func smallImageGlyph(_ layer: CALayer, _ p: Placed, _ s: Scope) -> String? {
        guard p.width <= 40, p.height <= 40, !s.blockImages, privacy(p.box, s) == .show,
              let contents = layer.contents
        else { return nil }
        let ref = contents as AnyObject
        guard CFGetTypeID(ref) == CGImage.typeID else { return nil }
        let image = ref as! CGImage
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let glyph = glyphs?.lookup(image, size: CGSize(width: p.width, height: p.height))
        else { return nil }
        shownGlyphs.insert(glyph.cls)
        return glyph.cls
    }

    /// A view SwiftUI draws text and shapes into. When the hosting view's
    /// accessibility names text at its place, that text is shown.
    func swiftUIDrawing(_ view: UIView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let (style, paints) = boxCss(s, p, layer, view)
        guard let item = takeText(at: p.box), let visible = shown(item.label, p.box, s) else {
            if paints { out.append(element(id(view), style, [])) }
            return
        }
        let color = textColor(for: item, view)
        out.append(element(
            id(view), style + swiftUITextCss(height: p.height, color: color),
            [textNode(id(view, 1), visible)], cls: p.height < 40 ? "t n" : "t"
        ))
    }

    /// Text the hosting view's accessibility names that no drawing view
    /// showed, placed where its frame is, above the hosting view's content.
    func remainingSwiftUITexts(_ texts: [SwiftUIText], _ host: UIView, _ s: Scope, _ out: inout [VNode]) {
        for (index, item) in texts.enumerated() where !item.used && (item.isStatic || item.isButton) {
            guard item.rect.overlaps(s.clip), let visible = shown(item.label, item.rect, s) else { continue }
            let t = WireframeAffine.translation(item.rect.x, item.rect.y)
            let style = wireframeGeometry(origin: s.origin, transform: t, width: item.rect.width, height: item.rect.height)
                + swiftUITextCss(height: item.rect.height, color: textColor(for: item, host))
            out.append(element(
                id(host, 100_000 + 2 * index), style,
                [textNode(id(host, 100_001 + 2 * index), visible)], cls: item.rect.height < 40 ? "t n" : "t"
            ))
        }
    }

    private func textColor(for item: SwiftUIText, _ view: UIView) -> WireframeColor {
        let traits = view.traitCollection
        if item.isButton && !item.isStatic, let tint = WireframeCapture.color(view.tintColor, traits) { return tint }
        return WireframeCapture.color(UIColor.label, traits) ?? .black
    }

    /// The font is not known: a line is sized from its frame.
    private func swiftUITextCss(height: Double, color: WireframeColor) -> String {
        if height < 40 {
            let size = min(max(height / 1.25, 9), 34)
            return "font-size:\(WireframeCSS.px(size));line-height:\(WireframeCSS.px(height));"
                + "color:\(WireframeCSS.color(color));align-items:center;"
        }
        return "font-size:15px;line-height:18px;color:\(WireframeCSS.color(color));"
    }
}
#endif
