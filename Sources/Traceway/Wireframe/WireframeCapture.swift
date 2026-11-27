#if canImport(UIKit)
import UIKit
import QuartzCore

/// Turns what the app's windows show into a wireframe DOM. The pipeline, in
/// the words every Traceway SDK uses for it:
///
/// roots → walk → convert → VNodes (stable ids, shared unchanged subtrees)
/// → CSS → diff → rrweb events
///
/// - **roots**: `WireframeRoots` picks the visible windows, back to front.
/// - **walk**: `visit` goes through each window's views and the layers no
///   view owns, in paint order, within a node budget and a depth limit.
/// - **convert**: each kind of view becomes nodes in its converter (`text`,
///   `field`, `image`, `toggle`, `slider`, `progress`, `segmented`,
///   `nativePlaceholder`, `customDrawing`, `keyboard`, `group`, `scroll`;
///   iOS's own `stepper`, `pageControl`, `visualEffect`, `glass`; SwiftUI's
///   in `WireframeSwiftUICapture.swift`).
/// - **VNodes**: a view keeps its node id from frame to frame, and an
///   unchanged node is the previous frame's very object.
/// - **CSS**: geometry and paint are inline styles (`WireframeCSS`); the
///   shared `wireframeCss` sets the classes; icon glyphs and pictures
///   (`WireframeGlyphs`, `WireframeImages`) are style nodes of their own.
/// - **diff** and **rrweb events**: `WireframeRecorder` keeps the frames and
///   turns them into a full snapshot and `diffScreens` mutations.
///
/// Main thread only. Nothing is laid out or read off the screen: the walk
/// reads properties UIKit already holds. The only pixels are the bitmaps of
/// symbols (their shape) and, when the images policy allows it, of the
/// pictures image views show; never a screenshot of the window.
///
/// Only views and layers that paint something, clip or fade get a DOM node;
/// layout-only views in between are folded into the geometry of their
/// children. Nodes nest the way they paint, so CSS clips, rounds and fades
/// their contents like Core Animation does. Views keep their node ids from
/// frame to frame, and a node that did not change is the previous frame's
/// very object, so the recorder can skip unchanged frames and the diff
/// unchanged subtrees.
///
/// SwiftUI draws most of its content without views of its own. Inside a
/// hosting view the walk still sees the layers SwiftUI uses for colors,
/// shapes and images, and it reads text from the hosting view's
/// accessibility elements (at most once a second per hosting view).
final class WireframeCapture {
    /// Text in editable fields is masked, as rrweb's `maskAllInputs` does.
    var maskAllInputs = true

    /// Reads SwiftUI text from the accessibility elements of hosting views.
    static var readsSwiftUIText = true

    /// Draws the shapes of symbols and template images; without it they are
    /// squares of their color.
    var glyphs: WireframeGlyphs? = WireframeGlyphs()
    /// How long a glyph's rule stays on the page after its icon left the
    /// screen, so an icon that comes back does not add it again.
    static let glyphLingerMs: Int64 = 10_000
    var shownGlyphs = Set<String>()

    /// When the pictures of image views are inlined (`replay.images`); set
    /// by the recorder from the settings before each capture. Off keeps
    /// every image a placeholder.
    var imagePolicy: TracewayImagePolicy = .off
    /// Whether the device is on an unmetered connection; asked at each
    /// capture under the `wifi` policy.
    var isUnmetered: () -> Bool = { NetworkState.shared.isUnmetered }
    /// The pictures shown lately and their rules.
    let images = WireframeImages()
    /// Whether this capture may show pictures: decided once per frame, so
    /// a picture captured on Wi-Fi stays in that frame.
    private var picturesAllowed = false

    /// The window whose coordinate space the frames are in.
    private(set) weak var screenWindow: UIWindow?

    /// Shared by every capture: a view keeps the id it was given.
    private static var nextId = firstCapturedNodeId
    private static let maxNodes = 3000

    private var previous: [Int: VNode] = [:]
    private var current: [Int: VNode] = [:]
    private var visited = Set<ObjectIdentifier>()
    private var budget = 0
    private var blankRects: [WireframeRect] = []
    private var blurRects: [WireframeRect] = []
    var hostTexts: [[SwiftUIText]] = []
    var textCache: [ObjectIdentifier: CachedTexts] = [:]
    private(set) var nowMs: Int64 = 0
    /// How deep the walk is: views and layers below this many levels are
    /// left out, so a very deep tree cannot overflow the main thread's stack.
    private var depth = 0
    private static let maxDepth = 128

    /// Forgets the previous frame, so the next capture shares nothing with it.
    func reset() {
        previous = [:]
        textCache = [:]
        cornerCache = [:]
    }

    // MARK: - Screen

    /// The wireframe of the app's visible windows, or nil when there is no
    /// window to show.
    func captureScreen(timestampMs: Int64, href: String?, keyboardFrame: CGRect?) -> WireframeFrame? {
        capture(windows: WireframeRoots.visibleWindows(), timestampMs: timestampMs, href: href, keyboardFrame: keyboardFrame)
    }

    /// The wireframe of `windows`, back to front, in the coordinate space of
    /// the key one (or the first normal one).
    func capture(windows: [UIWindow], timestampMs: Int64, href: String?, keyboardFrame: CGRect?) -> WireframeFrame? {
        guard let main = WireframeRoots.screenWindow(of: windows) else { return nil }
        let size = main.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        screenWindow = main
        nowMs = timestampMs
        current = [:]
        visited.removeAll(keepingCapacity: true)
        budget = WireframeCapture.maxNodes
        depth = 0
        blankRects = []
        blurRects = []
        hostTexts = []
        shownGlyphs = []
        picturesAllowed = imagePolicy.allowsCapture(unmetered: imagePolicy == .wifi && isUnmetered())

        let width = Double(size.width), height = Double(size.height)
        let screenRect = WireframeRect(x: 0, y: 0, width: width, height: height)
        let scope = Scope(
            origin: .identity,
            transform: .translation(-Double(main.frame.minX), -Double(main.frame.minY)),
            clip: screenRect
        )
        var children: [VNode] = []
        for window in windows {
            collectMasks(in: window, screen: main)
            visit(window, scope, &children)
        }
        if let keyboard = keyboardFrame {
            let frame = main.convert(keyboard, from: main.screen.coordinateSpace)
            children.append(self.keyboard(frame, dark: main.traitCollection.userInterfaceStyle == .dark))
        }
        children.insert(contentsOf: (glyphStyles() + pictureStyles()).sorted { $0.id < $1.id }, at: 0)
        let screen = element(screenNodeId, screenNodeStyle(width: width, height: height), children, extra: ["id": "tw"])
        previous = current
        current = [:]
        // Hosting views that went away take their cached text with them.
        if textCache.count > 32 { textCache = textCache.filter { $0.value.host != nil } }
        return WireframeFrame(screen: screen, width: width, height: height, timestampMs: timestampMs, href: href)
    }

