import Foundation
import XCTest
@testable import Traceway

/// The invariants every Traceway SDK's wireframe shares: the stylesheet,
/// byte for byte, and the fixed node ids of the document skeleton.
final class WireframeStylesheetTests: XCTestCase {
    /// `Resources/wireframe.css`, the copy of the shared stylesheet.
    private func sharedStylesheet() throws -> String {
        #if SWIFT_PACKAGE
        let bundled = Bundle.module.url(forResource: "wireframe", withExtension: "css")
        #else
        let bundled = Bundle(for: WireframeStylesheetTests.self).url(forResource: "wireframe", withExtension: "css")
        #endif
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/wireframe.css")
        let url = try XCTUnwrap(bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheStylesheetIsTheSharedOneByteForByte() throws {
        let shared = try sharedStylesheet()
        XCTAssertEqual(Array(wireframeCss.utf8), Array(shared.utf8))
        XCTAssertTrue(wireframeCss.hasSuffix("}\n"))
    }

    func testTheScreenNodeCarriesTheAppleFontStack() {
        let style = screenNodeStyle(width: 390, height: 844.5)
        XCTAssertEqual(
            style,
            #"width:390px;height:844.5px;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;"#
        )
        let away = WireframeRecorder.awayScreen(390, 844)
        XCTAssertTrue(away.attributes["style"]?.contains("font-family:-apple-system,") == true)
        XCTAssertFalse(wireframeCss.contains("-apple-system"), "the platform's font is inline, not in the shared sheet")
    }

    func testTheSkeletonHasTheFixedIds() {
        XCTAssertEqual(documentNodeId, 1)
        XCTAssertEqual(screenNodeId, 8)
        XCTAssertEqual([awayScreenTextBoxId, awayScreenTextId], [9, 10])
        XCTAssertEqual([keyboardNodeId, keyboardLabelBoxId, keyboardLabelTextId], [12, 13, 14])
        XCTAssertEqual(firstCapturedNodeId, 16)
        let doc = serializeDocument(VNode(element: screenNodeId, tag: "div", attributes: ["id": "tw"], children: []))
        var ids: [Int] = []
        func collect(_ node: JSON) {
            if let id = node["id"]?.int { ids.append(id) }
            node["childNodes"]?.array?.forEach(collect)
        }
        collect(doc)
        XCTAssertEqual(ids, [1, 2, 3, 4, 5, 6, 7, 8])
    }
}
