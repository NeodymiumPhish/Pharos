import Foundation

/// Pure merge of drill sub-keys, grouped by column, for multi-mark selections
/// (heatmap rectangular brush, pie ⌘-click). Flattens compounds, then per column:
/// unions `.anyOf` value-lists, coalesces overlapping/adjacent `.range`s into one,
/// and folds `.blank` into the `.anyOf` list as `PharosBlanks.sentinel` (so a
/// single key carries "these values OR null"; the translators split it back out —
/// grid via the existing sentinel handling, SQL via the `.anyOf` → `IS NULL`
/// branch). A column with only a blank stays a `.blank`.
enum DrillMerge {
    static func merge(_ keys: [DrillKey]) -> [DrillKey] {
        var flat: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { flat.append(k) } }
        keys.forEach(walk)

        struct AnyAcc { var ref: ColumnRef; var vals: [String]; var blank: Bool }
        var anyOf: [Int: AnyAcc] = [:]
        var ranges: [Int: (ref: ColumnRef, lo: Double, hi: Double, kind: RangeKind)] = [:]
        var order: [Int] = []
        func note(_ i: Int) { if !order.contains(i) { order.append(i) } }

        for k in flat {
            switch k {
            case .anyOf(let r, let vs):
                note(r.index); anyOf[r.index, default: AnyAcc(ref: r, vals: [], blank: false)].vals += vs
            case .blank(let r):
                note(r.index); anyOf[r.index, default: AnyAcc(ref: r, vals: [], blank: false)].blank = true
            case .range(let r, let lo, let hi, let kind):
                note(r.index)
                if let ex = ranges[r.index] { ranges[r.index] = (r, Swift.min(ex.lo, lo), Swift.max(ex.hi, hi), kind) }
                else { ranges[r.index] = (r, lo, hi, kind) }
            case .overlap, .compound:
                break   // not produced as a per-axis sub-key
            }
        }

        var out: [DrillKey] = []
        for i in order {
            let hasRange = ranges[i] != nil
            if let a = anyOf[i] {
                if a.vals.isEmpty && a.blank {
                    // Lone blank: emit it ONLY if no range on this column. A range +
                    // null on one column can't be expressed as "range OR null" in a
                    // single grid filter, and ANDing them matches nothing — so prefer
                    // the range and drop the null (a binned-axis brush that includes
                    // the null bucket excludes it from the drill).
                    if !hasRange { out.append(.blank(a.ref)) }
                } else {
                    var vals = dedup(a.vals)
                    if a.blank { vals.append(PharosBlanks.sentinel) }
                    out.append(.anyOf(a.ref, vals))
                }
            }
            if let r = ranges[i] { out.append(.range(r.ref, r.lo, r.hi, r.kind)) }
        }
        return out
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var r: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); r.append(x) }
        return r
    }
}
