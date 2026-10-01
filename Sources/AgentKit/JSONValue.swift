import Foundation

/// Any JSON value, `Sendable` and `Codable`, so protocol messages can cross
/// actors and be built and taken apart without `[String: Any]`.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integers stay integers on the wire: ids and counts read better.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encoded(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var jsonString: String { String(decoding: encoded(), as: UTF8.self) }

    // MARK: - Reading

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var double: Double? { if case .number(let value) = self { return value }; return nil }
    public var int: Int? { double.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var isNull: Bool { self == .null }

    // MARK: - Bridging to Foundation

    /// From what `JSONSerialization` or WebKit's script results produce.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            // `NSNumber` wraps booleans too; the type encoding tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(any: $0) })
        case let value as Date: self = .string(ISO8601DateFormatter().string(from: value))
        case let value as URL: self = .string(value.absoluteString)
        default: self = .string(String(describing: value!))
        }
    }

    /// For handing to `JSONSerialization` or WebKit as script arguments.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
