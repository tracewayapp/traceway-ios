#if canImport(MetricKit) && os(iOS)
import Foundation
import MetricKit

/// Receives MetricKit's diagnostics (iOS 14 and later; at the next launch
/// from iOS 15) and hands each payload's JSON to the running client, which
/// reports the crashes and watchdog terminations its own handlers did not
/// record (CONTRACT §14.1). Added once per process; MetricKit holds its
/// subscribers weakly, so this one is kept here.
@available(iOS 14.0, *)
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private static let lock = NSLock()
    private static var installed: MetricKitSubscriber?

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard installed == nil else { return }
        let subscriber = MetricKitSubscriber()
        installed = subscriber
        MXMetricManager.shared.add(subscriber)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guarded("MetricKit payload") {
                TracewayClient.shared?.receiveDiagnosticPayload(
                    payload.jsonRepresentation(), begin: payload.timeStampBegin, end: payload.timeStampEnd
                )
            }
        }
    }
}
#endif
