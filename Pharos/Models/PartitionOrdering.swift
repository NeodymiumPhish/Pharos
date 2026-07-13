import Foundation

/// Ordering modes for the partitions group in the schema browser.
enum PartitionSortMode: String {
    case bound   // default — by partition boundary
    case name
    case size
}

/// Pure sorting logic for a partitioned table's child partitions.
/// Depends only on TableInfo (Foundation) so it is unit-testable standalone.
enum PartitionOrdering {

    static func sorted(_ partitions: [TableInfo], by mode: PartitionSortMode) -> [TableInfo] {
        switch mode {
        case .name:
            return partitions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return partitions.sorted { ($0.totalSizeBytes ?? -1) > ($1.totalSizeBytes ?? -1) }
        case .bound:
            return partitions.sorted { boundLess($0, $1) }
        }
    }

    /// Strict weak ordering by bound. DEFAULT sorts last; ties break by name.
    private static func boundLess(_ a: TableInfo, _ b: TableInfo) -> Bool {
        let ka = boundKey(a.partitionBound)
        let kb = boundKey(b.partitionBound)
        switch (ka, kb) {
        case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case (nil, _):   return false   // a is DEFAULT → after b
        case (_, nil):   return true    // b is DEFAULT → a before
        case let (.some(x), .some(y)):
            if let nx = Double(x), let ny = Double(y), nx != ny { return nx < ny }
            if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Extract a comparable key from a bound expression. Returns nil for DEFAULT
    /// (which sorts last). RANGE → first FROM value; LIST → first IN value;
    /// HASH → remainder number; unknown → nil.
    static func boundKey(_ bound: String?) -> String? {
        guard let bound = bound else { return nil }
        let b = bound.trimmingCharacters(in: .whitespaces)
        if b == "DEFAULT" { return nil }
        if let r = b.range(of: "FROM (") {
            return firstToken(after: r.upperBound, in: b, closing: ")")
        }
        if let r = b.range(of: "IN (") {
            return firstToken(after: r.upperBound, in: b, closing: ")")
        }
        if let r = b.range(of: "remainder ") {
            return firstToken(after: r.upperBound, in: b, closing: ")")
        }
        return nil
    }

    /// Read the first value up to a comma or the closing token, stripping quotes/spaces.
    private static func firstToken(after start: String.Index, in s: String, closing: Character) -> String {
        var token = ""
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if ch == "," || ch == closing { break }
            token.append(ch)
            i = s.index(after: i)
        }
        return token
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespaces)
    }
}
