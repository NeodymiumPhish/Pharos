import AppKit

// MARK: - Column Filter Controller Delegate

protocol ResultsColumnFilterControllerDelegate: AnyObject {
    var filterableRows: [[String: AnyCodable]] { get }
    var filterableColumnCategories: [String: PGTypeCategory] { get }
    func columnFilterControllerDidUpdate(columnFilteredDisplayRows: [Int])
}

// MARK: - ResultsColumnFilterController

class ResultsColumnFilterController {

    private(set) var activeFilters: [String: ColumnFilter] = [:]

    weak var delegate: ResultsColumnFilterControllerDelegate?

    var hasActiveFilters: Bool { !activeFilters.isEmpty }
    var activeFilterCount: Int { activeFilters.count }

    // MARK: - Set / Clear Filters

    func setFilter(_ filter: ColumnFilter, forColumn column: String) {
        activeFilters[column] = filter
    }

    func clearFilter(forColumn column: String) {
        activeFilters.removeValue(forKey: column)
    }

    func clearAll() {
        activeFilters.removeAll()
    }

    func filter(forColumn column: String) -> ColumnFilter? {
        activeFilters[column]
    }

    // MARK: - Apply Filters

    /// Filters `inputDisplayRows` using all active filters. Returns filtered indices.
    func applyFilters(inputDisplayRows: [Int]) -> [Int] {
        guard let delegate = delegate, !activeFilters.isEmpty else {
            return inputDisplayRows
        }

        let rows = delegate.filterableRows
        let categories = delegate.filterableColumnCategories

        return inputDisplayRows.filter { rowIdx in
            for (colName, filter) in activeFilters {
                let category = categories[colName] ?? .string
                let value = rows[rowIdx][colName]
                if !evaluate(filter: filter, value: value, category: category) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Evaluation

    private func evaluate(filter: ColumnFilter, value: AnyCodable?, category: PGTypeCategory) -> Bool {
        switch filter.op {
        case .isNull:
            return value?.isNull ?? true
        case .isNotNull:
            return !(value?.isNull ?? true)
        case .isTrue:
            return boolValue(value) == true
        case .isFalse:
            return boolValue(value) == false
        default:
            break
        }

        // Remaining operators require a non-null value
        guard let value = value, !value.isNull else { return false }

        switch category {
        case .numeric:
            return evaluateNumeric(filter: filter, value: value)
        case .boolean:
            return evaluateText(filter: filter, value: value)
        case .temporal:
            return evaluateTemporal(filter: filter, value: value)
        default:
            return evaluateText(filter: filter, value: value)
        }
    }

    private func evaluateNumeric(filter: ColumnFilter, value: AnyCodable) -> Bool {
        // Multi-value: match if cell value equals any of the provided values
        if filter.op == .containsAnyOf {
            guard let cellNum = parseDouble(value), let vals = filter.values else { return false }
            return vals.contains { Double($0) == cellNum }
        }

        guard let cellNum = parseDouble(value) else {
            return evaluateText(filter: filter, value: value)
        }
        guard let filterNum = Double(filter.value) else {
            return evaluateText(filter: filter, value: value)
        }

        switch filter.op {
        case .equals: return cellNum == filterNum
        case .notEquals: return cellNum != filterNum
        case .lessThan: return cellNum < filterNum
        case .lessOrEqual: return cellNum <= filterNum
        case .greaterThan: return cellNum > filterNum
        case .greaterOrEqual: return cellNum >= filterNum
        case .between:
            guard let v2 = filter.value2, let filterNum2 = Double(v2) else { return false }
            let lo = min(filterNum, filterNum2)
            let hi = max(filterNum, filterNum2)
            return cellNum >= lo && cellNum <= hi
        default:
            return evaluateText(filter: filter, value: value)
        }
    }

    private func evaluateTemporal(filter: ColumnFilter, value: AnyCodable) -> Bool {
        let cellStr = value.displayString

        // Interval comparison — compare by total seconds
        if filter.dataType.lowercased() == "interval" {
            guard let cellSec = intervalToSeconds(cellStr) else { return false }

            switch filter.op {
            case .equals:
                guard let fSec = Double(filter.value) else { return false }
                return cellSec == fSec
            case .lessThan:
                guard let fSec = Double(filter.value) else { return false }
                return cellSec < fSec
            case .lessOrEqual:
                guard let fSec = Double(filter.value) else { return false }
                return cellSec <= fSec
            case .greaterThan:
                guard let fSec = Double(filter.value) else { return false }
                return cellSec > fSec
            case .greaterOrEqual:
                guard let fSec = Double(filter.value) else { return false }
                return cellSec >= fSec
            case .between:
                guard let fSec = Double(filter.value),
                      let v2 = filter.value2, let fSec2 = Double(v2) else { return false }
                let lo = min(fSec, fSec2)
                let hi = max(fSec, fSec2)
                return cellSec >= lo && cellSec <= hi
            default:
                return evaluateText(filter: filter, value: value)
            }
        }

        // Non-interval temporal — ISO string comparison (sorts lexicographically)
        let filterStr = filter.value

        switch filter.op {
        case .equals: return cellStr == filterStr
        case .lessThan: return cellStr < filterStr
        case .lessOrEqual: return cellStr <= filterStr
        case .greaterThan: return cellStr > filterStr
        case .greaterOrEqual: return cellStr >= filterStr
        case .between:
            guard let v2 = filter.value2 else { return false }
            let lo = min(filterStr, v2)
            let hi = max(filterStr, v2)
            return cellStr >= lo && cellStr <= hi
        default:
            return evaluateText(filter: filter, value: value)
        }
    }

    private func evaluateText(filter: ColumnFilter, value: AnyCodable) -> Bool {
        let cellStr = value.displayString.lowercased()
        let filterStr = filter.value.lowercased()

        switch filter.op {
        case .contains: return cellStr.contains(filterStr)
        case .notContains: return !cellStr.contains(filterStr)
        case .startsWith: return cellStr.hasPrefix(filterStr)
        case .endsWith: return cellStr.hasSuffix(filterStr)
        case .equals: return cellStr == filterStr
        case .notEquals: return cellStr != filterStr
        case .containsAnyOf:
            guard let vals = filter.values else { return false }
            return vals.contains { cellStr.contains($0.lowercased()) }
        case .notContainsAnyOf:
            guard let vals = filter.values else { return true }
            return !vals.contains { cellStr.contains($0.lowercased()) }
        default: return true
        }
    }

    // MARK: - Interval Parsing

    /// Parses PostgreSQL interval display formats into total seconds.
    /// Handles: "HH:MM:SS", "N days HH:MM:SS", "N years N mons N days HH:MM:SS", etc.
    private func intervalToSeconds(_ str: String) -> Double? {
        var totalSeconds: Double = 0
        var remaining = str.trimmingCharacters(in: .whitespaces)

        // Handle negative intervals
        let negative = remaining.hasPrefix("-")
        if negative { remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces) }

        // Extract "N years", "N mons", "N days" components
        let unitPatterns: [(String, Double)] = [
            ("years?", 365.25 * 86400),
            ("mons?", 30 * 86400),
            ("days?", 86400),
        ]

        for (pattern, multiplier) in unitPatterns {
            if let range = remaining.range(of: "(-?\\d+)\\s+\(pattern)", options: .regularExpression) {
                let match = String(remaining[range])
                if let numRange = match.range(of: "-?\\d+", options: .regularExpression) {
                    if let num = Double(match[numRange]) {
                        totalSeconds += num * multiplier
                    }
                }
                remaining = remaining.replacingCharacters(in: range, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Parse remaining HH:MM:SS or HH:MM
        if !remaining.isEmpty {
            let timeParts = remaining.split(separator: ":")
            if timeParts.count >= 2 {
                let h = Double(timeParts[0]) ?? 0
                let m = Double(timeParts[1]) ?? 0
                let s = timeParts.count >= 3 ? (Double(timeParts[2]) ?? 0) : 0
                totalSeconds += h * 3600 + m * 60 + s
            } else if let directSeconds = Double(remaining) {
                totalSeconds += directSeconds
            }
        }

        return negative ? -totalSeconds : totalSeconds
    }

    // MARK: - Helpers

    private func parseDouble(_ value: AnyCodable) -> Double? {
        if let v = value.value {
            if let i = v as? Int64 { return Double(i) }
            if let d = v as? Double { return d }
            if let s = v as? String { return Double(s) }
        }
        return nil
    }

    private func boolValue(_ value: AnyCodable?) -> Bool? {
        guard let v = value, !v.isNull else { return nil }
        if let b = v.value as? Bool { return b }
        let s = v.displayString.lowercased()
        if s == "true" || s == "t" { return true }
        if s == "false" || s == "f" { return false }
        return nil
    }
}
