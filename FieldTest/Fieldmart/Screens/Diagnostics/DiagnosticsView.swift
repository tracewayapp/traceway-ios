import SwiftUI
import UIKit
import FieldmartCore

/// Diagnostics (`02-APP-SPEC.md` §2.7): the run's identity as selectable
/// text, and buttons that make things go wrong.
struct DiagnosticsView: View {
    @State private var status = ""
    private let env = AppEnvironment.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                info
                actions
                if !status.isEmpty {
                    Text(status).font(.footnote).foregroundColor(.secondary).fmID("fm-diag-status")
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("fm-diag-list")
        .fmScreen("diag")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(FMText.Diag.run, env.settings.run, id: "fm-diag-run")
            row(FMText.Diag.variant, env.settings.variant, id: "fm-diag-variant")
            row(FMText.Diag.scenario, env.settings.scenario ?? "none", id: "fm-diag-scenario")
            row(FMText.Diag.build, env.build, id: "fm-diag-build")
            row(FMText.Diag.session, env.telemetry.sessionId ?? "none", id: "fm-diag-session")
        }
    }

    private func row(_ title: String, _ value: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold)).frame(width: 80, alignment: .leading)
            Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fmID(id)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            button(id: "fm-diag-handled") { FMDiagnostics.handled() }
            button(id: "fm-diag-unhandled") { FMDiagnostics.crash() }
            button(id: "fm-diag-hang") { FMDiagnostics.blockMainThread() }
            button(id: "fm-diag-logs") { env.appLog.burst() }
            button(id: "fm-diag-http500") {
                env.client.get(env.urls.fail500) { _, code in status = "HTTP \(code)" }
            }
            button(id: "fm-diag-slow") {
                env.client.get(env.urls.slow(ms: 1500)) { _, code in status = "slow: HTTP \(code)" }
            }
            button(id: "fm-diag-event") { FMDiagnostics.event() }
            button(id: "fm-diag-message") { FMDiagnostics.message() }
        }
    }

    private func button(id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(FMText.Diag.buttons[id] ?? id)
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .fmID(id)
    }
}

/// What the Diagnostics buttons do, in named functions so stacks name them.
enum FMDiagnostics {
    static var env: AppEnvironment { AppEnvironment.shared }

    @inline(never)
    static func handled() {
        env.telemetry.captureException(FMError(description: "FM handled \(env.settings.run)"),
                                       attributes: ["fm.diag": "handled"])
    }

    @inline(never)
    static func crash() {
        fatalError("FM unhandled \(env.settings.run)")
    }

    /// Blocks the main thread for 2,500 ms (S7f, E-37).
    @inline(never)
    static func blockMainThread() {
        let until = Date().addingTimeInterval(2.5)
        while Date() < until {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    @inline(never)
    static func event() {
        env.telemetry.track("fm.checkout.step", attributes: ["step": "review", "items": 3])
        env.telemetry.metric("fm.cart.value", value: 129.5, dimensions: ["currency": "usd"])
    }

    @inline(never)
    static func message() {
        env.telemetry.captureMessage("FM message \(env.settings.run)")
    }
}
