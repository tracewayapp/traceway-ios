import Foundation

/// Tiny debug logger, gated by `TracewayOptions.debug`. Uses `NSLog` so output
/// shows up in the device console as well as Xcode.
enum Log {
    static var debugEnabled: Bool = false
    static let tag = "Traceway"

    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        NSLog("[%@] %@", tag, message())
    }

    static func warn(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        NSLog("[%@] WARN %@", tag, message())
    }
}
