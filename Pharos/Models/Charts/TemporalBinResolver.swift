import Foundation

/// Turns `TemporalBin.auto` into a real unit from the data's time span.
///
/// The aggregator and the SQL generator both need a unit; neither can see the
/// span (the generator has no rows). So the config they are given has already
/// been resolved here, and their own `.auto` arms are a last-resort fallback
/// to day, never the path a chart takes.
enum TemporalBinResolver {

    /// The unit that gives roughly 12–60 buckets over `span` seconds.
    static func unit(forSpanSeconds span: Double) -> TemporalBin {
        let day = 86_400.0
        if span <= 3 * day { return .hour }
        if span <= 120 * day { return .day }
        if span <= 2 * 365 * day { return .week }
        if span <= 12 * 365 * day { return .month }
        return .year
    }

    /// Seconds between the column's earliest and latest value, or nil when
    /// fewer than one value parses.
    ///
    /// PostgreSQL text dates of one column share a format, so the lexical
    /// extremes are the temporal extremes: two parses over any row count.
    static func span(of result: QueryResult, column ref: ColumnRef) -> Double? {
        guard ref.index < result.columns.count else { return nil }
        var lo: String? = nil, hi: String? = nil
        for row in result.rows where ref.index < row.count {
            guard case let s as String = row[ref.index].value, !s.isEmpty else { continue }
            if lo == nil || s < lo! { lo = s }
            if hi == nil || s > hi! { hi = s }
        }
        guard let lo, let hi, let d0 = ValueCoercion.date(from: lo), let d1 = ValueCoercion.date(from: hi) else { return nil }
        return d1.timeIntervalSince(d0)
    }
}

extension ChartConfig {

    /// This config with every `.auto` temporal bin replaced by the unit the
    /// mapped column's span calls for. The stored config keeps `.auto` (it is
    /// the user's choice); only the copy handed to the aggregator, the SQL
    /// generator and the canvas is resolved.
    func resolvingAutoBins(for result: QueryResult) -> ChartConfig {
        var out = self
        func unit(_ role: ChartColumnRole) -> TemporalBin? {
            guard let ref = mappings[role], ref.index < result.columns.count,
                  ColumnClassifier.kind(of: ref.index, in: result) == .temporal,
                  let span = TemporalBinResolver.span(of: result, column: ref) else { return nil }
            return TemporalBinResolver.unit(forSpanSeconds: span)
        }
        switch chartType {
        case .heatmap:
            for role in [ChartColumnRole.x, .y] where resolvedBin(for: role).temporal == .auto {
                if let u = unit(role) {
                    var bin = resolvedBin(for: role)
                    bin.temporal = u
                    out.axisBins[role] = bin
                }
            }
        case .gantt:
            if temporalBin == .auto, let u = unit(.start) { out.temporalBin = u }
        default:
            if temporalBin == .auto, let u = unit(.category) { out.temporalBin = u }
        }
        return out
    }
}
