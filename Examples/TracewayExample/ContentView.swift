import SwiftUI
import Traceway

struct ContentView: View {
    @State private var lastAction = "—"
    @State private var cardNumber = "4242 4242 4242 4242"

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Issues (sent right away)")) {
                    Button("Capture a Swift Error") {
                        Traceway.captureException(SampleError.somethingFailed(code: 42))
                        lastAction = "captured Swift Error"
                    }
                    Button("Capture an NSError") {
                        Traceway.captureException(NSError(
                            domain: "com.example.Demo", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "demo failure"]
                        ))
                        lastAction = "captured NSError"
                    }
                    Button("Capture a message") {
                        Traceway.captureMessage("Something noteworthy happened")
                        lastAction = "captured message"
                    }
                }

                Section(header: Text("Breadcrumbs (kept until an issue)")) {
                    Button("Log a line") {
                        Traceway.log("Opened the cart", level: .info)
                        lastAction = "logged"
                    }
                    Button("Record an action") {
                        Traceway.recordAction(category: "cart", name: "add_item", data: ["sku": "SKU-123", "qty": 2])
                        lastAction = "recorded action"
                    }
                    Button("Track checkout_failed") {
                        Traceway.track("checkout_failed", attributes: ["reason": "card_declined"])
                        lastAction = "tracked checkout_failed"
                    }
                    Button("Send a request") {
                        let url = URL(string: "https://httpbin.org/status/503")!
                        URLSession.shared.dataTask(with: url) { _, _, _ in }.resume()
                        lastAction = "sent a request"
                    }
                    NavigationLink("Open the checkout screen", destination: CheckoutView())
                }

                Section(header: Text("Replay privacy")) {
                    Text("Card: \(cardNumber)")
                        .tracewayMask(.blank())
                    TextField("Typed text is masked in replays", text: .constant(""))
                }

                Section(header: Text("Hard crashes (reported on next launch)")) {
                    crashButton("Force-unwrap nil (SIGTRAP)") {
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

                Section(header: Text("SDK")) {
                    Button("Flush now") {
                        Traceway.flush(timeout: 5)
                        lastAction = "flushed"
                    }
                    Text("Instance \(Traceway.instanceId ?? "—")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(lastAction).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Traceway Demo")
        }
        .tracewayScreen("/home")
    }

    private func crashButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundColor(.red)
        }
    }
}

struct CheckoutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Checkout").font(.title)
            Button("Pay") {
                Traceway.captureException(SampleError.paymentDeclined)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .accessibilityIdentifier("pay")
        }
        .tracewayScreen("/checkout")
    }
}

enum SampleError: Error {
    case somethingFailed(code: Int)
    case paymentDeclined
}
