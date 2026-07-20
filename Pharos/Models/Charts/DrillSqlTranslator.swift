import Foundation

/// Converts a `DrillKey` into a SQL WHERE predicate for push-down drill-spawn.
/// Foundation-only: produces plain SQL strings, not `ColumnFilter`.
enum DrillSqlTranslator {
    static func predicate(for key: DrillKey, columns: [ColumnDef]) -> String {
        switch key {
        case .anyOf(let ref, let vals):
            // Split the blanks sentinel out so a null-inclusive selection matches
            // NULLs too — mirrors the grid's sentinel handling (grid↔SQL parity).
            let reals = vals.filter { $0 != PharosBlanks.sentinel }
            let hasNull = vals.contains(PharosBlanks.sentinel)
            var parts: [String] = []
            if !reals.isEmpty {
                let list = reals.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
                parts.append("\(ident(ref)) IN (\(list))")
            }
            if hasNull { parts.append("\(ident(ref)) IS NULL") }
            if parts.isEmpty { return "false" }   // empty selection matches nothing
            return parts.joined(separator: " OR ")
        case .blank(let ref):
            return "\(ident(ref)) IS NULL"
        case .range(let ref, let lo, let hi, let kind):
            let (l, h) = bounds(lo, hi, kind)
            return "\(ident(ref)) >= \(l) AND \(ident(ref)) < \(h)"
        case .compound(let keys):
            return keys.map { "(" + predicate(for: $0, columns: columns) + ")" }.joined(separator: " AND ")
        case .overlap(let s, let e, let lo, let hi, let kind):
            let (l, h) = bounds(lo, hi, kind)
            return "\(ident(s)) <= \(h) AND \(ident(e)) >= \(l)"
        }
    }

    private static func ident(_ ref: ColumnRef) -> String {
        "\"" + ref.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func bounds(_ lo: Double, _ hi: Double, _ kind: RangeKind) -> (String, String) {
        switch kind {
        case .numeric:
            func n(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
            return (n(lo), n(hi))
        case .temporal:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            func t(_ e: Double) -> String { "'" + f.string(from: Date(timeIntervalSince1970: e)) + "'" }
            return (t(lo), t(hi))
        }
    }
}
