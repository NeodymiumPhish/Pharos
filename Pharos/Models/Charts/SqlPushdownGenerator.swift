import Foundation

enum SqlPushdownGenerator {
    static let groupCap = 1000
    static let scatterSampleCap = 5000

    static func generate(_ config: ChartConfig, userSQL: String, columns: [ColumnDef]) -> PushdownQuery? {
        // Only gantt is unavailable (never aggregates; can't push down). Scatter
        // is available as a deterministic sample (handled below).
        if config.chartType == .gantt { return nil }
        guard isSingleSelect(userSQL) else { return nil }
        if config.chartType == .scatter {
            return scatter(config, userSQL: userSQL, columns: columns)
        }
        let agg = aggExpr(config, columns: columns)
        guard let agg else { return nil }   // non-count needs a value col
        switch config.chartType {
        case .heatmap: return heatmap(config, userSQL: userSQL, columns: columns, agg: agg)
        default:       return categorical(config, userSQL: userSQL, columns: columns, agg: agg)
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

    /// Binning expression for an axis column: the truncation/identity expr, plus
    /// whether numeric width_bucket binning applies (handled at query assembly).
    private static func axisExpr(_ config: ChartConfig, _ col: ColumnDef, bin: AxisBin) -> (expr: String, numericBinned: Bool) {
        let kind = ColumnClassifier.kind(forDataType: col.dataType)
        let id = quoteIdent(col.name)
        let dt = col.dataType.lowercased()
        let isDateTruncable = dt.hasPrefix("date") || dt.hasPrefix("timestamp")
        if kind == .temporal, bin.temporal != .none, isDateTruncable {
            let unit = truncUnit(bin.temporal)
            let tz = dt.hasPrefix("timestamptz") || dt.contains("with time zone")
            let colExpr = tz ? "\(id) AT TIME ZONE 'UTC'" : id
            return ("date_trunc('\(unit)', \(colExpr))", false)
        }
        if kind == .numeric, binCountExpr(bin.numeric) != nil {
            return (id, true)   // width_bucket handled at query assembly
        }
        return (id, false)
    }
    private static func truncUnit(_ b: TemporalBin) -> String {
        switch b { case .hour: return "hour"; case .day, .auto: return "day"; case .week: return "week"
                   case .month: return "month"; case .year: return "year"; case .none: return "day" }
    }
    /// The SQL expression for a numeric axis's bucket count: a literal for fixed
    /// bins, or a scalar over the source for `.auto` (~√n, clamped 1…50 — mirrors
    /// the client's `numericBinCount`). Returns nil when binning is off.
    private static func binCountExpr(_ b: NumericBin) -> String? {
        switch b {
        case .off: return nil
        case .b10: return "10"
        case .b20: return "20"
        case .b50: return "50"
        case .auto: return "LEAST(50, GREATEST(1, CEIL(SQRT(COUNT(*)))::int))"
        }
    }
    /// Nominal count for the layout (the builder prefers the returned `_n`); nil
    /// means "not numeric-binned". `.auto` reports 0 as a placeholder.
    private static func binCountNominal(_ b: NumericBin) -> Int? {
        switch b { case .off: return nil; case .b10: return 10; case .b20: return 20; case .b50: return 50; case .auto: return 0 }
    }

    private static func categorical(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let catCol = resolve(config, .category, columns) else { return nil }
        let bin = config.resolvedBin(for: .category)
        let (catExpr, numericBinned) = axisExpr(config, catCol, bin: bin)
        let series = numericBinned ? nil : resolve(config, .series, columns)
        let layout = PushdownLayout(kind: .categorical,
                                    hasSeries: !numericBinned && series != nil,
                                    numericBins: numericBinned ? binCountNominal(bin.numeric) : nil)

        if numericBinned, let countExpr = binCountExpr(bin.numeric) {   // numeric width_bucket needs the range CTE
            let id = quoteIdent(catCol.name)
            let sql = """
            WITH _pharos_src AS ( \(userSQL) ),
                 _r AS (SELECT min(\(id)) AS lo, max(\(id)) AS hi, \(countExpr) AS n FROM _pharos_src)
            SELECT CASE WHEN _r.lo = _r.hi THEN 1
                        ELSE LEAST(width_bucket(\(id), _r.lo, _r.hi, _r.n), _r.n) END AS _bucket,
                   _r.lo AS _lo, _r.hi AS _hi, _r.n AS _n, \(agg) AS _val
            FROM _pharos_src, _r
            GROUP BY _bucket, _r.lo, _r.hi, _r.n
            ORDER BY _bucket LIMIT \(groupCap)
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

    private static func scatter(_ config: ChartConfig, userSQL: String, columns: [ColumnDef]) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let x = quoteIdent(xCol.name), y = quoteIdent(yCol.name)
        // Deterministic pseudo-random order so a re-run of the recorded SQL
        // reproduces the same sample (audit). ORDER BY random() would not.
        let sql = """
        SELECT \(x) AS _x, \(y) AS _y
        FROM ( \(userSQL) ) AS _pharos_src
        WHERE \(x) IS NOT NULL AND \(y) IS NOT NULL
        ORDER BY hashtext((_pharos_src.*)::text)
        LIMIT \(scatterSampleCap)
        """
        return PushdownQuery(sql: sql,
                             layout: PushdownLayout(kind: .scatter, hasSeries: false,
                                                    numericBins: nil, sampleCap: scatterSampleCap))
    }

    private static func heatmap(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let (xExpr, _) = axisExpr(config, xCol, bin: config.resolvedBin(for: .x))
        let (yExpr, _) = axisExpr(config, yCol, bin: config.resolvedBin(for: .y))
        let n = config.display.topNCategories
        // Per-axis dense_rank top-N (matches the client's 25×25 marginal ranking):
        // rank X values by their total, Y values by theirs, keep top-N of each,
        // select only cells in (topX)×(topY). Ties may slightly overshoot N.
        let sql = """
        WITH _agg AS (
          SELECT \(xExpr) AS _x, \(yExpr) AS _y, \(agg) AS _val
          FROM ( \(userSQL) ) AS _pharos_src
          GROUP BY 1, 2
        ),
        _xr AS ( SELECT _x, dense_rank() OVER (ORDER BY sum(_val) DESC) AS rk FROM _agg GROUP BY _x ),
        _yr AS ( SELECT _y, dense_rank() OVER (ORDER BY sum(_val) DESC) AS rk FROM _agg GROUP BY _y )
        SELECT a._x, a._y, a._val
        FROM _agg a
          JOIN _xr ON _xr._x IS NOT DISTINCT FROM a._x AND _xr.rk <= \(n)
          JOIN _yr ON _yr._y IS NOT DISTINCT FROM a._y AND _yr.rk <= \(n)
        ORDER BY a._val DESC
        LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil))
    }
}
