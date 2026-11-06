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
        /// The cell's text ("t"/"f" for a boolean). Compared by code point.
        case boolean
        /// `localizedStandardCompare` of the display string.
        case text
    }

    /// Data-row indices of `rows` in sorted order, by column `column`.
    /// A column past the last one reads as NULL.
    static func order(rows: ResultTable, column: Int, kind: Kind, ascending: Bool) -> [Int] {
        let rowRange = 0..<rows.rowCount
        switch kind {
        case .numeric:
            let keys = rowRange.map { r -> Double? in
                rows.string(r, column).map { Double($0) ?? 0 }
            }
            return order(keys: keys, ascending: ascending) { a, b in
                a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
            }
        case .boolean:
            // PostgreSQL's text format spells a boolean "t"/"f" already.
            let keys = rowRange.map { r -> String? in rows.string(r, column) }
            return order(keys: keys, ascending: ascending) { a, b in
                a < b ? .orderedAscending : (b < a ? .orderedDescending : .orderedSame)
            }
        case .text:
            // NSString keys: the same `localizedStandardCompare`, without
            // bridging both Swift strings on every comparison (measured
            // 904 ms against 1,364 ms for 200,000 rows).
            let keys = rowRange.map { r -> NSString? in rows.string(r, column).map { $0 as NSString } }
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
}
