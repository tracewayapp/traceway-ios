import Foundation

/// Ids and stable hashes, the same as the browser and Flutter SDKs compute
/// them so all three sample the same sessions.
enum Ids {
    static func hex(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out += byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
        }
        return out
    }

    /// The bytes [hex] spells, or nil when it is not an even run of hex digits.
    static func bytes(hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0, !digits.isEmpty else { return digits.isEmpty ? [] : nil }
        var out = [UInt8]()
        out.reserveCapacity(digits.count / 2)
        var i = 0
        while i < digits.count {
            guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    static func uuidString(_ bytes: [UInt8]) -> String {
        let h = hex(bytes)
        guard h.count == 32 else { return h }
        let c = Array(h)
        return String(c[0..<8]) + "-" + String(c[8..<12]) + "-" + String(c[12..<16]) + "-"
            + String(c[16..<20]) + "-" + String(c[20..<32])
    }

    static func uuidBytes(_ uuid: String) -> [UInt8]? {
        let h = uuid.replacingOccurrences(of: "-", with: "")
        guard h.utf8.count == 32 else { return nil }
        return bytes(hex: h)
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    /// RFC 9562 UUIDv7: a millisecond timestamp followed by random bits, as
    /// OpAMP recommends for instance ids.
    static func uuidv7(nowMs: Int64 = Clock.nowMs()) -> String {
        var bytes = randomBytes(16)
        var ts = UInt64(max(0, nowMs))
        for i in stride(from: 5, through: 0, by: -1) {
            bytes[i] = UInt8(ts & 0xff)
            ts >>= 8
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return uuidString(bytes)
    }

    static func uuidv4() -> String {
        var bytes = randomBytes(16)
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return uuidString(bytes)
    }

    /// FNV-1a over the UTF-16 code units, mapped to [0, 1): a stable sampling
    /// decision for an id such as a session id. Matches the browser and
    /// Flutter SDKs.
    static func unitHash(_ value: String) -> Double {
        var hash: UInt32 = 0x811c_9dc5
        for unit in value.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return Double(hash) / 4_294_967_296.0
    }

    /// FNV-1a as eight hex digits: stable across runs, for file names and
    /// markers that must not hold a credential in the clear.
    static func fingerprint(_ value: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for unit in value.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        let h = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - h.count) + h
    }

    /// 64-bit FNV-1a over UTF-8 as sixteen hex digits, for keys that must
    /// tell destinations apart without holding their credentials.
    static func fingerprint64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let h = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - h.count) + h
    }
}

/// Wall-clock time in milliseconds since the epoch, the unit every SDK
/// timestamp uses.
enum Clock {
    static func nowMs() -> Int64 {
        ms(Date())
    }

    /// Saturating: the app can hand the SDK any date (`span.end(time:)`,
    /// a log record's timestamp), even an infinite one.
    static func ms(_ date: Date) -> Int64 {
        Int64(saturating: (date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
