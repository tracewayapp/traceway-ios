import Foundation

/// A color with components from 0 to 1, in sRGB.
struct WireframeColor: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let black = WireframeColor(r: 0, g: 0, b: 0)
    static let white = WireframeColor(r: 1, g: 1, b: 1)

    func withAlpha(_ alpha: Double) -> WireframeColor {
        WireframeColor(r: r, g: g, b: b, a: alpha)
    }

    /// Whether nothing of it shows: no color at all, or no alpha in 8 bits.
    var isTransparent: Bool { WireframeCSS.byte(a) == 0 }
}

/// Formatting of the inline styles the wireframe nodes carry, the same as
/// the Flutter SDK writes them so both replay alike.
enum WireframeCSS {
    /// A length in CSS pixels, rounded to a tenth so sub-pixel animation
    /// noise does not turn into a mutation on every frame.
    static func px(_ value: Double) -> String { num1(value) + "px" }

    /// `left`, `top`, `width` and `height` of a box.
    static func rect(left: Double, top: Double, width: Double, height: Double) -> String {
        let l = px(left), t = px(top), w = px(width), h = px(height)
        return "left:\(l);top:\(t);width:\(w);height:\(h);"
    }

    static func num1(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let scaled = (value * 10).rounded()
        guard abs(scaled) < 1e15 else { return "0" }
        let tenths = Int64(scaled)
        if tenths % 10 == 0 { return String(tenths / 10) }
        return "\(Double(tenths) / 10)"
    }

    static func num3(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 1000).rounded() / 1000
        guard abs(rounded) < 1e15 else { return "0" }
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        return "\(rounded)"
    }

    static func byte(_ component: Double) -> Int {
        guard component.isFinite else { return 0 }
        return Int((min(max(component, 0), 1) * 255).rounded())
    }

    private static let hex: [Character] = Array("0123456789abcdef")

    private static func hex2(_ value: Int) -> String {
        String([hex[(value >> 4) & 0xf], hex[value & 0xf]])
    }

    static func color(_ c: WireframeColor) -> String {
        let r = byte(c.r), g = byte(c.g), b = byte(c.b), a = byte(c.a)
        if a == 255 { return "#" + hex2(r) + hex2(g) + hex2(b) }
        return "rgba(\(r),\(g),\(b),\(num3(Double(a) / 255)))"
    }

    static func isTransparent(_ c: WireframeColor?) -> Bool {
        c?.isTransparent ?? true
    }

    /// `background-color` of a fill, or nothing when it does not show.
    static func fill(_ c: WireframeColor?) -> String {
        guard let c = c, !c.isTransparent else { return "" }
        return "background-color:\(color(c));"
    }

    /// `border-radius` for the four corners, or empty when all are square.
    static func radius(topLeft tl: Double, topRight tr: Double, bottomRight br: Double, bottomLeft bl: Double) -> String {
        let corners = [tl, tr, br, bl].map { $0.isFinite && $0 > 0 ? $0 : 0 }
        if corners.allSatisfy({ $0 == 0 }) { return "" }
        if corners.allSatisfy({ $0 == corners[0] }) { return "border-radius:\(px(corners[0]));" }
        return "border-radius:\(corners.map(px).joined(separator: " "));"
    }

    static func radius(_ uniform: Double) -> String {
        radius(topLeft: uniform, topRight: uniform, bottomRight: uniform, bottomLeft: uniform)
    }

    /// A border drawn as an inset box shadow: like a UIKit layer border it
    /// paints inside the box, and unlike a CSS border it does not move the
    /// children, which are placed from the box's corner.
    static func insetBorder(width: Double, color c: WireframeColor?) -> String? {
        guard width.isFinite, width > 0, let c = c, !c.isTransparent else { return nil }
        return "inset 0 0 0 \(px(width)) \(color(c))"
    }

    /// One side of a border as an inset shadow: `dx`/`dy` give the side
    /// (0, 1 is the top, -1, 0 the right, 0, -1 the bottom, 1, 0 the left).
    static func insetSide(width: Double, color c: WireframeColor?, dx: Double, dy: Double) -> String? {
        guard width.isFinite, width > 0, let c = c, !c.isTransparent else { return nil }
        func offset(_ d: Double) -> String { d == 0 ? "0" : px(d * width) }
        return "inset \(offset(dx)) \(offset(dy)) 0 0 \(color(c))"
    }

    static func boxShadow(dx: Double, dy: Double, blur: Double, spread: Double = 0, color c: WireframeColor?) -> String? {
        guard let c = c, !c.isTransparent else { return nil }
        return "\(px(dx)) \(px(dy)) \(px(max(0, blur))) \(px(spread)) \(color(c))"
    }

    static func shadow(_ parts: [String]) -> String {
        parts.isEmpty ? "" : "box-shadow:\(parts.joined(separator: ","));"
    }

    /// The color stops of a gradient: each color at its location, when
    /// locations are given.
    static func stops(_ colors: [WireframeColor], _ locations: [Double]?) -> String {
        var parts: [String] = []
        for (i, c) in colors.enumerated() {
            if let locations = locations, i < locations.count {
                parts.append("\(color(c)) \(num1(locations[i] * 100))%")
            } else {
                parts.append(color(c))
            }
        }
        return parts.joined(separator: ",")
    }

    /// A linear gradient from `start` to `end`, points in the box's unit
    /// square (0, 0 top left), as `background-image`.
    static func linearGradient(
        colors: [WireframeColor], locations: [Double]?,
        startX: Double, startY: Double, endX: Double, endY: Double,
        width: Double, height: Double
    ) -> String {
        guard !colors.isEmpty else { return "" }
        // CSS angles run clockwise from "to top".
        let dx = (endX - startX) * width
        let dy = (endY - startY) * height
        var degrees = atan2(dx, -dy) * 180 / Double.pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return "background-image:linear-gradient(\(num1(degrees))deg,\(stops(colors, locations)));"
    }

    static func radialGradient(
        colors: [WireframeColor], locations: [Double]?, centerX: Double, centerY: Double
    ) -> String {
        guard !colors.isEmpty else { return "" }
        return "background-image:radial-gradient(circle at \(num1(centerX * 100))% \(num1(centerY * 100))%,"
            + "\(stops(colors, locations)));"
    }

    static func conicGradient(
        colors: [WireframeColor], locations: [Double]?, centerX: Double, centerY: Double
    ) -> String {
        guard !colors.isEmpty else { return "" }
        return "background-image:conic-gradient(from 90deg at \(num1(centerX * 100))% \(num1(centerY * 100))%,"
            + "\(stops(colors, locations)));"
    }

    /// `text` with every character but whitespace replaced by `*`, as
    /// rrweb masks inputs.
    static func mask(_ text: String) -> String {
        String(text.map { $0.isWhitespace ? $0 : "*" })
    }
}

