import Foundation

// Conversions and products that hold their result to the type's range
// instead of trapping. Used wherever a number that comes
// from outside (the server, a file, the app, the system) becomes an integer.

extension Int64 {
    /// `value` rounded toward zero and held to `Int64`'s range; 0 for NaN.
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= 9_223_372_036_854_775_808.0 {
            self = .max
        } else if value < -9_223_372_036_854_775_808.0 {
            self = .min
        } else {
            self = Int64(value)
        }
    }

    /// `a × b`, or the bound it went past.
    static func saturatingProduct(_ a: Int64, _ b: Int64) -> Int64 {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return product }
        return (a < 0) == (b < 0) ? .max : .min
    }

    /// `a + b`, or the bound it went past.
    static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return b > 0 ? .max : .min
    }
}

extension Int {
    /// `value` rounded toward zero and held to `Int`'s range; 0 for NaN.
    init(saturating value: Double) {
        self = Int(clamping: Int64(saturating: value))
    }
}

/// Seconds as milliseconds, rounded and saturating.
func millisecondsSaturating(_ seconds: Double) -> Int64 {
    Int64(saturating: (seconds * 1000).rounded())
}
