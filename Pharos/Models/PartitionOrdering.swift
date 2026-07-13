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

    /// Strict weak ordering by bound. Rank orders the special classes
    /// (MINVALUE first, then normal keys, then MAXVALUE, then DEFAULT/unknown
    /// last); ties within a class break by name.
    private static func boundLess(_ a: TableInfo, _ b: TableInfo) -> Bool {
        let (ra, ka) = boundRank(a.partitionBound)
        let (rb, kb) = boundRank(b.partitionBound)
        if ra != rb { return ra < rb }
        if let x = ka, let y = kb {
            if let nx = Double(x), let ny = Double(y), nx != ny { return nx < ny }
            if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Classify a bound into a sort rank plus (for normal bounds) its comparable key.
    /// 0 = FROM (MINVALUE) — lowest; 1 = a normal key; 2 = FROM (MAXVALUE) — highest;
    /// 3 = DEFAULT or unparseable — last.
    private static func boundRank(_ bound: String?) -> (Int, String?) {
        guard let key = boundKey(bound) else { return (3, nil) }
        switch key {
        case "MINVALUE": return (0, nil)
        case "MAXVALUE": return (2, nil)
        default:         return (1, key)
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
