import Foundation

/// Any JSON document. Fixture models are read through it so a field the app
/// does not use, or one that is missing, never fails a whole page.
public enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, index >= 0, index < array.count { return array[index] }
        return nil
    }

    /// The first of `keys` that is present and not null.
    public func first(_ keys: String...) -> JSONValue? {
        for key in keys {
            if let value = self[key], value != .null { return value }
        }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var int: Int? {
        guard let value = double, value.isFinite, abs(value) < 9e15 else { return nil }
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }

    public var int64: Int64? {
        guard let value = double, value.isFinite, abs(value) < 9e18 else { return nil }
        return Int64(value.rounded(.toNearestOrAwayFromZero))
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return value == "true" || value == "1"
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// The list a page response holds: the document itself when it is an
    /// array, else the first array under one of the usual keys.
    public func items(_ preferred: String...) -> [JSONValue] {
        if let array = array { return array }
        for key in preferred + ["items", "data", "rows", "results", "list"] {
            if let array = self[key]?.array { return array }
        }
        if let object = object {
            for key in object.keys.sorted() {
                if let array = object[key]?.array { return array }
            }
        }
        return []
    }
}
