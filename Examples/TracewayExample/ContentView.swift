import SwiftUI
import Traceway

/// Demonstrates every capture path. The "hard crash" buttons kill the process —
/// relaunch the app and the report uploads from disk. Run these **without** the
/// Xcode debugger attached (it intercepts the signals first).
struct ContentView: View {
    @State private var lastAction = "—"

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Managed (reported in-process, best-effort)")) {
                    Button("Capture a Swift Error") {
                        Traceway.capture(SampleError.somethingFailed(code: 42))
                        lastAction = "captured Swift Error"
                    }
                    Button("Capture an NSError") {
                        Traceway.capture(error: NSError(
                            domain: "com.example.Demo", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "demo failure"]
                        ))
                        lastAction = "captured NSError"
                    }
                    Button("Capture a message") {
                        Traceway.capture(message: "Something noteworthy happened")
                        lastAction = "captured message"
                    }
                    Button("Flush now") {
                        Traceway.flush(timeout: 5)
                        lastAction = "flushed"
                    }
                }

                Section(header: Text("Hard crashes (reported on next launch)")) {
                    crashButton("Force-unwrap nil (SIGSEGV/SIGTRAP)") {
                        let value: Int? = nil
                        print(value!)
                    }
                    crashButton("Array out of bounds (SIGTRAP)") {
                        let array = [1, 2, 3]
                        print(array[10])
                    }
                    crashButton("fatalError()") {
                        fatalError("intentional crash from the example app")
                    }
                    crashButton("Uncaught NSException") {
                        NSException(name: .genericException, reason: "demo NSException", userInfo: nil).raise()
                    }
                }

                Section(header: Text("Last action")) {
                    Text(lastAction).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Traceway Demo")
        }
    }

    private func crashButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundColor(.red)
        }
    }
}

enum SampleError: Error {
    case somethingFailed(code: Int)
}
