#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import Traceway

/// The wireframe of SwiftUI screens, topics 41 to 48 of CONTRACT §10 (the
/// declarative ones, mirrored by Android's `ComposeWireframeTest`).
///
/// SwiftUI draws most of its content into layers without views of their
/// own. Its words are readable only through the hosting view's
/// accessibility elements, which iOS fills in while an assistive technology
/// runs; otherwise each text is a neutral bar (`.sk`) where it is drawn.
/// The tests check both: the text when it is readable, else the bar in its
/// place. Runs on the iOS Simulator (see project.yml).
final class SwiftUIWireframeTests: WireframeViewTestCase {
    /// Shows `content` filling the window, laid out from its top left
    /// corner (no safe area), so positions are window points.
    @discardableResult
    private func host<Content: View>(_ content: Content) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(
            ZStack(alignment: .topLeading) {
                Color.white
                content
            }.ignoresSafeArea()
        ))
        show(host)
        settle(0.3)
        return host
    }

    private func readable(_ host: UIViewController) -> Bool {
        host.view.accessibilityElementCount() > 0 || !(host.view.accessibilityElements?.isEmpty ?? true)
    }

    /// The text or bar nodes whose box on screen holds `point`.
    private func texts(at point: CGPoint, in s: VNode) -> [VNode] {
        allNodes(s).filter { node in
            let cls = classes(node)
            guard cls.contains("t") || cls.contains("sk"), let box = screenBox(s, node) else { return false }
            return box.insetBy(dx: -1, dy: -1).contains(point)
        }
    }

    func test41TextHasItsStyleAndPlace() throws {
        let host = self.host(ZStack {
            Text("Big title").font(.system(size: 30, weight: .bold)).position(x: 150, y: 200)
            Text("Small print").font(.system(size: 12)).position(x: 150, y: 400)
        })
        let s = try screen()
        let big = try XCTUnwrap(texts(at: CGPoint(x: 150, y: 200), in: s).first, "a text or bar where the title is")
        let small = try XCTUnwrap(texts(at: CGPoint(x: 150, y: 400), in: s).first, "a text or bar where the print is")
        let bigBox = try XCTUnwrap(screenBox(s, big)), smallBox = try XCTUnwrap(screenBox(s, small))
        XCTAssertGreaterThan(bigBox.height, smallBox.height * 1.6, "the title is the larger text")
        XCTAssertGreaterThan(bigBox.width, smallBox.width)
        if readable(host) {
            XCTAssertEqual(allTexts(big), ["Big title"])
            XCTAssertEqual(allTexts(small), ["Small print"])
            XCTAssertGreaterThan(styleNumber(big, "font-size") ?? 0, styleNumber(small, "font-size") ?? 0)
        } else {
            XCTAssertTrue(classes(big).contains("sk"))
            XCTAssertFalse(allTexts(s).contains("Big title"), "unread text is never guessed")
        }
    }

    func test42ButtonsAndIcons() throws {
        let host = self.host(ZStack {
            Button("Tap here") {}.position(x: 120, y: 150)
            Image(systemName: "star.fill").font(.system(size: 30)).foregroundColor(Color(red: 1, green: 0, blue: 0))
                .position(x: 120, y: 260)
            Button(action: {}, label: { Image(systemName: "heart.fill").font(.system(size: 24)) }).position(x: 260, y: 260)
        })
        let s = try screen()
        XCTAssertFalse(texts(at: CGPoint(x: 120, y: 150), in: s).isEmpty, "the button's title, or its bar")
        if readable(host) { XCTAssertTrue(allTexts(s).contains("Tap here"), "\(allTexts(s))") }
        // A symbol is drawn as its shape, in its color, where it is.
        let star = try XCTUnwrap(allNodes(s).first { node in
            styleMap(node)["background-color"] == "#ff0000" || (classes(node).contains("ic") && styleMap(node)["color"] == "#ff0000")
        }, "the red star")
        let box = try XCTUnwrap(screenBox(s, star))
        XCTAssertTrue(box.insetBy(dx: -2, dy: -2).contains(CGPoint(x: 120, y: 260)), "\(box)")
        XCTAssertFalse(allNodes(s).contains { classes($0).contains("im") }, "a symbol is not a picture")
    }

    func test43FieldsMaskTypedTextAndSecrets() throws {
        struct Fields: View {
            @State var email = "jane@example.com"
            @State var password = "hunter2"
            @State var empty = ""

            var body: some View {
                VStack(spacing: 20) {
                    TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    TextField("Empty field", text: $empty).textFieldStyle(.roundedBorder)
                }
                .padding(40)
                .frame(width: 390)
                .padding(.top, 100)
            }
        }
        host(Fields())
        let texts = allTexts(try screen())
        for secret in ["jane@example.com", "hunter2"] {
            XCTAssertFalse(texts.contains { $0.contains(secret) }, "\(secret) in \(texts)")
        }
        XCTAssertTrue(texts.contains(WireframeCSS.mask("jane@example.com")), "typed text is masked: \(texts)")
        XCTAssertTrue(texts.contains(String(repeating: "\u{2022}", count: 7)), "a secure field shows bullets: \(texts)")
        XCTAssertTrue(texts.contains("Empty field"), "the placeholder: \(texts)")
    }

    func test44TogglesSlidersAndProgressAreDrawnFromTheirState() throws {
        host(VStack(spacing: 30) {
            Toggle("Wi-Fi", isOn: .constant(true)).frame(width: 300)
            Slider(value: .constant(0.25)).frame(width: 300)
            ProgressView(value: 0.4).frame(width: 300)
            ProgressView()
        }.padding(.top, 120).padding(.leading, 40))
        let nodes = allNodes(try screen())
        XCTAssertTrue(nodes.contains { styleMap($0)["background-color"] == "#34c759" }, "the toggle is on")
        XCTAssertTrue(nodes.contains { styleMap($0)["box-shadow"]?.hasPrefix("0 .5px 4px") == true }, "the slider's thumb")
        XCTAssertTrue(nodes.contains { styleMap($0)["width"] == "40%" }, "the progress bar fills 40%")
        XCTAssertTrue(nodes.contains { styleMap($0)["border"]?.contains("dotted") == true }, "the spinner")
    }

    func test45AListScrollsAndReplays() throws {
        let host = self.host(List(0..<80, id: \.self) { i in Text("Item \(i)") }.frame(width: 390, height: 844))
        let list = try XCTUnwrap(GalleryScenes.find(UIScrollView.self, in: host.view), "a List scrolls in a scroll view")
        let recorder = self.recorder()
        let first = try frame()
        recorder.push(first)
        list.contentOffset = CGPoint(x: 0, y: 600)
        settle(0.2)
        let second = try frame()
        recorder.push(second)
        let mutation = try XCTUnwrap(diffScreens(try XCTUnwrap(first.screen), try XCTUnwrap(second.screen)))
        let moved = (mutation["attributes"]?.array ?? []).compactMap { $0["attributes"]?["style"]?.string }
        XCTAssertTrue(moved.contains { $0.hasPrefix("left:0px;top:-600px") }, "the list's content node moves: \(moved)")
        let mirror = try replayEnds(recorder, on: second)
        if readable(host) {
            XCTAssertFalse(mirror.screen.texts().contains("Item 0"))
        }
    }

    func test46MasksHideWhatTheyCover() throws {
        let host = self.host(VStack(spacing: 30) {
            Text("Card 4242 4242").tracewayMask(.blank(color: UIColor(red: 1, green: 0, blue: 0, alpha: 1)))
            Text("Balance 99.50").tracewayMask()
            Rectangle().fill(Color(red: 0, green: 0, blue: 1)).frame(width: 100, height: 40)
                .tracewayMask(.blank(color: UIColor(red: 0, green: 1, blue: 0, alpha: 1)))
        }.padding(.top, 120).padding(.leading, 40))
        let s = try screen()
        let texts = allTexts(s)
        XCTAssertFalse(texts.contains { $0.contains("4242") || $0.contains("99.50") }, "\(texts)")
        let nodes = allNodes(s)
        var markers: [String] = []
        func walk(_ view: UIView, _ depth: Int) {
            if view is TracewayMaskMarkerView || depth < 3 {
                markers.append("\(String(repeating: " ", count: depth))\(NSStringFromClass(Swift.type(of: view))) "
                    + "\(view.convert(view.bounds, to: window)) hidden=\(view.isHidden) alpha=\(view.alpha) "
                    + "mask=\(view.tracewayMask.map { "\($0)" } ?? "-")")
            }
            view.subviews.forEach { walk($0, depth + 1) }
        }
        walk(host.view, 0)
        let fills = nodes.compactMap { styleMap($0)["background-color"] }
        let red = try XCTUnwrap(nodes.firstIndex { styleMap($0)["background-color"] == "#ff0000" },
                                "the blank mask's box; fills \(fills); views \(markers.joined(separator: " | "))")
        XCTAssertTrue(nodes[red].children.isEmpty)
        let green = try XCTUnwrap(nodes.firstIndex { styleMap($0)["background-color"] == "#00ff00" })
        if let blue = nodes.firstIndex(where: { styleMap($0)["background-color"] == "#0000ff" }) {
            XCTAssertLessThan(blue, green, "the mask paints over what it covers")
        }
        // Under a blank mask not even the bar of a text is left.
        let box = try XCTUnwrap(screenBox(s, nodes[red]))
        XCTAssertTrue(self.texts(at: CGPoint(x: box.midX, y: box.midY), in: s).isEmpty)
    }

    func test47AStateChangeReplays() throws {
        final class Model: ObservableObject {
            @Published var on = false
        }
        struct Screen: View {
            @ObservedObject var model: Model
            var body: some View {
                VStack(spacing: 20) {
                    Rectangle().fill(model.on ? Color(red: 0, green: 0, blue: 1) : Color(red: 1, green: 0, blue: 0))
                        .frame(width: 120, height: 60)
                    Text(model.on ? "Switched on" : "Switched off")
                }.padding(.top, 120).padding(.leading, 40)
            }
        }
        let model = Model()
        host(Screen(model: model))
        let recorder = self.recorder()
        let first = try frame()
        recorder.push(first)
        XCTAssertTrue(allNodes(try XCTUnwrap(first.screen)).contains { styleMap($0)["background-color"] == "#ff0000" })
        model.on = true
        settle(0.3)
        let second = try frame()
        recorder.push(second)
        let nodes = allNodes(try XCTUnwrap(second.screen))
        XCTAssertTrue(nodes.contains { styleMap($0)["background-color"] == "#0000ff" })
        XCTAssertFalse(nodes.contains { styleMap($0)["background-color"] == "#ff0000" })
        try replayEnds(recorder, on: second)
    }

    func test48SwiftUIInsideAUIKitHierarchyIsPlacedWithIt() throws {
        let container = UIView(frame: CGRect(x: 40, y: 300, width: 300, height: 200))
        container.backgroundColor = UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
        let swiftUI = UIHostingController(rootView: Rectangle().fill(Color(red: 1, green: 0, blue: 0)).ignoresSafeArea())
        swiftUI.view.frame = CGRect(x: 20, y: 30, width: 200, height: 100)
        container.addSubview(swiftUI.view)
        let root = show(container)
        root.addChild(swiftUI)
        swiftUI.didMove(toParent: root)
        settle(0.3)
        let s = try screen()
        let red = try XCTUnwrap(allNodes(s).first { styleMap($0)["background-color"] == "#ff0000" }, "the SwiftUI fill")
        let box = try XCTUnwrap(screenBox(s, red))
        XCTAssertEqual(Double(box.minX), 60, accuracy: 0.5)
        XCTAssertEqual(Double(box.minY), 330, accuracy: 0.5)
        XCTAssertEqual(Double(box.width), 200, accuracy: 0.5)
        XCTAssertEqual(Double(box.height), 100, accuracy: 0.5)
        let gray = try XCTUnwrap(allNodes(s).firstIndex { styleMap($0)["background-color"] == "#cccccc" })
        let fill = try XCTUnwrap(allNodes(s).firstIndex { $0 === red })
        XCTAssertLessThan(gray, fill, "the SwiftUI content is inside the UIKit view")
    }
}
#endif
