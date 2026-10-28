import Foundation

/// A JSON value as Sail's Responses API sends and takes it, kept exactly so a conversation's
/// items can be saved and sent again as they were (`SailSession`).
public enum SailJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SailJSON])
    case object([String: SailJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([SailJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: SailJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers as integers, as the API writes them.
            if let whole = Int64(exactly: value) { try container.encode(whole) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> SailJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var int: Int? { number.flatMap { Int(exactly: $0) } }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [SailJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: SailJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public static func parse(_ data: Data) throws -> SailJSON {
        try JSONDecoder().decode(SailJSON.self, from: data)
    }

    /// Parses JSON text, or nil when it isn't JSON (a model's tool arguments can be anything).
    public static func parse(_ text: String) -> SailJSON? {
        try? parse(Data(text.utf8))
    }

    /// Compact JSON with sorted keys, so equal values are equal bytes.
    public func data() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var text: String { String(decoding: data(), as: UTF8.self) }

    /// As `JSONSerialization` would read it, for code that takes `Any` (`summarizeToolInput`).
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if let whole = Int(exactly: value) { return whole }
            return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundation)
        case .object(let value): return value.mapValues(\.foundation)
        }
    }
}

// Not `ExpressibleByNilLiteral`: `nil` stays Optional's, so `json["key"] == nil` means a missing key.
extension SailJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: SailJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, SailJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
