import Foundation

/// How a variable's value is rendered when substituted into SQL.
///
/// There is deliberately no `null` case. A `Literal` holding `NULL` says the same
/// thing with one less concept, and `Bool` carries `NULL` as one of its three
/// values, so nothing needs a type of its own to emit it. Legacy `"null"` types in
/// saved queries are migrated on decode — see `QueryVariable.init(from:)`.
enum VariableType: String, Codable, CaseIterable {
    case literal, text, number, bool

    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .text: return "Text"
        case .number: return "Number"
        case .bool: return "Bool"
        }
    }
}

/// A single user-defined query variable. `name` is stored WITHOUT the
/// surrounding `{{ }}` braces (e.g. "target_ip").
struct QueryVariable: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var value: String = ""
    var type: VariableType = .literal

    init(id: UUID = UUID(), name: String, value: String = "", type: VariableType = .literal) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, value, type
    }

    /// Decoding is written by hand for one reason: an unrecognised `type` must not
    /// throw. These arrive from `saved_queries.variables`, and
    /// `SavedQueryVariables.decode` swallows errors and returns `[]` — so a single
    /// stale type string would silently drop every variable attached to that saved
    /// query, not just the one it appeared on.
    ///
    /// `"null"` is the one such string that exists in the wild: it was a variable
    /// type before `Bool` gained a `NULL` value. It maps to a `Literal` holding
    /// `NULL`, which renders identically to what the old type produced (the old
    /// type ignored the value entirely and always emitted `NULL`). Anything else
    /// unrecognised keeps its value and falls back to `Literal`, the verbatim type,
    /// which is the least surprising thing to do with a value we cannot classify.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""

        let rawType = try container.decodeIfPresent(String.self, forKey: .type)
            ?? VariableType.literal.rawValue
        if let known = VariableType(rawValue: rawType) {
            type = known
        } else {
            type = .literal
            if rawType == "null" { value = "NULL" }
        }
    }
}
