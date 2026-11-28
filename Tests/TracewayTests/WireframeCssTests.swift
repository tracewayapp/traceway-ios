import XCTest
@testable import Traceway

/// The inline styles the wireframe nodes carry (`WireframeCSS`) and the
/// geometry they are placed with. The shared stylesheet itself is checked by
/// `WireframeStylesheetTests`; text and native-view styles come from the
/// UIKit capture and are checked by `UIKitWireframeTests`.
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

    func testNumbersLoseTheirTrailingZeros() {
        XCTAssertEqual(WireframeCSS.num1(12.34), "12.3")
        XCTAssertEqual(WireframeCSS.num1(-0.5), "-0.5")
        XCTAssertEqual(WireframeCSS.num1(3), "3")
        XCTAssertEqual(WireframeCSS.num1(0.04), "0")
        XCTAssertEqual(WireframeCSS.num1(-0.04), "0")
        XCTAssertEqual(WireframeCSS.num1(.infinity), "0")
        XCTAssertEqual(WireframeCSS.num1(1e300), "0", "a length no screen has")
        XCTAssertEqual(WireframeCSS.px(12.46), "12.5px")
        XCTAssertEqual(WireframeCSS.num3(64.0 / 255), "0.251")
        XCTAssertEqual(WireframeCSS.num3(0.05), "0.05")
        XCTAssertEqual(WireframeCSS.num3(0.007), "0.007")
        XCTAssertEqual(WireframeCSS.num3(-0.25), "-0.25")
        XCTAssertEqual(WireframeCSS.num3(0.0004), "0")
        XCTAssertEqual(WireframeCSS.num3(.nan), "0")
    }

    func testColors() {
        XCTAssertEqual(WireframeCSS.color(WireframeColor(r: 1, g: 0, b: 0)), "#ff0000")
        XCTAssertEqual(WireframeCSS.color(WireframeColor(r: 0, g: 0.5, b: 1, a: 0.5)), "rgba(0,128,255,0.502)")
        XCTAssertEqual(WireframeCSS.fill(WireframeColor(r: 1, g: 1, b: 1, a: 0)), "")
        XCTAssertEqual(WireframeCSS.fill(nil), "")
        XCTAssertEqual(WireframeCSS.fill(.white), "background-color:#ffffff;")
    }

    func testTransparencyIsDecidedInEightBits() {
        XCTAssertTrue(WireframeColor(r: 1, g: 1, b: 1, a: 0.001).isTransparent, "rounds to an alpha of 0")
        XCTAssertFalse(WireframeColor(r: 1, g: 1, b: 1, a: 0.003).isTransparent)
        XCTAssertEqual(WireframeCSS.color(WireframeColor(r: 0, g: 0, b: 0, a: 64.0 / 255)), "rgba(0,0,0,0.251)")
        XCTAssertTrue(WireframeCSS.isTransparent(nil))
        XCTAssertFalse(WireframeCSS.isTransparent(.black))
        XCTAssertEqual(WireframeColor.black.withAlpha(0.5), WireframeColor(r: 0, g: 0, b: 0, a: 0.5))
        // Components outside 0...1 (extended range colors) are clamped.
        XCTAssertEqual(WireframeCSS.color(WireframeColor(r: 1.5, g: -0.2, b: .nan)), "#ff0000")
        XCTAssertEqual(WireframeCSS.byte(0.5), 128)
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

    func testUnusableCornersAndShadowsAreLeftOut() {
        XCTAssertEqual(WireframeCSS.radius(topLeft: .nan, topRight: -4, bottomRight: .infinity, bottomLeft: 0), "")
        XCTAssertEqual(WireframeCSS.radius(topLeft: 6, topRight: .nan, bottomRight: 6, bottomLeft: 6),
                       "border-radius:6px 0px 6px 6px;")
        XCTAssertEqual(WireframeCSS.radius(4.04), "border-radius:4px;")
        XCTAssertNil(WireframeCSS.insetBorder(width: .nan, color: .black))
        XCTAssertNil(WireframeCSS.insetBorder(width: 1, color: WireframeColor(r: 0, g: 0, b: 0, a: 0)))
        XCTAssertEqual(WireframeCSS.insetSide(width: 1, color: .black, dx: -1, dy: 0), "inset -1px 0 0 0 #000000")
        XCTAssertEqual(WireframeCSS.insetSide(width: 1, color: .black, dx: 0, dy: -1), "inset 0 -1px 0 0 #000000")
        XCTAssertNil(WireframeCSS.insetSide(width: 0, color: .black, dx: 1, dy: 0))
        XCTAssertNil(WireframeCSS.boxShadow(dx: 0, dy: 1, blur: 2, color: nil))
        XCTAssertNil(WireframeCSS.boxShadow(dx: 0, dy: 1, blur: 2, color: WireframeColor(r: 0, g: 0, b: 0, a: 0)))
        XCTAssertEqual(WireframeCSS.boxShadow(dx: 1, dy: 1, blur: -3, spread: 2, color: .black),
                       "1px 1px 0px 2px #000000", "a negative blur is none")
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

    func testGradientAnglesRunClockwiseFromTheTopInTheBoxsProportions() {
        let colors = [WireframeColor.black, WireframeColor.white]
        func angle(_ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double, _ w: Double = 10, _ h: Double = 10) -> String {
            WireframeCSS.linearGradient(colors: colors, locations: nil, startX: sx, startY: sy, endX: ex, endY: ey, width: w, height: h)
        }
        XCTAssertTrue(angle(0.5, 1, 0.5, 0).contains("(0deg,"), "bottom to top")
        XCTAssertTrue(angle(1, 0.5, 0, 0.5).contains("(270deg,"), "right to left")
        XCTAssertTrue(angle(0, 0, 1, 1).contains("(135deg,"), "a square's diagonal")
        // The same diagonal of a wide box is flatter.
        XCTAssertTrue(angle(0, 0, 1, 1, 30, 10).contains("(108.4deg,"))
        XCTAssertEqual(WireframeCSS.linearGradient(colors: [], locations: nil, startX: 0, startY: 0, endX: 1, endY: 1,
                                                   width: 10, height: 10), "")
    }

    func testRadialAndConicGradientsArePlacedAtTheirCenter() {
        let colors = [WireframeColor(r: 1, g: 0, b: 0), WireframeColor(r: 0, g: 0, b: 1, a: 0.5)]
        XCTAssertEqual(
            WireframeCSS.radialGradient(colors: colors, locations: [0, 1], centerX: 0.5, centerY: 0.25),
            "background-image:radial-gradient(circle at 50% 25%,#ff0000 0%,rgba(0,0,255,0.502) 100%);"
        )
        XCTAssertEqual(
            WireframeCSS.conicGradient(colors: colors, locations: nil, centerX: 0.5, centerY: 0.5),
            "background-image:conic-gradient(from 90deg at 50% 50%,#ff0000,rgba(0,0,255,0.502));"
        )
        XCTAssertEqual(WireframeCSS.radialGradient(colors: [], locations: nil, centerX: 0, centerY: 0), "")
        XCTAssertEqual(WireframeCSS.conicGradient(colors: [], locations: nil, centerX: 0, centerY: 0), "")
        // Fewer locations than colors: the rest go without one.
        XCTAssertEqual(WireframeCSS.stops([.black, .white], [0.5]), "#000000 50%,#ffffff")
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

    func testTransformsComposeAndInvert() {
        let scale = WireframeAffine(a: 2, b: 0, c: 0, d: 2, tx: 10, ty: 20)
        // A child 5, 5 inside a view scaled by 2 sits at 20, 30 on screen.
        let child = scale.then(.translation(5, 5))
        XCTAssertEqual(child, WireframeAffine(a: 2, b: 0, c: 0, d: 2, tx: 20, ty: 30))
        XCTAssertEqual(scale.translated(5, 5), child)
        let p = scale.inverted.apply(x: 20, y: 30)
        XCTAssertEqual(p.x, 5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 5, accuracy: 1e-9)
        XCTAssertEqual(scale.inverted.then(scale), .identity)
        // Seen from inside the scaled parent the child is a plain offset.
        let inside = child.relative(to: scale)
        XCTAssertTrue(inside.isTranslation)
        XCTAssertEqual(inside.tx, 5, accuracy: 1e-9)
        XCTAssertEqual(inside.ty, 5, accuracy: 1e-9)
        let rotated = WireframeAffine(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        XCTAssertEqual(rotated.boundingBox(width: 10, height: 4), WireframeRect(x: -4, y: 0, width: 4, height: 10))
        // A transform that flattens everything cannot be undone.
        let flat = WireframeAffine(a: 1, b: 1, c: 1, d: 1, tx: 3, ty: 4)
        XCTAssertTrue(flat.isDegenerate)
        XCTAssertEqual(flat.inverted, .identity)
        XCTAssertTrue(WireframeAffine(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0).isDegenerate)
    }
}

final class WireframeRectTests: XCTestCase {
    func testCloseBoxesAreWithinHalfAPoint() {
        let a = WireframeRect(x: 20, y: 165.7, width: 125.3, height: 34.3)
        XCTAssertTrue(a.isClose(to: WireframeRect(x: 20.4, y: 165.3, width: 125.6, height: 34.3)))
        XCTAssertFalse(a.isClose(to: WireframeRect(x: 21, y: 165.7, width: 125.3, height: 34.3)))
    }

    func testRectsOverlapIntersectAndContainPoints() {
        let a = WireframeRect(x: 0, y: 0, width: 10, height: 10)
        let b = WireframeRect(x: 5, y: 5, width: 10, height: 10)
        XCTAssertTrue(a.overlaps(b))
        XCTAssertEqual(a.intersection(b), WireframeRect(x: 5, y: 5, width: 5, height: 5))
        // Touching edges do not overlap, and the intersection is empty.
        let beside = WireframeRect(x: 10, y: 0, width: 5, height: 5)
        XCTAssertFalse(a.overlaps(beside))
        XCTAssertTrue(a.intersection(beside).isEmpty)
        XCTAssertTrue(a.intersection(WireframeRect(x: 50, y: 50, width: 1, height: 1)).isEmpty)
        XCTAssertEqual(a.maxX, 10)
        XCTAssertEqual(b.maxY, 15)
        XCTAssertTrue(a.contains(x: 10, y: 0), "edges are inside")
        XCTAssertFalse(a.contains(x: 10.1, y: 5))
        XCTAssertTrue(WireframeRect(x: 0, y: 0, width: 0, height: 4).isEmpty)
        XCTAssertTrue(WireframeRect(x: 0, y: 0, width: .nan, height: 4).isEmpty)
        XCTAssertFalse(a.isEmpty)
    }
}
