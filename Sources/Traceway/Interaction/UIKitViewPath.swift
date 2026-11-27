#if canImport(UIKit)
import UIKit

// Click selectors and tap descriptions over the live UIKit hierarchy. Every
// function here reads UIKit state: call them on the main thread.

/// The view under a tap and its ancestors up to and including its window,
/// deepest first.
final class UIViewPath: SelectorPath {
    typealias Node = UIView

    let views: [UIView]
    private var infoCache: [ObjectIdentifier: ViewNodeInfo] = [:]
    private var childrenCache: [ObjectIdentifier: [UIView]] = [:]

    init(leaf: UIView) {
        var chain: [UIView] = []
        var current: UIView? = leaf
        while let view = current, chain.count < 4096 {
            chain.append(view)
            if view is UIWindow { break }
            current = view.superview
        }
        views = chain
    }

    /// The path under `point` (in `window` coordinates). `hitTest` stops at
    /// the deepest view that takes touches; labels and images do not, so the
    /// path continues into the topmost visible subview under the point, the
    /// way a browser's target is the element drawn there.
    static func at(_ point: CGPoint, in window: UIWindow) -> UIViewPath? {
        guard let hit = window.hitTest(point, with: nil) else { return nil }
        if TracewayIdentifierMarkerView.exists, let marker = identifierMarker(at: point, under: hit, in: window) {
            return UIViewPath(leaf: marker)
        }
        var leaf = hit
        var depth = 0
        while depth < 64, let child = topmostSubview(of: leaf, at: point, in: window) {
            leaf = child
            depth += 1
        }
        return UIViewPath(leaf: leaf)
    }

