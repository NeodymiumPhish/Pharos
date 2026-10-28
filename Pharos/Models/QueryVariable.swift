import Foundation

/// How a variable's value is rendered when substituted into SQL.
///
/// There is deliberately no `null` case. A `Literal` holding `NULL` says the same
/// thing with one less concept, and `Bool` carries `NULL` as one of its three
/// values, so nothing needs a type of its own to emit it. Legacy `"null"` types in
/// saved queries are migrated on decode — see `QueryVariable.init(from:)`.
enum VariableType: String, Codable, CaseIterable {
    case literal, text, number, bool
    /// `YYYY-MM-DD`, or the keyword `today`. Renders `DATE '…'` / `CURRENT_DATE`.
    case date
    /// `YYYY-MM-DD HH:MM:SS`, or `now`. Renders `TIMESTAMP '…'` / `LOCALTIMESTAMP`.
    case timestamp
    /// `YYYY-MM-DD HH:MM:SS <IANA zone id>`, or `now`. Renders `TIMESTAMPTZ '…±HH:MM'`
    /// / `CURRENT_TIMESTAMP`.
    case timestamptz
    /// One item per line. Renders `('a', 'b')`.
    case textList = "list_text"
    /// One number per line. Renders `(1, 2.5)`.
    case numberList = "list_number"

    /// The full name: unique per case, so a list of every case still reads
    /// unambiguously. A UI that shows one Timestamp and one List entry uses
    /// `family.displayName` plus `withTimeZone` / `listElement` instead.
    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .text: return "Text"
        case .number: return "Number"
        case .bool: return "Bool"
        case .date: return "Date"
        case .timestamp: return "Timestamp"
        case .timestamptz: return "Timestamp with Time Zone"
        case .textList: return "List of Text"
        case .numberList: return "List of Numbers"
        }
    }

    /// The entry a type pop-up shows for this case. Timestamp and its zoned
    /// variant share one family, as do the two lists.
    var family: VariableTypeFamily {
        switch self {
        case .literal: return .literal
        case .text: return .text
        case .number: return .number
        case .bool: return .bool
        case .date: return .date
        case .timestamp, .timestamptz: return .timestamp
        case .textList, .numberList: return .list
        }
    }

    /// True only for `.timestamptz`: the state of a "With time zone" switch.
    var withTimeZone: Bool { self == .timestamptz }

    /// The element type of a list, `nil` for every non-list case.
    var listElement: VariableListElement? {
        switch self {
        case .textList: return .text
        case .numberList: return .number
        default: return nil
        }
    }

    var isList: Bool { listElement != nil }

    /// The case a family pop-up plus its sub-option selects. `withTimeZone` is
    /// read only for `.timestamp`, `listElement` only for `.list`.
    static func make(
        family: VariableTypeFamily,
        withTimeZone: Bool = false,
        listElement: VariableListElement = .text
    ) -> VariableType {
        switch family {
        case .literal: return .literal
        case .text: return .text
        case .number: return .number
        case .bool: return .bool
        case .date: return .date
        case .timestamp: return withTimeZone ? .timestamptz : .timestamp
        case .list: return listElement == .number ? .numberList : .textList
        }
    }
}

/// One entry of a type pop-up. See `VariableType.family`.
enum VariableTypeFamily: String, CaseIterable {
    case literal, text, number, bool, date, timestamp, list

    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .text: return "Text"
        case .number: return "Number"
        case .bool: return "Bool"
        case .date: return "Date"
        case .timestamp: return "Timestamp"
        case .list: return "List"
        }
    }
}

/// What each item of a List variable is. See `VariableType.listElement`.
enum VariableListElement: String, CaseIterable {
    case text, number

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .number: return "Number"
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
    /// The connection records the variable is linked to. Empty is global:
    /// every connection, the default. A tab on any other connection does not
    /// see a linked variable (`VariableScope`).
    var connectionIds: [String] = []

    var isGlobal: Bool { connectionIds.isEmpty }

    init(id: UUID = UUID(), name: String, value: String = "", type: VariableType = .literal,
         connectionIds: [String] = []) {
        self.id = id
        self.name = name
        self.value = value
        self.type = type
        self.connectionIds = connectionIds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, value, type, connectionIds
    }

    // Written by hand so a global variable's document leaves the key out, as
    // the core does: older builds never see an unknown key from a global one.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encode(type, forKey: .type)
        if !connectionIds.isEmpty { try container.encode(connectionIds, forKey: .connectionIds) }
    }

    /// Decoding is written by hand for one reason: an unrecognised `type` must not
    /// throw. These arrive from the `query_variables` table through
    /// `PharosCore.loadQueryVariables()`, which decodes the whole array at once —
    /// so a single stale type string would fail the load and leave the app-wide
    /// list empty, not just the one variable it appeared on.
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
        // Absent from every variable written before scopes: global.
        connectionIds = try container.decodeIfPresent([String].self, forKey: .connectionIds) ?? []

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
