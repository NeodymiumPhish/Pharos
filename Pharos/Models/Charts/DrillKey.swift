import Foundation

/// Whether a range drill is over numeric values or temporal instants (epoch seconds).
enum RangeKind: String, Codable, Equatable { case numeric, temporal }

/// How to filter the source rows a chart mark represents. Carries a ColumnRef
/// (index authoritative) so the translator can key grid filters by "col_<index>".
enum DrillKey: Equatable {
    /// Exact category match(es) on one column (case-sensitive displayString).
    case anyOf(ColumnRef, [String])
    /// The null / empty-cell mark on one column.
    case blank(ColumnRef)
    /// A numeric or temporal range on one column. For temporal, lo/hi are epoch seconds.
    case range(ColumnRef, Double, Double, RangeKind)
    /// Multiple keys ANDed across columns (e.g. a heatmap cell = X and Y).
    case compound([DrillKey])
    /// A gantt time-brush: rows whose [startRef, endRef] span overlaps [lo, hi].
    /// RangeKind is REQUIRED — a gantt start/end axis may be numeric, not just
    /// temporal, so bounds must be formatted per kind (like `.range`).
    case overlap(ColumnRef, ColumnRef, Double, Double, RangeKind)

    /// All column refs this key touches (for chip labels / dedup).
    var columnRefs: [ColumnRef] {
        switch self {
        case .anyOf(let r, _), .blank(let r): return [r]
        case .range(let r, _, _, _): return [r]
        case .compound(let keys): return keys.flatMap { $0.columnRefs }
        case .overlap(let s, let e, _, _, _): return [s, e]
        }
    }
}