    /// The keyboard as a neutral box: its keys are never recorded.
    private func keyboard(_ frame: CGRect, dark: Bool) -> VNode {
        let colors = dark ? "background-color:#2c2c2e;color:#8e8e93;" : "background-color:#d1d3d9;color:#6d6d72;"
        let place = WireframeCSS.rect(
            left: Double(frame.minX), top: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)
        )
        let style = place + colors + "display:flex;align-items:center;justify-content:center;font-size:13px;"
        return element(keyboardNodeId, style, [textNode(keyboardLabelTextId, "Keyboard")])
    }

    /// A style node for each glyph shown lately, first on the screen (a
    /// style draws nothing), in a stable order.
    private func glyphStyles() -> [VNode] {
        guard let glyphs = glyphs else { return [] }
        var styles: [VNode] = []
        for glyph in glyphs.all {
            if shownGlyphs.contains(glyph.cls) { glyph.lastShownMs = nowMs }
            guard let css = glyph.css, glyph.lastShownMs > 0,
                  nowMs - glyph.lastShownMs <= WireframeCapture.glyphLingerMs else { continue }
            let styleId: Int
            if let existing = glyph.styleId {
                styleId = existing
            } else {
                styleId = WireframeCapture.nextId
                WireframeCapture.nextId += 1
                glyph.styleId = styleId
            }
            styles.append(intern(VNode(element: styleId, tag: "style", attributes: ["_cssText": css], children: [])))
        }
        return styles.sorted { $0.id < $1.id }
    }

    /// A style node for each picture shown lately, while pictures are
    /// allowed: under a policy that does not allow them, nothing of a
    /// picture is in the frame.
    private func pictureStyles() -> [VNode] {
        guard picturesAllowed else { return [] }
        var styles: [VNode] = []
        for picture in images.all {
            guard let css = picture.css, nowMs - picture.lastShownMs <= WireframeImages.lingerMs else { continue }
            let styleId: Int
            if let existing = picture.styleId {
                styleId = existing
            } else {
                styleId = WireframeCapture.nextId
                WireframeCapture.nextId += 1
                picture.styleId = styleId
            }
            styles.append(intern(VNode(element: styleId, tag: "style", attributes: ["_cssText": css], children: [])))
        }
        return styles
    }

    // MARK: - Ids and interning

    private static var idKey: UInt8 = 0

    private final class IdBox {
        var ids: [Int: Int] = [:]
    }

    /// The id of the node playing `role` for `object`; the same in every
    /// frame while the object lives.
    func id(_ object: AnyObject, _ role: Int = 0) -> Int {
        let box: IdBox
        if let existing = objc_getAssociatedObject(object, &WireframeCapture.idKey) as? IdBox {
            box = existing
        } else {
            box = IdBox()
            objc_setAssociatedObject(object, &WireframeCapture.idKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let id = box.ids[role] { return id }
        let id = WireframeCapture.nextId
        WireframeCapture.nextId += 1
        box.ids[role] = id
        return id
    }

    private func intern(_ node: VNode) -> VNode {
        let kept: VNode
        if let previous = previous[node.id], previous.sameAs(node) {
            kept = previous
        } else {
            kept = node
        }
        current[node.id] = kept
        return kept
    }

    func element(
        _ id: Int, _ style: String, _ children: [VNode],
        cls: String? = nil, tag: String = "div", extra: [String: String]? = nil
    ) -> VNode {
        var attributes: [String: String] = ["style": style]
        if let cls = cls { attributes["class"] = cls }
        if let extra = extra {
            for (key, value) in extra { attributes[key] = value }
        }
        return intern(VNode(element: id, tag: tag, attributes: attributes, children: children))
    }

    func textNode(_ id: Int, _ value: String) -> VNode {
        intern(VNode(text: id, text: value))
    }

    // MARK: - Walk

    /// Where the walk is: the DOM parent being filled and the coordinates of
    /// both it and the layer above.
    struct Scope {
        /// Maps the DOM parent's coordinates (its top left is 0, 0) to the
        /// screen.
        var origin: WireframeAffine
        /// Maps the coordinates sublayers are positioned in (the bounds of
        /// the layer above) to the screen.
        var transform: WireframeAffine
        /// What clips above leave visible, in screen coordinates.
        var clip: WireframeRect
        var maskText = false
        var blockImages = false
        /// The layer whose bounds `transform` maps; nil above the windows.
        var layer: CALayer?
        /// Inside a Liquid Glass lens (the selection of a tab bar).
        var lens = false
        /// The corner radius of a view above with the same box. iOS 26's
        /// corner configurations round a view by its ancestor's radius,
        /// which a clipping fill of the same size takes.
        var shapeRadius: (box: WireframeRect, radius: Double)?

        /// The scope of what is inside a placed layer.
        func entering(_ p: Placed, _ model: CALayer) -> Scope {
            var inner = self
            inner.transform = p.t
            inner.layer = model
            return inner
        }
    }

    /// How the layers between a view's layer and its superview's map, when
    /// UIKit put some in between: iOS 26 wraps the layer of many views (bars,
    /// glass, alerts, labels with vibrancy) in a `_UIMultiLayer` that holds
    /// the view's position. Nil when one of them hides the view.
    private func wrapperTransform(_ model: CALayer, _ s: Scope) -> WireframeAffine? {
        guard let reference = s.layer else { return .identity }
        var chain: [CALayer] = []
        var current = model.superlayer
        while let layer = current, layer !== reference {
            if chain.count >= 8 { return .identity }
            chain.append(layer)
            current = layer.superlayer
        }
        // Not under the scope's layer at all: placed as before.
        guard current === reference else { return .identity }
        var t = WireframeAffine.identity
        for wrapper in chain.reversed() {
            let layer = wrapper.presentation() ?? wrapper
            if layer.isHidden || layer.opacity < 0.01 { return nil }
            guard let local = WireframeCapture.localTransform(layer) else { return nil }
            t = t.then(local)
        }
        return t
    }

    /// Where a layer is on screen.
    struct Placed {
        /// The layer's bounds coordinates to the screen.
        var t: WireframeAffine
        /// The node's coordinates (0, 0 at the bounds' origin) to the screen.
        var node: WireframeAffine
        var width: Double
        var height: Double
        /// The node's bounding box on screen.
        var box: WireframeRect
        var boundsX: Double
        var boundsY: Double
    }

    private func place(_ layer: CALayer, _ s: Scope) -> Placed? {
        guard let local = WireframeCapture.localTransform(layer) else { return nil }
        let t = s.transform.then(local)
        if t.isDegenerate { return nil }
        let b = layer.bounds
        let w = Double(b.width), h = Double(b.height)
        guard w.isFinite, h.isFinite, w >= 0, h >= 0 else { return nil }
        let node = t.translated(Double(b.minX), Double(b.minY))
        let box = node.boundingBox(width: w, height: h)
        if !box.isEmpty && !box.overlaps(s.clip) { return nil }
        return Placed(t: t, node: node, width: w, height: h, box: box, boundsX: Double(b.minX), boundsY: Double(b.minY))
    }

    /// How a layer's bounds map into its superlayer: its position, anchor
    /// point and the affine part of its transform. Nil when it collapses to
    /// nothing.
    static func localTransform(_ layer: CALayer) -> WireframeAffine? {
        let b = layer.bounds
        let anchor = layer.anchorPoint
        let position = layer.position
        guard position.x.isFinite, position.y.isFinite else { return nil }
        let ax = Double(b.minX) + Double(anchor.x) * Double(b.width)
        let ay = Double(b.minY) + Double(anchor.y) * Double(b.height)
        var m = WireframeAffine.translation(Double(position.x), Double(position.y))
        let transform = layer.transform
        if !CATransform3DIsIdentity(transform) {
            let a = CATransform3DGetAffineTransform(transform)
            let local = WireframeAffine(
                a: Double(a.a), b: Double(a.b), c: Double(a.c), d: Double(a.d), tx: Double(a.tx), ty: Double(a.ty)
            )
            if local.isDegenerate { return nil }
            m = m.then(local)
        }
        return m.translated(-ax, -ay)
    }

    func geometry(_ s: Scope, _ p: Placed) -> String {
        wireframeGeometry(origin: s.origin, transform: p.node, width: p.width, height: p.height)
    }

    private func visit(_ view: UIView, _ scope: Scope, _ out: inout [VNode]) {
        guard budget > 0, depth < WireframeCapture.maxDepth else { return }
        depth += 1
        defer { depth -= 1 }
        let key = ObjectIdentifier(view)
        if visited.contains(key) { return }
        visited.insert(key)
        budget -= 1
        if view.isHidden { return }
        let layer = view.layer.presentation() ?? view.layer
        if layer.isHidden || layer.opacity < 0.01 { return }
        guard let wrapper = wrapperTransform(view.layer, scope) else { return }
        var scope = scope
        if wrapper != .identity { scope.transform = scope.transform.then(wrapper) }
        if WireframeCapture.cutsOut(layer) { return }
        guard let p = place(layer, scope) else { return }
        var info = ClassInfo.of(view)
        // A view backed by a video, Metal or OpenGL layer (`layerClass`)
        // shows what that layer draws.
        if info.kind == .plain, case .native = ClassInfo.of(view.layer).kind { info = ClassInfo.of(view.layer) }
        if info.kind == .skip { return }
        if info.kind == .glassShape {
            out.append(glass(id(view), layer, p, scope, dark: view.traitCollection.userInterfaceStyle == .dark))
            return
        }
        var s = scope
        if info.isLens { s.lens = true }
        if layer.cornerRadius > 0 {
            s.shapeRadius = (p.box, min(Double(layer.cornerRadius), min(p.width, p.height) / 2))
        } else if let configured = configuredRadius(view, p), configured > 0 {
            // A popover or sheet rounds through its corner configuration and
            // clips its content with a mask of the same box.
            s.shapeRadius = (p.box, configured)
        }

        if let mode = view.maskInEffect {
            switch mode {
            case .blank(let color):
                // A box of its color; nothing inside is recorded.
                var style = geometry(s, p) + WireframeCSS.fill(WireframeCapture.color(color, view.traitCollection))
                if !(view is TracewayMaskMarkerView) { style += box(layer, p, clips: true).radius }
                out.append(element(id(view), style, []))
                return
            case .blur:
                // A marker's content is masked by its rect (see collectMasks).
                if view is TracewayMaskMarkerView { return }
                s.maskText = true
                s.blockImages = true
            }
        }

        switch info.kind {
        case .native(let label):
            out.append(nativePlaceholder(view, label, geometry(s, p) + box(layer, p, clips: true).radius))
            return
        case .swiftUIDrawing:
            swiftUIDrawing(view, layer, p, s, &out)
            // SwiftUI holds the UIKit views of overlays and backgrounds (a
            // UIViewRepresentable, a traceway mask's marker) in such a view.
            let inner = s.entering(p, view.layer)
            for subview in view.subviews {
                guard budget > 0 else { break }
                visit(subview, inner, &out)
            }
            return
        default:
            break
        }

        if let label = view as? UILabel {
            text(label, layer, p, s, &out)
        } else if let textField = view as? UITextField {
            field(textField, layer, p, s, &out)
        } else if let textView = view as? UITextView {
            field(textView, layer, p, s, &out)
        } else if let imageView = view as? UIImageView {
            image(imageView, layer, p, s, &out)
        } else if let toggle = view as? UISwitch {
            self.toggle(toggle, layer, p, s, &out)
        } else if let slider = view as? UISlider {
            self.slider(slider, layer, p, s, &out)
        } else if let progress = view as? UIProgressView {
            self.progress(progress, layer, p, s, &out)
        } else if let spinner = view as? UIActivityIndicatorView {
            self.progress(spinner, layer, p, s, &out)
        } else if let pages = view as? UIPageControl {
            pageControl(pages, layer, p, s, &out)
        } else if let segmented = view as? UISegmentedControl {
            self.segmented(segmented, layer, p, s, &out)
        } else if let stepper = view as? UIStepper {
            self.stepper(stepper, layer, p, s, &out)
        } else if let effect = view as? UIVisualEffectView {
            visualEffect(effect, layer, p, s, &out)
        } else if info.kind == .swiftUIHost && WireframeCapture.readsSwiftUIText {
            let depth = hostTexts.count
            hostTexts.append(swiftUITexts(of: view))
            group(view, layer, p, s, info, &out) { children, scope in
                if let texts = self.hostTexts.last {
                    self.remainingSwiftUITexts(texts, view, scope, &children)
                }
            }
            if hostTexts.count > depth { hostTexts.removeSubrange(depth...) }
        } else {
            group(view, layer, p, s, info, &out)
        }
    }

    /// A view that is only its box and its subviews: a node when it paints,
    /// clips, fades or scrolls, else folded into its children's geometry.
    func group(
        _ view: UIView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ info: ClassInfo, _ out: inout [VNode],
        trailing: ((inout [VNode], Scope) -> Void)? = nil
    ) {
        let clips = view.clipsToBounds || layer.masksToBounds || layer.mask != nil
        if clips && p.box.isEmpty { return }
        var paint = box(layer, p, clips: clips)
        if paint.radius.isEmpty, paint.paints || clips {
            if let configured = configuredRadius(view, p), configured > 0 {
                paint.radius = WireframeCSS.radius(configured)
            } else if clips, let shape = s.shapeRadius, shape.box.isClose(to: p.box) {
                paint.radius = WireframeCSS.radius(shape.radius)
            }
        }
        let opacity = Double(layer.opacity)
        let scrolls = view is UIScrollView
        let custom = info.kind == .customDraw
        // A view whose own layer is a gradient or a shape (`layerClass`)
        // paints it under its subviews.
        let gradient = (layer as? CAGradientLayer).map { gradientCss($0, p) } ?? ""
        let shape = (layer as? CAShapeLayer).flatMap { shapeNode($0, view.layer, p) }
        let needsNode = paint.paints || clips || opacity < 0.999 || view is UIWindow || custom || scrolls
            || !gradient.isEmpty || shape != nil
        var inner = s.entering(p, view.layer)
        if !needsNode {
            visitSublayers(of: view, inner, &out)
            trailing?(&out, inner)
            return
        }
        var style = geometry(s, p) + paint.css + gradient
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        if clips {
            style += "overflow:hidden;"
            inner.clip = s.clip.intersection(p.box)
        }
        inner.origin = p.node
        var children: [VNode] = []
        if custom { children.append(customDrawing(view)) }
        if let shape = shape { children.append(shape) }
        if scrolls || p.boundsX != 0 || p.boundsY != 0 {
            children.append(scroll(view, p, inner, trailing: trailing))
        } else {
            visitSublayers(of: view, inner, &children)
            trailing?(&children, inner)
        }
        out.append(element(id(view), style, children))
    }

    /// The content of a view whose bounds are shifted (a scroll view): a
    /// node of its own that moves as it scrolls, inside the view's clip, so
    /// one attribute changes per frame, not every child's.
    private func scroll(
        _ view: UIView, _ p: Placed, _ inner: Scope, trailing: ((inout [VNode], Scope) -> Void)?
    ) -> VNode {
        var content: [VNode] = []
        var contentScope = inner
        contentScope.origin = p.t
        visitSublayers(of: view, contentScope, &content)
        trailing?(&content, contentScope)
        return element(
            id(view, 2),
            "left:\(WireframeCSS.px(-p.boundsX));top:\(WireframeCSS.px(-p.boundsY));",
            content
        )
    }

    /// A view the app draws in its own `draw(_:)`: a dashed outline, since
    /// its pixels are not read.
    private func customDrawing(_ view: UIView) -> VNode {
        element(id(view, 1), "width:100%;height:100%;", [], cls: "cp")
    }

    /// A view or layer whose pixels the system draws (a web view, a map,
    /// video, the camera, Metal): a labeled placeholder.
    private func nativePlaceholder(_ owner: AnyObject, _ label: String, _ style: String) -> VNode {
        element(id(owner), style, [textNode(id(owner, 1), label)], cls: "pv")
    }

    /// The subviews and other sublayers of `view`, in the order they paint.
    private func visitSublayers(of view: UIView, _ s: Scope, _ out: inout [VNode]) {
        // iOS 26 can put a subview's layer beside the view's own layer, in
        // the wrapper layer they share (an alert button's background): it
        // paints in the wrapper's order.
        if let wrapper = view.layer.superlayer, wrapper.delegate === view, let siblings = wrapper.sublayers {
            // A Liquid Glass group paints under the view's content: UIKit
            // draws the content again over the glass through a portal.
            let glassFirst = siblings.filter { sibling in
                guard let subview = sibling.delegate as? UIView, subview.superview === view else { return false }
                return ClassInfo.of(subview).isGlassGroup
            }
            let rest = WireframeCapture.paintOrder(siblings.filter { sibling in !glassFirst.contains { $0 === sibling } })
            for sibling in glassFirst + rest {
                guard budget > 0 else { return }
                if sibling === view.layer {
                    visitOwnSublayers(of: view, s, &out)
                } else if let subview = sibling.delegate as? UIView, subview.superview === view {
                    visit(subview, s, &out)
                }
            }
            return
        }
        visitOwnSublayers(of: view, s, &out)
    }

    /// Sublayers in the order Core Animation paints them: by `zPosition`,
    /// and in array order (subview order) among equals.
    static func paintOrder(_ sublayers: [CALayer]) -> [CALayer] {
        guard sublayers.contains(where: { $0.zPosition != 0 }) else { return sublayers }
        return sublayers.enumerated().sorted { a, b in
            a.element.zPosition != b.element.zPosition ? a.element.zPosition < b.element.zPosition : a.offset < b.offset
        }.map { $0.element }
    }

    private func visitOwnSublayers(of view: UIView, _ s: Scope, _ out: inout [VNode]) {
        guard let sublayers = view.layer.sublayers else { return }
        for sublayer in WireframeCapture.paintOrder(sublayers) {
            guard budget > 0 else { return }
            if let subview = sublayer.delegate as? UIView {
                if subview.superview === view { visit(subview, s, &out) }
            } else {
                visitLayer(sublayer, s, &out)
            }
        }
    }

    private static let cornerConfigurationSelector = NSSelectorFromString("cornerConfiguration")
    private var cornerCache: [ObjectIdentifier: (width: Double, height: Double, radius: Double?)] = [:]

    /// The radius iOS 26's `cornerConfiguration` gives a view whose layer
    /// has none (a sheet, a configured button): `fixed(radius:)`, or half
    /// the short side for a capsule. Read once per view and size.
    private func configuredRadius(_ view: UIView, _ p: Placed) -> Double? {
        guard #available(iOS 26.0, *) else { return nil }
        let key = ObjectIdentifier(view)
        if let cached = cornerCache[key], cached.width == p.width, cached.height == p.height { return cached.radius }
        var radius: Double?
        if view.responds(to: WireframeCapture.cornerConfigurationSelector),
           let configuration = view.value(forKey: "cornerConfiguration") {
            let text = String(describing: configuration)
            if let at = text.range(of: "topLeftRadius = ") {
                let rest = text[at.upperBound...]
                if rest.hasPrefix("capsule") {
                    radius = min(p.width, p.height) / 2
                } else if rest.hasPrefix("fixed(radius: "), let end = rest.firstIndex(of: ")") {
                    radius = Double(rest[rest.index(rest.startIndex, offsetBy: 14)..<end]).map { min($0, min(p.width, p.height) / 2) }
                }
            }
        }
        if cornerCache.count > 2000 { cornerCache.removeAll() }
        cornerCache[key] = (p.width, p.height, radius)
        return radius
    }

    /// Whether a layer cuts out what is under it (`destOut`, `destIn`)
    /// instead of painting: Liquid Glass uses such masks.
    private static func cutsOut(_ layer: CALayer) -> Bool {
        guard let filter = layer.compositingFilter else { return false }
        return String(describing: filter).hasPrefix("dest")
    }

    /// iOS 26's Liquid Glass: a shape (`CASDFElementLayer`) the system
    /// fills with frosted glass. A light or dark frost with a soft shadow,
    /// rounded as the layer is, else a capsule (bars and buttons) or a
    /// rounded panel.
    private func glass(_ id: Int, _ layer: CALayer, _ p: Placed, _ s: Scope, dark: Bool) -> VNode {
        let side = min(p.width, p.height)
        let radius = layer.cornerRadius > 0 ? min(Double(layer.cornerRadius), side / 2) : (side <= 80 ? side / 2 : 26)
        var style = geometry(s, p) + "border-radius:\(WireframeCSS.px(radius));"
        if s.lens {
            // The lens over a selected tab or segment: a faint highlight
            // over what it selects.
            style += dark ? "background-color:rgba(255,255,255,.12);" : "background-color:rgba(120,120,128,.14);"
        } else {
            style += dark
                ? "background-color:rgba(44,44,46,.78);box-shadow:inset 0 0 0 .5px rgba(255,255,255,.16),0 6px 20px rgba(0,0,0,.35);"
                : "background-color:rgba(255,255,255,.78);box-shadow:inset 0 0 0 .5px rgba(0,0,0,.06),0 6px 20px rgba(0,0,0,.1);"
        }
        return element(id, style, [])
    }

    private func visitSublayers(of layer: CALayer, _ s: Scope, _ out: inout [VNode]) {
        guard let sublayers = layer.sublayers else { return }
        for sublayer in WireframeCapture.paintOrder(sublayers) {
            guard budget > 0 else { return }
            if sublayer.delegate is UIView { continue }
            visitLayer(sublayer, s, &out)
        }
    }

    /// A layer no view owns: SwiftUI's colors, shapes and images, and the
    /// gradient, shape and text layers apps add themselves.
    private func visitLayer(_ model: CALayer, _ scope: Scope, _ out: inout [VNode]) {
        guard budget > 0, depth < WireframeCapture.maxDepth else { return }
        depth += 1
        defer { depth -= 1 }
        let key = ObjectIdentifier(model)
        if visited.contains(key) { return }
        visited.insert(key)
        budget -= 1
        let layer = model.presentation() ?? model
        if layer.isHidden || layer.opacity < 0.01 || WireframeCapture.cutsOut(layer) { return }
        guard let p = place(layer, scope) else { return }
        let info = ClassInfo.of(model)
        if info.kind == .skip { return }
        if info.kind == .glassShape {
            out.append(glass(id(model), layer, p, scope, dark: screenWindow?.traitCollection.userInterfaceStyle == .dark))
            return
        }
        if case .native(let label) = info.kind {
            out.append(nativePlaceholder(model, label, geometry(scope, p) + box(layer, p, clips: true).radius))
            return
        }
        if info.kind == .swiftUIText {
            swiftUIText(model, p, scope, &out)
            return
        }
        let clips = layer.masksToBounds || layer.mask != nil
        if clips && p.box.isEmpty { return }
        var paint = box(layer, p, clips: clips)
        var extra = ""
        var leaf: VNode?
        var cls: String?
        if let gradient = layer as? CAGradientLayer {
            extra = gradientCss(gradient, p)
        } else if let shape = layer as? CAShapeLayer {
            leaf = shapeNode(shape, model, p)
        } else if let textLayer = layer as? CATextLayer {
            leaf = textLayerNode(textLayer, model, p, scope)
        } else if info.kind == .swiftUIImage || (info.kind == .imageLayer && layer.contents != nil) {
            if let glyph = smallImageGlyph(layer, p, scope) {
                // A small picture with see-through parts is an icon: its
                // shape, in a neutral gray (its colors are not read).
                cls = "ic " + glyph
                extra = "color:#8e8e93;"
            } else if let picture = layerPhoto(model, layer, p, scope) {
                cls = "im " + picture.cls
                extra = picture.placement
                paint.paints = true
            } else {
                cls = "im"
                paint.paints = true
            }
        }
        let opacity = Double(layer.opacity)
        let hasSublayers = !(model.sublayers?.isEmpty ?? true)
        if !paint.paints && extra.isEmpty && leaf == nil && cls == nil && !clips && opacity >= 0.999 {
            // Only a place for its sublayers.
            let inner = scope.entering(p, model)
            visitSublayers(of: model, inner, &out)
            return
        }
        if !hasSublayers && leaf == nil && cls == nil && !paint.paints && extra.isEmpty { return }
        var style = geometry(scope, p) + paint.css + extra
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        var inner = scope.entering(p, model)
        inner.origin = p.node
        if clips {
            style += "overflow:hidden;"
            inner.clip = scope.clip.intersection(p.box)
        }
        var children: [VNode] = []
        if let leaf = leaf { children.append(leaf) }
        visitSublayers(of: model, inner, &children)
        out.append(element(id(model), style, children, cls: cls))
    }

    // MARK: - Boxes

    private struct BoxStyle {
        var fill = ""
        var radius = ""
        var shadows: [String] = []
        var paints = false

        var css: String { fill + radius + WireframeCSS.shadow(shadows) }

        func css(adding more: [String]) -> String {
            fill + radius + WireframeCSS.shadow(shadows + more)
        }
    }

    /// The background, corners, border and shadow a layer paints.
    private func box(_ layer: CALayer, _ p: Placed, clips: Bool) -> BoxStyle {
        var out = BoxStyle()
        let background = WireframeCapture.color(layer.backgroundColor)
        out.fill = WireframeCSS.fill(background)
        let hasFill = !WireframeCSS.isTransparent(background)
        if let border = WireframeCSS.insetBorder(
            width: Double(layer.borderWidth), color: WireframeCapture.color(layer.borderColor)
        ) {
            out.shadows.append(border)
        }
        if layer.shadowOpacity > 0, hasFill || layer.shadowPath != nil || !out.shadows.isEmpty,
           let color = WireframeCapture.color(layer.shadowColor) {
            let shadow = WireframeCSS.boxShadow(
                dx: Double(layer.shadowOffset.width), dy: Double(layer.shadowOffset.height),
                blur: Double(layer.shadowRadius) * 2,
                color: color.withAlpha(color.a * Double(layer.shadowOpacity))
            )
            if let shadow = shadow { out.shadows.insert(shadow, at: 0) }
        }
        out.paints = hasFill || !out.shadows.isEmpty
        let r = min(Double(layer.cornerRadius), min(p.width, p.height) / 2)
        if r > 0 && (out.paints || clips) {
            let corners = layer.maskedCorners
            out.radius = WireframeCSS.radius(
                topLeft: corners.contains(.layerMinXMinYCorner) ? r : 0,
                topRight: corners.contains(.layerMaxXMinYCorner) ? r : 0,
                bottomRight: corners.contains(.layerMaxXMaxYCorner) ? r : 0,
                bottomLeft: corners.contains(.layerMinXMaxYCorner) ? r : 0
            )
        }
        return out
    }

    func boxCss(_ s: Scope, _ p: Placed, _ layer: CALayer, _ view: UIView, extraShadows: [String] = []) -> (String, Bool) {
        let clips = view.clipsToBounds || layer.masksToBounds
        let paint = box(layer, p, clips: clips)
        var style = geometry(s, p) + paint.css(adding: extraShadows)
        let opacity = Double(layer.opacity)
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        if clips { style += "overflow:hidden;" }
        return (style, paint.paints)
    }

    // MARK: - Colors

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    static func color(_ cg: CGColor?) -> WireframeColor? {
        guard let cg = cg, cg.alpha > 0 else { return nil }
        if let space = sRGB, let converted = cg.converted(to: space, intent: .defaultIntent, options: nil),
           let c = converted.components, c.count >= 4 {
            return WireframeColor(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]), a: Double(c[3]))
        }
        if let c = cg.components, cg.numberOfComponents == 2, c.count == 2 {
            return WireframeColor(r: Double(c[0]), g: Double(c[0]), b: Double(c[0]), a: Double(c[1]))
        }
        return nil
    }

    static func color(_ ui: UIColor?, _ traits: UITraitCollection) -> WireframeColor? {
        guard let ui = ui else { return nil }
        return color(ui.resolvedColor(with: traits).cgColor)
    }

    private static func cgColor(_ value: Any) -> CGColor? {
        let ref = value as AnyObject
        guard CFGetTypeID(ref) == CGColor.typeID else { return nil }
        return (ref as! CGColor) // CF bridging: CFGetTypeID checked above
    }

    // MARK: - Privacy

    enum Privacy { case show, mask, hide }

    /// What may be recorded of text shown at `box`: a blank mask over it
    /// hides it, a blur mask or a masked subtree turns it into `*`.
    func privacy(_ box: WireframeRect, _ s: Scope) -> Privacy {
        if blankRects.contains(where: { $0.overlaps(box) }) { return .hide }
        if s.maskText || blurRects.contains(where: { $0.overlaps(box) }) { return .mask }
        return .show
    }

    func shown(_ value: String, _ box: WireframeRect, _ s: Scope) -> String? {
        switch privacy(box, s) {
        case .show: return value
        case .mask: return WireframeCSS.mask(value)
        case .hide: return nil
        }
    }

    /// The masks SwiftUI's `tracewayMask` modifier put over content
    /// that has no views of its own.
    private func collectMasks(in root: UIView, screen: UIWindow) {
        var stack: [UIView] = [root]
        var count = 0
        while let view = stack.popLast(), count < 6000 {
            count += 1
            if view.isHidden { continue }
            if view is TracewayMaskMarkerView, let mode = view.maskInEffect {
                let r = screen.convert(view.bounds, from: view)
                let rect = WireframeRect(
                    x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)
                )
                switch mode {
                case .blank: blankRects.append(rect)
                case .blur: blurRects.append(rect)
                }
                continue
            }
            if case .blank? = view.maskInEffect { continue }
            stack.append(contentsOf: view.subviews)
        }
    }

    // MARK: - Text

    private static func cssWeight(_ font: UIFont) -> Int {
        let descriptor = font.fontDescriptor
        if let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any],
           let raw = traits[.weight] as? NSNumber {
            let w = raw.doubleValue
            switch w {
            case ..<(-0.7): return 100
            case ..<(-0.5): return 200
            case ..<(-0.2): return 300
            case ..<0.15: return 400
            case ..<0.27: return 500
            case ..<0.35: return 600
            case ..<0.5: return 700
            case ..<0.6: return 800
            default: return 900
            }
        }
        return descriptor.symbolicTraits.contains(.traitBold) ? 700 : 400
    }

    private static func fontCss(_ font: UIFont, color: WireframeColor?) -> String {
        var css = "font-size:\(WireframeCSS.px(Double(font.pointSize)));"
        if let color = color { css += "color:\(WireframeCSS.color(color));" }
        let weight = cssWeight(font)
        if weight != 400 { css += "font-weight:\(weight);" }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.traitItalic) { css += "font-style:italic;" }
        if traits.contains(.traitMonoSpace) { css += "font-family:ui-monospace,Menlo,monospace;" }
        return css
    }

    /// `left`, `center`, `right` or `justify`.
    private static func align(_ alignment: NSTextAlignment, rtl: Bool) -> String {
        switch alignment {
        case .center: return "center"
        case .right: return "right"
        case .justified: return "justify"
        case .natural: return rtl ? "right" : "left"
        default: return "left"
        }
    }

    /// Where a one-line flex text sits for `align`. Right to left, the flex
    /// line starts at the right edge, so right is its start and left its end.
    private static func justify(_ align: String, rtl: Bool) -> String {
        switch align {
        case "center": return "justify-content:center;"
        case "right": return rtl ? "" : "justify-content:flex-end;"
        case "left": return rtl ? "justify-content:flex-end;" : ""
        default: return ""
        }
    }

    /// A label: its text with the label's font, color, alignment and line
    /// breaking, and rich text as spans.
    private func text(_ label: UILabel, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        var (baseStyle, paints) = boxCss(s, p, layer, label)
        // A label draws its background color into its own contents, not as
        // its layer's background.
        if layer.backgroundColor == nil,
           let background = WireframeCapture.color(label.backgroundColor, label.traitCollection),
           !background.isTransparent {
            baseStyle += WireframeCSS.fill(background)
            paints = true
        }
        var style = baseStyle
        // At most `maxTextLength` of it: each frame copies, masks and
        // measures the text on the main thread.
        let attributedText = WireframeCSS.capped(label.attributedText)
        let raw = attributedText?.string ?? WireframeCSS.capped(label.text ?? "")
        let value = raw.isEmpty ? nil : shown(raw, p.box, s)
        guard let shownText = value else {
            if paints { out.append(element(id(label), style, [])) }
            return
        }
        let font: UIFont = label.font ?? UIFont.systemFont(ofSize: 17)
        let traits = label.traitCollection
        let textColor = label.isHighlighted ? (label.highlightedTextColor ?? label.textColor) : label.textColor
        let color = WireframeCapture.color(textColor, traits) ?? WireframeCapture.color(UIColor.label, traits)
        style += WireframeCapture.fontCss(font, color: color)
        let content = label.isHighlighted ? nil : runs(
            attributedText, font: font, color: color, traits: traits, owner: label,
            masked: privacy(p.box, s) == .mask
        )
        let rtl = label.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let align = WireframeCapture.align(label.textAlignment, rtl: rtl)
        if rtl { style += "direction:rtl;" }
        let cls: String
        // A label that may wrap but holds one line (a cell's title, sized
        // to its text) is one line in the replay too: the browser's font is
        // a little wider and would wrap its last word.
        if label.numberOfLines == 1 || p.height < Double(font.lineHeight) * 1.6 {
            let measured: CGFloat
            if let attributed = attributedText, attributed.length > 0 {
                measured = attributed.size().width
            } else {
                measured = (raw as NSString).size(withAttributes: [.font: font]).width
            }
            let truncating: Bool
            switch label.lineBreakMode {
            case .byTruncatingTail, .byTruncatingHead, .byTruncatingMiddle: truncating = true
            default: truncating = false
            }
            if truncating && !label.adjustsFontSizeToFitWidth && Double(measured) > p.width + 0.5 {
                // UIKit cut this line: the browser cuts it too.
                style += "line-height:\(WireframeCSS.px(p.height));"
                if align != "left" || rtl { style += "text-align:\(align);" }
                cls = "t n e"
            } else {
                // The browser's font is not the app's: a line it draws wider
                // spills out the way it is aligned instead of being cut.
                style += "line-height:\(WireframeCSS.px(Double(font.lineHeight)));align-items:center;"
                    + WireframeCapture.justify(align, rtl: rtl)
                cls = "t n"
            }
        } else {
            // Lines of a paragraph as far apart as its style sets them.
            var lineHeight = Double(font.lineHeight)
            if let attributed = attributedText, attributed.length > 0,
               let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                if paragraph.lineHeightMultiple > 0 { lineHeight *= Double(paragraph.lineHeightMultiple) }
                lineHeight = max(lineHeight, Double(paragraph.minimumLineHeight))
                if paragraph.maximumLineHeight > 0 { lineHeight = min(lineHeight, Double(paragraph.maximumLineHeight)) }
                lineHeight += Double(paragraph.lineSpacing)
            }
            style += "line-height:\(WireframeCSS.px(lineHeight));display:flex;align-items:center;"
                + WireframeCapture.justify(align, rtl: rtl)
            if align != "left" || rtl { style += "text-align:\(align);" }
            if label.numberOfLines > 0 && !style.contains("overflow:hidden") { style += "overflow:hidden;" }
            cls = "t"
        }
        let children: [VNode]
        switch content {
        case .spans(let spans)?:
            children = spans
        case .uniform(let css)?:
            style += css
            children = [textNode(id(label, 1), shownText)]
        case nil:
            children = [textNode(id(label, 1), shownText)]
        }
        out.append(element(id(label), style, children, cls: cls))
    }

    /// Rich text: `spans` for runs that differ from the font and color of
    /// the text around them, or `uniform` when the whole text is one such
    /// run (its style goes on the text's own node, which keeps its box).
    enum Runs {
        case spans([VNode])
        case uniform(String)
    }

    /// The runs of `attributed`; nil when the text is all in the font and
    /// color around it.
    private func runs(
        _ attributed: NSAttributedString?, font: UIFont, color: WireframeColor?,
        traits: UITraitCollection, owner: AnyObject, masked: Bool
    ) -> Runs? {
        guard let attributed = attributed, attributed.length > 0 else { return nil }
        var parts: [(String, String)] = []
        var styled = false
        let whole = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, stop in
            if parts.count >= 50 {
                stop.pointee = true
                return
            }
            var css = ""
            if let runFont = attributes[.font] as? UIFont, runFont != font {
                css += WireframeCapture.fontCss(runFont, color: nil)
            }
            if let runColor = (attributes[.foregroundColor] as? UIColor).flatMap({ WireframeCapture.color($0, traits) }),
               runColor != color {
                css += "color:\(WireframeCSS.color(runColor));"
            }
            if let background = (attributes[.backgroundColor] as? UIColor).flatMap({ WireframeCapture.color($0, traits) }) {
                css += WireframeCSS.fill(background)
            }
            var lines: [String] = []
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { lines.append("underline") }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { lines.append("line-through") }
            if !lines.isEmpty { css += "text-decoration:\(lines.joined(separator: " "));" }
            if attributes[.link] != nil && lines.isEmpty { css += "text-decoration:underline;" }
            if !css.isEmpty { styled = true }
            let piece = whole.substring(with: range)
            parts.append((masked ? WireframeCSS.mask(piece) : piece, css))
        }
        guard styled else { return nil }
        let shown = parts.filter { !$0.0.isEmpty }
        if shown.count == 1 { return .uniform(shown[0].1) }
        var nodes: [VNode] = []
        for (i, part) in parts.enumerated() where !part.0.isEmpty {
            nodes.append(element(id(owner, 10 + 2 * i), part.1, [textNode(id(owner, 11 + 2 * i), part.0)], tag: "span"))
        }
        return .spans(nodes)
    }

    private func fieldBorder(_ field: UITextField, dark: Bool, paints: Bool) -> (fill: String, radius: String, shadows: [String]) {
        switch field.borderStyle {
        case .roundedRect:
            return (
                paints ? "" : (dark ? "background-color:#1c1c1e;" : "background-color:#ffffff;"),
                field.layer.cornerRadius > 0 ? "" : "border-radius:5px;",
                [dark ? "inset 0 0 0 .5px rgba(84,84,88,.65)" : "inset 0 0 0 .5px rgba(60,60,67,.29)"]
            )
        case .line:
            return ("", "", [dark ? "inset 0 0 0 1px #ffffff" : "inset 0 0 0 1px #000000"])
        case .bezel:
            return ("", "", ["inset 0 0 0 1px rgba(128,128,128,.7)"])
        default:
            return ("", "", [])
        }
    }

    /// A text field: its border style, the placeholder or what is typed
    /// (masked), and its side views.
    private func field(_ field: UITextField, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = field.traitCollection
        let dark = traits.userInterfaceStyle == .dark
        let clips = field.clipsToBounds || layer.masksToBounds
        let paint = box(layer, p, clips: clips)
        let border = fieldBorder(field, dark: dark, paints: paint.paints)
        var style = geometry(s, p) + paint.fill + border.fill + paint.radius + border.radius
            + WireframeCSS.shadow(paint.shadows + border.shadows)
        let opacity = Double(layer.opacity)
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        if !field.isEnabled { style += "opacity:.5;" }

        var children: [VNode] = []
        let font: UIFont = field.font ?? UIFont.systemFont(ofSize: 17)
        let raw = WireframeCSS.capped(field.text ?? "")
        let value: String
        let color: WireframeColor?
        if raw.isEmpty {
            let placeholder = field.attributedPlaceholder
            value = WireframeCSS.capped(placeholder?.string ?? field.placeholder ?? "")
            var placeholderColor: UIColor = .placeholderText
            if let placeholder = placeholder, placeholder.length > 0,
               let own = placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor {
                placeholderColor = own
            }
            color = WireframeCapture.color(placeholderColor, traits)
        } else {
            if field.isSecureTextEntry {
                value = String(repeating: "\u{2022}", count: raw.count)
            } else if maskAllInputs || s.maskText {
                value = WireframeCSS.mask(raw)
            } else {
                value = raw
            }
            color = WireframeCapture.color(field.textColor ?? UIColor.label, traits)
        }
        let rect = field.isEditing ? field.editingRect(forBounds: field.bounds) : field.textRect(forBounds: field.bounds)
        let textBox = p.node.translated(Double(rect.minX) - p.boundsX, Double(rect.minY) - p.boundsY)
            .boundingBox(width: Double(rect.width), height: Double(rect.height))
        if !value.isEmpty, let visible = shown(value, textBox, s), rect.width > 0, rect.height > 0 {
            // UIKit draws the placeholder with a label of its own, which
            // works out its direction by itself: it is placed as that label is.
            var placeholderLabel: UILabel?
            if raw.isEmpty {
                placeholderLabel = field.subviews.compactMap { $0 as? UILabel }
                    .first { ($0.attributedText?.string ?? $0.text ?? "") == value }
            }
            let direction = placeholderLabel?.effectiveUserInterfaceLayoutDirection ?? field.effectiveUserInterfaceLayoutDirection
            let rtl = direction == .rightToLeft
            let align = WireframeCapture.align(placeholderLabel?.textAlignment ?? field.textAlignment, rtl: rtl)
            let place = WireframeCSS.rect(
                left: Double(rect.minX) - p.boundsX, top: Double(rect.minY) - p.boundsY,
                width: Double(rect.width), height: Double(rect.height)
            )
            let lineHeight = WireframeCSS.px(Double(rect.height))
            var textStyle = place + WireframeCapture.fontCss(font, color: color)
            textStyle += "line-height:\(lineHeight);"
            if align != "left" { textStyle += "text-align:\(align);" }
            children.append(element(id(field, 1), textStyle, [textNode(id(field, 2), visible)], cls: "t n k"))
        }
        var inner = s.entering(p, field.layer)
        inner.origin = p.node
        if clips {
            style += "overflow:hidden;"
            inner.clip = s.clip.intersection(p.box)
        }
        for side in [field.leftView, field.rightView] {
            if let side = side, side.superview === field { visit(side, inner, &children) }
        }
        out.append(element(id(field), style, children))
    }

    /// A text view: its text within the container insets, masked when it
    /// is editable.
    private func field(_ view: UITextView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        var style = boxCss(s, p, layer, view).0
        if !style.contains("overflow:hidden") { style += "overflow:hidden;" }
        let traits = view.traitCollection
        // At most `maxTextLength` of it: a log console's megabytes are not
        // masked, kept and sent at every frame.
        let attributedText = WireframeCSS.capped(view.attributedText)
        let raw = attributedText?.string ?? WireframeCSS.capped(view.text ?? "")
        var children: [VNode] = []
        if !raw.isEmpty {
            let masked = view.isEditable && maskAllInputs ? WireframeCSS.mask(raw) : raw
            if let visible = shown(masked, p.box, s) {
                let font: UIFont = view.font ?? UIFont.systemFont(ofSize: 12)
                let color = WireframeCapture.color(view.textColor ?? UIColor.label, traits)
                let inset = view.textContainerInset
                let pad = Double(view.textContainer.lineFragmentPadding)
                let left = Double(inset.left) + pad
                let width = max(0, p.width - Double(inset.left) - Double(inset.right) - 2 * pad)
                let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                let align = WireframeCapture.align(view.textAlignment, rtl: rtl)
                let x = WireframeCSS.px(left - p.boundsX)
                let y = WireframeCSS.px(Double(inset.top) - p.boundsY)
                let lineHeight = WireframeCSS.px(Double(font.lineHeight))
                var textStyle = "left:\(x);top:\(y);width:\(WireframeCSS.px(width));"
                textStyle += WireframeCapture.fontCss(font, color: color)
                textStyle += "line-height:\(lineHeight);"
                if align != "left" || rtl { textStyle += "text-align:\(align);" }
                if rtl { textStyle += "direction:rtl;" }
                let maskTyped = view.isEditable && maskAllInputs
                let content = runs(attributedText, font: font, color: color, traits: traits, owner: view,
                                   masked: maskTyped || privacy(p.box, s) == .mask)
                let text: [VNode]
                switch content {
                case .spans(let spans)?:
                    text = spans
                case .uniform(let css)?:
                    textStyle += css
                    text = [textNode(id(view, 2), visible)]
                case nil:
                    text = [textNode(id(view, 2), visible)]
                }
                children.append(element(id(view, 1), textStyle, text, cls: "t"))
            }
        }
        out.append(element(id(view), style, children))
    }

    // MARK: - Images and controls

    private func image(_ view: UIImageView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let (baseStyle, paints) = boxCss(s, p, layer, view)
        var style = baseStyle
        // An image view can hold views of its own, such as the label of a
        // segment or a badge over a picture: they paint over the image.
        var children: [VNode] = []
        if !(view.subviews.isEmpty && (view.layer.sublayers?.isEmpty ?? true)) {
            var inner = s.entering(p, view.layer)
            inner.origin = p.node
            if view.clipsToBounds || layer.masksToBounds { inner.clip = s.clip.intersection(p.box) }
            visitSublayers(of: view, inner, &children)
        }
        let image = view.isHighlighted ? (view.highlightedImage ?? view.image) : view.image
        guard let shownImage = image, p.width > 0, p.height > 0 else {
            if paints || !children.isEmpty { out.append(element(id(view), style, children)) }
            return
        }
        // Symbols are the system's artwork and template images only their
        // shape: both are drawn. Any other image is the app's or the user's
        // picture and never is.
        let template = shownImage.renderingMode == .alwaysTemplate || shownImage.isSymbolImage
        if template && !s.blockImages && privacy(p.box, s) == .show {
            let tint = WireframeCapture.color(view.tintColor, view.traitCollection) ?? .black
            style += "color:\(WireframeCSS.color(tint));"
            if let glyph = glyphs?.lookup(shownImage, size: CGSize(width: p.width, height: p.height),
                                          contentMode: view.contentMode, color: shownImage.isSymbolImage) {
                shownGlyphs.insert(glyph.cls)
                out.append(element(id(view), style, children, cls: "ic " + glyph.cls))
            } else {
                out.append(element(id(view), style, children, cls: "ic"))
            }
        } else if WireframeCapture.isStretchable(shownImage) {
            // A stretched background, border or shadow (a control's, a
            // popover's): artwork, not a picture. Its pixels are not read,
            // and a placeholder would hide what is around it.
            if paints || !children.isEmpty { out.append(element(id(view), style, children)) }
        } else if let picture = photo(shownImage, contentMode: view.contentMode, p, s) {
            out.append(element(id(view), style + picture.placement, children, cls: "im " + picture.cls))
        } else {
            // The app's or the user's picture, while pictures are not
            // allowed or not encoded yet: a placeholder.
            out.append(element(id(view), style, children, cls: "im"))
        }
    }

    /// The picture class and placement of a photo an image view shows, when
    /// this capture may show pictures, no traceway mask covers it and its
    /// picture is encoded; nil keeps the placeholder. Asking starts the
    /// encoding of a picture seen for the first time.
    private func photo(
        _ image: UIImage, contentMode: UIView.ContentMode, _ p: Placed, _ s: Scope
    ) -> (cls: String, placement: String)? {
        guard picturesAllowed, !s.blockImages, privacy(p.box, s) == .show else { return nil }
        let placement = WireframeGlyphs.placement(contentMode)
        let natural = (width: Double(image.size.width), height: Double(image.size.height))
        let drawn = placement.rect(image: natural, box: (p.width, p.height))
        guard let picture = images.picture(image, displayed: CGSize(width: drawn.width, height: drawn.height), nowMs: nowMs),
              picture.css != nil
        else { return nil }
        return (picture.cls, WireframeImageEncoding.placementCss(placement, image: natural, box: (p.width, p.height)))
    }

    /// The same for a photo a layer shows as its contents (SwiftUI's
    /// `Image`, an `ImageLayer`), placed by its `contentsGravity`.
    private func layerPhoto(_ model: CALayer, _ layer: CALayer, _ p: Placed, _ s: Scope) -> (cls: String, placement: String)? {
        guard picturesAllowed, !s.blockImages, privacy(p.box, s) == .show, p.width > 0, p.height > 0,
              let contents = layer.contents
        else { return nil }
        let ref = contents as AnyObject
        guard CFGetTypeID(ref) == CGImage.typeID else { return nil }
        let image = ref as! CGImage // CF bridging: CFGetTypeID checked above
        let scale = max(Double(layer.contentsScale), 1)
        let natural = (width: Double(image.width) / scale, height: Double(image.height) / scale)
        let placement: ImagePlacement
        switch layer.contentsGravity {
        case .resizeAspect: placement = .aspectFit
        case .resizeAspectFill: placement = .aspectFill
        case .center: placement = .center
        default: placement = .fill
        }
        let drawn = placement.rect(image: natural, box: (p.width, p.height))
        guard let picture = images.picture(model, contents: image, displayed: CGSize(width: drawn.width, height: drawn.height),
                                           nowMs: nowMs),
              picture.css != nil
        else { return nil }
        return (picture.cls, WireframeImageEncoding.placementCss(placement, image: natural, box: (p.width, p.height)))
    }

    /// Whether an image is drawn stretched between cap insets, the way
    /// backgrounds and borders are.
    private static func isStretchable(_ image: UIImage) -> Bool {
        let insets = image.capInsets
        return insets.top > 0 || insets.left > 0 || insets.bottom > 0 || insets.right > 0
    }

    /// The fill UIKit's grouped controls (segmented control, stepper) use
    /// behind their content.
    private static func controlFill(dark: Bool) -> String {
        dark ? "background-color:rgba(118,118,128,.24);" : "background-color:rgba(118,118,128,.12);"
    }

    /// A segmented control as UIKit draws it: a rounded track, the selected
    /// segment raised on it, and each segment's title or image centered in
    /// its share of the width. The control's own subviews are internal.
    private func segmented(_ control: UISegmentedControl, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = control.traitCollection
        let dark = traits.userInterfaceStyle == .dark
        let count = min(control.numberOfSegments, 20)
        var style = geometry(s, p) + WireframeCapture.controlFill(dark: dark)
            + "border-radius:\(WireframeCSS.px(min(9, p.height / 2)));"
        if !control.isEnabled { style += "opacity:.5;" }
        let opacity = Double(layer.opacity)
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        guard count > 0, p.width > 0 else {
            out.append(element(id(control), style, []))
            return
        }
        // Widths the app set, the rest sharing what is left.
        var widths = (0..<count).map { Double(control.widthForSegment(at: $0)) }
        let fixed = widths.filter { $0 > 0 }.reduce(0, +)
        let auto = widths.filter { $0 <= 0 }.count
        let share = auto > 0 ? max(0, (p.width - fixed) / Double(auto)) : 0
        widths = widths.map { $0 > 0 ? $0 : share }
        let selected = control.selectedSegmentIndex
        let normalAttributes = control.titleTextAttributes(for: .normal) ?? [:]
        let selectedAttributes = control.titleTextAttributes(for: .selected) ?? [:]
        var children: [VNode] = []
        var x = 0.0
        for i in 0..<count {
            let w = widths[i]
            let isSelected = i == selected
            if isSelected {
                let fill = WireframeCapture.color(control.selectedSegmentTintColor, traits)
                    ?? (dark ? WireframeColor(r: 0.388, g: 0.388, b: 0.4) : .white)
                let knob = WireframeCSS.rect(left: x + 2, top: 2, width: max(0, w - 4), height: max(0, p.height - 4))
                    + "border-radius:\(WireframeCSS.px(min(7, p.height / 2 - 2)));"
                    + WireframeCSS.fill(fill) + "box-shadow:0 3px 8px rgba(0,0,0,.12),0 3px 1px rgba(0,0,0,.04);"
                children.append(element(id(control, 1), knob, []))
            } else if i > 0 && i - 1 != selected {
                let line = WireframeCSS.rect(left: x - 0.5, top: p.height * 0.25, width: 1, height: p.height * 0.5)
                    + (dark ? "background-color:rgba(84,84,88,.6);" : "background-color:rgba(60,60,67,.18);")
                children.append(element(id(control, 100 + i), line, []))
            }
            let place = WireframeCSS.rect(left: x, top: 0, width: w, height: p.height)
            if let title = control.titleForSegment(at: i), !title.isEmpty {
                let attributes = isSelected ? selectedAttributes.merging(normalAttributes) { a, _ in a } : normalAttributes
                let font = attributes[.font] as? UIFont
                    ?? UIFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
                var color = (attributes[.foregroundColor] as? UIColor).flatMap { WireframeCapture.color($0, traits) }
                    ?? WireframeCapture.color(UIColor.label, traits)
                if !control.isEnabledForSegment(at: i) { color = color?.withAlpha((color?.a ?? 1) * 0.35) }
                let visible = shown(title, p.box, s) ?? ""
                let textStyle = place + WireframeCapture.fontCss(font, color: color)
                    + "line-height:\(WireframeCSS.px(p.height));align-items:center;justify-content:center;"
                children.append(element(id(control, 200 + 2 * i), textStyle,
                                        visible.isEmpty ? [] : [textNode(id(control, 201 + 2 * i), visible)], cls: "t n"))
            } else if control.imageForSegment(at: i) != nil {
                let side = min(w, p.height) * 0.6
                let icon = WireframeCSS.rect(left: x + (w - side) / 2, top: (p.height - side) / 2, width: side, height: side)
                    + "color:\(WireframeCSS.color(WireframeCapture.color(UIColor.label, traits) ?? .black));"
                children.append(element(id(control, 200 + 2 * i), icon, [], cls: "ic"))
            }
            x += w
        }
        out.append(element(id(control), style, children))
    }

    /// A stepper: a rounded track split in two, a minus and a plus, each
    /// faded where the value cannot go further.
    private func stepper(_ stepper: UIStepper, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = stepper.traitCollection
        let dark = traits.userInterfaceStyle == .dark
        var style = geometry(s, p) + WireframeCapture.controlFill(dark: dark)
            + "border-radius:\(WireframeCSS.px(min(8, p.height / 2)));"
        if !stepper.isEnabled { style += "opacity:.5;" }
        let half = p.width / 2
        let ink = WireframeCapture.color(UIColor.label, traits) ?? .black
        let atMin = !stepper.wraps && stepper.value <= stepper.minimumValue
        let atMax = !stepper.wraps && stepper.value >= stepper.maximumValue
        func sign(_ role: Int, _ glyph: String, _ left: Double, _ faded: Bool) -> VNode {
            let color = faded ? ink.withAlpha(ink.a * 0.3) : ink
            let place = WireframeCSS.rect(left: left, top: 0, width: half, height: p.height)
                + "font-size:20px;line-height:\(WireframeCSS.px(p.height));color:\(WireframeCSS.color(color));"
                + "align-items:center;justify-content:center;"
            return element(id(stepper, role), place, [textNode(id(stepper, role + 1), glyph)], cls: "t n")
        }
        let divider = WireframeCSS.rect(left: half - 0.5, top: p.height * 0.25, width: 1, height: p.height * 0.5)
            + (dark ? "background-color:rgba(84,84,88,.6);" : "background-color:rgba(60,60,67,.29);")
        out.append(element(id(stepper), style, [
            sign(1, "\u{2212}", 0, atMin),
            element(id(stepper, 3), divider, []),
            sign(4, "+", half, atMax),
        ]))
    }

    private func toggle(_ toggle: UISwitch, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = toggle.traitCollection
        let dark = traits.userInterfaceStyle == .dark
        // The switch's bounds are its track: 51 x 31 up to iOS 18, 63 x 28
        // with iOS 26's wider track and capsule knob.
        let w = p.width, h = p.height
        let cx = p.width / 2, cy = p.height / 2
        let on = toggle.isOn
        let track = on
            ? WireframeCSS.fill(WireframeCapture.color(toggle.onTintColor, traits) ?? WireframeColor(r: 0.204, g: 0.78, b: 0.349))
            : (dark ? "background-color:rgba(120,120,128,.32);" : "background-color:rgba(120,120,128,.16);")
        let thumb = WireframeCapture.color(toggle.thumbTintColor, traits) ?? .white
        let knob = max(0, h - 4)
        let knobWidth = w / h > 2 ? min(knob * 1.5, w / 2) : knob
        var kx = on ? w - knobWidth - (h - knob) / 2 : (h - knob) / 2
        // Right to left, a switch is mirrored: on is to the left.
        if toggle.effectiveUserInterfaceLayoutDirection == .rightToLeft { kx = w - knobWidth - kx }
        var style = geometry(s, p)
        if !toggle.isEnabled { style += "opacity:.5;" }
        let opacity = Double(layer.opacity)
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        let trackRadius = WireframeCSS.px(h / 2)
        let trackStyle = WireframeCSS.rect(left: cx - w / 2, top: cy - h / 2, width: w, height: h)
            + "border-radius:\(trackRadius);" + track
        let thumbFill = WireframeCSS.color(thumb)
        let thumbStyle = WireframeCSS.rect(left: kx, top: (h - knob) / 2, width: knobWidth, height: knob)
            + "border-radius:\(WireframeCSS.px(knob / 2));background-color:\(thumbFill);box-shadow:0 2px 6px rgba(0,0,0,.2);"
        let knobNode = element(id(toggle, 2), thumbStyle, [])
        out.append(element(id(toggle), style, [element(id(toggle, 1), trackStyle, [knobNode])]))
    }

    private func slider(_ slider: UISlider, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = slider.traitCollection
        let bounds = slider.bounds
        let track = slider.trackRect(forBounds: bounds)
        let thumb = slider.thumbRect(forBounds: bounds, trackRect: track, value: slider.value)
        let ox = Double(bounds.minX), oy = Double(bounds.minY)
        let trackHeight = max(2, Double(track.height))
        let top = Double(track.midY) - oy - trackHeight / 2
        let split = min(max(Double(thumb.midX), Double(track.minX)), Double(track.maxX)) - ox
        let minColor = WireframeCapture.color(slider.minimumTrackTintColor ?? slider.tintColor, traits)
            ?? WireframeColor(r: 0, g: 0.478, b: 1)
        let maxColor = WireframeCapture.color(slider.maximumTrackTintColor, traits)
            ?? WireframeColor(r: 0.47, g: 0.47, b: 0.5, a: 0.2)
        let thumbColor = WireframeCapture.color(slider.thumbTintColor, traits) ?? .white
        let radius = "border-radius:\(WireframeCSS.px(trackHeight / 2));"
        var style = geometry(s, p)
        if !slider.isEnabled { style += "opacity:.5;" }
        let trackLeft = Double(track.minX) - ox
        let trackRight = Double(track.maxX) - ox
        let maxStyle = WireframeCSS.rect(left: split, top: top, width: Swift.max(0.0, trackRight - split), height: trackHeight)
            + radius + WireframeCSS.fill(maxColor)
        let minStyle = WireframeCSS.rect(left: trackLeft, top: top, width: Swift.max(0.0, split - trackLeft), height: trackHeight)
            + radius + WireframeCSS.fill(minColor)
        let thumbFill = WireframeCSS.color(thumbColor)
        let thumbStyle = WireframeCSS.rect(
            left: Double(thumb.minX) - ox, top: Double(thumb.minY) - oy,
            width: Double(thumb.width), height: Double(thumb.height)
        ) + "border-radius:\(WireframeCSS.px(min(Double(thumb.width), Double(thumb.height)) / 2));"
            + "background-color:\(thumbFill);box-shadow:0 .5px 4px rgba(0,0,0,.25),0 0 0 .5px rgba(0,0,0,.04);"
        out.append(element(id(slider), style, [
            element(id(slider, 1), maxStyle, []),
            element(id(slider, 2), minStyle, []),
            element(id(slider, 3), thumbStyle, []),
        ]))
    }

    private func progress(_ view: UIProgressView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = view.traitCollection
        let track = WireframeCapture.color(view.trackTintColor, traits) ?? WireframeColor(r: 0.47, g: 0.47, b: 0.5, a: 0.2)
        let fill = WireframeCapture.color(view.progressTintColor ?? view.tintColor, traits) ?? WireframeColor(r: 0, g: 0.478, b: 1)
        let value = min(max(Double(view.progress), 0), 1)
        let radius = "border-radius:\(WireframeCSS.px(p.height / 2));"
        let percent = WireframeCSS.num1(value * 100)
        // Right to left, a bar fills from the right edge.
        let side = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? "left:auto;right:0;" : ""
        let barStyle = side + "width:\(percent)%;height:100%;" + radius + WireframeCSS.fill(fill)
        let trackStyle = geometry(s, p) + WireframeCSS.fill(track) + radius + "overflow:hidden;"
        out.append(element(id(view), trackStyle, [element(id(view, 1), barStyle, [])]))
    }

    /// A spinner: a dotted ring in its color.
    private func progress(_ view: UIActivityIndicatorView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let color = WireframeCapture.color(view.color, view.traitCollection) ?? WireframeColor(r: 0.557, g: 0.557, b: 0.576)
        let side = min(p.width, p.height)
        guard side > 0 else { return }
        let stroke = WireframeCSS.px(Swift.max(2.0, side / 8))
        let strokeColor = WireframeCSS.color(color)
        let ring = WireframeCSS.rect(left: (p.width - side) / 2, top: (p.height - side) / 2, width: side, height: side)
            + "border-radius:50%;border:\(stroke) dotted \(strokeColor);"
        out.append(element(id(view), geometry(s, p), [element(id(view, 1), ring, [])]))
    }

    private func pageControl(_ view: UIPageControl, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let traits = view.traitCollection
        let count = min(view.numberOfPages, 30)
        let (style, _) = boxCss(s, p, layer, view)
        guard count > 0, !(view.hidesForSinglePage && count == 1) else {
            out.append(element(id(view), style, []))
            return
        }
        let current = WireframeCapture.color(view.currentPageIndicatorTintColor ?? UIColor.label, traits) ?? .black
        let other = WireframeCapture.color(view.pageIndicatorTintColor ?? UIColor.tertiaryLabel, traits)
            ?? WireframeColor(r: 0.5, g: 0.5, b: 0.5, a: 0.4)
        let dot = 7.0, gap = 9.0
        let total = Double(count) * dot + Double(count - 1) * gap
        let x0 = (p.width - total) / 2, y = (p.height - dot) / 2
        var dots: [VNode] = []
        for i in 0..<count {
            let c = i == view.currentPage ? current : other
            let x = x0 + Double(i) * (dot + gap)
            let dotStyle = WireframeCSS.rect(left: x, top: y, width: dot, height: dot) + "border-radius:50%;"
                + WireframeCSS.fill(c)
            dots.append(element(id(view, 1 + i), dotStyle, []))
        }
        out.append(element(id(view), style, dots))
    }

    private func visualEffect(_ view: UIVisualEffectView, _ layer: CALayer, _ p: Placed, _ s: Scope, _ out: inout [VNode]) {
        let clips = view.clipsToBounds || layer.masksToBounds
        let paint = box(layer, p, clips: true)
        var style = geometry(s, p) + paint.css
        let dark = view.traitCollection.userInterfaceStyle == .dark
        if let effect = view.effect, NSStringFromClass(type(of: effect)).contains("Glass") {
            // iOS 26's Liquid Glass: a lighter frost with a bright rim.
            if !paint.paints {
                style += dark ? "background-color:rgba(60,60,64,.55);" : "background-color:rgba(255,255,255,.6);"
            }
            if !style.contains("border-radius") {
                // Bars and buttons are capsules; a large panel is rounded.
                let side = min(p.width, p.height)
                style += "border-radius:\(WireframeCSS.px(side <= 80 ? side / 2 : 26));"
            }
            style += "-webkit-backdrop-filter:blur(12px) saturate(1.6);backdrop-filter:blur(12px) saturate(1.6);"
                + (dark ? "box-shadow:inset 0 0 0 .5px rgba(255,255,255,.18),0 4px 16px rgba(0,0,0,.3);"
                        : "box-shadow:inset 0 0 0 .5px rgba(255,255,255,.7),0 4px 16px rgba(0,0,0,.08);")
        } else if view.effect is UIBlurEffect {
            style += (dark ? "background-color:rgba(30,30,30,.72);" : "background-color:rgba(250,250,250,.72);")
                + "-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);"
        }
        let opacity = Double(layer.opacity)
        if opacity < 0.999 { style += "opacity:\(WireframeCSS.num3(opacity));" }
        var inner = s.entering(p, view.layer)
        inner.origin = p.node
        if clips {
            style += "overflow:hidden;"
            inner.clip = s.clip.intersection(p.box)
        }
        var children: [VNode] = []
        visit(view.contentView, inner, &children)
        out.append(element(id(view), style, children))
    }

    // MARK: - Layers

    private func gradientCss(_ layer: CAGradientLayer, _ p: Placed) -> String {
        let colors = (layer.colors ?? []).compactMap { WireframeCapture.cgColor($0) }
            .map { WireframeCapture.color($0) ?? WireframeColor(r: 0, g: 0, b: 0, a: 0) }
        guard !colors.isEmpty else { return "" }
        let locations = layer.locations?.map { $0.doubleValue }
        let start = layer.startPoint, end = layer.endPoint
        if layer.type == .radial {
            return WireframeCSS.radialGradient(colors: colors, locations: locations, centerX: Double(start.x), centerY: Double(start.y))
        }
        if layer.type == .conic {
            return WireframeCSS.conicGradient(colors: colors, locations: locations, centerX: Double(start.x), centerY: Double(start.y))
        }
        return WireframeCSS.linearGradient(
            colors: colors, locations: locations,
            startX: Double(start.x), startY: Double(start.y), endX: Double(end.x), endY: Double(end.y),
            width: p.width, height: p.height
        )
    }

    /// A shape as its bounding box: filled, outlined, and round when it is
    /// about as wide as tall and not a rectangle.
    private func shapeNode(_ layer: CAShapeLayer, _ model: CALayer, _ p: Placed) -> VNode? {
        guard let path = layer.path else { return nil }
        let bounds = path.boundingBox
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let fill = WireframeCapture.color(layer.fillColor)
        let stroke = WireframeCSS.insetBorder(width: Double(layer.lineWidth), color: WireframeCapture.color(layer.strokeColor))
        if WireframeCSS.isTransparent(fill) && stroke == nil { return nil }
        var rect = CGRect.zero
        let isRect = path.isRect(&rect)
        let w = Double(bounds.width), h = Double(bounds.height)
        var style = WireframeCSS.rect(
            left: Double(bounds.minX) - p.boundsX, top: Double(bounds.minY) - p.boundsY, width: w, height: h
        ) + WireframeCSS.fill(fill)
        if !isRect {
            style += abs(w - h) < 1.5 ? "border-radius:50%;" : WireframeCSS.radius(min(4, min(w, h) / 2))
        }
        if let stroke = stroke { style += "box-shadow:\(stroke);" }
        return element(id(model, 1), style, [])
    }

    private func textLayerNode(_ layer: CATextLayer, _ model: CALayer, _ p: Placed, _ s: Scope) -> VNode? {
        let raw: String
        if let string = layer.string as? String {
            raw = string
        } else if let attributed = layer.string as? NSAttributedString {
            raw = attributed.string
        } else {
            return nil
        }
        guard !raw.isEmpty, let visible = shown(raw, p.box, s) else { return nil }
        var style = "width:100%;height:100%;font-size:\(WireframeCSS.px(Double(layer.fontSize)));"
        if let color = WireframeCapture.color(layer.foregroundColor) { style += "color:\(WireframeCSS.color(color));" }
        switch layer.alignmentMode {
        case .center: style += "text-align:center;"
        case .right: style += "text-align:right;"
        case .justified: style += "text-align:justify;"
        default: break
        }
        return element(id(model, 1), style, [textNode(id(model, 2), visible)], cls: "t")
    }
}

