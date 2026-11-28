import Foundation
import XCTest
@testable import Traceway

/// A view of a fake hierarchy: what a selector reads of a UIView, without
/// UIKit.
final class FakeView {
    let type: String
    let ids: [String]
    let roles: Set<String>
    let values: [String: String]
    /// A label's text or a button's title.
    let ownText: String?
    /// A text field: its content is never read.
    let input: Bool
    let control: Bool
    let handler: Bool
    let content: Bool
    let masked: Bool
    let boundary: Bool
    /// Hidden or fully transparent: its text is not shown.
    let hidden: Bool
    /// Plumbing a tap handler sits in (a SwiftUI modifier wrapper).
    let primitive: Bool
    var children: [FakeView] = []
    /// Strong, so a test can hold only the leaf; the cycles only live as
    /// long as the test.
    var parent: FakeView?

    init(
        _ type: String,
        id: String? = nil,
        roles: Set<String> = [],
        values: [String: String] = [:],
        text: String? = nil,
        input: Bool = false,
        control: Bool = false,
        handler: Bool = false,
        content: Bool = false,
        masked: Bool = false,
        boundary: Bool = false,
        hidden: Bool = false,
        primitive: Bool = false
    ) {
        self.type = type
        var values = values
        if let id = id { values["identifier"] = id }
        ids = id.map { [$0] } ?? []
        self.roles = roles
        self.values = values
        ownText = text
        self.input = input
        self.control = control
        self.handler = handler
        self.content = content
        self.masked = masked
        self.boundary = boundary
        self.hidden = hidden
        self.primitive = primitive
    }

    @discardableResult
    func add(_ child: FakeView) -> FakeView {
        child.parent = self
        children.append(child)
        return child
    }

    /// Mirrors `shownText` of the UIKit path.
    func shownText(includeMasked: Bool) -> String? {
        if input { return nil }
        if let own = ownText.flatMap(cleanShownText) { return own }
        var parts: [String] = []
        func visit(_ view: FakeView) {
            if parts.count >= 3 || view.input || view.hidden { return }
            if !includeMasked && view.masked { return }
            if let own = view.ownText.flatMap(cleanShownText) {
                parts.append(own)
                return
            }
            view.children.forEach(visit)
        }
        children.forEach(visit)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func labelBelow() -> String? {
        var current = self
        for _ in 0..<32 {
            guard current.children.count == 1 else { return nil }
            current = current.children[0]
            if current.masked { return nil }
            if let label = current.values["label"] { return label }
        }
        return nil
    }
}

final class FakePath: SelectorPath {
    let views: [FakeView]
    private var infos: [ObjectIdentifier: ViewNodeInfo] = [:]

    init(_ leaf: FakeView) {
        var chain: [FakeView] = []
        var current: FakeView? = leaf
        while let view = current {
            chain.append(view)
            current = view.parent
        }
        views = chain
    }

    var count: Int { views.count }
    func node(at index: Int) -> FakeView { views[index] }
    func children(of node: FakeView) -> [FakeView] { node.children }

    func info(_ node: FakeView) -> ViewNodeInfo {
        if let cached = infos[ObjectIdentifier(node)] { return cached }
        let made = ViewNodeInfo(
            type: node.type,
            ids: node.ids,
            roles: node.roles,
            values: node.values,
            label: { node.labelBelow() },
            text: { node.shownText(includeMasked: true) }
        )
        infos[ObjectIdentifier(node)] = made
        return made
    }

    var classifier: TapClassifier<FakeView> {
        TapClassifier(
            isBoundary: { $0.boundary },
            isControl: { $0.control },
            isTapHandler: { $0.handler },
            isPrimitive: { $0.primitive },
            isContent: { $0.content },
            isMasked: { index in self.views[index...].contains { $0.masked } },
            shownText: { $0.shownText(includeMasked: false) }
        )
    }

