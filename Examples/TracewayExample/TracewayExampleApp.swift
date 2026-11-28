import SwiftUI
import Traceway

@main
struct TracewayExampleApp: App {
    init() {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }

        // The project token (and, off Traceway Cloud, the server) come from
        // Traceway.xcconfig through Info.plist, as the Connection page shows
        // it. See Examples/README.md.
        let info = Bundle.main.infoDictionary
        Traceway.initialize(
            token: info?["TracewayToken"] as? String ?? "",
            baseUrl: info?["TracewayURL"] as? String ?? "",
            options: TracewayOptions(
                debug: true,
                version: "1.0.0",
                environment: "development",
                screenCapture: true
            )
        )
        Traceway.setAttribute("user.id", "demo-user")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
