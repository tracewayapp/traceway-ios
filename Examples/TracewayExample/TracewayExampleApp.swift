import SwiftUI
import Traceway

@main
struct TracewayExampleApp: App {
    init() {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }

        // `python3 Examples/mock_server.py` stands in for a Traceway server.
        Traceway.start(
            connectionString: "demo-token@http://localhost:8080",
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
