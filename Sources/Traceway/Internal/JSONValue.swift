import Foundation

/// A minimal, ordered JSON value used to serialize the Traceway wire format.
///
/// We deliberately do **not** use `Codable`/`JSONEncoder` because the backend
/// contract (shared with the Android/Flutter/JS SDKs) requires:
///   * a specific, stable key order, and
///   * certain keys emitted as literal `null` (not omitted).
///
/// `object` stores ordered `(key, value)` pairs so insertion order is preserved
/// byte-for-byte. This mirrors the Android `JsonExt.kt` helper.
enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case null

    /// Serializes to compact JSON (no insignificant whitespace).
    func serialize() -> String {
        var out = String()
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            // Integral doubles serialize without a trailing ".0" decimal so the
            // output stays stable and compact.
            if d.rounded() == d && abs(d) < 1e15 {
                out += String(Int64(d))
            } else {
                out += String(d)
            }
        case .string(let s):
            JSONValue.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (idx, item) in items.enumerated() {
                if idx > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (idx, pair) in pairs.enumerated() {
                if idx > 0 { out += "," }
                JSONValue.writeString(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    /// Writes a JSON-escaped string literal (including surrounding quotes).
    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue {
    /// Builds an ordered JSON object from `(key, value)` pairs whose values are
    /// already `JSONValue`s.
    static func ordered(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(pairs)
    }

    /// Builds a JSON object from a string map. Iteration order follows the
    /// provided `keyOrder` (any keys not listed are appended afterwards, sorted
    /// for determinism). Used for the `attributes` map.
    static func stringMap(_ map: [String: String], keyOrder: [String] = []) -> JSONValue {
        var pairs: [(String, JSONValue)] = []
        var seen = Set<String>()
        for key in keyOrder where map[key] != nil {
            pairs.append((key, .string(map[key]!)))
            seen.insert(key)
        }
        for key in map.keys.sorted() where !seen.contains(key) {
            pairs.append((key, .string(map[key]!)))
        }
        return .object(pairs)
    }
}
