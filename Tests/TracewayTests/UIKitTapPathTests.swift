#if canImport(UIKit)
import UIKit
import XCTest
@testable import Traceway

/// What a recorded tap says about real UIKit views: a masked view's text and
/// label stay out of it, and a mask marker in the accessibility identifier
/// is not reported as the view's id. Runs on the iOS Simulator.
final class UIKitTapPathTests: WireframeViewTestCase {
    private func tap(_ view: UIView) throws -> TapTarget {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        let path = try XCTUnwrap(UIViewPath.at(point, in: window), "a path to \(view)")
        return try XCTUnwrap(describeTap(path))
    }

    private func button(_ title: String, _ frame: CGRect, identifier: String? = nil) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.frame = frame
        button.accessibilityIdentifier = identifier
        return button
    }

    func testMaskMarkersKeepTextOutOfTapsAndAreNoIds() throws {
        let card = UIView(frame: CGRect(x: 20, y: 100, width: 300, height: 60))
        card.accessibilityIdentifier = "traceway-mask"
        let pay = button("Pay 4242", CGRect(x: 10, y: 10, width: 200, height: 40))
        pay.accessibilityLabel = "Pay with card 4242"
        card.addSubview(pay)
        let pin = button("PIN 9876", CGRect(x: 20, y: 200, width: 200, height: 40), identifier: "traceway-blank")
        let plain = button("Continue", CGRect(x: 20, y: 300, width: 200, height: 40), identifier: "continue-button")
        show(card, pin, plain)

        for (view, secret) in [(pay as UIView, "4242"), (pin as UIView, "9876")] {
            let target = try tap(view)
            XCTAssertNil(target.text, "a masked view's text stays out")
            XCTAssertNil(target.label, "and so does its label")
            XCTAssertNil(target.id, "a mask marker is not an id")
            XCTAssertFalse(target.selector.contains("traceway"), target.selector)
            XCTAssertFalse(target.selector.contains(secret), target.selector)
        }
        let named = try tap(plain)
        XCTAssertEqual(named.id, "continue-button")
        XCTAssertEqual(named.text, "Continue")
        XCTAssertTrue(named.selector.hasSuffix("#continue-button"), named.selector)
    }

    func testTheMaskPropertyKeepsTextOutOfTaps() throws {
        let pay = button("Pay 4242", CGRect(x: 20, y: 100, width: 200, height: 40), identifier: "pay")
        pay.tracewayMask = .blur
        show(pay)
        let target = try tap(pay)
        XCTAssertNil(target.text)
        XCTAssertNil(target.label)
        XCTAssertEqual(target.id, "pay", "a real identifier still names the view")
    }
}
#endif
