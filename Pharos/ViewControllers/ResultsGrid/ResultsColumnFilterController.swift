import AppKit

// MARK: - Column Filter Controller Delegate

protocol ResultsColumnFilterControllerDelegate: AnyObject {
    var filterableRows: [[AnyCodable]] { get }
    var filterableColumnCategories: [PGTypeCategory] { get }
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

        // Precompute value sets for .isAnyOf filters once (avoids re-hashing per row).
        var anyOfSets: [String: Set<String>] = [:]
        for (colId, filter) in activeFilters where filter.op == .isAnyOf {
            anyOfSets[colId] = Set(filter.values ?? [])
        }

        return inputDisplayRows.filter { rowIdx in
            for (colId, filter) in activeFilters {
                guard let idx = colIndex(from: colId) else { continue }
                let category = idx < categories.count ? categories[idx] : .string
                let value: AnyCodable? = idx < rows[rowIdx].count ? rows[rowIdx][idx] : nil
                if !evaluate(filter: filter, value: value, category: category,
                             preparedAnyOf: anyOfSets[colId]) {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Distinct Values (for the value-picker checklist)

    /// Distinct display-string values for a column plus per-value row counts, for the filter checklist.
    struct DistinctValuesResult {
        let values: [String]                       // shown values, type-aware ascending
        let hasBlanks: Bool                         // any null/empty in rows passing other filters
        let counts: [String: FilterValueCount]      // keyed by display string + blanksSentinel
    }

    /// Distinct display-string values for a column, computed over rows that pass
    /// every OTHER column's active filter (cascading). Also tallies, per value,
    /// `filtered` (rows passing the other filters) and `total` (all rows). Values
    /// are sorted type-aware ascending. `hasBlanks` is true if any null/empty cell
    /// appeared among rows passing the other filters (caller adds a "(Blanks)" row).
    func distinctValues(forColumnIndex idx: Int,
                        excludingColumnId colId: String,
                        category: PGTypeCategory) -> DistinctValuesResult {
        guard let delegate = delegate else {
            return DistinctValuesResult(values: [], hasBlanks: false, counts: [:])
        }
        let rows = delegate.filterableRows
        let categories = delegate.filterableColumnCategories

        // Every active filter except the column being edited (so all of this
        // column's values stay selectable even when it already has a filter).
        let otherFilters = activeFilters.filter { $0.key != colId }

        var total: [String: Int] = [:]
        var filtered: [String: Int] = [:]

        for row in rows {
            // Does this row pass every OTHER column's filter?
            var passes = true
            for (fColId, filter) in otherFilters {
                guard let fIdx = colIndex(from: fColId) else { continue }
                let fCat = fIdx < categories.count ? categories[fIdx] : .string
                let fVal: AnyCodable? = fIdx < row.count ? row[fIdx] : nil
                if !evaluate(filter: filter, value: fVal, category: fCat) { passes = false; break }
            }

            let cell: AnyCodable? = idx < row.count ? row[idx] : nil
            let key: String
            if cell == nil || cell!.isNull || cell!.displayString.isEmpty {
                key = ColumnFilter.blanksSentinel
            } else {
                key = cell!.displayString
            }
            total[key, default: 0] += 1
            if passes { filtered[key, default: 0] += 1 }
        }

        // Shown values = those appearing in >=1 row passing the other filters.
        let blanks = ColumnFilter.blanksSentinel
        let sorted = sortValues(filtered.keys.filter { $0 != blanks }, category: category)
        let hasBlanks = (filtered[blanks] ?? 0) >= 1

        var counts: [String: FilterValueCount] = [:]
        for key in sorted {
            counts[key] = FilterValueCount(filtered: filtered[key] ?? 0, total: total[key] ?? 0)
        }
        if hasBlanks {
            counts[blanks] = FilterValueCount(filtered: filtered[blanks] ?? 0, total: total[blanks] ?? 0)
        }
        return DistinctValuesResult(values: sorted, hasBlanks: hasBlanks, counts: counts)
    }

    /// Type-aware ascending sort of distinct display strings.
    private func sortValues(_ values: [String], category: PGTypeCategory) -> [String] {
        switch category {
        case .numeric:
            return values.sorted { a, b in
                switch (Double(a), Double(b)) {
                case let (x?, y?): return x < y
                case (nil, _?):    return false   // non-numeric strings sort after numeric
                case (_?, nil):    return true
                case (nil, nil):   return a.localizedStandardCompare(b) == .orderedAscending
                }
            }
        default:
            // Temporal display strings are ISO-ish, so natural compare is chronological;
            // strings/json/boolean use the same natural, case-insensitive ordering.
            return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    // MARK: - Evaluation

    private func evaluate(filter: ColumnFilter, value: AnyCodable?, category: PGTypeCategory,
                          preparedAnyOf: Set<String>? = nil) -> Bool {
        switch filter.op {
        case .isNull:
            return value?.isNull ?? true
        case .isNotNull:
            return !(value?.isNull ?? true)
        case .isTrue:
            return boolValue(value) == true
        case .isFalse:
            return boolValue(value) == false
        case .isAnyOf:
            let set = preparedAnyOf ?? Set(filter.values ?? [])
            let isBlank = (value?.isNull ?? true) || (value?.displayString.isEmpty ?? true)
            if isBlank { return set.contains(ColumnFilter.blanksSentinel) }
            return set.contains(value!.displayString)
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
