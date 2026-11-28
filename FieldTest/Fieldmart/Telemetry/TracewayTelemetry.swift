#if FM_SDK
import UIKit
import Traceway
import FieldmartCore

/// Telemetry through the Traceway SDK, started the way the README shows,
/// with the options of `03-MEASUREMENT.md` §1.4 for the variant.
final class TracewayTelemetry: Telemetry {
    var sdkName: String { "traceway" }

    @discardableResult
    func start(_ settings: LaunchSettings) -> Double {
        let plan = settings.sdkPlan
        guard plan.known else {
            NSLog("Fieldmart: unknown variant %@, the SDK is not started", settings.variant)
            return 0
        }
        var options = TracewayOptions(
            debug: plan.debug,
            version: SDKPlan.version,
            environment: SDKPlan.environment,
            attributes: settings.attributes(target: DeviceDescription.target),
            screenCapture: plan.screenCapture,
            recordAllSessions: plan.recordAllSessions,
            collection: plan.collection,
            remoteConfig: plan.remoteConfig
        )
        if let fps = plan.fps { options.fps = fps }
        let started = CFAbsoluteTimeGetCurrent()
        Traceway.initialize(token: settings.token, baseUrl: settings.baseUrl, options: options)
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    var sessionId: String? { Traceway.currentSessionId }

    func screen(_ path: String) {
        // SwiftUI screens carry `.tracewayScreen` (see `fmScreen`), which
        // records the navigation itself.
    }

    func track(_ name: String, attributes: [String: Any]) {
        Traceway.track(name, attributes: attributes)
    }

    func metric(_ name: String, value: Double, dimensions: [String: Any]) {
        Traceway.metric(name, value: value, dimensions: dimensions)
    }

    func captureException(_ error: Error, attributes: [String: String]) {
        Traceway.captureException(error, attributes: attributes)
    }

    func captureMessage(_ message: String) {
        Traceway.captureMessage(message)
    }

    func mask(_ view: UIView, _ mode: FMMaskMode) {
        switch mode {
        case .blur: view.tracewayMask = .blur
        case .blank: view.tracewayMask = .blank()
        }
    }

    func flush() {
        Traceway.flush(timeout: 2)
    }
}
#endif
