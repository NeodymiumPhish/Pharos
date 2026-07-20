import Foundation

/// Pure builder for the chart-selection label shown on the commit button
/// ("Filter in Grid" / "Query Selected Rows") and the "Filtered by Chart" chip.
/// Groups drill keys per column and describes each; ordered by column index.
enum DrillSummary {
    struct Part: Equatable { let column: String; let detail: String }

    static func parts(_ keys: [DrillKey]) -> [Part] {
        var flat: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { flat.append(k) } }
        keys.forEach(walk)

        struct Acc { var ref: ColumnRef; var vals: Set<String>; var blank: Bool; var range: Bool }
        var byCol: [Int: Acc] = [:]
        func acc(_ r: ColumnRef) -> Int {
            if byCol[r.index] == nil { byCol[r.index] = Acc(ref: r, vals: [], blank: false, range: false) }
            return r.index
        }
        for k in flat {
            switch k {
            case .anyOf(let r, let vs):
                let i = acc(r)
                for v in vs { if v == PharosBlanks.sentinel { byCol[i]!.blank = true } else { byCol[i]!.vals.insert(v) } }
            case .blank(let r): byCol[acc(r)]!.blank = true
            case .range(let r, _, _, _): byCol[acc(r)]!.range = true
            case .overlap(let s, _, _, _, _): byCol[acc(s)]!.range = true
            case .compound: break
            }
        }
        return byCol.keys.sorted().map { idx in
            let a = byCol[idx]!
            let detail: String
            if a.range { detail = "(range)" }
            else if a.vals.isEmpty && a.blank { detail = "(null)" }
            else { detail = "(\(a.vals.count + (a.blank ? 1 : 0)))" }
            return Part(column: a.ref.name, detail: detail)
        }
    }

    /// e.g. "Filtered by Chart — protocol (2); dst_country (2)". Bare prefix when empty.
    static func label(_ keys: [DrillKey], prefix: String) -> String {
        let p = parts(keys)
        guard !p.isEmpty else { return prefix }
        return prefix + " — " + p.map { "\($0.column) \($0.detail)" }.joined(separator: "; ")
    }
}
