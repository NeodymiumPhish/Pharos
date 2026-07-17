import Foundation

/// Converts drill keys (from chart marks) into grid column filters.
/// Output is keyed by "col_<index>" — the identifier the grid's filter engine
/// resolves via colIndex(from:). A name-keyed filter would silently no-op.
enum DrillTranslator {
    struct Applied { let columnId: String; let filter: ColumnFilter }

    static func filters(for keys: [DrillKey], columns: [ColumnDef]) -> [Applied] {
        // Flatten compounds, then group by column index.
        var flat: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { flat.append(k) } }
        keys.forEach(walk)

        // Coalesce anyOf/blank per column into one value set; ranges pass through.
        var anyOfByCol: [Int: (ref: ColumnRef, vals: [String])] = [:]
        var ranges: [(ref: ColumnRef, lo: Double, hi: Double, kind: RangeKind)] = []
        for k in flat {
            switch k {
            case .anyOf(let ref, let vals):
                anyOfByCol[ref.index, default: (ref, [])].vals.append(contentsOf: vals)
            case .blank(let ref):
                anyOfByCol[ref.index, default: (ref, [])].vals.append(ColumnFilter.blanksSentinel)
            case .range(let ref, let lo, let hi, let kind):
                ranges.append((ref, lo, hi, kind))
            case .compound: break
            }
        }

        var out: [Applied] = []
        for (idx, entry) in anyOfByCol {
            guard idx < columns.count else { continue }
            let dt = columns[idx].dataType
            let f = ColumnFilter(columnName: entry.ref.name, op: .isAnyOf, value: "", value2: nil,
                                 values: dedupPreservingOrder(entry.vals), dataType: dt)
            out.append(Applied(columnId: "col_\(idx)", filter: f))
        }
        for r in ranges where r.ref.index < columns.count {
            let dt = columns[r.ref.index].dataType
            let (loS, hiS) = formatRange(r.lo, r.hi, kind: r.kind, dataType: dt)
            let f = ColumnFilter(columnName: r.ref.name, op: .between, value: loS, value2: hiS, values: nil, dataType: dt)
            out.append(Applied(columnId: "col_\(r.ref.index)", filter: f))
        }
        return out
    }

    private static func dedupPreservingOrder(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var r: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); r.append(x) }
        return r
    }

    private static func formatRange(_ lo: Double, _ hi: Double, kind: RangeKind, dataType: String) -> (String, String) {
        switch kind {
        case .numeric:
            func n(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
            return (n(lo), n(hi))
        case .temporal:
            // Match the grid's lexicographic, inclusive .between over display strings.
            // Bare `date` columns render "yyyy-MM-dd"; timestamps carry time (+ tz).
            let bare = dataType.lowercased().hasPrefix("date")
            if bare {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = "yyyy-MM-dd"
                return (f.string(from: Date(timeIntervalSince1970: lo)), f.string(from: Date(timeIntervalSince1970: hi)))
            }
            return (formatMicros(lo), formatMicros(hi))
        }
    }

    /// Formats an epoch instant as "yyyy-MM-dd HH:mm:ss.SSSSSS" (UTC) with true
    /// microsecond precision. DateFormatter's "SSSSSS" fractional-second pattern
    /// rounds sub-millisecond remainders up into the whole-second field (e.g. it
    /// turns 23:59:59.999999 into 00:00:00.000000 the next day), which would make
    /// a bucket's last-instant `hi` collide with the *next* bucket's first-instant
    /// instead of staying just below it. Splitting the whole-second and
    /// microsecond parts and formatting them independently avoids that rounding.
    private static func formatMicros(_ epoch: Double) -> String {
        let totalMicros = Int64((epoch * 1_000_000).rounded(.down))
        let seconds = totalMicros / 1_000_000
        var micros = totalMicros % 1_000_000
        if micros < 0 { micros += 1_000_000 }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let base = f.string(from: Date(timeIntervalSince1970: Double(seconds)))
        return base + "." + String(format: "%06d", micros)
    }
}
