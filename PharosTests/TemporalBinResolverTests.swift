// Standalone test runner for TemporalBinResolver + ChartConfig.resolvingAutoBins.
// Compiled by scripts/test-temporal-bin-resolver.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func makeResult(_ columns: [(String, String)], _ rows: [[String?]]) -> QueryResult {
    let cols = columns.map { ColumnDef(name: $0.0, dataType: $0.1) }
    let anyRows = rows.map { row in row.map { AnyCodable($0 as Any?) } }
    return QueryResult(columns: cols, rows: anyRows, rowCount: rows.count,
                       executionTimeMs: 0, hasMore: false, historyEntryId: nil)
}

func daily(_ days: Int, col: String = "day") -> QueryResult {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let start = cal.date(from: DateComponents(year: 2021, month: 1, day: 1))!
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm:ss+00"
    let rows = (0..<days).map { [f.string(from: cal.date(byAdding: .day, value: $0, to: start)!), "1"] }
    return makeResult([(col, "timestamptz"), ("v", "numeric")], rows)
}

func runTests() {
    let day = 86_400.0
    expect(TemporalBinResolver.unit(forSpanSeconds: 3600) == .hour, "an hour → hour")
    expect(TemporalBinResolver.unit(forSpanSeconds: 3 * day) == .hour, "3 days → hour")
    expect(TemporalBinResolver.unit(forSpanSeconds: 4 * day) == .day, "4 days → day")
    expect(TemporalBinResolver.unit(forSpanSeconds: 120 * day) == .day, "120 days → day")
    expect(TemporalBinResolver.unit(forSpanSeconds: 200 * day) == .week, "200 days → week")
    expect(TemporalBinResolver.unit(forSpanSeconds: 3 * 365 * day) == .month, "3 years → month")
    expect(TemporalBinResolver.unit(forSpanSeconds: 30 * 365 * day) == .year, "30 years → year")

    // span from a column: lexical extremes, not row order
    let r = makeResult([("ts", "timestamptz")],
                       [["2024-03-01 00:00:00+00"], ["2024-01-01 00:00:00+00"], [nil], ["2024-02-01 00:00:00+00"]])
    expect(TemporalBinResolver.span(of: r, column: ColumnRef(index: 0, name: "ts")) == 60 * day, "span ignores order and nulls")
    expect(TemporalBinResolver.span(of: r, column: ColumnRef(index: 3, name: "x")) == nil, "span nil for a bad index")
    let text = makeResult([("s", "text")], [["a"], ["b"]])
    expect(TemporalBinResolver.span(of: text, column: ColumnRef(index: 0, name: "s")) == nil, "span nil when nothing parses")

    // resolvingAutoBins: categorical chart
    let three = daily(3 * 365)
    var cfg = ChartConfig(chartType: .line)
    cfg.mappings[.category] = ColumnRef(index: 0, name: "day")
    cfg.mappings[.value] = ColumnRef(index: 1, name: "v")
    let resolved = cfg.resolvingAutoBins(for: three)
    expect(resolved.temporalBin == .month, "3 daily years → month")
    expect(cfg.temporalBin == .auto, "the stored config keeps .auto")
    var fixed = cfg; fixed.temporalBin = .day
    expect(fixed.resolvingAutoBins(for: three).temporalBin == .day, "an explicit unit is left alone")
    var none = cfg; none.temporalBin = .none
    expect(none.resolvingAutoBins(for: three).temporalBin == .none, "none is left alone")

    // a numeric category does not resolve
    var num = ChartConfig(chartType: .bar)
    num.mappings[.category] = ColumnRef(index: 1, name: "v")
    expect(num.resolvingAutoBins(for: three).temporalBin == .auto, "numeric category: auto untouched")

    // gantt resolves from start
    var g = ChartConfig(chartType: .gantt)
    g.mappings[.label] = ColumnRef(index: 1, name: "v"); g.mappings[.start] = ColumnRef(index: 0, name: "day")
    expect(g.resolvingAutoBins(for: daily(10)).temporalBin == .day, "gantt: 10 days → day")

    // heatmap resolves per axis
    var h = ChartConfig(chartType: .heatmap)
    h.mappings[.x] = ColumnRef(index: 0, name: "day"); h.mappings[.y] = ColumnRef(index: 1, name: "v")
    let hr = h.resolvingAutoBins(for: daily(30))
    expect(hr.axisBins[.x]?.temporal == .day, "heatmap x: auto → day")
    expect(hr.axisBins[.y] == nil, "heatmap y (numeric): untouched")
    expect(hr.resolvedBin(for: .x).numeric == .auto, "heatmap x keeps the global numeric bin")
    var hx = h; hx.axisBins[.x] = AxisBin(temporal: .year, numeric: .auto)
    expect(hx.resolvingAutoBins(for: daily(30)).axisBins[.x]?.temporal == .year, "heatmap explicit axis unit is kept")

    // through the aggregator: the daily series lands in months
    let agg = ChartAggregator.aggregate(three, resolved)
    expect(agg.series.first?.points.count == 36, "3 years of days aggregate to 36 month buckets")
    expect(agg.series.first?.points.first?.xLabel == "2021-01", "first bucket labelled as a month")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
