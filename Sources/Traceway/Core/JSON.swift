import Foundation

/// A JSON value with strict types. `JSONSerialization` returns `NSNumber` for
/// both booleans and numbers on Apple platforms, so `1 as? Bool` succeeds
/// there; the settings document needs the difference, so the SDK parses and
/// writes JSON through this type instead.
enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: - Reading

    var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// A finite number.
    var number: Double? {
        if case .number(let value) = self, value.isFinite { return value }
        return nil
    }

    /// A number without a fractional part that fits an `Int`.
    var int: Int? {
        guard let value = number, value == value.rounded(),
              value >= -9_007_199_254_740_992, value <= 9_007_199_254_740_992
        else { return nil }
        return Int(value)
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A string, number or boolean.
    var isScalar: Bool {
        switch self {
        case .string, .number, .bool: return true
        default: return false
        }
    }

    subscript(key: String) -> JSON? {
        object?[key]
    }

    // MARK: - Parsing

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ data: Data) throws -> JSON {
        do {
            return try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            throw ParseError(description: "invalid JSON")
        }
    }

    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    // MARK: - Writing

    /// The value as JSON text. With [sortedKeys] the output is stable, for
    /// values that are compared or hashed.
    func encoded(sortedKeys: Bool = false) -> String {
        var out = ""
        write(into: &out, sortedKeys: sortedKeys)
        return out
    }

    func encodedData(sortedKeys: Bool = false) -> Data {
        Data(encoded(sortedKeys: sortedKeys).utf8)
    }

    private func write(into out: inout String, sortedKeys: Bool) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let value):
            out += JSON.format(value)
        case .string(let value):
            JSON.writeString(value, into: &out)
        case .array(let items):
            out += "["
            var first = true
            for item in items {
                if !first { out += "," }
                first = false
                item.write(into: &out, sortedKeys: sortedKeys)
            }
            out += "]"
        case .object(let members):
            out += "{"
            var first = true
            let keys = sortedKeys ? members.keys.sorted() : Array(members.keys)
            for key in keys {
                if !first { out += "," }
                first = false
                JSON.writeString(key, into: &out)
                out += ":"
                members[key]!.write(into: &out, sortedKeys: sortedKeys)
            }
            out += "}"
        }
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    let v = Int(scalar.value)
                    out += "\\u"
                    out.append(hexDigits[(v >> 12) & 0xf])
                    out.append(hexDigits[(v >> 8) & 0xf])
                    out.append(hexDigits[(v >> 4) & 0xf])
                    out.append(hexDigits[v & 0xf])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }
    init(dictionaryLiteral elements: (String, JSON)...) {
        var members: [String: JSON] = [:]
        for (key, value) in elements { members[key] = value }
        self = .object(members)
    }
}

extension JSON {
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: Double) { self = .number(value) }
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    init(_ values: [String]) { self = .array(values.map { .string($0) }) }
    init(_ values: [String: String]) { self = .object(values.mapValues { .string($0) }) }

    /// The value as text for string comparisons: a string as is, a number
    /// without a needless fraction, a boolean as `true` / `false`.
    var text: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return JSON.format(value)
        case .string(let value): return value
        case .array, .object: return encoded(sortedKeys: true)
        }
    }
}