/// What the walk needs to know about a class, worked out once per class.
struct ClassInfo: Equatable {
    enum Kind: Equatable {
        case plain
        /// Internal views that only get in the way, such as scroll indicators.
        case skip
        case swiftUIHost
        case swiftUIDrawing
        case swiftUIImage
        /// A layer SwiftUI draws a `Text` into.
        case swiftUIText
        /// A Liquid Glass shape the system fills with frosted glass.
        case glassShape
        case imageLayer
        /// A view or layer whose pixels the system draws: a placeholder with
        /// this label.
        case native(String)
        /// A view of the app that draws itself in `draw(_:)`.
        case customDraw
    }

    var kind: Kind = .plain
    var isKeyboardWindow = false
    /// iOS 26's group of Liquid Glass shapes, painted under the content of
    /// the view it belongs to.
    var isGlassGroup = false
    /// iOS 26's lens over a selection.
    var isLens = false

    private static var cache: [ObjectIdentifier: ClassInfo] = [:]

    static func of(_ object: AnyObject) -> ClassInfo {
        guard let cls = object_getClass(object) else { return ClassInfo() }
        let key = ObjectIdentifier(cls)
        if let hit = cache[key] { return hit }
        let info = compute(cls)
        cache[key] = info
        return info
    }

    private static let drawSelector = #selector(UIView.draw(_:))
    private static let baseDraw: IMP? = class_getInstanceMethod(UIView.self, ClassInfo.drawSelector)
        .map { method_getImplementation($0) }

