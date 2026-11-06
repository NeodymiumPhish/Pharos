import Foundation

/// The row order of a results column sort. Pure: no AppKit, so a harness can
/// test it (`scripts/test-results-sort-keys.sh`).
///
/// Each cell's key is computed ONE time, before the sort. The comparator then
/// reads keys by index: it does no `as?` casts and no `Double(String)` parse
/// per comparison, which is what made a sort of a large result slow.
///
/// The order is total and repeatable: equal keys keep their data-row order in
/// both directions, and NULLs go last in both directions. So the same rows
/// sorted twice give the same permutation, and a permutation kept from an
/// earlier sort is the one a new sort would give.
///
/// Keys come from RAW values, never from the escaped display text (see
/// `ResultsSortController`).
enum ResultsSortKeys {
    enum Kind {
        /// Compared as `Double`. A value that does not parse counts as 0.
        case numeric
        /// `true`/`false` as "t"/"f"; text as itself. Compared by code point.
        case boolean
        /// `localizedStandardCompare` of the display string.
        case text
    }

    /// Data-row indices of `rows` in sorted order, by column `column`.
    /// A row too short to hold the column counts as NULL.
    static func order(rows: [[AnyCodable]], column: Int, kind: Kind, ascending: Bool) -> [Int] {
        switch kind {
        case .numeric:
            let keys = rows.map { row -> Double? in
                guard let cell = cell(row, column) else { return nil }
                return numericValue(cell)
            }
            return order(keys: keys, ascending: ascending) { a, b in
                a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
            }
        case .boolean:
            let keys = rows.map { row -> String? in
                guard let cell = cell(row, column) else { return nil }
                return (cell.value as? Bool).map { $0 ? "t" : "f" } ?? (cell.value as? String) ?? ""
            }
            return order(keys: keys, ascending: ascending) { a, b in
                a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
            }
        case .text:
            // NSString keys: the same `localizedStandardCompare`, without
            // bridging both Swift strings on every comparison (measured
            // 904 ms against 1,364 ms for 200,000 rows).
            let keys = rows.map { row -> NSString? in (cell(row, column)?.displayString).map { $0 as NSString } }
            return order(keys: keys, ascending: ascending) { $0.localizedStandardCompare($1 as String) }
        }
    }

    /// The sort of `keys`, nil = NULL. `compare` is three-way, so one call
    /// decides the order or a tie.
    static func order<Key>(keys: [Key?], ascending: Bool,
                           compare: (Key, Key) -> ComparisonResult) -> [Int] {
        var indices = Array(keys.indices)
        keys.withUnsafeBufferPointer { k in
            indices.sort { a, b in
                switch (k[a], k[b]) {
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                case let (x?, y?):
                    switch compare(x, y) {
                    case .orderedAscending: return ascending
                    case .orderedDescending: return !ascending
                    case .orderedSame: return a < b
                    }
                }
            }
        }
        return indices
    }

    /// The cell, or nil for a SQL NULL or a row too short to hold the column.
    private static func cell(_ row: [AnyCodable], _ column: Int) -> AnyCodable? {
        guard column < row.count else { return nil }
        let value = row[column]
        return value.isNull ? nil : value
    }

    private static func numericValue(_ value: AnyCodable) -> Double {
        switch value.value {
        case let s as String: return Double(s) ?? 0
        case let i as Int64: return Double(i)
        case let d as Double: return d
        default: return 0
        }
    }
}
