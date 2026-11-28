import UIKit
import FieldmartCore

/// How a mask hides a view in session replays (the SDK's `.blur` and
/// `.blank()`), named here so the `off` build needs no SDK types.
enum FMMaskMode {
    case blur
    case blank
}

/// The one seam between Fieldmart and the SDK (`02-APP-SPEC.md` §1.5). The
/// `Fieldmart` target (compilation flag `FM_SDK`) implements it with
/// Traceway; `FieldmartOff` links no SDK at all and gets the no-op.
protocol Telemetry: AnyObject {
    /// `traceway` or `none`.
    var sdkName: String { get }
    /// Starts the SDK for the variant in `settings`. Returns how long the
    /// start took on the calling thread, in milliseconds.
    @discardableResult
    func start(_ settings: LaunchSettings) -> Double
    var sessionId: String? { get }
    /// A SwiftUI screen became visible (UIKit screens are recorded by the
    /// SDK's `viewDidAppear` hook).
    func screen(_ path: String)
    func track(_ name: String, attributes: [String: Any])
    func metric(_ name: String, value: Double, dimensions: [String: Any])
    func captureException(_ error: Error, attributes: [String: String])
    func captureMessage(_ message: String)
    func mask(_ view: UIView, _ mode: FMMaskMode)
    func flush()
}

/// What the `off` build reports: nothing.
final class NoopTelemetry: Telemetry {
    var sdkName: String { "none" }
    func start(_ settings: LaunchSettings) -> Double { 0 }
    var sessionId: String? { nil }
    func screen(_ path: String) {}
    func track(_ name: String, attributes: [String: Any]) {}
    func metric(_ name: String, value: Double, dimensions: [String: Any]) {}
    func captureException(_ error: Error, attributes: [String: String]) {}
    func captureMessage(_ message: String) {}
    func mask(_ view: UIView, _ mode: FMMaskMode) {}
    func flush() {}
}

enum TelemetryFactory {
    static func make() -> Telemetry {
        #if FM_SDK
        return TracewayTelemetry()
        #else
        return NoopTelemetry()
        #endif
    }
}

/// An error whose description is exactly its message (the SDK reports
/// `String(describing:)` as the issue message).
struct FMError: Error, CustomStringConvertible {
    let description: String
}
