import Foundation
import XCTest
// A plain import, as an app writes it: no `@preconcurrency`, no `@testable`.
import Traceway

// The README's snippets as an app in Swift 6 language mode writes them
// (this target builds with `.swiftLanguageMode(.v6)`): options in a
// `static let`, `beforeCapture` written on the main actor, an interaction
// run from a main-actor view model, a capture from a detached task. If any
// of the SDK's types were not `Sendable`, or the async `run` hopped off
// the caller's actor, this file would not compile.

/// Options shared by the app, as a `static let` (needs `Sendable`).
enum AppTraceway {
    static let options = TracewayOptions(
        version: "1.0.0",
        screenCapture: true,
        ignoreErrors: TracewayOptions.defaultIgnoreErrors + ["CancellationError", .regex(#"^Shop\.Retry"#)],
        beforeCapture: { captured in
            captured.attributes["app.screen.name"] != "/debug"
        }
    )
}

/// Shaped like the Quick start's `App`: its `init` runs on the main actor.
@MainActor
struct ShopApp {
    init() {
        let info = Bundle.main.infoDictionary
        Traceway.initialize(
            token: info?["TracewayToken"] as? String ?? "",
            baseUrl: info?["TracewayURL"] as? String ?? "",
            options: TracewayOptions(
                version: "1.0.0",
                screenCapture: true,
                // Written on the main actor, called on whatever thread
                // captured the issue: `@Sendable`, so no isolation check.
                beforeCapture: { captured in !captured.message.contains("secret") }
            )
        )
    }
}

/// A view model with an async interaction.
@MainActor
final class CheckoutModel {
    private(set) var placed = false
    private(set) var traceId: String?

    func placeOrder() async {
        let checkout = Traceway.startInteraction("checkout", attributes: ["cart.items": 3])
        do {
            try await checkout.run {
                try await Task.sleep(nanoseconds: 1_000_000)
                // Main-actor state, inside the interaction's `run`.
                placed = true
            }
        } catch {
            checkout.captureException(error)
        }
        traceId = checkout.traceId
        checkout.end()
    }
}

final class ReadmeSnippetsTests: XCTestCase {
    func testTheReadmeSnippetsBuildAndRunInSwift6() async throws {
        await MainActor.run { _ = ShopApp() }
        // There is no token in a test bundle: the SDK is not started, and
        // every call below still runs (and records nothing).
        XCTAssertNil(Traceway.client)
        let model = CheckoutModel()
        await model.placeOrder()
        let placed = await model.placed
        XCTAssertTrue(placed)

        struct CheckoutFailed: Error {}
        let error = CheckoutFailed()
        await Task.detached { Traceway.captureException(error, attributes: ["order": "42"]) }.value
        Traceway.captureMessage("User completed checkout")
        Traceway.log("Cache miss", level: .warn, attributes: ["cache": "images"])
        _ = AppTraceway.options
        // Standalone, as "Send telemetry to another OpenTelemetry provider"
        // shows it: no token. (No receiver here: it is not started.)
        XCTAssertNil(Traceway.initialize(options: TracewayOptions(serviceName: "shop-app")))
        _ = Traceway.defaultBaseUrl
        Traceway.shutdown()
    }
}
