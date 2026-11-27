#if canImport(UIKit)
import AVFoundation
import UIKit
import WebKit
import XCTest
@testable import Traceway

/// The wireframe of real UIKit views, one test per topic of CONTRACT §10 in
/// the same order as Android's `ViewWireframeTest` (topics 1 to 40; the
/// SwiftUI ones, 41 to 48, are in `SwiftUIWireframeTests`): what each kind
/// of view becomes, where it is against its native frame, what is masked,
/// and that frames replay in rrweb as the screen changes. Runs on the iOS
/// Simulator (see project.yml).
final class UIKitWireframeTests: WireframeViewTestCase {
    // MARK: - 1-10 Boxes, geometry and text

    func test01BoxesCornersBordersShadowsAndTheirPositions() throws {
        let card = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 120))
        card.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 2
        card.layer.borderColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 4
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        let title = label("Hello card", CGRect(x: 10, y: 20, width: 180, height: 24))
        card.addSubview(title)
        let corners = UIView(frame: CGRect(x: 240, y: 100, width: 120, height: 60))
        corners.backgroundColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1)
        corners.layer.cornerRadius = 10
        corners.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMaxYCorner]
        show(card, corners)
        let s = try screen()

        let text = try node("Hello card", in: s)
        assertPlaced(text, in: s, like: title)
        XCTAssertTrue(classes(text).contains("t"))
        XCTAssertEqual(styleMap(text)["font-size"], "17px")
        XCTAssertEqual(styleMap(text)["color"], "#000000")

        let box = try XCTUnwrap(ancestry(s, text)?.dropLast().last, "the card holds its label")
        assertPlaced(box, in: s, like: card)
        let style = styleMap(box)
        XCTAssertEqual(style["background-color"], "#ff0000")
        XCTAssertEqual(style["border-radius"], "12px")
        let shadow = try XCTUnwrap(style["box-shadow"])
        XCTAssertTrue(shadow.hasPrefix("0px 2px 8px 0px rgba(0,0,0,0.502)"), shadow)
        XCTAssertTrue(shadow.contains("inset 0 0 0 2px #0000ff"), shadow)

        let cornered = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#00ff00" })
        XCTAssertEqual(styleMap(cornered)["border-radius"], "10px 0px 10px 0px")
        assertPlaced(cornered, in: s, like: corners)
    }

    func test02LengthsArePointsWhateverTheScreenScale() throws {
        // A hairline at this screen's scale: a fraction of a point.
        let hairline = 1 / window.screen.scale
        let view = UIView(frame: CGRect(x: 10 + hairline, y: 20 + 2 * hairline, width: 100 + hairline, height: 40))
        view.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        view.layer.borderWidth = hairline
        view.layer.borderColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor
        show(view)
        let f = try frame()
        XCTAssertEqual(f.width, 390, "the screen is in points, not pixels")
        XCTAssertEqual(f.height, 844)
        let s = try XCTUnwrap(f.screen)
        XCTAssertEqual(styleMap(s)["width"], "390px")
        let node = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#ff0000" })
        // Lengths are rounded to a tenth of a point.
        assertPlaced(node, in: s, like: view, accuracy: 0.051)
        XCTAssertEqual(styleMap(node)["width"], WireframeCSS.px(Double(100 + hairline)))
        let border = WireframeCSS.px(Double(hairline))
        XCTAssertNotEqual(border, "0px")
        XCTAssertTrue(styleMap(node)["box-shadow"]?.contains("inset 0 0 0 \(border) #0000ff") == true,
                      styleMap(node)["box-shadow"] ?? "no border")
    }

    func test03LayoutOnlyContainersFoldIntoTheirChildren() throws {
        let group = UIView(frame: CGRect(x: 40, y: 50, width: 300, height: 300))
        let inner = UIView(frame: CGRect(x: 10, y: 10, width: 200, height: 200))
        let deep = label("Deep", CGRect(x: 5, y: 6, width: 100, height: 20))
        inner.addSubview(deep)
        group.addSubview(inner)
        show(group)
        let s = try screen()
        let text = try node("Deep", in: s)
        assertPlaced(text, in: s, like: deep)
        // Window, root view, then the label: the two plain views paint nothing.
        let chain = try XCTUnwrap(ancestry(s, text))
        XCTAssertLessThanOrEqual(chain.count, 4, chain.map { $0.attributes["style"] ?? "" }.joined(separator: " | "))
    }

    func test04WhatIsNotPaintedIsLeftOut() throws {
        let hidden = label("Hidden", CGRect(x: 10, y: 10, width: 100, height: 20))
        hidden.isHidden = true
        let transparent = label("Transparent", CGRect(x: 10, y: 40, width: 100, height: 20))
        transparent.alpha = 0
        let clipper = UIView(frame: CGRect(x: 10, y: 80, width: 100, height: 40))
        clipper.clipsToBounds = true
        clipper.addSubview(label("Outside", CGRect(x: 200, y: 0, width: 100, height: 20)))
        let offscreen = label("Offscreen", CGRect(x: 10, y: 2000, width: 100, height: 20))
        show(hidden, transparent, clipper, offscreen, label("Shown", CGRect(x: 10, y: 140, width: 100, height: 20)))
        let texts = allTexts(try screen())
        XCTAssertTrue(texts.contains("Shown"))
        for gone in ["Hidden", "Transparent", "Outside", "Offscreen"] {
            XCTAssertFalse(texts.contains(gone), gone)
        }
    }

    func test05OpacityClipsAndTransforms() throws {
        let faded = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 50))
        faded.backgroundColor = .green
        faded.alpha = 0.5
        let clip = UIView(frame: CGRect(x: 10, y: 80, width: 100, height: 50))
        clip.backgroundColor = .blue
        clip.clipsToBounds = true
        clip.layer.cornerRadius = 25
        let rotated = UIView(frame: CGRect(x: 150, y: 150, width: 100, height: 40))
        rotated.backgroundColor = .orange
        rotated.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let turned = UIView()
        turned.bounds = CGRect(x: 0, y: 0, width: 120, height: 40)
        turned.center = CGPoint(x: 200, y: 400)
        turned.transform = CGAffineTransform(rotationAngle: .pi / 6).scaledBy(x: 1.5, y: 1.5)
        let turnedText = label("Turned", turned.bounds)
        turned.addSubview(turnedText)
        show(faded, clip, rotated, turned)
        let s = try screen()
        let nodes = allNodes(s)
        XCTAssertTrue(nodes.contains { styleMap($0)["opacity"] == "0.5" })
        XCTAssertTrue(nodes.contains { styleMap($0)["overflow"] == "hidden" && styleMap($0)["border-radius"] == "25px" })
        let matrix = try XCTUnwrap(nodes.first { styleMap($0)["transform"]?.hasPrefix("matrix(") == true })
        XCTAssertTrue(styleMap(matrix)["transform"]!.hasPrefix("matrix(0,1,-1,0,"), styleMap(matrix)["transform"]!)
        // A turned and grown view covers what it covers on screen.
        assertPlaced(try node("Turned", in: s), in: s, like: turnedText, accuracy: 0.3)
    }

    func test06ZOrderFollowsZPositionThenOrder() throws {
        let front = label("Front", CGRect(x: 10, y: 10, width: 100, height: 30))
        front.layer.zPosition = 1
        let middle = label("Middle", CGRect(x: 20, y: 20, width: 100, height: 30))
        let back = label("Back", CGRect(x: 30, y: 30, width: 100, height: 30))
        back.layer.zPosition = -1
        let last = label("Last", CGRect(x: 40, y: 40, width: 100, height: 30))
        show(front, middle, back, last)
        let names = ["Front", "Middle", "Back", "Last"]
        let recorder = self.recorder()
        let first = try frame()
        recorder.push(first)
        XCTAssertEqual(allTexts(try XCTUnwrap(first.screen)).filter(names.contains), ["Back", "Middle", "Last", "Front"])
        middle.superview?.bringSubviewToFront(middle)
        front.layer.zPosition = 0
        let second = try frame()
        recorder.push(second)
        XCTAssertEqual(allTexts(try XCTUnwrap(second.screen)).filter(names.contains), ["Back", "Front", "Last", "Middle"])
        try replayEnds(recorder, on: second)
    }

    func test07ALabelKeepsItsBackground() throws {
        let badge = label("Badge", CGRect(x: 10, y: 10, width: 100, height: 22))
        badge.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        show(badge)
        let node = try node("Badge", in: try screen())
        XCTAssertEqual(styleMap(node)["background-color"], "rgba(0,0,0,0.502)")
    }

    func test08LabelsKeepLinesAlignmentFontsAndTruncation() throws {
        let single = label("One line", CGRect(x: 10, y: 10, width: 300, height: 22))
        let centered = label("Centered", CGRect(x: 10, y: 40, width: 300, height: 22))
        centered.textAlignment = .center
        let bold = label("Bold", CGRect(x: 10, y: 70, width: 300, height: 22))
        bold.font = .boldSystemFont(ofSize: 17)
        let cut = label("This line is much too long for a box this narrow", CGRect(x: 10, y: 100, width: 80, height: 22))
        let wrapped = label("Wrapped text over lines", CGRect(x: 10, y: 130, width: 80, height: 66))
        wrapped.numberOfLines = 0
        let mono = label("code()", CGRect(x: 10, y: 200, width: 200, height: 22))
        mono.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        let italic = label("Slanted", CGRect(x: 10, y: 230, width: 200, height: 22))
        italic.font = .italicSystemFont(ofSize: 15)
        show(single, centered, bold, cut, wrapped, mono, italic)
        let s = try screen()
        XCTAssertEqual(classes(try node("One line", in: s)), ["t", "n"])
        XCTAssertEqual(styleMap(try node("Centered", in: s))["justify-content"], "center")
        // iOS draws the bold system font semibold: 600, or 700.
        XCTAssertGreaterThanOrEqual(Int(styleMap(try node("Bold", in: s))["font-weight"] ?? "") ?? 0, 600)
        XCTAssertEqual(classes(try node("This line is much too long for a box this narrow", in: s)), ["t", "n", "e"])
        XCTAssertEqual(classes(try node("Wrapped text over lines", in: s)), ["t"])
        XCTAssertNotNil(styleMap(try node("code()", in: s))["font-family"])
        XCTAssertEqual(styleMap(try node("Slanted", in: s))["font-style"], "italic")
        assertPlaced(try node("Wrapped text over lines", in: s), in: s, like: wrapped)
    }

    func test09RichTextBecomesSpans() throws {
        let rich = UILabel(frame: CGRect(x: 10, y: 10, width: 370, height: 24))
        let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]
        let text = NSMutableAttributedString(string: "Plain ", attributes: font)
        func add(_ part: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: part, attributes: font.merging(attributes) { _, new in new }))
        }
        add("red", [.foregroundColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1)])
        add(" underlined", [.underlineStyle: NSUnderlineStyle.single.rawValue])
        add(" struck", [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        add(" marked", [.backgroundColor: UIColor(red: 1, green: 1, blue: 0, alpha: 1)])
        add(" big", [.font: UIFont.systemFont(ofSize: 24)])
        rich.attributedText = text
        // One run in its own style: the style is the label's, on its own box.
        let uniform = UILabel(frame: CGRect(x: 10, y: 50, width: 370, height: 24))
        uniform.attributedText = NSAttributedString(string: "All purple", attributes: [
            .font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor(red: 0.5, green: 0, blue: 1, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        show(rich, uniform)
        let s = try screen()
        let red = try node("red", in: s)
        XCTAssertEqual(red.tag, "span")
        XCTAssertEqual(styleMap(red)["color"], "#ff0000")
        XCTAssertEqual(styleMap(try node(" underlined", in: s))["text-decoration"], "underline")
        XCTAssertEqual(styleMap(try node(" struck", in: s))["text-decoration"], "line-through")
        XCTAssertEqual(styleMap(try node(" marked", in: s))["background-color"], "#ffff00")
        XCTAssertEqual(styleMap(try node(" big", in: s))["font-size"], "24px")
        XCTAssertEqual(allTexts(s).filter { ["Plain ", "red", " underlined", " struck", " marked", " big"].contains($0) }.count, 6)
        let purple = try node("All purple", in: s)
        XCTAssertEqual(purple.tag, "div")
        XCTAssertEqual(styleMap(purple)["color"], "#8000ff")
        XCTAssertEqual(styleMap(purple)["text-decoration"], "underline")
        assertPlaced(purple, in: s, like: uniform)
    }

    func test10RightToLeftTextAndLayoutDirection() throws {
        let container = UIView(frame: CGRect(x: 0, y: 100, width: 390, height: 200))
        container.semanticContentAttribute = .forceRightToLeft
        let natural = UILabel(frame: CGRect(x: 0, y: 0, width: 390, height: 30))
        natural.text = "שלום עולם"
        natural.textAlignment = .natural
        natural.semanticContentAttribute = .forceRightToLeft
        let first = label("First", .zero), second = label("Second", .zero)
        let stack = UIStackView(arrangedSubviews: [first, second])
        stack.semanticContentAttribute = .forceRightToLeft
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.frame = CGRect(x: 0, y: 60, width: 390, height: 30)
        let left = label("Left in a mirrored layout", CGRect(x: 0, y: 100, width: 390, height: 30))
        left.textAlignment = .left
        left.semanticContentAttribute = .forceRightToLeft
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.semanticContentAttribute = .forceRightToLeft
        toggle.frame.origin = CGPoint(x: 10, y: 140)
        for view in [natural, stack, left, toggle] { container.addSubview(view) }
        show(container)
        let s = try screen()
        let text = try node("שלום עולם", in: s)
        XCTAssertEqual(styleMap(text)["direction"], "rtl")
        // Right to left a line starts at the right edge: natural alignment
        // is its start, left alignment its end.
        XCTAssertNil(styleMap(text)["justify-content"], "natural alignment is the right edge")
        XCTAssertEqual(styleMap(try node("Left in a mirrored layout", in: s))["justify-content"], "flex-end")
        // A mirrored switch that is on has its knob on the left.
        let knob = try XCTUnwrap(allNodes(s).first { styleMap($0)["box-shadow"] == "0 2px 6px rgba(0,0,0,.2)" })
        XCTAssertLessThan(styleNumber(knob, "left") ?? 99, 5)
        // A mirrored stack puts its first view on the right; so does the replay.
        XCTAssertGreaterThan(nativeFrame(first).minX, nativeFrame(second).minX)
        assertPlaced(try node("First", in: s), in: s, like: first)
        assertPlaced(try node("Second", in: s), in: s, like: second)
    }

    // MARK: - 11-14 Fields and privacy

    func test11FieldsMaskTypedTextShowPlaceholdersAndBulletSecrets() throws {
        let empty = UITextField(frame: CGRect(x: 10, y: 10, width: 300, height: 34))
        empty.placeholder = "Email address"
        empty.borderStyle = .roundedRect
        let typed = UITextField(frame: CGRect(x: 10, y: 60, width: 300, height: 34))
        typed.text = "jane doe"
        let secure = UITextField(frame: CGRect(x: 10, y: 110, width: 300, height: 34))
        secure.isSecureTextEntry = true
        secure.text = "hunter2"
        let notes = UITextView(frame: CGRect(x: 10, y: 160, width: 300, height: 60))
        notes.text = "private notes"
        let terms = UITextView(frame: CGRect(x: 10, y: 230, width: 300, height: 60))
        terms.text = "public terms"
        terms.isEditable = false
        show(empty, typed, secure, notes, terms)

        var texts = allTexts(try screen())
        XCTAssertTrue(texts.contains("Email address"))
        XCTAssertTrue(texts.contains("**** ***"), "\(texts)")
        XCTAssertTrue(texts.contains(String(repeating: "\u{2022}", count: 7)))
        XCTAssertTrue(texts.contains("******* *****"))
        XCTAssertTrue(texts.contains("public terms"))
        for secret in ["jane doe", "hunter2", "private notes"] {
            XCTAssertFalse(texts.contains(secret), secret)
        }

        capture.maskAllInputs = false
        texts = allTexts(try screen())
        XCTAssertTrue(texts.contains("jane doe"))
        XCTAssertTrue(texts.contains("private notes"))
        XCTAssertFalse(texts.contains("hunter2"), "a secure field is never shown")
    }

    func test12FieldDecorationsSideViewsAndBorderStyles() throws {
        func field(_ y: CGFloat, _ style: UITextField.BorderStyle, _ placeholder: String) -> UITextField {
            let field = UITextField(frame: CGRect(x: 10, y: y, width: 300, height: 34))
            field.borderStyle = style
            field.placeholder = placeholder
            return field
        }
        let rounded = field(10, .roundedRect, "Rounded")
        let line = field(60, .line, "Line")
        let bezel = field(110, .bezel, "Bezel")
        let plain = field(160, .none, "Plain")
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        rounded.leftView = icon
        rounded.leftViewMode = .always
        let unit = label("kg", CGRect(x: 0, y: 0, width: 24, height: 20))
        plain.rightView = unit
        plain.rightViewMode = .always
        show(rounded, line, bezel, plain)
        let s = try screen()
        func box(_ placeholder: String) throws -> [String: String] {
            styleMap(try XCTUnwrap(ancestry(s, try node(placeholder, in: s))?.dropLast().last))
        }
        XCTAssertEqual(try box("Rounded")["border-radius"], "5px")
        XCTAssertTrue(try box("Rounded")["box-shadow"]?.hasPrefix("inset 0 0 0 .5px") == true)
        XCTAssertEqual(try box("Line")["box-shadow"], "inset 0 0 0 1px #000000")
        XCTAssertEqual(try box("Bezel")["box-shadow"], "inset 0 0 0 1px rgba(128,128,128,.7)")
        XCTAssertNil(try box("Plain")["box-shadow"])
        // Placeholders in the placeholder color, the text after the left view.
        XCTAssertTrue(styleMap(try node("Rounded", in: s))["color"]?.hasPrefix("rgba(60,60,67,") == true)
        let glyph = try XCTUnwrap(allNodes(s).first { classes($0).contains("ic") }, "the left view's symbol")
        XCTAssertEqual(styleMap(glyph)["color"], "#ff0000")
        assertPlaced(glyph, in: s, like: icon)
        let placeholder = try XCTUnwrap(screenBox(s, try node("Rounded", in: s)))
        XCTAssertGreaterThanOrEqual(Double(placeholder.minX), Double(nativeFrame(icon).maxX) - 0.5)
        assertPlaced(try node("kg", in: s), in: s, like: unit)
    }

    func test13MasksBlankAndBlur() throws {
        capture.imagePolicy = .always
        let blank = UIView(frame: CGRect(x: 10, y: 10, width: 300, height: 40))
        blank.tracewayMask = .blank(color: .red)
        blank.addSubview(label("4242 4242", CGRect(x: 0, y: 0, width: 200, height: 20)))
        let blur = UIView(frame: CGRect(x: 10, y: 60, width: 300, height: 40))
        blur.tracewayMask = .blur
        blur.addSubview(label("Balance 99", CGRect(x: 0, y: 0, width: 200, height: 20)))
        let icon = UIImageView(image: UIImage(systemName: "star.fill"))
        icon.frame = CGRect(x: 220, y: 0, width: 24, height: 24)
        blur.addSubview(icon)
        let blurredPhoto = UIView(frame: CGRect(x: 10, y: 120, width: 200, height: 120))
        blurredPhoto.tracewayMask = .blur
        blurredPhoto.addSubview(imageView(photo(CGSize(width: 40, height: 30)), CGRect(x: 0, y: 0, width: 200, height: 120)))
        let blankedPhoto = UIView(frame: CGRect(x: 10, y: 260, width: 200, height: 120))
        blankedPhoto.tracewayMask = .blank()
        blankedPhoto.addSubview(imageView(photo(CGSize(width: 40, height: 30), .red), CGRect(x: 0, y: 0, width: 200, height: 120)))
        show(blank, blur, blurredPhoto, blankedPhoto)
        _ = try screen()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertFalse(texts.contains { $0.contains("4242") })
        XCTAssertTrue(texts.contains("******* **"))
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#ff0000" && $0.children.isEmpty })
        // An image under a blur mask is a placeholder, not its shape or its picture.
        XCTAssertFalse(allNodes(s).contains { classes($0).contains("ic") })
        XCTAssertTrue(allNodes(s).contains { classes($0) == ["im"] })
        XCTAssertTrue(capture.images.all.isEmpty, "a masked picture is never encoded")
        XCTAssertTrue(pictureRules(s).isEmpty)
    }

    func test13IdentifierMarkersMaskLikeTheModes() throws {
        let blurred = UIView(frame: CGRect(x: 10, y: 10, width: 300, height: 40))
        blurred.accessibilityIdentifier = "traceway-mask"
        let account = label("Account 1234", CGRect(x: 0, y: 0, width: 200, height: 20))
        blurred.addSubview(account)
        let blanked = UIView(frame: CGRect(x: 10, y: 60, width: 300, height: 40))
        blanked.accessibilityIdentifier = "traceway-blank"
        blanked.addSubview(label("PIN 9876", CGRect(x: 0, y: 0, width: 200, height: 20)))
        let named = UIView(frame: CGRect(x: 10, y: 110, width: 300, height: 40))
        named.accessibilityIdentifier = "checkout"
        named.addSubview(label("Plain 5555", CGRect(x: 0, y: 0, width: 200, height: 20)))
        show(blurred, blanked, named)
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertFalse(texts.contains { $0.contains("1234") || $0.contains("9876") }, "\(texts)")
        assertPlaced(try node("******* ****", in: s), in: s, like: account)
        let box = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#000000" && $0.children.isEmpty },
                                "the blank marker's box")
        assertPlaced(box, in: s, like: blanked)
        XCTAssertTrue(texts.contains("Plain 5555"), "another identifier masks nothing")
    }

    @available(*, deprecated)
    func test13TheOldMaskNameStillMasks() throws {
        let card = UIView(frame: CGRect(x: 10, y: 10, width: 300, height: 40))
        card.tracewayPrivacyMask = .blur
        XCTAssertNotNil(card.tracewayMask)
        card.addSubview(label("Old 4321", CGRect(x: 0, y: 0, width: 200, height: 20)))
        show(card)
        let texts = allTexts(try screen())
        XCTAssertFalse(texts.contains { $0.contains("4321") })
        XCTAssertTrue(texts.contains("*** ****"), "\(texts)")
    }

    func test14AMaskedSubtreeHidesItsTextButKeepsItsShape() throws {
        let card = UIView(frame: CGRect(x: 20, y: 40, width: 300, height: 100))
        card.backgroundColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        card.layer.cornerRadius = 12
        card.tracewayMask = .blur
        let name = label("Jane Appleseed", CGRect(x: 16, y: 16, width: 200, height: 24))
        let chip = UIView(frame: CGRect(x: 16, y: 56, width: 120, height: 30))
        chip.backgroundColor = UIColor(red: 0, green: 1, blue: 0, alpha: 1)
        let tag = label("VIP", CGRect(x: 8, y: 4, width: 60, height: 22))
        chip.addSubview(tag)
        card.addSubview(name)
        card.addSubview(chip)
        show(card)
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertFalse(texts.contains("Jane Appleseed"))
        XCTAssertFalse(texts.contains("VIP"))
        let masked = try node("**** *********", in: s)
        assertPlaced(masked, in: s, like: name)
        XCTAssertEqual(styleMap(masked)["font-size"], "17px")
        assertPlaced(try node("***", in: s), in: s, like: tag)
        let box = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#0000ff" })
        XCTAssertEqual(styleMap(box)["border-radius"], "12px")
        assertPlaced(box, in: s, like: card)
        let inner = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#00ff00" })
        assertPlaced(inner, in: s, like: chip)
    }

    // MARK: - 15-18 Images

    /// A bitmap of `size` points in one color; opaque unless `clear`, which
    /// leaves the corners see-through.
    private func photo(_ size: CGSize, _ color: UIColor = .blue, clear: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = !clear
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            if clear {
                UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            } else {
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
    }

    private func imageView(_ image: UIImage, _ frame: CGRect, mode: UIView.ContentMode = .scaleAspectFill) -> UIImageView {
        let view = UIImageView(image: image)
        view.frame = frame
        view.contentMode = mode
        return view
    }

    /// Spins the main run loop until `count` pictures are encoded.
    private func waitForPictures(_ count: Int = 1) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, capture.images.all.filter({ $0.css != nil }).count < count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func pictureRules(_ s: VNode) -> [String] {
        allNodes(s).compactMap { $0.tag == "style" ? $0.attributes["_cssText"] : nil }.filter { $0.hasPrefix(".im.p") }
    }

    func test15ImagesArePlaceholdersWhenOffAndSymbolsAreTheirShape() throws {
        capture.imagePolicy = .off
        let picture = imageView(photo(CGSize(width: 20, height: 20)), CGRect(x: 10, y: 10, width: 100, height: 100))
        picture.addSubview(label("Over the picture", CGRect(x: 4, y: 4, width: 90, height: 20), size: 11))
        let symbol = UIImageView(image: UIImage(systemName: "star.fill"))
        symbol.frame = CGRect(x: 130, y: 10, width: 30, height: 30)
        symbol.tintColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        symbol.contentMode = .scaleAspectFit
        let template = UIImageView(image: photo(CGSize(width: 20, height: 20), clear: true).withRenderingMode(.alwaysTemplate))
        template.frame = CGRect(x: 180, y: 10, width: 30, height: 30)
        template.tintColor = UIColor(red: 0, green: 0.5, blue: 0, alpha: 1)
        show(picture, symbol, template)
        _ = try screen()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let s = try screen()
        XCTAssertTrue(capture.images.all.isEmpty, "nothing is encoded while pictures are off")
        let placeholder = try XCTUnwrap(allNodes(s).first { classes($0).contains("im") })
        XCTAssertEqual(classes(placeholder), ["im"])
        XCTAssertTrue(allTexts(placeholder).contains("Over the picture"), "an image view's subviews are kept")
        assertPlaced(placeholder, in: s, like: picture)
        let icon = try XCTUnwrap(allNodes(s).first { classes($0).contains("ic") && styleMap($0)["color"] == "#ff0000" })
        let glyph = try XCTUnwrap(classes(icon).first { $0.hasPrefix("g") }, "a symbol is drawn as a mask of its shape")
        let rule = try XCTUnwrap(allNodes(s).first { $0.tag == "style" && $0.attributes["_cssText"]?.hasPrefix(".ic.\(glyph)::before{") == true }?
            .attributes["_cssText"])
        XCTAssertTrue(rule.contains("mask:url(data:image/png;base64,"))
        XCTAssertLessThan(rule.count, 4000, "a glyph stays small")
        XCTAssertTrue(allNodes(s).contains { classes($0).contains("ic") && styleMap($0)["color"] == "#008000" },
                      "a template image is its shape in its tint")
    }

    func test16PhotosAreInlinedWhenThePolicyIsAlways() throws {
        let view = imageView(photo(CGSize(width: 40, height: 30)), CGRect(x: 10, y: 10, width: 200, height: 150), mode: .scaleAspectFit)
        show(view)
        capture.imagePolicy = .always
        capture.isUnmetered = { false }
        let first = try screen()
        XCTAssertEqual(classes(try XCTUnwrap(allNodes(first).first { classes($0).contains("im") })), ["im"],
                       "the first frame shows the placeholder")
        waitForPictures()
        let s = try screen()
        let node = try XCTUnwrap(allNodes(s).first { classes($0).contains("im") })
        let cls = try XCTUnwrap(classes(node).first { $0.hasPrefix("p") }, "a later frame shows the picture")
        XCTAssertEqual(styleMap(node)["background-size"], "contain")
        assertPlaced(node, in: s, like: view)
        let rules = pictureRules(s)
        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertTrue(rule.hasPrefix(".im.\(cls){background:url(data:image/jpeg;base64,"), rule)
        XCTAssertTrue(rule.hasSuffix(") center/cover no-repeat}"), rule)
        XCTAssertLessThan(rule.count, WireframeImageEncoding.maxEncodedBytes * 4 / 3 + 100)
    }

    func test17WifiOnAMeteredNetworkGivesPlaceholders() throws {
        show(imageView(photo(CGSize(width: 40, height: 30)), CGRect(x: 10, y: 10, width: 200, height: 150)))
        capture.imagePolicy = .wifi
        capture.isUnmetered = { false }
        _ = try screen()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var s = try screen()
        XCTAssertTrue(capture.images.all.isEmpty, "nothing is encoded on a metered network")
        XCTAssertTrue(pictureRules(s).isEmpty)
        XCTAssertEqual(classes(try XCTUnwrap(allNodes(s).first { classes($0).contains("im") })), ["im"])
        // On Wi-Fi the picture comes; off it again, the next frame drops it.
        capture.isUnmetered = { true }
        _ = try screen()
        waitForPictures()
        s = try screen()
        XCTAssertEqual(pictureRules(s).count, 1)
        capture.isUnmetered = { false }
        s = try screen()
        XCTAssertTrue(pictureRules(s).isEmpty)
        XCTAssertEqual(classes(try XCTUnwrap(allNodes(s).first { classes($0).contains("im") })), ["im"])
    }

    func test18PicturesAreSharedAcrossViewsAndHeldToTheSessionAllowance() throws {
        let shared = photo(CGSize(width: 40, height: 30))
        let badge = photo(CGSize(width: 24, height: 24), .green, clear: true)
        show(
            imageView(shared, CGRect(x: 10, y: 10, width: 120, height: 90)),
            imageView(shared, CGRect(x: 10, y: 120, width: 120, height: 90)),
            imageView(badge, CGRect(x: 200, y: 10, width: 24, height: 24), mode: .center)
        )
        let budget = CollectionBudget()
        budget.use("session-1")
        capture.images.budget = budget
        capture.imagePolicy = .always
        _ = try screen()
        waitForPictures(2)
        let s = try screen()
        XCTAssertEqual(capture.images.all.count, 2, "one picture per bitmap and size")
        let pictured = allNodes(s).filter { classes($0).contains("im") }
        XCTAssertEqual(pictured.count, 3)
        let shownClasses = pictured.map { classes($0).subtracting(["im"]) }
        XCTAssertEqual(shownClasses[0], shownClasses[1])
        XCTAssertNotEqual(shownClasses[0], shownClasses[2])
        let rules = pictureRules(s)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.filter { $0.contains("data:image/png;base64,") }.count, 1)
        XCTAssertEqual(styleMap(pictured[2])["background-size"], "24px 24px")
        XCTAssertGreaterThan(budget.snapshot("session-1")["traceway.replay.image_bytes"] ?? 0, 0, "the bytes count for the session")

        // A session whose allowance is used up gets placeholders.
        capture = WireframeCapture()
        let spent = CollectionBudget(maxImageBytes: 10)
        spent.use("session-2")
        capture.images.budget = spent
        capture.imagePolicy = .always
        _ = try screen()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let over = try screen()
        XCTAssertTrue(pictureRules(over).isEmpty, "past the allowance pictures stay placeholders")
        XCTAssertTrue(allNodes(over).filter { classes($0).contains("im") }.allSatisfy { classes($0) == ["im"] })
        XCTAssertEqual(spent.snapshot("session-2")["traceway.replay.image_bytes"], 0)
    }

    // MARK: - 19-24 Controls

    func test19TogglesAreDrawnFromTheirState() throws {
        let on = UISwitch()
        on.isOn = true
        on.frame.origin = CGPoint(x: 10, y: 10)
        let off = UISwitch()
        off.frame.origin = CGPoint(x: 100, y: 10)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Bold"
        let toggle = UIButton(configuration: configuration)
        toggle.changesSelectionAsPrimaryAction = true
        toggle.frame = CGRect(x: 10, y: 60, width: 120, height: 40)
        show(on, off, toggle)
        var s = try screen()
        let nodes = allNodes(s)
        XCTAssertTrue(nodes.contains { styleMap($0)["background-color"] == "#34c759" }, "a green track when on")
        XCTAssertTrue(nodes.contains { styleMap($0)["background-color"]?.hasPrefix("rgba(120,120,128,") == true },
                      "a gray one when off")
        // The knob is at the end of the track when on, at its start when off.
        let knobs = nodes.filter { styleMap($0)["box-shadow"] == "0 2px 6px rgba(0,0,0,.2)" }
        XCTAssertEqual(knobs.count, 2)
        let lefts = knobs.compactMap { styleNumber($0, "left") }
        XCTAssertEqual(lefts.count, 2)
        if lefts.count == 2 { XCTAssertGreaterThan(lefts[0], lefts[1] + 10) }
        XCTAssertNotNil(element(withText: "Bold", in: s))
        let fills = Set(nodes.compactMap { styleMap($0)["background-color"] })
        toggle.isSelected = true
        s = try screen()
        XCTAssertNotEqual(Set(allNodes(s).compactMap { styleMap($0)["background-color"] }), fills,
                          "a selected toggle button looks selected")
    }

    func test20SlidersProgressAndSpinners() throws {
        let slider = UISlider(frame: CGRect(x: 10, y: 60, width: 300, height: 30))
        slider.value = 0.25
        let progress = UIProgressView(frame: CGRect(x: 10, y: 110, width: 300, height: 4))
        progress.progress = 0.4
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.frame = CGRect(x: 10, y: 130, width: 20, height: 20)
        spinner.startAnimating()
        show(slider, progress, spinner)
        let s = try screen()
        let nodes = allNodes(s)
        // The slider's filled part is a quarter of its track.
        let track = slider.trackRect(forBounds: slider.bounds)
        let filled = nodes.compactMap { styleNumber($0, "width") }.filter { abs($0 - Double(track.width) * 0.25) < 12 }
        XCTAssertFalse(filled.isEmpty)
        XCTAssertTrue(nodes.contains { styleMap($0)["box-shadow"]?.hasPrefix("0 .5px 4px") == true }, "the thumb")
        // The progress bar fills 40% of its track.
        let bar = try XCTUnwrap(nodes.first { styleMap($0)["width"] == "40%" })
        let barTrack = try XCTUnwrap(nodes.first { $0.children.contains { $0 === bar } })
        assertPlaced(barTrack, in: s, like: progress)
        // A spinner is a dotted ring.
        let ring = try XCTUnwrap(nodes.first { styleMap($0)["border"]?.contains("dotted") == true })
        let ringHolder = try XCTUnwrap(nodes.first { $0.children.contains { $0 === ring } })
        assertPlaced(ringHolder, in: s, like: spinner)
    }

    func test21SegmentedControlsShowTheirTitlesAndSelection() throws {
        let control = UISegmentedControl(items: ["Day", "Week", "Month"])
        control.frame = CGRect(x: 10, y: 10, width: 300, height: 32)
        control.selectedSegmentIndex = 1
        show(control)
        var s = try screen()
        for title in ["Day", "Week", "Month"] { XCTAssertNotNil(element(withText: title, in: s), title) }
        let week = try node("Week", in: s)
        XCTAssertEqual(styleNumber(week, "left") ?? -1, 100, accuracy: 0.6)
        XCTAssertFalse(allNodes(s).contains { classes($0).contains("im") }, "no image placeholders in a segmented control")
        let knob = try XCTUnwrap(allNodes(s).first { styleMap($0)["box-shadow"]?.hasPrefix("0 3px 8px") == true })
        XCTAssertEqual(styleNumber(knob, "left") ?? -1, 102, accuracy: 0.6)

        control.selectedSegmentIndex = 2
        s = try screen()
        let moved = try XCTUnwrap(allNodes(s).first { styleMap($0)["box-shadow"]?.hasPrefix("0 3px 8px") == true })
        XCTAssertEqual(styleNumber(moved, "left") ?? -1, 202, accuracy: 0.6)
    }

    func test22SteppersShowMinusAndPlus() throws {
        let stepper = UIStepper()
        stepper.frame.origin = CGPoint(x: 10, y: 10)
        stepper.value = 0
        show(stepper)
        let s = try screen()
        let minus = try node("\u{2212}", in: s), plus = try node("+", in: s)
        // At its minimum the minus is faded.
        XCTAssertTrue(styleMap(minus)["color"]?.hasPrefix("rgba(0,0,0,") == true, styleMap(minus)["color"] ?? "")
        XCTAssertEqual(styleMap(plus)["color"], "#000000")
        XCTAssertFalse(allNodes(s).contains { classes($0).contains("im") })
        let holder = try XCTUnwrap(ancestry(s, minus)?.dropLast().last)
        assertPlaced(holder, in: s, like: stepper)
    }

    func test23PageDotsShowTheCurrentPage() throws {
        let pages = UIPageControl(frame: CGRect(x: 10, y: 160, width: 300, height: 30))
        pages.numberOfPages = 4
        pages.currentPage = 2
        show(pages)
        let s = try screen()
        let dots = allNodes(s).filter { styleMap($0)["border-radius"] == "50%" && styleMap($0)["width"] == "7px" }
            .sorted { (styleNumber($0, "left") ?? 0) < (styleNumber($1, "left") ?? 0) }
        XCTAssertEqual(dots.count, 4)
        let colors = dots.map { styleMap($0)["background-color"] ?? "" }
        XCTAssertEqual(colors.filter { $0 == "#000000" }.count, 1)
        XCTAssertEqual(colors.firstIndex(of: "#000000"), 2, "\(colors)")
    }

    func test24ButtonsShowTheirTitleAndBackground() throws {
        let system = UIButton(type: .system)
        system.setTitle("Continue", for: .normal)
        system.frame = CGRect(x: 10, y: 10, width: 200, height: 44)
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Pay now"
        configuration.baseBackgroundColor = UIColor(red: 0, green: 0.5, blue: 0, alpha: 1)
        let filled = UIButton(configuration: configuration)
        filled.frame = CGRect(x: 10, y: 70, width: 200, height: 44)
        show(system, filled)
        let s = try screen()
        XCTAssertNotNil(element(withText: "Continue", in: s))
        XCTAssertNotNil(element(withText: "Pay now", in: s))
        let fill = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#008000" },
                                 "the filled button paints its background")
        let box = try XCTUnwrap(screenBox(s, fill))
        XCTAssertTrue(nativeFrame(filled).insetBy(dx: -1, dy: -1).contains(box), "\(box) in \(nativeFrame(filled))")
    }

    // MARK: - 25-30 Scrolling, lists, navigation and tabs

    func test25ScrollingMovesOneContentNode() throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        scroll.contentSize = CGSize(width: 390, height: 3000)
        for i in 0..<60 {
            scroll.addSubview(label("Item \(i)", CGRect(x: 20, y: CGFloat(i) * 50, width: 200, height: 24)))
        }
        show(scroll)
        let before = try screen()
        scroll.contentOffset = CGPoint(x: 0, y: 500)
        let after = try screen()
        let mutation = try XCTUnwrap(diffScreens(before, after))
        let attributes = try XCTUnwrap(mutation["attributes"]?.array)
        // Rows that scrolled out leave and new ones come in; the rows that
        // stay are not touched.
        XCTAssertEqual(attributes.count, 1, "only the content node moves: \(mutation.encoded())")
        XCTAssertEqual(attributes.first?["attributes"]?["style"]?.string?.hasPrefix("left:0px;top:-500px"), true)
        XCTAssertTrue(mutation["texts"]?.array?.isEmpty ?? false)
        XCTAssertTrue(allTexts(after).contains("Item 11"))
        XCTAssertFalse(allTexts(after).contains("Item 0"))
    }

    func test26ListsReplayAsTheyScroll() throws {
        final class Source: NSObject, UITableViewDataSource {
            func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 100 }
            func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
                let cell = tableView.dequeueReusableCell(withIdentifier: "c") ?? UITableViewCell(style: .default, reuseIdentifier: "c")
                cell.textLabel?.text = "Row \(indexPath.row)"
                return cell
            }
        }
        let source = Source()
        let table = UITableView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), style: .plain)
        table.dataSource = source
        show(table)
        let recorder = self.recorder()
        let first = try frame()
        let s = try XCTUnwrap(first.screen)
        let row = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0))?.textLabel)
        assertPlaced(try node("Row 0", in: s), in: s, like: row)
        recorder.push(first)
        var last = first
        for y in stride(from: 400, through: 2000, by: 400) {
            table.contentOffset = CGPoint(x: 0, y: CGFloat(y))
            last = try frame()
            recorder.push(last)
        }
        let mirror = try replayEnds(recorder, on: last)
        let shown = mirror.screen.texts()
        XCTAssertFalse(shown.contains("Row 0"))
        XCTAssertTrue(shown.contains { $0.hasPrefix("Row 4") }, "\(shown)")
        withExtendedLifetime(source) {}
    }

    func test27GridsReplayAsTheyScroll() throws {
        final class Source: NSObject, UICollectionViewDataSource {
            func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 90 }
            func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath)
                cell.contentView.backgroundColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
                let title = (cell.contentView.viewWithTag(7) as? UILabel) ?? {
                    let title = UILabel(frame: cell.contentView.bounds)
                    title.tag = 7
                    title.textColor = .white
                    title.textAlignment = .center
                    title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    cell.contentView.addSubview(title)
                    return title
                }()
                title.text = "Tile \(indexPath.item)"
                return cell
            }
        }
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 120, height: 100)
        layout.minimumInteritemSpacing = 5
        layout.minimumLineSpacing = 5
        let grid = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), collectionViewLayout: layout)
        grid.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "c")
        let source = Source()
        grid.dataSource = source
        show(grid)
        let recorder = self.recorder()
        let first = try frame()
        let s = try XCTUnwrap(first.screen)
        // Three columns, each tile where its cell is.
        for item in 0..<3 {
            let cell = try XCTUnwrap(grid.cellForItem(at: IndexPath(item: item, section: 0)))
            assertPlaced(try node("Tile \(item)", in: s), in: s, like: try XCTUnwrap(cell.contentView.viewWithTag(7)))
        }
        recorder.push(first)
        var last = first
        for y in stride(from: 300, through: 1500, by: 300) {
            grid.contentOffset = CGPoint(x: 0, y: CGFloat(y))
            last = try frame()
            recorder.push(last)
        }
        let mirror = try replayEnds(recorder, on: last)
        XCTAssertTrue(mirror.screen.texts().contains("Tile 45"), "\(mirror.screen.texts())")
        XCTAssertFalse(mirror.screen.texts().contains("Tile 0"))
        withExtendedLifetime(source) {}
    }

    func test28AHorizontalListInsideAVerticalScroll() throws {
        let outer = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        outer.contentSize = CGSize(width: 390, height: 2000)
        let strip = UIScrollView(frame: CGRect(x: 0, y: 100, width: 390, height: 100))
        strip.contentSize = CGSize(width: 1600, height: 100)
        for i in 0..<12 {
            strip.addSubview(label("Card \(i)", CGRect(x: CGFloat(i) * 130 + 10, y: 30, width: 110, height: 40)))
        }
        outer.addSubview(strip)
        for i in 0..<30 {
            outer.addSubview(label("Line \(i)", CGRect(x: 20, y: 220 + CGFloat(i) * 50, width: 200, height: 24)))
        }
        show(outer)
        let recorder = self.recorder()
        let f0 = try frame()
        recorder.push(f0)
        strip.contentOffset = CGPoint(x: 400, y: 0)
        let f1 = try frame()
        recorder.push(f1)
        let sideways = try XCTUnwrap(diffScreens(try XCTUnwrap(f0.screen), try XCTUnwrap(f1.screen)))
        let moved = try XCTUnwrap(sideways["attributes"]?.array)
        XCTAssertEqual(moved.count, 1, "only the strip's content node moves: \(sideways.encoded())")
        XCTAssertEqual(moved.first?["attributes"]?["style"]?.string?.hasPrefix("left:-400px;top:0px"), true)
        outer.contentOffset = CGPoint(x: 0, y: 50)
        let f2 = try frame()
        recorder.push(f2)
        let down = try XCTUnwrap(diffScreens(try XCTUnwrap(f1.screen), try XCTUnwrap(f2.screen)))
        let scrolled = try XCTUnwrap(down["attributes"]?.array)
        XCTAssertEqual(scrolled.count, 1, "only the page's content node moves: \(down.encoded())")
        XCTAssertEqual(scrolled.first?["attributes"]?["style"]?.string?.hasPrefix("left:0px;top:-50px"), true)
        let mirror = try replayEnds(recorder, on: f2)
        XCTAssertTrue(mirror.screen.texts().contains("Card 4"))
        XCTAssertFalse(mirror.screen.texts().contains("Card 0"))
    }

    func test29PushingAndPoppingAScreenReplaysCleanly() throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.title = "Home"
        root.view.addSubview(label("First page", CGRect(x: 20, y: 200, width: 300, height: 24)))
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        let recorder = self.recorder()
        recorder.push(try frame())
        let detail = UIViewController()
        detail.view.backgroundColor = .white
        detail.title = "Detail"
        detail.view.addSubview(label("Second page", CGRect(x: 20, y: 200, width: 300, height: 24)))
        nav.pushViewController(detail, animated: false)
        let pushed = try frame()
        recorder.push(pushed)
        XCTAssertTrue(allTexts(try XCTUnwrap(pushed.screen)).contains("Second page"))
        nav.popViewController(animated: false)
        let last = try frame()
        recorder.push(last)
        let mirror = try replayEnds(recorder, on: last)
        XCTAssertTrue(mirror.screen.texts().contains("First page"))
        XCTAssertFalse(mirror.screen.texts().contains("Second page"))
        XCTAssertTrue(mirror.screen.texts().contains("Home"), "the navigation bar's title: \(mirror.screen.texts())")
    }

    func test30TabsReplayAsTheyAreSwitched() throws {
        func page(_ title: String, _ text: String) -> UIViewController {
            let controller = UIViewController()
            controller.view.backgroundColor = .white
            controller.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: "circle"), tag: 0)
            controller.view.addSubview(label(text, CGRect(x: 20, y: 200, width: 300, height: 24)))
            return controller
        }
        let tabs = UITabBarController()
        tabs.viewControllers = [page("Feed", "Feed page"), page("Inbox", "Inbox page")]
        show(tabs)
        let recorder = self.recorder()
        let first = try frame()
        recorder.push(first)
        let texts = allTexts(try XCTUnwrap(first.screen))
        XCTAssertTrue(texts.contains("Feed page"))
        XCTAssertTrue(texts.contains("Feed") && texts.contains("Inbox"), "the tab bar's titles: \(texts)")
        tabs.selectedIndex = 1
        let second = try frame()
        recorder.push(second)
        let mirror = try replayEnds(recorder, on: second)
        XCTAssertTrue(mirror.screen.texts().contains("Inbox page"))
        XCTAssertFalse(mirror.screen.texts().contains("Feed page"))
    }

    // MARK: - 31-34 Dialogs, sheets, popovers and the keyboard

    func test31ADialogShowsOverThePageWithItsDim() throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.view.addSubview(label("Under", CGRect(x: 20, y: 100, width: 300, height: 24)))
        show(root)
        let alert = UIAlertController(title: "Sign out?", message: "You can sign in again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sign out", style: .destructive))
        root.present(alert, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let s = try screen()
        let texts = allTexts(s)
        for expected in ["Under", "Sign out?", "You can sign in again.", "Sign out"] {
            XCTAssertTrue(texts.contains(expected), "\(expected) in \(texts)")
        }
        let nodes = allNodes(s)
        let under = try XCTUnwrap(nodes.firstIndex { $0.isText && $0.text == "Under" })
        let title = try XCTUnwrap(nodes.firstIndex { $0.isText && $0.text == "Sign out?" })
        let dim = try XCTUnwrap(nodes.firstIndex {
            styleMap($0)["background-color"]?.hasPrefix("rgba(0,0,0,") == true && styleMap($0)["width"] == "390px"
        }, "the dim over the page")
        XCTAssertLessThan(under, dim, "the dim paints over the page")
        XCTAssertLessThan(dim, title, "the alert paints over the dim")
        alert.dismiss(animated: false)
    }

    func test32ASheetShowsOverThePage() throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.view.addSubview(label("Page under", CGRect(x: 20, y: 120, width: 300, height: 24)))
        show(root)
        let sheet = UIViewController()
        sheet.view.backgroundColor = UIColor(red: 0.8, green: 0.8, blue: 1, alpha: 1)
        let text = label("In the sheet", CGRect(x: 20, y: 30, width: 300, height: 24))
        sheet.view.addSubview(text)
        sheet.sheetPresentationController?.detents = [.medium()]
        root.present(sheet, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: "Page under")), try XCTUnwrap(texts.firstIndex(of: "In the sheet")),
                          "the sheet paints over the page")
        // At its medium detent the sheet holds the lower half, where its text is.
        XCTAssertGreaterThan(nativeFrame(text).minY, window.bounds.height * 0.35)
        assertPlaced(try node("In the sheet", in: s), in: s, like: text, accuracy: 1)
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#ccccff" }, "the sheet's own color")
        sheet.dismiss(animated: false)
    }

    func test33APopoverSitsOverItsAnchor() throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        let anchor = UIButton(type: .system)
        anchor.setTitle("Options", for: .normal)
        anchor.frame = CGRect(x: 120, y: 200, width: 150, height: 44)
        root.view.addSubview(anchor)
        root.view.addSubview(label("Page text", CGRect(x: 20, y: 120, width: 300, height: 24)))
        show(root)
        let menu = UIViewController()
        menu.view.backgroundColor = .white
        menu.preferredContentSize = CGSize(width: 200, height: 120)
        let item = label("Rename", CGRect(x: 16, y: 16, width: 160, height: 24))
        menu.view.addSubview(item)
        menu.modalPresentationStyle = .popover
        let delegate = NoAdaptation()
        let popover = try XCTUnwrap(menu.popoverPresentationController)
        popover.sourceView = anchor
        popover.sourceRect = anchor.bounds
        popover.permittedArrowDirections = .up
        popover.delegate = delegate
        root.present(menu, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: "Page text")), try XCTUnwrap(texts.firstIndex(of: "Rename")),
                          "the popover paints over the page")
        let box = try XCTUnwrap(screenBox(s, try node("Rename", in: s)))
        XCTAssertGreaterThanOrEqual(Double(box.minY), Double(nativeFrame(anchor).maxY) - 1, "under its anchor, the arrow up")
        assertPlaced(try node("Rename", in: s), in: s, like: item, accuracy: 1)
        menu.dismiss(animated: false)
        withExtendedLifetime(delegate) {}
    }

    func test34TheKeyboardIsANeutralBox() throws {
        show(label("Above the keyboard", CGRect(x: 10, y: 10, width: 300, height: 24)))
        let keys = CGRect(x: 0, y: 544, width: 390, height: 300)
        let s = try XCTUnwrap(try frame(keyboard: window.convert(keys, to: window.screen.coordinateSpace)).screen)
        let keyboard = try XCTUnwrap(allNodes(s).first { $0.id == keyboardNodeId })
        XCTAssertEqual(allTexts(keyboard), ["Keyboard"])
        XCTAssertEqual(keyboard.children.first?.id, keyboardLabelTextId)
        XCTAssertEqual(styleNumber(keyboard, "top"), 544)
        XCTAssertEqual(styleNumber(keyboard, "height"), 300)
        XCTAssertEqual(styleMap(keyboard)["background-color"], "#d1d3d9")
    }

    // MARK: - 35-40 Frames, limits, appearance and edits

    func test35UnchangedScreensShareTheirNodesAndAChangeIsOneText() throws {
        let status = label("Loading", CGRect(x: 10, y: 10, width: 200, height: 24))
        show(status, label("Static", CGRect(x: 10, y: 40, width: 200, height: 24)))
        let first = try screen()
        let second = try screen()
        XCTAssertNil(diffScreens(first, second))
        XCTAssertTrue(first === second, "an unchanged screen is the previous frame's object")
        status.text = "Done"
        let third = try screen()
        let mutation = try XCTUnwrap(diffScreens(second, third))
        XCTAssertEqual(mutation["texts"]?.array?.count, 1)
        XCTAssertEqual(mutation["texts"]?.array?.first?["value"]?.string, "Done")
        XCTAssertTrue(mutation["adds"]?.array?.isEmpty ?? false)
        XCTAssertTrue(mutation["removes"]?.array?.isEmpty ?? false)
    }

    func test36ManyAndDeepViewsStayBounded() throws {
        let many = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        for i in 0..<5000 {
            let dot = UIView(frame: CGRect(x: CGFloat(i % 50) * 7, y: CGFloat(i / 50) * 7, width: 5, height: 5))
            dot.backgroundColor = .red
            many.addSubview(dot)
        }
        var deep = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let top = deep
        for _ in 0..<400 {
            let next = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            next.backgroundColor = .blue
            deep.addSubview(next)
            deep = next
        }
        show(many, top)
        let s = try screen()
        XCTAssertLessThanOrEqual(allNodes(s).count, 3200)
    }

    func test37DarkModeResolvesDynamicColors() throws {
        window.overrideUserInterfaceStyle = .dark
        let text = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        text.text = "Dark"
        text.textColor = .label
        let card = UIView(frame: CGRect(x: 10, y: 50, width: 200, height: 60))
        card.backgroundColor = .secondarySystemBackground
        show(text, card, background: .systemBackground)
        var s = try screen()
        XCTAssertEqual(styleMap(try node("Dark", in: s))["color"], "#ffffff")
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#000000" })
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#1c1c1e" })
        window.overrideUserInterfaceStyle = .light
        s = try screen()
        XCTAssertEqual(styleMap(try node("Dark", in: s))["color"], "#000000", "the colors follow the appearance")
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#f2f2f7" })
    }

    func test38NativeViewsAndCustomDrawingArePlaceholders() throws {
        let drawn = Drawn(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        let web = WKWebView(frame: CGRect(x: 10, y: 130, width: 200, height: 100))
        let video = PlayerView(frame: CGRect(x: 10, y: 250, width: 200, height: 100))
        show(drawn, web, video)
        let s = try screen()
        XCTAssertTrue(allNodes(s).contains { classes($0).contains("cp") })
        let placeholders = allNodes(s).filter { classes($0).contains("pv") }
        XCTAssertEqual(Set(placeholders.flatMap(allTexts)), ["Web view", "Video"])
        assertPlaced(try node("Web view", in: s), in: s, like: web)
        assertPlaced(try node("Video", in: s), in: s, like: video)
    }

    func test39AViewThatCannotBeDrawnCostsItsOwnNodeNotTheFrame() throws {
        let collapsed = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        collapsed.backgroundColor = .red
        collapsed.addSubview(label("Collapsed", CGRect(x: 0, y: 0, width: 100, height: 20)))
        collapsed.transform = CGAffineTransform(scaleX: 0, y: 0)
        let squashed = UIView(frame: CGRect(x: 10, y: 60, width: 100, height: 40))
        squashed.backgroundColor = .red
        squashed.addSubview(label("Squashed", CGRect(x: 0, y: 0, width: 100, height: 20)))
        squashed.transform = CGAffineTransform(a: 1, b: 0, c: 0, d: 0, tx: 0, ty: 0)
        let empty = UIView(frame: CGRect(x: 10, y: 110, width: 0, height: 0))
        empty.clipsToBounds = true
        empty.addSubview(label("In nothing", CGRect(x: 0, y: 0, width: 100, height: 20)))
        let fine = label("Still here", CGRect(x: 10, y: 160, width: 200, height: 24))
        show(collapsed, squashed, empty, fine)
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertTrue(texts.contains("Still here"), "the frame goes on: \(texts)")
        assertPlaced(try node("Still here", in: s), in: s, like: fine)
        for gone in ["Collapsed", "Squashed", "In nothing"] { XCTAssertFalse(texts.contains(gone), gone) }
        XCTAssertFalse(allNodes(s).contains { styleMap($0)["background-color"] == "#ff0000" })
    }

    func test40ViewEditsReplayInTheMirror() throws {
        let title = label("Title", CGRect(x: 10, y: 10, width: 200, height: 24))
        let removable = label("Removable", CGRect(x: 10, y: 40, width: 200, height: 24))
        let hideable = label("Hideable", CGRect(x: 10, y: 70, width: 200, height: 24))
        let button = UIButton(type: .system)
        button.setTitle("Submit", for: .normal)
        button.frame = CGRect(x: 10, y: 100, width: 120, height: 44)
        let root = show(title, removable, hideable, button)
        let recorder = self.recorder()
        var frames = [try frame()]
        recorder.push(frames[0])
        func step(_ change: () -> Void) throws {
            change()
            let next = try frame()
            XCTAssertNotNil(diffScreens(try XCTUnwrap(frames.last?.screen), try XCTUnwrap(next.screen)), "each edit changes the screen")
            recorder.push(next)
            frames.append(next)
        }
        try step { root.view.addSubview(self.label("Added", CGRect(x: 10, y: 160, width: 200, height: 24))) }
        try step { removable.removeFromSuperview() }
        try step { hideable.isHidden = true }
        try step { button.isEnabled = false }
        try step { title.text = "Renamed" }
        let mirror = try replayEnds(recorder, on: try XCTUnwrap(frames.last))
        let texts = mirror.screen.texts()
        for shown in ["Added", "Renamed", "Submit"] { XCTAssertTrue(texts.contains(shown), shown) }
        for gone in ["Removable", "Hideable", "Title"] { XCTAssertFalse(texts.contains(gone), gone) }
    }

    // MARK: - iOS only

    func testAClippingFillTakesTheCornersOfTheViewItFills() throws {
        // iOS 26 rounds a configured button through its corner
        // configuration: the button's layer has the radius, the clipping
        // fill of the same size inside it has none of its own.
        let button = UIView(frame: CGRect(x: 20, y: 20, width: 120, height: 34))
        button.layer.cornerRadius = 17
        let fill = UIView(frame: button.bounds)
        fill.backgroundColor = UIColor(red: 0, green: 0.533, blue: 1, alpha: 1)
        fill.clipsToBounds = true
        button.addSubview(fill)
        show(button)
        let s = try screen()
        let node = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#0088ff" })
        XCTAssertEqual(styleMap(node)["border-radius"], "17px")
    }

    func testLayersThatCutOutPaintNothing() throws {
        // Liquid Glass punches holes with black layers composited destOut:
        // they hide what is under them and paint nothing themselves.
        let host = UIView(frame: CGRect(x: 10, y: 10, width: 200, height: 100))
        let hole = CALayer()
        hole.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        hole.backgroundColor = UIColor.black.cgColor
        hole.compositingFilter = "destOut"
        host.layer.addSublayer(hole)
        let painted = CALayer()
        painted.frame = CGRect(x: 100, y: 0, width: 100, height: 100)
        painted.backgroundColor = UIColor.blue.cgColor
        host.layer.addSublayer(painted)
        show(host)
        let s = try screen()
        XCTAssertFalse(allNodes(s).contains { styleMap($0)["background-color"] == "#000000" })
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#0000ff" })
    }
}

/// Draws itself in `draw(_:)`.
private final class Drawn: UIView {
    override func draw(_ rect: CGRect) {
        UIColor.red.setFill()
        UIRectFill(rect)
    }
}

/// Keeps a popover a popover in a compact width.
private final class NoAdaptation: NSObject, UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection)
        -> UIModalPresentationStyle { .none }
}

/// A view backed by a video player's layer.
private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}
#endif