    private static func compute(_ cls: AnyClass) -> ClassInfo {
        var names: [String] = []
        var c: AnyClass? = cls
        while let k = c {
            names.append(NSStringFromClass(k))
            c = class_getSuperclass(k)
        }
        func has(_ part: String) -> Bool { names.contains { $0.contains(part) } }
        var info = ClassInfo()
        if has("UIRemoteKeyboardWindow") || has("UITextEffectsWindow") || has("UIKeyboardWindow") {
            info.isKeyboardWindow = true
        }
        info.isGlassGroup = has("GlassGroupView")
        info.isLens = has("LiquidLens")
        if has("_UIScrollViewScrollIndicator") || has("UIScrollViewScrollIndicator") {
            info.kind = .skip
        } else if has("WKWebView") || has("UIWebView") || has("SFSafariView") {
            info.kind = .native("Web view")
        } else if has("MKMapView") {
            info.kind = .native("Map")
        } else if has("AVCaptureVideoPreviewLayer") {
            info.kind = .native("Camera")
        } else if has("AVPlayerLayer") || has("AVPlayerView") || has("AVPictureInPicture") {
            info.kind = .native("Video")
        } else if has("MTKView") || has("GLKView") || has("SCNView") || has("SKView") || has("ARView")
            || has("CAMetalLayer") || has("CAEAGLLayer") {
            info.kind = .native("Native view")
        } else if has("PDFView") {
            info.kind = .native("Document")
        } else if has("_UIRemoteView") {
            info.kind = .native("Native view")
        } else if has("HostingView") {
            info.kind = .swiftUIHost
        } else if has("SDFElement") {
            info.kind = .glassShape
        } else if has("CGDrawingLayer") {
            info.kind = .swiftUIText
        } else if has("CGDrawingView") || (has("SwiftUI") && has("_UIGraphicsView")) {
            info.kind = .swiftUIDrawing
        } else if has("SwiftUI") && has("ImageLayer") {
            info.kind = .swiftUIImage
        } else if has("ImageLayer") {
            info.kind = .imageLayer
        } else if cls is UIView.Type, isCustomDrawing(cls) {
            info.kind = .customDraw
        }
        return info
    }

    /// Whether `cls` paints in a `draw(_:)` the app itself implements.
    private static func isCustomDrawing(_ cls: AnyClass) -> Bool {
        guard let method = class_getInstanceMethod(cls, drawSelector) else { return false }
        let imp = method_getImplementation(method)
        if imp == baseDraw { return false }
        var definer: AnyClass = cls
        while let superclass = class_getSuperclass(definer),
              let superMethod = class_getInstanceMethod(superclass, drawSelector),
              method_getImplementation(superMethod) == imp {
            definer = superclass
        }
        let path = Bundle(for: definer).bundlePath
        return !(path.contains("/System/Library/") || path.contains("/usr/lib/") || path.hasPrefix("/Library/"))
    }
}
#endif
