import Foundation

/// A JSON value, for the MCP server's messages.
///
/// Foundation only, so the standalone test scripts compile it
/// (scripts/test-mcp-protocol.sh). Numbers are doubles; a whole number is
/// written without a fraction, so a JSON-RPC id of `7` goes back as `7`.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Reading

    subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    var numberValue: Double? { if case let .number(n) = self { return n }; return nil }
    var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    var isNull: Bool { self == .null }

    /// A whole number that fits an `Int`, else nil.
    var intValue: Int? {
        guard case let .number(n) = self, n.rounded() == n, abs(n) < 9.0e15 else { return nil }
        return Int(n)
    }

    // MARK: - Building

    static func int(_ n: Int) -> JSONValue { .number(Double(n)) }
    static func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
    static func optional(_ n: Int?) -> JSONValue { n.map(JSONValue.int) ?? .null }

    // MARK: - Text

    /// Parse one JSON document. Throws on text that is not JSON.
    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    /// One line of JSON: no newline, keys sorted so the output is stable.
    var serialized: String {
        let any = foundationObject
        guard let data = try? JSONSerialization.data(
            withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The same, indented, for the text an MCP client shows a model.
    var prettySerialized: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: foundationObject,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // A JSON true/false arrives as a CFBoolean, which also casts to
            // NSNumber: tell the two apart by type id, not by value.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return NSNumber(value: b)
        case let .number(n):
            if n.rounded() == n, abs(n) < 9.0e15 { return NSNumber(value: Int64(n)) }
            return NSNumber(value: n)
        case let .string(s): return s
        case let .array(a): return a.map(\.foundationObject)
        case let .object(o): return o.mapValues(\.foundationObject)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    init(nilLiteral: ()) { self = .null }
}