    func describe(includeText: Bool = true) -> TapTarget? {
        describeTap(self, classifier: classifier, includeText: includeText)
    }
}

private func sel(_ selector: String, _ path: FakePath, file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard let parsed = ViewSelector.parse(selector) else {
        XCTFail("\(selector) does not parse", file: file, line: line)
        return false
    }
    return parsed.matches(path)
}

private func screen() -> FakeView {
    let window = FakeView("UIWindow", boundary: true)
    return window.add(FakeView("UIView"))
}

final class ViewSelectorSyntaxTests: XCTestCase {
    func testAcceptsWhatTheDashboardAccepts() {
        for valid in [
            "UIButton",
            "#checkout",
            ".button",
            "[key=\"42\"]",
            "[text='Pay now']",
            "[label]",
            "UITableViewCell[text^=\"Set\"]",
            "#cart UIButton",
            "UIStackView > UILabel",
            "UILabel + UILabel",
            "UILabel ~ UILabel",
            "*[type=\"_PrivateCard\"]",
            "[data-step=\"2\"]",
            "a#b.c[d=e][f~=\"g\"][h|=\"i\"][j$=\"k\"][l*=\"m\"]",
            "#--x",
            "#-a",
            "  UIButton  ",
            "UIButton#pay",
            "#toolbar_actions   >   UIButton",
            "  .textField  ",
            "[ text = \"Pay\" ]",
        ] {
            XCTAssertNotNil(ViewSelector.parse(valid), valid)
        }
    }

    func testRejectsPseudoClassesListsEscapesAndBrokenSyntax() {
        for invalid in [
            "UILabel:hover",
            "a, b",
            "#a\\:b",
            "[text=\"unterminated]",
            "[text=2]",
            ">",
            "a >",
            "",
            "   ",
            "#",
            "#-1",
            "a\"b",
            "[text=\"a\nb\"]",
            String(repeating: "x", count: 257),
            "[text]]",
            "[=x]",
            "#1abc",
            "#-",
            "[text!=\"a\"]",
            "a >> b",
            "[text=\"a\"",
            "1Button",
        ] {
            XCTAssertNil(ViewSelector.parse(invalid), invalid)
        }
    }

    func testCachesParsesIncludingFailures() {
        let first = ViewSelector.parse("UIButton#cached")
        XCTAssertTrue(first === ViewSelector.parse("UIButton#cached"))
        XCTAssertNil(ViewSelector.parse("a:b"))
        XCTAssertNil(ViewSelector.parse("a:b"))
    }

    func testTypeNamesDropModulesAndGenericArguments() {
        XCTAssertEqual(selectorTypeName("Shop.CheckoutButton<Int>"), "CheckoutButton")
        XCTAssertEqual(selectorTypeName("_UIHostingView<ModifiedContent<A, B>>"), "_UIHostingView")
        XCTAssertEqual(selectorTypeName("UIButton"), "UIButton")
        XCTAssertEqual(selectorTypeName("Outer.Inner"), "Inner")
    }

    func testCleansShownText() {
        XCTAssertEqual(cleanShownText("  Pay \n  now "), "Pay now")
        XCTAssertNil(cleanShownText(" \n "))
        XCTAssertEqual(cleanShownText(String(repeating: "a", count: 300))?.count, 256)
    }
}

final class ViewSelectorMatchingTests: XCTestCase {
    func testAButtonMatchesByTypeIdTextRoleAndAncestor() {
        let cart = screen().add(FakeView("UIStackView", id: "cart"))
        let button = cart.add(FakeView("ElevatedButton", id: "pay", roles: ["button"], control: true))
        let content = button.add(FakeView("UIView"))
        let text = content.add(FakeView("UILabel", text: "Pay now", content: true))
        let path = FakePath(text)

        XCTAssertTrue(sel("ElevatedButton", path))
        XCTAssertTrue(sel("elevatedbutton", path))
        XCTAssertTrue(sel("#pay", path))
        XCTAssertTrue(sel("ElevatedButton#pay", path))
        XCTAssertTrue(sel("ElevatedButton[text=\"Pay now\"]", path))
        XCTAssertTrue(sel("[text^=\"Pay\"]", path))
        XCTAssertTrue(sel("[text~=\"now\"]", path))
        XCTAssertTrue(sel("[text$=\"now\"]", path))
        XCTAssertTrue(sel("[text*=\"y n\"]", path))
        XCTAssertTrue(sel("[text|=\"Pay now\"]", path))
        XCTAssertTrue(sel(".button[text=\"Pay now\"]", path))
        XCTAssertTrue(sel("#cart ElevatedButton", path))
        XCTAssertTrue(sel("#cart #pay", path))
        XCTAssertTrue(sel("#cart > #pay", path))
        XCTAssertTrue(sel("[id=\"pay\"]", path))
        XCTAssertTrue(sel("UIStackView ElevatedButton UILabel", path))
        XCTAssertTrue(sel("UIView > UILabel", path))
        XCTAssertTrue(sel("*", path))

        XCTAssertFalse(sel("TextButton", path))
        XCTAssertFalse(sel("#other", path))
        XCTAssertFalse(sel("ElevatedButton[text=\"Pay\"]", path))
        XCTAssertFalse(sel("ElevatedButton #cart", path))
        XCTAssertFalse(sel("ElevatedButton > UILabel", path), "the label is two views below the button")
        XCTAssertFalse(sel("[text~=\"no\"]", path))
        XCTAssertFalse(sel("[text^=\"\"]", path), "an empty prefix matches nothing")
        XCTAssertFalse(sel("[data-step=\"2\"]", path))
        XCTAssertFalse(sel(".link", path))
    }

