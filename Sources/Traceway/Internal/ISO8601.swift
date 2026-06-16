import Foundation

enum ISO8601 {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    static func format(millis: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000.0))
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func parseMillis(_ string: String) -> Int64 {
        guard let date = formatter.date(from: string) else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
