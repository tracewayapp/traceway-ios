#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import XCTest
@testable import Traceway

struct ScreenTestCheckout: View {
    var body: some View { Text("Checkout") }
}

struct ScreenTestDetail: View {
    var body: some View { Text("Detail") }
}

/// IOS2-4: which hosting controllers are screens, and what `.tracewayScreen`
/// records as its view appears and comes back. Runs on the iOS Simulator.
final class SwiftUIScreenTests: WireframeViewTestCase {
    private var server: FakeServer!

    override func setUp() {
        super.setUp()
        TracewayClient.resetForTesting()
        PlatformHooks.explicitScreens = false
        server = FakeServer()
    }

    override func tearDown() {
        TracewayClient.resetForTesting()
        PlatformHooks.explicitScreens = false
        super.tearDown()
    }

    /// Navigation records stream to `server` (OTLP protobuf, gzipped).
    @discardableResult
    private func startClient() throws -> TracewayClient {
        try TracewayClient.start(
            token: "token", baseUrl: "https://traceway.example.com",
            options: TracewayOptions(recordAllSessions: true, remoteConfig: false, exportDelayMs: 50),
            overrides: TracewayTestOverrides(transport: server, deviceAttributes: ["os.name": "ios"])
        )
    }

    /// Whether a sent log record has the string attribute `key` = `value`:
    /// protobuf writes it as the key, then an AnyValue holding the string.
    private func sentAttribute(_ key: String, _ value: String) -> Bool {
        var needle = Data(key.utf8)
        let text = Data(value.utf8)
        needle.append(contentsOf: [0x12, UInt8(text.count + 2), 0x0A, UInt8(text.count)])
        needle.append(text)
        return server.requests(to: "/api/otel/v1/logs").contains { request in
            var body = request.body
            if request.headers["Content-Encoding"] == "gzip", let plain = Gzip.decompress(body) { body = plain }
            return body.range(of: needle) != nil
        }
    }

    func testAHostingControllerIsNamedAfterItsRootView() {
        XCTAssertEqual(PlatformHooks.screenPath(for: UIHostingController(rootView: ScreenTestCheckout())), "/ScreenTestCheckout")
    }

    func testASwiftUIAppWindowIsNotAScreen() {
        XCTAssertNil(PlatformHooks.screenPath(for: UIHostingController(rootView: AnyView(ScreenTestCheckout()))))
    }

    func testTracewayScreenWinsOverItsHostingController() throws {
        let client = try startClient()
        let host = UIHostingController(rootView: ScreenTestCheckout().tracewayScreen("/checkout", route: "/checkout"))
        show(host)
        settle(0.3)
        XCTAssertEqual(client.screen.name, "/checkout")
        XCTAssertEqual(client.screen.route, "/checkout")
        XCTAssertTrue(PlatformHooks.explicitScreens)
        XCTAssertNil(PlatformHooks.screenPath(for: host), "the explicit name wins")
        XCTAssertNil(PlatformHooks.screenPath(for: UIHostingController(rootView: ScreenTestDetail())))
    }

    func testTracewayScreenRecordsAPushThenAPopWhenItComesBack() throws {
        let client = try startClient()
        let home = UIHostingController(rootView: ScreenTestCheckout().tracewayScreen("/home"))
        let navigation = UINavigationController(rootViewController: home)
        show(navigation)
        settle(0.3)
        XCTAssertEqual(client.screen.name, "/home")
        navigation.pushViewController(UIHostingController(rootView: ScreenTestDetail().tracewayScreen("/detail")),
                                      animated: false)
        settle(0.3)
        XCTAssertEqual(client.screen.name, "/detail")
        navigation.popViewController(animated: false)
        settle(0.3)
        XCTAssertEqual(client.screen.name, "/home", "the screen came back")
        client.flush(timeout: 5)
        XCTAssertTrue(eventually(timeout: 10) { self.sentAttribute("navigation.action", "pop") },
                      "coming back is a pop")
        XCTAssertTrue(sentAttribute("navigation.action", "push"))
        XCTAssertTrue(sentAttribute("navigation.from", "/detail"), "from the screen shown before")
    }
}
#endif