    func testFirstMatchIsTheDeepestMatchingView() {
        let outer = screen().add(FakeView("Card"))
        let inner = outer.add(FakeView("Card"))
        let leaf = inner.add(FakeView("UILabel", text: "x"))
        let path = FakePath(leaf)
        XCTAssertEqual(ViewSelector.parse("Card")!.firstMatch(path), 1)
        XCTAssertEqual(ViewSelector.parse("Card")!.firstMatch(path, where: { $0 === outer }), 2)
        XCTAssertNil(ViewSelector.parse("Missing")!.firstMatch(path))
    }

    func testIdentifiersLabelsAndTags() {
        let row = screen().add(FakeView("UIStackView"))
        let user = row.add(FakeView("UserTile", id: "open-user", handler: true))
        let name = user.add(FakeView("UILabel", text: "Ann"))
        let delete = row.add(FakeView("UIButton", values: ["label": "Delete"], control: true))
        let icon = delete.add(FakeView("UIImageView", content: true))
        let wrapper = row.add(FakeView("Favorite"))
        let star = wrapper.add(FakeView("UIImageView", values: ["label": "Favorite"], content: true))
        let order = row.add(FakeView("UIButton", values: ["key": "42"], control: true))

        let userPath = FakePath(name)
        XCTAssertTrue(sel("#open-user", userPath))
        XCTAssertTrue(sel("[identifier=\"open-user\"]", userPath))
        XCTAssertTrue(sel("[id=\"open-user\"]", userPath))

        let deletePath = FakePath(icon)
        XCTAssertTrue(sel("UIButton[label=\"Delete\"]", deletePath))
        XCTAssertTrue(sel("[label=\"Delete\"]", deletePath))
        XCTAssertFalse(sel("UIButton[label=\"Remove\"]", deletePath))

        let starPath = FakePath(star)
        XCTAssertTrue(sel("UIImageView[label=\"Favorite\"]", starPath))
        // The label of the only view below.
        XCTAssertTrue(sel("Favorite[label=\"Favorite\"]", starPath))
        XCTAssertTrue(sel("[type=\"Favorite\"]", starPath))

        XCTAssertTrue(sel("UIButton[key=\"42\"]", FakePath(order)))
        XCTAssertFalse(sel("UIButton[key=\"43\"]", FakePath(order)))
    }

    func testSiblingCombinatorsFollowTheOrderOfSubviews() {
        let row = screen().add(FakeView("UIStackView"))
        let first = row.add(FakeView("UILabel", id: "first", text: "first"))
        let second = row.add(FakeView("UILabel", id: "second", text: "second"))
        let third = row.add(FakeView("UILabel", id: "third", text: "third"))
        let path = FakePath(third)
        XCTAssertTrue(sel("#second + #third", path))
        XCTAssertTrue(sel("#first ~ #third", path))
        XCTAssertTrue(sel("#first + #second + #third", path))
        XCTAssertTrue(sel("UIStackView > #first ~ #third", path))
        XCTAssertTrue(sel("[text=\"first\"] ~ UILabel", path))
        XCTAssertFalse(sel("#first + #third", path))
        XCTAssertFalse(sel("#third ~ #first", path))
        XCTAssertFalse(sel("#third + #third", path))
        XCTAssertFalse(sel("#third ~ #second", FakePath(second)), "siblings come before")
        XCTAssertFalse(sel("* + #first", FakePath(first)), "the first subview has none")
    }

