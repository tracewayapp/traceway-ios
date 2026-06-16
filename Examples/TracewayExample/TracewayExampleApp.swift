import SwiftUI
import Traceway

@main
struct TracewayExampleApp: App {
    init() {

        let isRunningTests = NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else { return }

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
