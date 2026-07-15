import Foundation

/// How a variable's value is rendered when substituted into SQL.
enum VariableType: String, Codable, CaseIterable {
    case literal, text, number, bool, null

    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .text: return "Text"
        case .number: return "Number"
        case .bool: return "Bool"
        case .null: return "Null"
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
}
