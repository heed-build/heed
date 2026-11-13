import Foundation

/// A JSON value, for the Agent Client Protocol's messages: read leniently (ACP's schema marks most fields "default on
/// error", so a field of the wrong shape reads as missing rather than failing the message) and written exactly.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public var string: String? {
        if case let .string(text) = self { return text }
        return nil
    }

    public var int: Int? {
        if case let .number(value) = self, value.rounded() == value, abs(value) < 9e15 { return Int(value) }
        return nil
    }

    public var double: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(values) = self { return values }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Parses one JSON text; nil when it is not JSON.
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(any: object)
    }

    init(any: Any) {
        switch any {
        case let number as NSNumber:
            // NSNumber carries booleans too: tell them apart by their Objective-C type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let text as String: self = .string(text)
        case let values as [Any]: self = .array(values.map(JSONValue.init(any:)))
        case let fields as [String: Any]: self = .object(fields.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// One line of compact JSON with sorted keys (ACP's stdio transport is newline-delimited: a message may not
    /// contain a raw newline, which JSON's string escaping guarantees).
    public var text: String {
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .number(value):
            if value.rounded() == value, abs(value) < 9e15 { return String(Int(value)) }
            return String(value)
        case let .string(text): return Self.quoted(text)
        case let .array(values): return "[" + values.map(\.text).joined(separator: ",") + "]"
        case let .object(fields):
            return "{" + fields.keys.sorted().map { Self.quoted($0) + ":" + fields[$0]!.text }.joined(separator: ",")
                + "}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let control where control.value < 0x20:
                out += String(format: "\\u%04x", control.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
