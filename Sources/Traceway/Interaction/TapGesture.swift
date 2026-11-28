import Foundation

/// When a touch is a tap: it lifts within `slop` points of where it went
/// down, before UIKit's long-press duration (`UILongPressGestureRecognizer`
/// waits 0.5 s). The tap record and the replay's rrweb click use the same
/// rule, as Android (`ViewConfiguration`) and Flutter (`kLongPressTimeout`)
/// use their platform's.
enum TapGesture {
    static let slop: Double = 10
    static let maxDurationMs: Int64 = 500

    static func isTap(dx: Double, dy: Double, durationMs: Int64) -> Bool {
        dx * dx + dy * dy <= slop * slop && durationMs < maxDurationMs
    }
}