    /// The smallest `tracewayIdentifier` marker under `point` in `root`'s
    /// subtree (the innermost SwiftUI view named so), looking at no more
    /// than 2,000 views.
    private static func identifierMarker(at point: CGPoint, under root: UIView, in window: UIWindow) -> UIView? {
        var best: UIView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        var stack: [UIView] = [root]
        var visited = 0
        while let view = stack.popLast(), visited < 2000 {
            visited += 1
            if view.isHidden || view.alpha < 0.01 { continue }
            if view is TracewayIdentifierMarkerView {
                let rect = view.convert(view.bounds, to: window)
                let area = rect.width * rect.height
                if rect.contains(point), area.isFinite, area <= bestArea {
                    best = view
                    bestArea = area
                }
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }

    private static func topmostSubview(of view: UIView, at point: CGPoint, in window: UIWindow) -> UIView? {
        // UIKit draws later subviews on top.
        for child in view.subviews.reversed() {
            if child.isHidden || child.alpha < 0.01 || child is TracewayMaskMarkerView
                || child is TracewayIdentifierMarkerView { continue }
            if child.bounds.contains(child.convert(point, from: window)) { return child }
        }
        return nil
    }

    var count: Int { views.count }

    func node(at index: Int) -> UIView { views[index] }

    func info(_ node: UIView) -> ViewNodeInfo {
        let key = ObjectIdentifier(node)
        if let cached = infoCache[key] { return cached }
        let made = viewInfo(node)
        infoCache[key] = made
        return made
    }

    func children(of node: UIView) -> [UIView] {
        let key = ObjectIdentifier(node)
        if let cached = childrenCache[key] { return cached }
        let made = node.subviews
        childrenCache[key] = made
        return made
    }
}

private func nonEmpty(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}

/// What a selector sees of `view`: its class, accessibility identifier,
/// roles from its accessibility traits and class, label, `tag` as `key`, and
/// (when asked) the text it shows.
func viewInfo(_ view: UIView) -> ViewNodeInfo {
    var ids: [String] = []
    var values: [String: String] = [:]
    // A mask marker (`traceway-mask`, `traceway-blank`) is not a name.
    if let identifier = nonEmpty(view.accessibilityIdentifier), !isTracewayMaskMarker(identifier) {
        ids.append(identifier)
        values["identifier"] = identifier
    }
    if let label = nonEmpty(view.accessibilityLabel) {
        values["label"] = label
    }
    if view.tag != 0 {
        values["key"] = "\(view.tag)"
    }

    var roles = Set<String>()
    let traits = view.accessibilityTraits
    if traits.contains(.button) { roles.insert("button") }
    if traits.contains(.link) { roles.insert("link") }
    if traits.contains(.header) { roles.insert("header") }
    if traits.contains(.image) || view is UIImageView { roles.insert("image") }
    if traits.contains(.searchField) || view is UITextField || view is UITextView { roles.insert("textField") }
    if traits.contains(.adjustable) || view is UISlider { roles.insert("slider") }
    if traits.contains(.selected) { roles.insert("selected") }
    if view is UISwitch { roles.insert("toggle") }
    if #available(iOS 17.0, *) {
        if traits.contains(.toggleButton) { roles.insert("toggle") }
    }

    return ViewNodeInfo(
        type: selectorTypeName(String(describing: type(of: view))),
        ids: ids,
        roles: roles,
        values: values,
        label: { [weak view] in view.flatMap(labelBelow) },
        text: { [weak view] in view.flatMap { shownText($0, includeMasked: true) } }
    )
}

/// The accessibility label of the first view below `view`, as long as the
/// hierarchy does not branch (a button's image view, a wrapper's content).
private func labelBelow(_ view: UIView) -> String? {
    var current = view
    for _ in 0..<32 {
        let subviews = current.subviews
        guard subviews.count == 1 else { return nil }
        current = subviews[0]
        if current.maskInEffect != nil { return nil }
        if let label = nonEmpty(current.accessibilityLabel) { return label }
    }
    return nil
}

/// The text of a label or the title of a button, without descending.
private func ownText(_ view: UIView) -> String? {
    if let label = view as? UILabel {
        return label.attributedText?.string ?? label.text
    }
    if let button = view as? UIButton {
        return button.currentTitle ?? button.currentAttributedTitle?.string
    }
    return nil
}

/// The text `view` shows: a label's own, a button's title, else that of the
/// labels under it, at most three, joined by a space. Text fields and text
/// views are never read (their content may be anything the user typed), nor
/// hidden views, nor masked ones unless `includeMasked`.
func shownText(_ view: UIView, includeMasked: Bool) -> String? {
    if view is UITextField || view is UITextView { return nil }
    if let own = ownText(view), let cleaned = cleanShownText(own) { return cleaned }
    var parts: [String] = []
    var visited = 0
    func visit(_ current: UIView) {
        if parts.count >= 3 { return }
        visited += 1
        if visited > 400 { return }
        if current.isHidden || current.alpha < 0.01 { return }
        if current is UITextField || current is UITextView { return }
        if !includeMasked && current.maskInEffect != nil { return }
        if let own = ownText(current) {
            if let cleaned = cleanShownText(own) {
                parts.append(cleaned)
                return
            }
        }
        for child in current.subviews {
            visit(child)
            if parts.count >= 3 || visited > 400 { return }
        }
    }
    for child in view.subviews {
        visit(child)
        if parts.count >= 3 || visited > 400 { break }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// Whether the view at `index` or one of its ancestors is masked (a
/// traceway mask or its identifier marker) or a secure text field.
func isMasked(_ path: UIViewPath, from index: Int) -> Bool {
    var i = max(0, index)
    while i < path.count {
        let view = path.views[i]
        if view.maskInEffect != nil { return true }
        if let field = view as? UITextField, field.isSecureTextEntry { return true }
        i += 1
    }
    return false
}

private func hasTapRecognizer(_ view: UIView) -> Bool {
    guard let recognizers = view.gestureRecognizers else { return false }
    return recognizers.contains { recognizer in
        recognizer.isEnabled
            && (recognizer is UITapGestureRecognizer || recognizer is UILongPressGestureRecognizer)
    }
}

/// A view that names itself as what was tapped: a control, a table or
/// collection cell, or a view with its own tap or long-press recognizer.
/// A view controller's root view does not count as one through its
/// recognizers: those are usually "tap the background to dismiss the
/// keyboard", which would otherwise claim every tap on the screen.
private func isTapOwner(_ view: UIView) -> Bool {
    if view is UIControl || view is UITableViewCell || view is UICollectionViewCell { return true }
    if view is UIWindow || view.next is UIViewController { return false }
    return hasTapRecognizer(view)
}

/// Names the view a tap landed on for the `browser.user_action.click`
/// record. The owner is the nearest control (see `isTapOwner`), else the
/// nearest label or image view, else the deepest view; the window and what
/// is above it are left out. Text and labels of masked views and secure
/// fields are never included.
func describeTap(_ path: UIViewPath, includeText: Bool = true) -> TapTarget? {
    let classifier = TapClassifier<UIView>(
        isBoundary: { $0 is UIWindow },
        isControl: isTapOwner,
        isContent: { $0 is UILabel || $0 is UIImageView },
        isMasked: { isMasked(path, from: $0) },
        shownText: { shownText($0, includeMasked: false) }
    )
    return describeTap(path, classifier: classifier, includeText: includeText)
}
#endif