    func testTextInsideInputsIsNeverMatched() {
        let container = screen().add(FakeView("FormRow"))
        container.add(FakeView("UILabel", text: "Password"))
        let field = container.add(
            FakeView("UITextField", roles: ["textField"], text: "secret-password", input: true)
        )
        let path = FakePath(field)
        XCTAssertFalse(sel("UITextField[text*=\"secret\"]", path))
        XCTAssertFalse(sel("FormRow[text*=\"secret\"]", path))
        XCTAssertTrue(sel("FormRow[text*=\"Password\"]", path))
    }

    func testABudgetBoundsDeepDescendantChains() {
        var leaf = screen()
        for _ in 0..<600 { leaf = leaf.add(FakeView("A")) }
        let path = FakePath(leaf)
        let started = Date()
        XCTAssertFalse(sel("A A A A A A A A A Z A", path))
        XCTAssertTrue(sel(Array(repeating: "A", count: 18).joined(separator: " "), path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testATapMatchesItsTargetOrAnAncestorNotADescendant() {
        let row = screen().add(FakeView("UIStackView", id: "row", handler: true))
        let label = row.add(FakeView("UILabel", text: "Settings", content: true))
        XCTAssertTrue(sel("#row", FakePath(label)))
        XCTAssertTrue(sel("#row", FakePath(row)))
        XCTAssertFalse(sel("UILabel", FakePath(row)), "a tap on the row is not on its text")
    }

    func testAnIdentifierIsAnIdAndATagIsAKey() {
        let button = screen().add(FakeView("UIButton", id: "order.42", values: ["key": "7"], control: true))
        let path = FakePath(button)
        XCTAssertTrue(sel("[identifier=\"order.42\"]", path))
        XCTAssertTrue(sel("[id=\"order.42\"]", path))
        XCTAssertFalse(sel("#order", path), "an id is matched whole")
        XCTAssertTrue(sel("[key=\"7\"]", path))
        XCTAssertTrue(sel("[key]", path))
        XCTAssertFalse(sel("[identifier=\"7\"]", path))
        XCTAssertFalse(sel("[key=\"order.42\"]", path))
        XCTAssertFalse(sel("UILabel[key]", path))
    }

    func testANodeReadsItsLabelAndTextOnceAndOnlyWhenAsked() {
        var labelReads = 0
        var textReads = 0
        let info = ViewNodeInfo(
            type: "UIButton",
            ids: ["first", "second"],
            values: ["key": "1"],
            label: { labelReads += 1; return "Below" },
            text: { textReads += 1; return nil }
        )
        XCTAssertEqual(info.attribute("type"), "UIButton")
        XCTAssertEqual(info.attribute("id"), "first", "the first id")
        XCTAssertEqual(info.attribute("key"), "1")
        XCTAssertNil(info.attribute("other"))
        XCTAssertEqual(labelReads + textReads, 0, "other attributes read neither")
        XCTAssertEqual(info.label, "Below")
        XCTAssertEqual(info.attribute("label"), "Below")
        XCTAssertEqual(labelReads, 1)
        XCTAssertNil(info.text)
        XCTAssertNil(info.attribute("text"))
        XCTAssertEqual(textReads, 1, "no text is remembered too")
        // A label of its own wins over the one below.
        let own = ViewNodeInfo(type: "UIImageView", values: ["label": "Own"], label: {
            XCTFail("the label below is not read")
            return nil
        })
        XCTAssertEqual(own.label, "Own")
    }

    func testSiblingsOfAncestorsWork() {
        let page = screen().add(FakeView("UIStackView"))
        page.add(FakeView("UILabel", id: "title", text: "Title"))
        let body = page.add(FakeView("UIView", id: "body"))
        let button = body.add(FakeView("UIButton", text: "Go", control: true))
        let path = FakePath(button)
        XCTAssertTrue(sel("#title + #body UIButton", path))
        XCTAssertTrue(sel("#title ~ #body > UIButton", path))
        XCTAssertFalse(sel("#title + UIButton", path))
    }

    func testTextIsJoinedFromAtMostThreeShownViews() {
        let row = screen().add(FakeView("UIStackView", handler: true))
        row.add(FakeView("UILabel", text: "One"))
        row.add(FakeView("UILabel", text: "gone", hidden: true))
        row.add(FakeView("UILabel", text: "  Two \n lines "))
        let pair = row.add(FakeView("UIView"))
        pair.add(FakeView("UILabel", text: "Three"))
        pair.add(FakeView("UILabel", text: "Four"))
        let path = FakePath(row)
        XCTAssertEqual(path.info(row).text, "One Two lines Three")
        XCTAssertTrue(sel("UIStackView[text=\"One Two lines Three\"]", path))
        XCTAssertFalse(sel("[text*=\"gone\"]", path))
        XCTAssertFalse(sel("[text*=\"Four\"]", path))
    }

    func testMaskedTextStillMatchesButIsNeverReported() {
        let button = screen().add(FakeView("CardButton", control: true, masked: true))
        let card = button.add(FakeView("UILabel", text: "4242 4242 4242 4242", content: true))
        let path = FakePath(card)
        XCTAssertTrue(sel("CardButton[text^=\"4242\"]", path), "a rule still sees the text on the device")
        XCTAssertNil(path.describe()!.text, "but it is never reported")
        XCTAssertTrue(path.classifier.isMasked(0))
        XCTAssertTrue(path.classifier.isMasked(1))
        XCTAssertFalse(path.classifier.isMasked(2))
    }

    func testAMaskInsideKeepsItsTextOutOfTheReportedText() {
        let row = screen().add(FakeView("UIStackView", control: true))
        row.add(FakeView("UILabel", text: "Ann Smith", masked: true))
        row.add(FakeView("UILabel", text: "Call"))
        let path = FakePath(row)
        XCTAssertEqual(path.info(row).text, "Ann Smith Call")
        XCTAssertEqual(path.describe()!.text, "Call")
    }

    func testAttributeOperatorsFollowCSS() {
        let chip = screen().add(FakeView("Chip", values: ["label": "pay-now", "kind": "primary large"], text: "Pay"))
        let path = FakePath(chip)
        XCTAssertTrue(sel("[label|=\"pay\"]", path), "a prefix up to a hyphen")
        XCTAssertTrue(sel("[label|=\"pay-now\"]", path))
        XCTAssertFalse(sel("[label|=\"pa\"]", path))
        XCTAssertTrue(sel("[kind~=\"large\"]", path), "one of the words")
        XCTAssertFalse(sel("[kind~=\"arge\"]", path))
        XCTAssertFalse(sel("[kind~=\"\"]", path))
        XCTAssertFalse(sel("[kind$=\"\"]", path))
        XCTAssertFalse(sel("[kind*=\"\"]", path))
        XCTAssertFalse(sel("[kind=primary]", path), "= compares the whole value")
        XCTAssertTrue(sel("[text=Pay]", path), "an unquoted value")
        XCTAssertTrue(sel("[kind]", path))
        XCTAssertFalse(sel("[missing]", path))
        XCTAssertTrue(sel("CHIP", path), "types match in any case")
        XCTAssertTrue(sel("*[kind^=\"prim\"]", path))
    }
}

private struct PayButton {}
private struct Box<Content> {}

/// Class names as selectors see them: what `String(describing:)` and
/// `String(reflecting:)` give for real Swift types.
final class ViewSelectorTypeNameTests: XCTestCase {
    fileprivate final class Nested {}

    func testANestedTypeIsNamedByItsOwnName() {
        XCTAssertEqual(selectorTypeName(String(reflecting: Nested.self)), "Nested")
        XCTAssertEqual(selectorTypeName(String(describing: Nested.self)), "Nested")
        XCTAssertEqual(selectorTypeName(String(describing: Box<Int>.self)), "Box")
        XCTAssertEqual(selectorTypeName(String(reflecting: Box<Nested>.self)), "Box")
    }

    func testAPrivateTypeIsNamedWithoutItsContext() {
        let name = String(reflecting: PayButton.self)
        XCTAssertTrue(name.hasSuffix(".PayButton"), name)
        XCTAssertEqual(selectorTypeName(name), "PayButton")
        XCTAssertTrue(SelectorSyntax.isTag(selectorTypeName(name)))
        XCTAssertFalse(SelectorSyntax.isTag("_UIHostingView"), "a leading underscore is not a tag")
        XCTAssertTrue(SelectorSyntax.isIdent("_UIHostingView"))
    }
}

final class DescribeTapTests: XCTestCase {
    func testNamesTheControlNotTheHandlerOrLabelInsideIt() {
        let button = screen().add(FakeView("ElevatedButton", roles: ["button"], control: true))
        let ink = button.add(FakeView("InkWell", handler: true))
        let text = ink.add(FakeView("UILabel", text: "Pay now", content: true))
        let target = FakePath(text).describe()!
        XCTAssertEqual(target.tag, "ElevatedButton")
        XCTAssertEqual(target.selector, "ElevatedButton[text=\"Pay now\"]")
        XCTAssertEqual(target.text, "Pay now")
        XCTAssertNil(target.id)
    }

    func testAHandlerNamesTheControlAboveIt() {
        let tile = screen().add(FakeView("ListTile", control: true))
        let middle = tile.add(FakeView("UIView"))
        let handler = middle.add(FakeView("Gesture", handler: true))
        let label = handler.add(FakeView("UILabel", text: "Settings", content: true))
        let target = FakePath(label).describe()!
        XCTAssertEqual(target.tag, "ListTile")
        XCTAssertEqual(target.selector, "ListTile[text=\"Settings\"]")
    }

    func testAHandlerWithoutAControlAboveNamesItself() {
        let outer = screen().add(FakeView("Gesture", handler: true))
        let inner = outer.add(FakeView("Gesture", handler: true))
        let label = inner.add(FakeView("UILabel", text: "inner", content: true))
        let target = FakePath(label).describe()!
        XCTAssertEqual(target.tag, "Gesture")
        XCTAssertEqual(target.selector, "Gesture[text=\"inner\"]")
    }

    func testPrefersAnIdOnTheAppsWrapperAboveTheControl() {
        let wrapper = screen().add(FakeView("CheckoutButton", id: "checkout"))
        let button = wrapper.add(FakeView("UIButton", roles: ["button"], control: true))
        let label = button.add(FakeView("UILabel", text: "Checkout", content: true))
        let path = FakePath(label)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "CheckoutButton#checkout")
        XCTAssertEqual(target.id, "checkout")
        XCTAssertEqual(target.tag, "UIButton")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testAnIdThatIsNotAnIdentifierIsQuoted() {
        let button = screen().add(FakeView("UIButton", id: "order.42", control: true))
        let label = button.add(FakeView("UILabel", text: "Order", content: true))
        let path = FakePath(label)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "UIButton[identifier=\"order.42\"]")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testUsesTheKeyBeforeText() {
        let button = screen().add(FakeView("UIButton", values: ["key": "42"], control: true))
        let label = button.add(FakeView("UILabel", text: "Order", content: true))
        let path = FakePath(label)
        XCTAssertEqual(path.describe()!.selector, "UIButton[key=\"42\"]")
    }

    func testUsesTheLabelOfAnIconButton() {
        let button = screen().add(FakeView("UIButton", values: ["label": "Delete"], control: true))
        let icon = button.add(FakeView("UIImageView", content: true))
        let target = FakePath(icon).describe()!
        XCTAssertEqual(target.selector, "UIButton[label=\"Delete\"]")
        XCTAssertEqual(target.label, "Delete")
        XCTAssertNil(target.text)
    }

    func testTextWithCommasOrQuotesIsMatchedByItsPrefix() {
        let button = screen().add(FakeView("TextButton", control: true))
        let label = button.add(FakeView("UILabel", text: "Yes, delete", content: true))
        let path = FakePath(label)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "TextButton[text^=\"Yes\"]")
        XCTAssertEqual(target.text, "Yes, delete")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testLongTextIsLeftOutOfTheSelector() {
        let long = String(repeating: "word ", count: 12)
        let button = screen().add(FakeView("UIButton", control: true))
        let label = button.add(FakeView("UILabel", text: long, content: true))
        let target = FakePath(label).describe()!
        XCTAssertEqual(target.selector, "UIButton")
        XCTAssertEqual(target.text, cleanShownText(long))
    }

    func testMaskedControlsKeepTheirTextAndLabelOut() {
        let mask = screen().add(FakeView("Secret", masked: true))
        let button = mask.add(FakeView("UIButton", values: ["label": "Ann Smith"], control: true))
        let label = button.add(FakeView("UILabel", text: "Ann Smith", content: true))
        let target = FakePath(label).describe()!
        XCTAssertNil(target.text)
        XCTAssertNil(target.label)
        XCTAssertEqual(target.selector, "UIButton")
        XCTAssertFalse(target.selector.contains("Ann"))
    }

    func testTextIsLeftOutWhenNotWanted() {
        let button = screen().add(FakeView("UIButton", control: true))
        let label = button.add(FakeView("UILabel", text: "Pay", content: true))
        let target = FakePath(label).describe(includeText: false)!
        XCTAssertNil(target.text)
        XCTAssertEqual(target.selector, "UIButton")
    }

    func testFallsBackToTheContentThatWasTapped() {
        let column = screen().add(FakeView("UIStackView"))
        let label = column.add(FakeView("UILabel", text: "Hello there", content: true))
        let target = FakePath(label).describe()!
        XCTAssertEqual(target.tag, "UILabel")
        XCTAssertEqual(target.selector, "UILabel[text=\"Hello there\"]")
    }

    func testFallsBackToTheDeepestView() {
        let plain = screen().add(FakeView("Backdrop"))
        let target = FakePath(plain).describe()!
        XCTAssertEqual(target.tag, "Backdrop")
        XCTAssertEqual(target.selector, "Backdrop")
    }

    func testAnIdFurtherUpScopesTheType() {
        let list = screen().add(FakeView("Orders", id: "orders"))
        var above = list
        for _ in 0..<6 { above = above.add(FakeView("UIView")) }
        let cell = above.add(FakeView("UITableViewCell", control: true))
        let content = cell.add(FakeView("UIView"))
        let target = FakePath(content).describe(includeText: false)!
        // Too far up to be the cell's own wrapper: the id says where the cell is.
        XCTAssertNil(target.id)
        XCTAssertEqual(target.selector, "#orders UITableViewCell")
    }

    func testAnIdRightAboveTheControlNamesIt() {
        let list = screen().add(FakeView("Orders", id: "orders"))
        let cell = list.add(FakeView("UITableViewCell", control: true))
        let content = cell.add(FakeView("UIView"))
        let target = FakePath(content).describe(includeText: false)!
        XCTAssertEqual(target.id, "orders")
        XCTAssertEqual(target.selector, "Orders#orders")
    }

    func testATypeThatIsNotATagIsQuoted() {
        let card = screen().add(FakeView("_PrivateCard", control: true))
        let label = card.add(FakeView("UILabel", text: "Hi", content: true))
        let path = FakePath(label)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "[type=\"_PrivateCard\"][text=\"Hi\"]")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testAnUnnameableTypeFallsBackToItsRole() {
        let odd = screen().add(FakeView("a:b", roles: ["button"], control: true))
        let target = FakePath(odd).describe(includeText: false)!
        XCTAssertEqual(target.selector, ".button")
    }

    func testTheWindowAndWhatIsAboveItAreLeftOut() {
        let window = FakeView("UIWindow", id: "main-window", boundary: true)
        let root = window.add(FakeView("UIView"))
        let button = root.add(FakeView("UIButton", control: true))
        let target = FakePath(button).describe(includeText: false)!
        XCTAssertNil(target.id)
        XCTAssertEqual(target.selector, "UIButton")
        // Tapping the window itself still names it.
        XCTAssertEqual(FakePath(window).describe()!.tag, "UIWindow")
    }

    func testAnIdOnTheControlComesFirst() {
        let cart = screen().add(FakeView("UIStackView", id: "cart"))
        let pay = cart.add(FakeView("UIButton", id: "pay", text: "Pay now", control: true))
        cart.add(FakeView("UIButton", text: "Cancel", control: true))
        let path = FakePath(pay)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "UIButton#pay")
        XCTAssertEqual(target.id, "pay")
        XCTAssertEqual(target.text, "Pay now")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testAnIdInsideTheControlNamesIt() {
        let row = screen().add(FakeView("UIStackView", handler: true))
        let title = row.add(FakeView("UILabel", id: "title", text: "Settings", content: true))
        row.add(FakeView("UILabel", text: "On", content: true))
        let path = FakePath(title)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "UILabel#title")
        XCTAssertEqual(target.tag, "UIStackView")
        XCTAssertEqual(target.id, "title")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testAnIconButtonInsideAClickableRowIsTheIconButton() {
        let row = screen().add(FakeView("UIStackView", handler: true))
        let title = row.add(FakeView("UILabel", text: "Settings", content: true))
        let more = row.add(FakeView("UIButton", values: ["label": "More"], control: true))
        let icon = more.add(FakeView("UIImageView", content: true))
        let button = FakePath(icon).describe()!
        XCTAssertEqual(button.tag, "UIButton")
        XCTAssertEqual(button.selector, "UIButton[label=\"More\"]")
        let target = FakePath(title).describe()!
        XCTAssertEqual(target.tag, "UIStackView")
        XCTAssertEqual(target.selector, "UIStackView[text=\"Settings\"]")
    }

    func testAClickableViewInsideAClickableRowIsNotTheRow() {
        let row = screen().add(FakeView("UIStackView", handler: true))
        let inner = row.add(FakeView("UILabel", text: "inner", handler: true))
        row.add(FakeView("UILabel", text: "other"))
        let target = FakePath(inner).describe()!
        XCTAssertEqual(target.tag, "UILabel")
        XCTAssertEqual(target.selector, "UILabel[text=\"inner\"]")
    }

    func testAHandlerInsidePlumbingNamesTheOutermostPlumbing() {
        let card = screen().add(FakeView("Card"))
        let style = card.add(FakeView("PlainButtonStyle", primitive: true))
        let modifier = style.add(FakeView("ModifiedContent", primitive: true))
        let gesture = modifier.add(FakeView("TapGesture", handler: true))
        let target = FakePath(gesture).describe(includeText: false)!
        XCTAssertEqual(target.tag, "PlainButtonStyle")
        XCTAssertEqual(target.selector, "PlainButtonStyle")
        // A named control above the plumbing is what was tapped.
        let button = screen().add(FakeView("Button", control: true))
        let wrapper = button.add(FakeView("ModifiedContent", primitive: true))
        let tap = wrapper.add(FakeView("TapGesture", handler: true))
        XCTAssertEqual(FakePath(tap).describe(includeText: false)!.tag, "Button")
    }

    func testAMaskInsideAControlHidesItsLabel() {
        let button = screen().add(FakeView("UIButton", control: true))
        let icon = button.add(FakeView("UIImageView", values: ["label": "Call Ann Smith"], content: true, masked: true))
        let target = FakePath(icon).describe()!
        XCTAssertNil(target.label)
        XCTAssertNil(target.text)
        XCTAssertEqual(target.selector, "UIButton")
    }

    func testAMaskInsideAControlHidesOnlyItsText() {
        let row = screen().add(FakeView("UIStackView", control: true))
        row.add(FakeView("UILabel", text: "Ann Smith", masked: true))
        row.add(FakeView("UILabel", text: "Call"))
        let target = FakePath(row).describe()!
        XCTAssertEqual(target.text, "Call")
        XCTAssertFalse(target.selector.contains("Ann"))
        // The reported text is not what a rule sees, so it cannot name the row.
        XCTAssertEqual(target.selector, "UIStackView")
    }

    func testAnUnnameableTypeIsLeftOutOfItsSelector() {
        let tagged = screen().add(FakeView("a:b", id: "checkout", control: true))
        XCTAssertEqual(FakePath(tagged).describe()!.selector, "#checkout")
        let plain = screen().add(FakeView("a:b", control: true))
        let label = plain.add(FakeView("UILabel", text: "Settings", content: true))
        let path = FakePath(label)
        let target = path.describe()!
        XCTAssertEqual(target.selector, "[text=\"Settings\"]")
        XCTAssertEqual(target.tag, "a:b")
        XCTAssertTrue(sel(target.selector, path))
    }

    func testTextUpToFortyCharactersAndLabelsUpToSixtyNameTheTarget() {
        let forty = String(repeating: "x", count: 40)
        let fits = screen().add(FakeView("UIButton", text: forty, control: true))
        XCTAssertEqual(FakePath(fits).describe()!.selector, "UIButton[text=\"\(forty)\"]")
        let longer = screen().add(FakeView("UIButton", text: forty + "x", control: true))
        let target = FakePath(longer).describe()!
        XCTAssertEqual(target.selector, "UIButton")
        XCTAssertEqual(target.text, forty + "x", "the text is still reported")
        let long = String(repeating: "y", count: 61)
        let labelled = screen().add(FakeView("UIButton", values: ["label": long], control: true))
        let named = FakePath(labelled).describe()!
        XCTAssertEqual(named.selector, "UIButton")
        XCTAssertEqual(named.label, long)
    }

    func testAnEmptyPathDescribesNothing() {
        final class Empty: SelectorPath {
            var count: Int { 0 }
            func node(at index: Int) -> FakeView { fatalError() }
            func info(_ node: FakeView) -> ViewNodeInfo { fatalError() }
            func children(of node: FakeView) -> [FakeView] { [] }
        }
        let classifier = TapClassifier<FakeView>(
            isBoundary: { _ in false },
            isControl: { _ in false },
            isContent: { _ in false },
            isMasked: { _ in false },
            shownText: { _ in nil }
        )
        XCTAssertNil(describeTap(Empty(), classifier: classifier))
    }
}