/// A 2D affine transform: x' = a·x + c·y + tx, y' = b·x + d·y + ty, the
/// layout of `CGAffineTransform`. The perspective part of a 3D transform is
/// dropped.
struct WireframeAffine: Equatable {
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var tx: Double
    var ty: Double

    static let identity = WireframeAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    static func translation(_ x: Double, _ y: Double) -> WireframeAffine {
        WireframeAffine(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    private static let epsilon = 1e-6

    var isTranslation: Bool {
        abs(a - 1) < WireframeAffine.epsilon && abs(b) < WireframeAffine.epsilon
            && abs(c) < WireframeAffine.epsilon && abs(d - 1) < WireframeAffine.epsilon
    }

    var isDegenerate: Bool { abs(a * d - b * c) < 1e-9 || !a.isFinite || !d.isFinite || !tx.isFinite || !ty.isFinite }

    func translated(_ x: Double, _ y: Double) -> WireframeAffine {
        WireframeAffine(a: a, b: b, c: c, d: d, tx: tx + a * x + c * y, ty: ty + b * x + d * y)
    }

    /// This transform applied after `local`: maps `local`'s space to where
    /// this one maps.
    func then(_ local: WireframeAffine) -> WireframeAffine {
        if local.isTranslation { return translated(local.tx, local.ty) }
        return WireframeAffine(
            a: a * local.a + c * local.b,
            b: b * local.a + d * local.b,
            c: a * local.c + c * local.d,
            d: b * local.c + d * local.d,
            tx: a * local.tx + c * local.ty + tx,
            ty: b * local.tx + d * local.ty + ty
        )
    }

    var inverted: WireframeAffine {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return .identity }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return WireframeAffine(
            a: ia, b: ib, c: ic, d: id,
            tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty)
        )
    }

    /// This transform as seen from inside `origin`'s space.
    func relative(to origin: WireframeAffine) -> WireframeAffine {
        if origin.isTranslation && isTranslation {
            return .translation(tx - origin.tx, ty - origin.ty)
        }
        return origin.inverted.then(self)
    }

    func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    /// The bounding box of the rectangle `0, 0, width, height` once mapped.
    func boundingBox(width: Double, height: Double) -> WireframeRect {
        let p = [apply(x: 0, y: 0), apply(x: width, y: 0), apply(x: 0, y: height), apply(x: width, y: height)]
        let xs = p.map { $0.x }, ys = p.map { $0.y }
        let minX = xs.min()!, minY = ys.min()!
        return WireframeRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
    }
}

struct WireframeRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var isEmpty: Bool { !(width > 0 && height > 0) }

    func overlaps(_ other: WireframeRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func intersection(_ other: WireframeRect) -> WireframeRect {
        let nx = max(x, other.x), ny = max(y, other.y)
        let w = min(maxX, other.maxX) - nx, h = min(maxY, other.maxY) - ny
        return WireframeRect(x: nx, y: ny, width: max(0, w), height: max(0, h))
    }

    func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }
}

/// Where a node is inside its DOM parent, whose coordinates `origin` maps to
/// the screen, and how big it is.
func wireframeGeometry(origin: WireframeAffine, transform t: WireframeAffine, width: Double, height: Double) -> String {
    let rel = t.relative(to: origin)
    let dims = "width:\(WireframeCSS.px(width));height:\(WireframeCSS.px(height));"
    if rel.isTranslation {
        return "left:\(WireframeCSS.px(rel.tx));top:\(WireframeCSS.px(rel.ty));" + dims
    }
    return "transform:matrix(\(WireframeCSS.num3(rel.a)),\(WireframeCSS.num3(rel.b)),"
        + "\(WireframeCSS.num3(rel.c)),\(WireframeCSS.num3(rel.d)),"
        + "\(WireframeCSS.num1(rel.tx)),\(WireframeCSS.num1(rel.ty)));transform-origin:0 0;" + dims
}
