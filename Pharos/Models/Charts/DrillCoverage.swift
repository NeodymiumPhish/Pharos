import Foundation

/// Whether one chart mark falls inside a merged drill selection — drives the
/// chart's dim/lit preview so it matches exactly what a commit filters. Pure.
/// `merged` is post-`DrillMerge` per-column keys; `mark` is one mark's own key
/// (a value, null, range, or a compound of per-axis sub-keys).
enum DrillCoverage {
    static func covers(_ merged: [DrillKey], _ mark: DrillKey) -> Bool {
        let idx = index(merged)
        let subs = flatten(mark)
        guard !subs.isEmpty else { return false }
        return subs.allSatisfy { coversSub(idx, $0) }
    }

    private struct ColSel { var vals: Set<String>; var blank: Bool; var range: (lo: Double, hi: Double)? }

    private static func flatten(_ key: DrillKey) -> [DrillKey] {
        var out: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { out.append(k) } }
        walk(key)
        return out
    }

    private static func index(_ merged: [DrillKey]) -> [Int: ColSel] {
        var out: [Int: ColSel] = [:]
        func ensure(_ i: Int) { if out[i] == nil { out[i] = ColSel(vals: [], blank: false, range: nil) } }
        for k in flatten(.compound(merged)) {
            switch k {
            case .anyOf(let r, let vs):
                ensure(r.index)
                for v in vs { if v == PharosBlanks.sentinel { out[r.index]!.blank = true } else { out[r.index]!.vals.insert(v) } }
            case .blank(let r): ensure(r.index); out[r.index]!.blank = true
            case .range(let r, let lo, let hi, _): ensure(r.index); out[r.index]!.range = (lo, hi)
            case .overlap, .compound: break
            }
        }
        return out
    }

    private static func coversSub(_ idx: [Int: ColSel], _ sub: DrillKey) -> Bool {
        switch sub {
        case .anyOf(let r, let vs):
            guard let c = idx[r.index] else { return false }
            return vs.allSatisfy { $0 == PharosBlanks.sentinel ? c.blank : c.vals.contains($0) }
        case .blank(let r):
            return idx[r.index]?.blank ?? false
        case .range(let r, let mlo, let mhi, _):
            guard let rg = idx[r.index]?.range else { return false }
            return rg.lo <= mlo && mhi <= rg.hi
        case .overlap, .compound:
            return false
        }
    }
}
