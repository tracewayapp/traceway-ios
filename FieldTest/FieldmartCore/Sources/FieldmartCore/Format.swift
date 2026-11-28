import Foundation

/// Text formats every build shares: prices are integer cents shown as
/// `123.45`, never floating-point text.
public enum FMFormat {
    /// `12345` → `"123.45"`, `-5` → `"-0.05"`.
    public static func cents(_ value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = value.magnitude
        let whole = magnitude / 100
        let fraction = magnitude % 100
        return "\(sign)\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// `12345` → `"$123.45"`.
    public static func price(_ value: Int) -> String {
        "$" + cents(value)
    }

    /// The change from `from` to `to` in percent with two decimals and a
    /// sign: `"+1.25%"`, `"-0.40%"`, computed in integers (basis points).
    public static func changePercent(from: Int, to: Int) -> String {
        guard from > 0 else { return "+0.00%" }
        // Basis points, rounded half away from zero.
        let numerator = (to - from) * 10_000
        var bp = numerator / from
        let remainder = numerator % from
        if remainder.magnitude * 2 >= UInt(from) { bp += numerator < 0 ? -1 : 1 }
        let sign = bp < 0 ? "-" : "+"
        let magnitude = bp.magnitude
        let fraction = magnitude % 100
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)%"
    }

    /// A discount as shown on deal cards: `"-25%"`.
    public static func discount(_ percent: Int) -> String {
        "-\(percent)%"
    }

    /// `4.6` → `"4.6"`, `4` → `"4.0"` (one decimal, half away from zero).
    public static func rating(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded(.toNearestOrAwayFromZero))
        return "\(tenths / 10).\(abs(tenths % 10))"
    }

    /// `"3 / 8"`, the gallery counter.
    public static func pageCounter(_ index: Int, of count: Int) -> String {
        "\(index + 1) / \(count)"
    }
}

/// Epoch milliseconds, the clock every marker, checkpoint and SDK event
/// timestamp uses.
public enum FMClock {
    public static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    public static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
