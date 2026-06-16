import Foundation

/// ISO-8601 timestamp formatting that matches the Traceway wire contract
/// exactly: UTC, millisecond precision, trailing `Z`, e.g.
/// `2023-11-14T22:13:20.000Z`.
///
/// We use a fixed-format `DateFormatter` with the POSIX locale rather than
/// `ISO8601DateFormatter` because the latter does not reliably emit
/// milliseconds and is sensitive to the device calendar/locale. The format
/// string mirrors the Android `Iso8601.kt` helper.
enum ISO8601 {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    /// Formats milliseconds-since-epoch into the wire timestamp.
    static func format(millis: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000.0))
    }

    /// Formats a `Date` into the wire timestamp.
    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// Parses a wire timestamp back to milliseconds-since-epoch. Returns `0`
    /// when the input cannot be parsed.
    static func parseMillis(_ string: String) -> Int64 {
        guard let date = formatter.date(from: string) else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    /// Current time in milliseconds since epoch.
    static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
