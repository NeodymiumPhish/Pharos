// Standalone test runner for ChartAggregator.
// Compiled by scripts/test-chart-aggregator.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// Helper: build a QueryResult where every cell is a PG-text string (as in prod).
func makeResult(_ columns: [(String, String)], _ rows: [[String?]]) -> QueryResult {
    let cols = columns.map { ColumnDef(name: $0.0, dataType: $0.1) }
    let anyRows = rows.map { row in row.map { AnyCodable($0 as Any?) } }
    return QueryResult(columns: cols, rows: anyRows, rowCount: rows.count,
                       executionTimeMs: 0, hasMore: false, historyEntryId: nil)
}

func runTests() {
    // --- Bar: group by category, SUM value ---
    let sales = makeResult([("month", "text"), ("revenue", "numeric")],
                           [["Jan", "100"], ["Feb", "200"], ["Jan", "50"]])
    var cfg = ChartConfig(chartType: .bar, temporalBin: .none)
    cfg.mappings[.category] = ColumnRef(index: 0, name: "month")
    cfg.mappings[.value] = ColumnRef(index: 1, name: "revenue")
    cfg.aggregation = .sum
    let bar = ChartAggregator.aggregate(sales, cfg)
    expect(bar.series.count == 1, "bar: single series")
    let jan = bar.series[0].points.first { $0.xLabel == "Jan" }
    expect(jan?.y == 150, "bar: Jan summed to 150")
    expect(bar.plottedRowCount == 3, "bar: plotted 3 loaded rows")

    // --- count aggregation ignores value numerics ---
    var countCfg = cfg; countCfg.aggregation = .count
    let counted = ChartAggregator.aggregate(sales, countCfg)
    expect(counted.series[0].points.first { $0.xLabel == "Jan" }?.y == 2, "count: Jan appears twice")

    // --- duplicate column names resolve by index ---
    let dup = makeResult([("id", "text"), ("id", "numeric")],
                         [["a", "10"], ["a", "5"]])
    var dupCfg = ChartConfig(chartType: .bar, temporalBin: .none)
    dupCfg.mappings[.category] = ColumnRef(index: 0, name: "id")
    dupCfg.mappings[.value] = ColumnRef(index: 1, name: "id")
    dupCfg.aggregation = .sum
    let dupOut = ChartAggregator.aggregate(dup, dupCfg)
    expect(dupOut.series[0].points.first { $0.xLabel == "a" }?.y == 15, "dup names resolve by index")

    // --- temporal binning: two timestamps same month collapse to one bucket ---
    let ts = makeResult([("ts", "timestamptz"), ("v", "numeric")],
                        [["2024-01-01 01:00:00+00", "1"],
                         ["2024-01-31 23:00:00+00", "2"],
                         ["2024-02-05 10:00:00+00", "4"]])
    var tcfg = ChartConfig(chartType: .line, temporalBin: .month)
    tcfg.mappings[.category] = ColumnRef(index: 0, name: "ts")
    tcfg.mappings[.value] = ColumnRef(index: 1, name: "v")
    tcfg.aggregation = .sum
    let tout = ChartAggregator.aggregate(ts, tcfg)
    expect(tout.series[0].points.count == 2, "binning: 3 rows → 2 monthly buckets")

    // --- top-N capping rolls remainder into Other ---
    var many: [[String?]] = []
    for i in 0..<30 { many.append(["c\(i)", "\(30 - i)"]) }  // descending values
    let big = makeResult([("c", "text"), ("v", "numeric")], many)
    var bigCfg = cfg; bigCfg.display.topNCategories = 5
    let bigOut = ChartAggregator.aggregate(big, bigCfg)
    expect(bigOut.wasTruncated, "topN: truncation flagged")
    expect(bigOut.series[0].points.contains { $0.xLabel == "Other" }, "topN: Other bucket present")

    // --- top-N under COUNT: Other must sum the dropped categories' counts ---
    var manyCount: [[String?]] = []
    for i in 0..<10 { manyCount.append(["k\(i)", "1"]) }   // 10 distinct cats, 1 row each
    let bigC = makeResult([("k", "text"), ("v", "numeric")], manyCount)
    var cCfg = ChartConfig(chartType: .bar, temporalBin: .none)
    cCfg.mappings[.category] = ColumnRef(index: 0, name: "k")
    cCfg.mappings[.value] = ColumnRef(index: 1, name: "v")
    cCfg.aggregation = .count
    cCfg.display.topNCategories = 3
    let cOut = ChartAggregator.aggregate(bigC, cCfg)
    let otherPt = cOut.series[0].points.first { $0.xLabel == "Other" }
    expect(otherPt?.y == 7, "count+topN: Other = 7 dropped rows")   // 10 total - 3 kept

    // --- gantt: label + start + end, no aggregation ---
    let tasks = makeResult([("task", "text"), ("s", "date"), ("e", "date")],
                           [["A", "2024-01-01", "2024-01-05"],
                            ["B", "2024-01-03", "2024-01-08"]])
    var gcfg = ChartConfig(chartType: .gantt)
    gcfg.mappings[.label] = ColumnRef(index: 0, name: "task")
    gcfg.mappings[.start] = ColumnRef(index: 1, name: "s")
    gcfg.mappings[.end] = ColumnRef(index: 2, name: "e")
    let gout = ChartAggregator.aggregate(tasks, gcfg)
    expect(gout.ganttBars.count == 2, "gantt: two bars")
    expect(gout.ganttBars[0].end > gout.ganttBars[0].start, "gantt: end after start")

    // --- degenerate: value column all null ---
    let nullish = makeResult([("m", "text"), ("v", "numeric")], [["Jan", nil], ["Feb", nil]])
    let nout = ChartAggregator.aggregate(nullish, cfg)
    expect(nout.emptyReason == .allNull, "degenerate: allNull")

    // --- degenerate: missing required role ---
    let noValue = ChartConfig(chartType: .bar)
    let mout = ChartAggregator.aggregate(sales, noValue)
    expect(mout.emptyReason == .noColumns, "degenerate: noColumns when role unmapped")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
