import SwiftUI
import Traceway

@main
struct TracewayExampleApp: App {
    init() {
        // Skip auto-start when this app is hosting the XCTest bundle — the tests
        // initialize Traceway themselves with their own DSN.
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }

        // Replace with your project's connection string: "{token}@{apiUrl}".
        // For local testing, run Examples/mock_server.py and use:
        //   "demo-token@http://localhost:8080/api/report"
        Traceway.start(
            connectionString: "demo-token@http://localhost:8080/api/report",
            options: TracewayOptions(debug: true, version: "1.0.0")
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
