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

    // --- week-label boundary fix: 2026-12-29 is ISO week 1 of 2027 ---
    let wk = makeResult([("ts","timestamptz"),("v","numeric")],
                        [["2026-12-29 00:00:00+00","1"]])
    var wkc = ChartConfig(chartType: .line, temporalBin: .week)
    wkc.mappings[.category] = ColumnRef(index: 0, name: "ts")
    wkc.mappings[.value] = ColumnRef(index: 1, name: "v")
    let wkOut = ChartAggregator.aggregate(wk, wkc)
    expect(wkOut.series[0].points.first?.xLabel == "2027-W01", "week label uses yearForWeekOfYear")

    // --- count histogram needs only a category (no value mapping) ---
    let ages = makeResult([("age","int4")], [["21"],["24"],["37"],["39"],["55"]])
    var hc = ChartConfig(chartType: .bar, numericBin: .b10)
    hc.mappings[.category] = ColumnRef(index: 0, name: "age")
    hc.aggregation = .count
    let hout = ChartAggregator.aggregate(ages, hc)
    expect(hout.emptyReason == nil, "count histogram works with no value mapping")
    expect(hout.series[0].points.allSatisfy { $0.drill != nil }, "each bin carries a drill key")
    if case .range(_, _, _, .numeric)? = hout.series[0].points.first?.drill {} else { expect(false, "numeric bin drill is a numeric range") }

    // --- low-cardinality numeric stays discrete under .auto ---
    let rating = makeResult([("r","int4"),("v","numeric")],
                            [["1","5"],["2","3"],["1","2"],["3","9"]])
    var rc = ChartConfig(chartType: .bar, numericBin: .auto)
    rc.mappings[.category] = ColumnRef(index: 0, name: "r")
    rc.mappings[.value] = ColumnRef(index: 1, name: "v")
    rc.aggregation = .sum
    let rout = ChartAggregator.aggregate(rating, rc)
    expect(rout.series[0].points.contains { $0.xLabel == "1" }, "low-cardinality numeric stays discrete (label '1', not a range)")

    // --- discrete category drill uses anyOf; null uses blank ---
    let cats = makeResult([("s","text"),("v","numeric")], [["done","1"],["open","2"],[nil,"3"]])
    var cc = ChartConfig(chartType: .bar); cc.aggregation = .count
    cc.mappings[.category] = ColumnRef(index: 0, name: "s")
    let cout = ChartAggregator.aggregate(cats, cc)
    let donePt = cout.series[0].points.first { $0.xLabel == "done" }
    if case .anyOf(_, let vals)? = donePt?.drill { expect(vals == ["done"], "discrete drill anyOf carries raw label") }
    else { expect(false, "discrete drill is anyOf") }
    let nullPt = cout.series[0].points.first { $0.xLabel.isEmpty || $0.xLabel == "(null)" }
    if case .blank? = nullPt?.drill {} else { expect(false, "null category drill is .blank") }

    // --- Other bar drills the dropped labels ---
    var manyDrop: [[String?]] = []
    for i in 0..<30 { manyDrop.append(["c\(i)","\(30-i)"]) }
    let bigDrop = makeResult([("c","text"),("v","numeric")], manyDrop)
    var bc = ChartConfig(chartType: .bar); bc.aggregation = .sum
    bc.mappings[.category] = ColumnRef(index: 0, name: "c"); bc.mappings[.value] = ColumnRef(index: 1, name: "v")
    bc.display.topNCategories = 5
    let bout = ChartAggregator.aggregate(bigDrop, bc)
    let otherDrillPt = bout.series[0].points.first { $0.xLabel == "Other" }
    if case .anyOf(_, let dropped)? = otherDrillPt?.drill { expect(dropped.count == 25, "Other drill lists the 25 dropped labels") }
    else { expect(false, "Other drill is anyOf of dropped labels") }

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
