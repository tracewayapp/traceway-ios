#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import Traceway

/// The wireframe of real UIKit views: what each kind of view becomes, where
/// it is, what is masked, and that frames replay in rrweb as the screen
/// changes. Runs on the iOS Simulator (see project.yml).
final class UIKitWireframeTests: XCTestCase {
    private var window: UIWindow!
    private var capture: WireframeCapture!
    private var clock: Int64 = 1_800_000_000_000

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow()
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .light
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 5)
        window.isHidden = false
        capture = WireframeCapture()
    }

    override func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        UIView.setAnimationsEnabled(true)
        super.tearDown()
    }

    // MARK: - Harness

    /// A controller whose view holds `views` at the frames they have.
    private func show(_ views: UIView..., background: UIColor = .white) {
        let controller = UIViewController()
        controller.view.backgroundColor = background
        for view in views { controller.view.addSubview(view) }
        window.rootViewController = controller
        settle()
    }

    private func settle() {
        window.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
    }

    private func frame(keyboard: CGRect? = nil) throws -> WireframeFrame {
        settle()
        clock += 250
        return try XCTUnwrap(capture.capture(windows: [window], timestampMs: clock, href: "/test", keyboardFrame: keyboard))
    }

    private func screen() throws -> VNode {
        try XCTUnwrap(try frame().screen)
    }

    private func node(_ text: String, in screen: VNode, file: StaticString = #filePath, line: UInt = #line) throws -> VNode {
        try XCTUnwrap(element(withText: text, in: screen), "no node shows \"\(text)\"", file: file, line: line)
    }

    private func label(_ text: String, _ frame: CGRect, size: CGFloat = 17) -> UILabel {
        let label = UILabel(frame: frame)
        label.text = text
        label.font = .systemFont(ofSize: size)
        label.textColor = .black
        return label
    }

    // MARK: - Boxes and text

    func testBoxesCornersBordersShadowsAndPositions() throws {
        let card = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 120))
        card.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 2
        card.layer.borderColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.5
        card.layer.shadowRadius = 4
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.addSubview(label("Hello card", CGRect(x: 10, y: 20, width: 180, height: 24)))
        show(card)
        let s = try screen()

        let text = try node("Hello card", in: s)
        let position = try XCTUnwrap(screenPosition(s, text))
        XCTAssertEqual(position.x, 30, accuracy: 0.11)
        XCTAssertEqual(position.y, 120, accuracy: 0.11)
        XCTAssertTrue(classes(text).contains("t"))
        XCTAssertEqual(styleMap(text)["font-size"], "17px")
        XCTAssertEqual(styleMap(text)["color"], "#000000")

        let box = try XCTUnwrap(ancestry(s, text)?.dropLast().last, "the card holds its label")
        let style = styleMap(box)
        XCTAssertEqual(style["background-color"], "#ff0000")
        XCTAssertEqual(style["border-radius"], "12px")
        XCTAssertEqual(style["width"], "200px")
        XCTAssertEqual(style["height"], "120px")
        let shadow = try XCTUnwrap(style["box-shadow"])
        XCTAssertTrue(shadow.hasPrefix("0px 2px 8px 0px rgba(0,0,0,0.502)"), shadow)
        XCTAssertTrue(shadow.contains("inset 0 0 0 2px #0000ff"), shadow)
    }

    func testLayoutOnlyViewsFoldIntoTheirChildren() throws {
        let group = UIView(frame: CGRect(x: 40, y: 50, width: 300, height: 300))
        let inner = UIView(frame: CGRect(x: 10, y: 10, width: 200, height: 200))
        inner.addSubview(label("Deep", CGRect(x: 5, y: 6, width: 100, height: 20)))
        group.addSubview(inner)
        show(group)
        let s = try screen()
        let text = try node("Deep", in: s)
        let position = try XCTUnwrap(screenPosition(s, text))
        XCTAssertEqual(position.x, 55, accuracy: 0.11)
        XCTAssertEqual(position.y, 66, accuracy: 0.11)
        // Window, root view, then the label: the two plain views paint nothing.
        let chain = try XCTUnwrap(ancestry(s, text))
        XCTAssertLessThanOrEqual(chain.count, 4, chain.map { $0.attributes["style"] ?? "" }.joined(separator: " | "))
    }

    func testWhatIsNotPaintedIsLeftOut() throws {
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

    func testOpacityClipsAndTransforms() throws {
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
        show(faded, clip, rotated)
        let s = try screen()
        let nodes = allNodes(s)
        XCTAssertTrue(nodes.contains { styleMap($0)["opacity"] == "0.5" })
        XCTAssertTrue(nodes.contains { styleMap($0)["overflow"] == "hidden" && styleMap($0)["border-radius"] == "25px" })
        let matrix = try XCTUnwrap(nodes.first { styleMap($0)["transform"]?.hasPrefix("matrix(") == true })
        XCTAssertTrue(styleMap(matrix)["transform"]!.hasPrefix("matrix(0,1,-1,0,"), styleMap(matrix)["transform"]!)
    }

    func testLabelsKeepLinesAlignmentFontsAndCutLines() throws {
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
        show(single, centered, bold, cut, wrapped, mono)
        let s = try screen()
        XCTAssertEqual(classes(try node("One line", in: s)), ["t", "n"])
        XCTAssertEqual(styleMap(try node("Centered", in: s))["justify-content"], "center")
        // iOS draws the bold system font semibold: 600, or 700.
        XCTAssertGreaterThanOrEqual(Int(styleMap(try node("Bold", in: s))["font-weight"] ?? "") ?? 0, 600)
        XCTAssertEqual(classes(try node("This line is much too long for a box this narrow", in: s)), ["t", "n", "e"])
        XCTAssertEqual(classes(try node("Wrapped text over lines", in: s)), ["t"])
        XCTAssertNotNil(styleMap(try node("code()", in: s))["font-family"])
    }

    func testRichTextBecomesSpans() throws {
        let rich = UILabel(frame: CGRect(x: 10, y: 10, width: 350, height: 24))
        let text = NSMutableAttributedString(string: "Plain ", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        text.append(NSAttributedString(string: "red", attributes: [.font: UIFont.systemFont(ofSize: 17),
                                                                   .foregroundColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1)]))
        text.append(NSAttributedString(string: " underlined", attributes: [.font: UIFont.systemFont(ofSize: 17),
                                                                           .underlineStyle: NSUnderlineStyle.single.rawValue]))
        rich.attributedText = text
        show(rich)
        let s = try screen()
        let red = try node("red", in: s)
        XCTAssertEqual(red.tag, "span")
        XCTAssertEqual(styleMap(red)["color"], "#ff0000")
        XCTAssertEqual(styleMap(try node(" underlined", in: s))["text-decoration"], "underline")
        XCTAssertEqual(allTexts(s).filter { ["Plain ", "red", " underlined"].contains($0) }.count, 3)
    }

    // MARK: - Fields

    func testFieldsMaskTypedTextShowPlaceholdersAndBulletSecrets() throws {
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

    func testPrivacyMasksBlankAndBlur() throws {
        let blank = UIView(frame: CGRect(x: 10, y: 10, width: 300, height: 40))
        blank.tracewayPrivacyMask = .blank(color: .red)
        blank.addSubview(label("4242 4242", CGRect(x: 0, y: 0, width: 200, height: 20)))
        let blur = UIView(frame: CGRect(x: 10, y: 60, width: 300, height: 40))
        blur.tracewayPrivacyMask = .blur
        blur.addSubview(label("Balance 99", CGRect(x: 0, y: 0, width: 200, height: 20)))
        let icon = UIImageView(image: UIImage(systemName: "star.fill"))
        icon.frame = CGRect(x: 220, y: 0, width: 24, height: 24)
        blur.addSubview(icon)
        show(blank, blur)
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertFalse(texts.contains { $0.contains("4242") })
        XCTAssertTrue(texts.contains("******* **"))
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#ff0000" && $0.children.isEmpty })
        // An image under a blur mask is a placeholder, not its shape.
        XCTAssertFalse(allNodes(s).contains { classes($0).contains("ic") })
        XCTAssertTrue(allNodes(s).contains { classes($0).contains("im") })
    }

    // MARK: - Images

    func testImagesArePlaceholdersAndSymbolsAreTheirShape() throws {
        let picture = UIImageView(image: UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        })
        picture.frame = CGRect(x: 10, y: 10, width: 100, height: 100)
        picture.addSubview(label("Over the picture", CGRect(x: 4, y: 4, width: 90, height: 20), size: 11))
        let symbol = UIImageView(image: UIImage(systemName: "star.fill"))
        symbol.frame = CGRect(x: 130, y: 10, width: 30, height: 30)
        symbol.tintColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        symbol.contentMode = .scaleAspectFit
        show(picture, symbol)
        let s = try screen()
        let placeholder = try XCTUnwrap(allNodes(s).first { classes($0).contains("im") })
        XCTAssertTrue(allTexts(placeholder).contains("Over the picture"), "an image view's subviews are kept")
        let icon = try XCTUnwrap(allNodes(s).first { classes($0).contains("ic") })
        XCTAssertEqual(styleMap(icon)["color"], "#ff0000")
        let glyph = try XCTUnwrap(classes(icon).first { $0.hasPrefix("g") }, "a symbol is drawn as a mask of its shape")
        let rule = try XCTUnwrap(allNodes(s).first { $0.tag == "style" }?.attributes["_cssText"])
        XCTAssertTrue(rule.hasPrefix(".ic.\(glyph)::before{"), rule)
        XCTAssertTrue(rule.contains("mask:url(data:image/png;base64,"))
        XCTAssertLessThan(rule.count, 4000, "a glyph stays small")
    }

    // MARK: - Controls

    func testSwitchSliderProgressSpinnerAndPages() throws {
        let on = UISwitch()
        on.isOn = true
        on.frame.origin = CGPoint(x: 10, y: 10)
        let off = UISwitch()
        off.frame.origin = CGPoint(x: 100, y: 10)
        let slider = UISlider(frame: CGRect(x: 10, y: 60, width: 300, height: 30))
        slider.value = 0.25
        let progress = UIProgressView(frame: CGRect(x: 10, y: 110, width: 300, height: 4))
        progress.progress = 0.4
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.frame = CGRect(x: 10, y: 130, width: 20, height: 20)
        spinner.startAnimating()
        let pages = UIPageControl(frame: CGRect(x: 10, y: 160, width: 300, height: 30))
        pages.numberOfPages = 4
        pages.currentPage = 2
        show(on, off, slider, progress, spinner, pages)
        let s = try screen()
        let nodes = allNodes(s)
        // Switches: a green track when on, a gray one when off.
        XCTAssertTrue(nodes.contains { styleMap($0)["background-color"] == "#34c759" })
        XCTAssertTrue(nodes.contains { styleMap($0)["background-color"] == "rgba(120,120,128,0.161)"
                || styleMap($0)["background-color"] == "rgba(120,120,128,.16)" })
        // The progress bar fills 40%.
        XCTAssertTrue(nodes.contains { styleMap($0)["width"] == "40%" })
        // A ring for the spinner, four dots for the pages.
        XCTAssertTrue(nodes.contains { styleMap($0)["border"]?.contains("dotted") == true })
        XCTAssertEqual(nodes.filter { styleMap($0)["border-radius"] == "50%" && styleMap($0)["width"] == "7px" }.count, 4)
        // The slider's filled part is a quarter of its track.
        let track = slider.trackRect(forBounds: slider.bounds)
        let filled = nodes.compactMap { styleNumber($0, "width") }.filter { abs($0 - Double(track.width) * 0.25) < 12 }
        XCTAssertFalse(filled.isEmpty)
    }

    func testSegmentedControlShowsItsTitlesAndSelection() throws {
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

    func testStepperShowsMinusAndPlus() throws {
        let stepper = UIStepper()
        stepper.frame.origin = CGPoint(x: 10, y: 10)
        stepper.value = 0
        show(stepper)
        let s = try screen()
        XCTAssertNotNil(element(withText: "\u{2212}", in: s))
        XCTAssertNotNil(element(withText: "+", in: s))
        XCTAssertFalse(allNodes(s).contains { classes($0).contains("im") })
    }

    func testButtonsShowTheirTitleAndBackground() throws {
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
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#008000" },
                      "the filled button paints its background")
    }

    // MARK: - Scrolling, lists and navigation

    func testScrollingMovesOneContentNode() throws {
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

    func testTableCellsShowAndReplayAsTheyScroll() throws {
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
        let recorder = WireframeRecorder(maxFrames: 50, fps: 4, now: { [unowned self] in self.clock })
        let first = try frame()
        XCTAssertNotNil(element(withText: "Row 0", in: try XCTUnwrap(first.screen)))
        recorder.push(first)
        var last = first
        for y in stride(from: 400, through: 2000, by: 400) {
            table.contentOffset = CGPoint(x: 0, y: CGFloat(y))
            last = try frame()
            recorder.push(last)
        }
        let clip = try XCTUnwrap(recorder.captureRecording(clipId: "b", sinceMs: nil, untilMs: clock + 1))
        let mirror = replay(clip.events)
        XCTAssertEqual(mirror.screen.dump(), dump(try XCTUnwrap(last.screen)), "the replay ends on the last screen")
        let shown = mirror.screen.texts()
        XCTAssertFalse(shown.contains("Row 0"))
        XCTAssertTrue(shown.contains { $0.hasPrefix("Row 4") }, "\(shown)")
        withExtendedLifetime(source) {}
    }

    func testPushingAControllerReplaysCleanly() throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.title = "Home"
        root.view.addSubview(label("First page", CGRect(x: 20, y: 200, width: 300, height: 24)))
        let nav = UINavigationController(rootViewController: root)
        window.rootViewController = nav
        let recorder = WireframeRecorder(maxFrames: 50, fps: 4, now: { [unowned self] in self.clock })
        recorder.push(try frame())
        let detail = UIViewController()
        detail.view.backgroundColor = .white
        detail.title = "Detail"
        detail.view.addSubview(label("Second page", CGRect(x: 20, y: 200, width: 300, height: 24)))
        nav.pushViewController(detail, animated: false)
        recorder.push(try frame())
        nav.popViewController(animated: false)
        let last = try frame()
        recorder.push(last)
        let clip = try XCTUnwrap(recorder.captureRecording(clipId: "nav", sinceMs: nil, untilMs: clock + 1))
        let mirror = replay(clip.events)
        XCTAssertEqual(mirror.screen.dump(), dump(try XCTUnwrap(last.screen)), "the replay ends on the last screen")
        XCTAssertTrue(mirror.screen.texts().contains("First page"))
        XCTAssertFalse(mirror.screen.texts().contains("Second page"))
        XCTAssertTrue(mirror.screen.texts().contains("Home"), "the navigation bar's title: \(mirror.screen.texts())")
    }

    func testAnAlertShowsOverThePage() throws {
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.view.addSubview(label("Under", CGRect(x: 20, y: 100, width: 300, height: 24)))
        window.rootViewController = root
        settle()
        let alert = UIAlertController(title: "Sign out?", message: "You can sign in again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sign out", style: .destructive))
        root.present(alert, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let s = try screen()
        let texts = allTexts(s)
        for expected in ["Under", "Sign out?", "You can sign in again.", "Sign out"] {
            XCTAssertTrue(texts.contains(expected), "\(expected) in \(texts)")
        }
        let under = try XCTUnwrap(texts.firstIndex(of: "Under"))
        let title = try XCTUnwrap(texts.firstIndex(of: "Sign out?"))
        XCTAssertLessThan(under, title, "the alert paints after the page")
        alert.dismiss(animated: false)
    }

    // MARK: - Frames

    func testUnchangedScreensShareTheirNodesAndAChangeIsOneText() throws {
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

    func testTheKeyboardIsANeutralBox() throws {
        show(label("Above the keyboard", CGRect(x: 10, y: 10, width: 300, height: 24)))
        let s = try XCTUnwrap(try frame(keyboard: CGRect(x: 0, y: 544, width: 390, height: 300)).screen)
        let keyboard = try XCTUnwrap(allNodes(s).first { $0.id == keyboardNodeId })
        XCTAssertEqual(allTexts(keyboard), ["Keyboard"])
    }

    func testManyAndDeepViewsStayBounded() throws {
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

    func testDarkModeResolvesDynamicColors() throws {
        window.overrideUserInterfaceStyle = .dark
        let text = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        text.text = "Dark"
        text.textColor = .label
        show(text, background: .systemBackground)
        let s = try screen()
        XCTAssertEqual(styleMap(try node("Dark", in: s))["color"], "#ffffff")
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#000000" })
    }

    func testNativeViewsAndCustomDrawingArePlaceholders() throws {
        final class Drawn: UIView {
            override func draw(_ rect: CGRect) {
                UIColor.red.setFill()
                UIRectFill(rect)
            }
        }
        let drawn = Drawn(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        show(drawn)
        let s = try screen()
        XCTAssertTrue(allNodes(s).contains { classes($0).contains("cp") })
    }

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

    // MARK: - SwiftUI

    func testSwiftUIShowsItsTextAndShapes() throws {
        struct Screen: View {
            var body: some View {
                VStack(spacing: 20) {
                    Text("Hello SwiftUI")
                    Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 120, height: 60)
                    Button("Tap here") {}
                }
            }
        }
        let host = UIHostingController(rootView: Screen())
        window.rootViewController = host
        settle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertTrue(allNodes(s).contains { styleMap($0)["background-color"] == "#ff0000" }, "the red rectangle")
        if host.view.accessibilityElementCount() > 0 || !(host.view.accessibilityElements?.isEmpty ?? true) {
            // An assistive technology runs: SwiftUI describes its text.
            XCTAssertTrue(texts.contains("Hello SwiftUI"), "SwiftUI text, read from accessibility: \(texts)")
            XCTAssertTrue(texts.contains("Tap here"), "\(texts)")
        } else {
            // Its words are not readable: each text is a bar where it is drawn.
            let bars = allNodes(s).filter { classes($0).contains("sk") }
            XCTAssertEqual(bars.count, 2, "one bar per text: \(bars.map { $0.attributes["style"] ?? "" })")
            XCTAssertFalse(texts.contains("Hello SwiftUI"))
        }
    }
}
#endif
