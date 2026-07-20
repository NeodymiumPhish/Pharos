import Foundation

enum SqlPushdownGenerator {
    static let groupCap = 1000

    static func generate(_ config: ChartConfig, userSQL: String, columns: [ColumnDef]) -> PushdownQuery? {
        // Only aggregating types.
        switch config.chartType { case .scatter, .gantt: return nil; default: break }
        guard isSingleSelect(userSQL) else { return nil }
        let agg = aggExpr(config, columns: columns)
        guard agg != nil else { return nil }   // non-count needs a value col

        switch config.chartType {
        case .heatmap: return heatmap(config, userSQL: userSQL, columns: columns, agg: agg!)
        default:       return categorical(config, userSQL: userSQL, columns: columns, agg: agg!)
        }
    }

    // MARK: helpers
    static func quoteIdent(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func isSingleSelect(_ sql: String) -> Bool {
        let segs = SQLSegmentParser.parse(sql).filter { !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard segs.count == 1 else { return false }
        let t = segs[0].sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("select") || t.hasPrefix("with")
    }

    private static func resolve(_ config: ChartConfig, _ role: ChartColumnRole, _ columns: [ColumnDef]) -> ColumnDef? {
        guard let ref = config.mappings[role], ref.index < columns.count else { return nil }
        // Ambiguity guard: the mapped name must be unique in the projection.
        if columns.filter({ $0.name == ref.name }).count > 1 { return nil }
        return columns[ref.index]
    }

    private static func aggExpr(_ config: ChartConfig, columns: [ColumnDef]) -> String? {
        if config.aggregation == .count { return "count(*)" }
        // Non-count requires a value column (mirror the client aggregator); if
        // absent, push-down is unavailable (generate() returns nil).
        guard let v = resolve(config, .value, columns) else { return nil }
        let c = quoteIdent(v.name)
        switch config.aggregation {
        case .sum: return "sum(\(c))"; case .avg: return "avg(\(c))"
        case .min: return "min(\(c))"; case .max: return "max(\(c))"; case .count: return "count(*)"
        }
    }

    /// Binning expression for an axis column + the numeric bin count if applied.
    private static func axisExpr(_ config: ChartConfig, _ col: ColumnDef) -> (expr: String, numericBins: Int?) {
        let kind = ColumnClassifier.kind(forDataType: col.dataType)
        let id = quoteIdent(col.name)
        let dt = col.dataType.lowercased()
        let isDateTruncable = dt.hasPrefix("date") || dt.hasPrefix("timestamp")
        if kind == .temporal, config.temporalBin != .none, isDateTruncable {
            let unit = truncUnit(config.temporalBin)
            let tz = dt.hasPrefix("timestamptz") || dt.contains("with time zone")
            let colExpr = tz ? "\(id) AT TIME ZONE 'UTC'" : id
            return ("date_trunc('\(unit)', \(colExpr))", nil)
        }
        if kind == .numeric, let n = binCount(config.numericBin) {
            return (id, n)   // width_bucket handled at query assembly (needs the range CTE)
        }
        return (id, nil)
    }
    private static func truncUnit(_ b: TemporalBin) -> String {
        switch b { case .hour: return "hour"; case .day, .auto: return "day"; case .week: return "week"
                   case .month: return "month"; case .year: return "year"; case .none: return "day" }
    }
    private static func binCount(_ b: NumericBin) -> Int? {
        switch b { case .off: return nil; case .b10: return 10; case .b20: return 20; case .b50: return 50; case .auto: return 20 }
    }

    private static func categorical(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let catCol = resolve(config, .category, columns) else { return nil }
        let series = resolve(config, .series, columns)
        let (catExpr, nbins) = axisExpr(config, catCol)
        let layout = PushdownLayout(kind: .categorical, hasSeries: nbins == nil && series != nil, numericBins: nbins)

        if let n = nbins {   // numeric width_bucket needs the range CTE
            let id = quoteIdent(catCol.name)
            let sql = """
            WITH _pharos_src AS ( \(userSQL) ),
                 _r AS (SELECT min(\(id)) lo, max(\(id)) hi FROM _pharos_src)
            SELECT CASE WHEN _r.lo = _r.hi THEN 1
                        ELSE LEAST(width_bucket(\(id), _r.lo, _r.hi, \(n)), \(n)) END AS _bucket,
                   _r.lo AS _lo, _r.hi AS _hi, \(agg) AS _val
            FROM _pharos_src, _r GROUP BY _bucket, _r.lo, _r.hi ORDER BY _bucket LIMIT \(groupCap)
            """
            return PushdownQuery(sql: sql, layout: layout)
        }
        let seriesSel = series.map { ", \(quoteIdent($0.name)) AS _series" } ?? ""
        let seriesGrp = series.map { ", \(quoteIdent($0.name))" } ?? ""
        let sql = """
        SELECT \(catExpr) AS _cat\(seriesSel), \(agg) AS _val
        FROM ( \(userSQL) ) AS _pharos_src
        GROUP BY \(catExpr)\(seriesGrp)
        ORDER BY _val DESC LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: layout)
    }

    private static func heatmap(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let (xExpr, _) = axisExpr(config, xCol)     // heatmap numeric-axis binning deferred (phase-2 parity)
        let (yExpr, _) = axisExpr(config, yCol)
        let sql = """
        SELECT \(xExpr) AS _x, \(yExpr) AS _y, \(agg) AS _val
        FROM ( \(userSQL) ) AS _pharos_src
        GROUP BY \(xExpr), \(yExpr)
        ORDER BY _val DESC LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil))
    }
}
