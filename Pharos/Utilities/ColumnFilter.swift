import Foundation

// MARK: - Filter Operator

enum FilterOperator: String, CaseIterable {
    // Universal
    case isNull, isNotNull
    // Text
    case contains, notContains, startsWith, endsWith, equals, notEquals
    // Multi-value text
    case containsAnyOf, notContainsAnyOf
    // Exact-match multi-value (produced only by the value checklist, not the operator dropdown)
    case isAnyOf
    // Numeric / Temporal comparison
    case lessThan, lessOrEqual, greaterThan, greaterOrEqual, between
    // Boolean
    case isTrue, isFalse

    var label: String {
        switch self {
        case .isNull: return "is null"
        case .isNotNull: return "is not null"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .equals: return "equals"
        case .notEquals: return "does not equal"
        case .containsAnyOf: return "contains any of"
        case .notContainsAnyOf: return "does not contain any of"
        case .isAnyOf: return "is any of"
        case .lessThan: return "less than"
        case .lessOrEqual: return "less than or equal"
        case .greaterThan: return "greater than"
        case .greaterOrEqual: return "greater than or equal"
        case .between: return "between"
        case .isTrue: return "is true"
        case .isFalse: return "is false"
        }
    }

    var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isTrue, .isFalse: return false
        default: return true
        }
    }

    var needsSecondValue: Bool {
        self == .between
    }

    var needsMultiValue: Bool {
        self == .containsAnyOf || self == .notContainsAnyOf || self == .isAnyOf
    }

    static func operators(for category: PGTypeCategory) -> [FilterOperator] {
        switch category {
        case .string:
            return [.contains, .notContains, .containsAnyOf, .notContainsAnyOf, .startsWith, .endsWith, .equals, .notEquals, .isNull, .isNotNull]
        case .numeric:
            return [.equals, .notEquals, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual, .between, .containsAnyOf, .isNull, .isNotNull]
        case .boolean:
            return [.isTrue, .isFalse, .isNull, .isNotNull]
        case .temporal:
            return [.equals, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual, .between, .isNull, .isNotNull]
        case .json, .array:
            return [.contains, .equals, .containsAnyOf, .notContainsAnyOf, .isNull, .isNotNull]
        }
    }
}

// MARK: - Column Filter

struct ColumnFilter {
    let columnName: String
    let op: FilterOperator
    let value: String
    let value2: String?
    let values: [String]?
    let dataType: String

    /// Sentinel placed in `values` (for an `.isAnyOf` filter) to mean "match
    /// null / empty cells". NUL-prefixed so it cannot collide with a rendered
    /// cell value. Also used as the model value of the checklist's "(Blanks)" row.
    static let blanksSentinel = PharosBlanks.sentinel
}
