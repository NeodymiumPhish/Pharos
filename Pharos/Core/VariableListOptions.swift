import Foundation

/// How the Variable Manager's sidebar orders and narrows its list: the Sort
/// and Filter menu in its toolbar. The filter field's text is separate, and
/// both apply. Pure (`scripts/test-variable-manager.sh`).
struct VariableListOptions: Equatable {

    enum Sort: String, CaseIterable {
        /// The stored order: the order the variables were added in.
        case added
        case name
        case type
        case aiApps

        var displayName: String {
            switch self {
            case .added: return String(localized: "Order Added", comment: "Variable Manager: a sort order.")
            case .name: return String(localized: "Name")
            case .type: return String(localized: "Type")
            case .aiApps: return String(localized: "AI Apps")
            }
        }
    }

    var sort: Sort = .added
    var ascending = true
    /// Only variables of this type. Nil shows every type.
    var typeFilter: VariableTypeFamily?
    /// Only variables with this AI apps choice. Nil shows every choice.
    var aiFilter: VariableAIAccess?

    /// True while a filter of the menu hides variables.
    var isFiltering: Bool { typeFilter != nil || aiFilter != nil }

    /// True while the list is not the stored one, in the stored order.
    var changesTheList: Bool { isFiltering || sort != .added || !ascending }

    /// `variables`, narrowed and ordered. A tie keeps the names in order,
    /// then the stored order, whichever way the sort runs.
    func apply(to variables: [QueryVariable]) -> [QueryVariable] {
        let kept = variables.enumerated().filter { _, variable in
            (typeFilter.map { variable.type.family == $0 } ?? true)
                && (aiFilter.map { variable.mcpAccess == $0 } ?? true)
        }
        let sorted = kept.sorted { a, b in
            switch Self.compare(a.element, b.element, by: sort) {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame:
                if sort != .added, sort != .name {
                    switch Self.compare(a.element, b.element, by: .name) {
                    case .orderedAscending: return true
                    case .orderedDescending: return false
                    case .orderedSame: break
                    }
                }
                return sort == .added && !ascending ? a.offset > b.offset : a.offset < b.offset
            }
        }
        return sorted.map(\.element)
    }

    private static func compare(_ a: QueryVariable, _ b: QueryVariable, by sort: Sort) -> ComparisonResult {
        switch sort {
        case .added:
            return .orderedSame
        case .name:
            let x = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let y = b.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unnamed row (a new one) goes last, as "Untitled" would not.
            if x.isEmpty != y.isEmpty { return x.isEmpty ? .orderedDescending : .orderedAscending }
            return x.localizedStandardCompare(y)
        case .type:
            return order(VariableTypeFamily.allCases.firstIndex(of: a.type.family),
                         VariableTypeFamily.allCases.firstIndex(of: b.type.family))
        case .aiApps:
            return order(VariableAIAccess.allCases.firstIndex(of: a.mcpAccess),
                         VariableAIAccess.allCases.firstIndex(of: b.mcpAccess))
        }
    }

    private static func order(_ a: Int?, _ b: Int?) -> ComparisonResult {
        let x = a ?? .max, y = b ?? .max
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
}
