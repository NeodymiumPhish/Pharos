// Standalone test for ServerChartDataBuilder. Compiled with QueryResult.swift,
// ChartTypes.swift, ChartConfig.swift, ColumnClassifier.swift, ChartData.swift,
// DrillKey.swift, ValueCoercion.swift, PushdownQuery.swift,
// ServerChartDataBuilder.swift.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

/// All cell values arrive as strings (mirrors the FFI's JSON-string cells).
func makeResult(_ cols: [(String, String)], _ rows: [[String?]], hasMore: Bool = false) -> QueryResult {
    let columns = cols.map { ColumnDef(name: $0.0, dataType: $0.1) }
    let anyRows = rows.map { r in r.map { AnyCodable($0) } }
    return QueryResult(columns: columns, rows: anyRows, rowCount: anyRows.count,
                        executionTimeMs: 0, hasMore: hasMore, historyEntryId: nil)
}

func runTests() {
    // MARK: categorical, single series
    do {
        let result = makeResult([("_cat", "text"), ("_val", "numeric")],
                                 [["a", "10"], ["b", "20"], [nil, "5"]])
        let catRef = ColumnRef(index: 0, name: "status")
        var cfg = ChartConfig(chartType: .bar)
        cfg.mappings[.category] = catRef
        let layout = PushdownLayout(kind: .categorical, hasSeries: false, numericBins: nil)

        let data = ServerChartDataBuilder.build(result, layout: layout, config: cfg)
        expect(data.series.count == 1, "categorical: single series")
        expect(data.series.first?.name == "", "categorical: series name empty")
        let pts = data.series.first?.points ?? []
        expect(pts.count == 3, "categorical: 3 points")
        expect(pts[0].xLabel == "a" && pts[0].y == 10, "categorical: point a")
        expect(pts[0].drill == .anyOf(catRef, ["a"]), "categorical: anyOf drill for a")
        expect(pts[1].xLabel == "b" && pts[1].y == 20, "categorical: point b")
        expect(pts[1].drill == .anyOf(catRef, ["b"]), "categorical: anyOf drill for b")
        expect(pts[2].xLabel == "" && pts[2].y == 5, "categorical: null point")
        expect(pts[2].drill == .blank(catRef), "categorical: blank drill for null")
        expect(data.plottedRowCount == 3, "categorical: plottedRowCount")
        expect(data.totalLoadedRowCount == result.rowCount, "categorical: totalLoadedRowCount")
        expect(data.wasTruncated == false, "categorical: not truncated")
    }

    // MARK: categorical with series (hasSeries)
    do {
        let result = makeResult([("_cat", "text"), ("_series", "text"), ("_val", "numeric")],
                                 [["a", "s1", "10"], ["a", "s2", "20"], ["b", "s1", "5"]])
        let catRef = ColumnRef(index: 0, name: "status")
        var cfg = ChartConfig(chartType: .bar)
        cfg.mappings[.category] = catRef
        cfg.mappings[.series] = ColumnRef(index: 1, name: "region")
        let layout = PushdownLayout(kind: .categorical, hasSeries: true, numericBins: nil)

        let data = ServerChartDataBuilder.build(result, layout: layout, config: cfg)
        expect(data.series.count == 2, "series: two series groups")
        expect(data.series.map(\.name) == ["s1", "s2"], "series: first-seen order")
        let s1 = data.series.first { $0.name == "s1" }!.points
        let s2 = data.series.first { $0.name == "s2" }!.points
        expect(s1.count == 2 && s1.map(\.xLabel) == ["a", "b"], "series: s1 has a,b")
        expect(s2.count == 1 && s2[0].xLabel == "a" && s2[0].y == 20, "series: s2 has a=20")
    }

    // MARK: numeric bins (width_bucket)
    do {
        // lo=0, hi=20, N=2 → width 10; bucket1 -> [0,10), bucket2 -> [10,20)
        let result = makeResult([("_bucket", "int4"), ("_lo", "numeric"), ("_hi", "numeric"), ("_val", "numeric")],
                                 [["2", "0", "20", "30"], ["1", "0", "20", "10"]])
        let catRef = ColumnRef(index: 3, name: "age")
        var cfg = ChartConfig(chartType: .bar)
        cfg.mappings[.category] = catRef
        let layout = PushdownLayout(kind: .categorical, hasSeries: false, numericBins: 2)

        let data = ServerChartDataBuilder.build(result, layout: layout, config: cfg)
        expect(data.series.count == 1, "numeric: single series")
        let pts = data.series.first?.points ?? []
        expect(pts.count == 2, "numeric: 2 points")
        expect(pts[0].xLabel == "0\u{2013}10", "numeric: ascending bucket 1 label  [\(pts.map(\.xLabel))]")
        expect(pts[0].y == 10, "numeric: bucket 1 value")
        expect(pts[0].drill == .range(catRef, 0, 10, .numeric), "numeric: bucket 1 range drill")
        expect(pts[1].xLabel == "10\u{2013}20", "numeric: ascending bucket 2 label")
        expect(pts[1].y == 30, "numeric: bucket 2 value")
        expect(pts[1].drill == .range(catRef, 10, 20, .numeric), "numeric: bucket 2 range drill")
        expect(data.plottedRowCount == 2, "numeric: plottedRowCount")
    }

    // MARK: numeric bins — fractional width label formatting
    do {
        // lo=0, hi=25, N=2 → width 12.5; bucket1 -> [0,12.5), bucket2 -> [12.5,25)
        let result = makeResult([("_bucket", "int4"), ("_lo", "numeric"), ("_hi", "numeric"), ("_val", "numeric")],
                                 [["1", "0", "25", "5"]])
        var cfg = ChartConfig(chartType: .bar)
        cfg.mappings[.category] = ColumnRef(index: 3, name: "age")
        let layout = PushdownLayout(kind: .categorical, hasSeries: false, numericBins: 2)
        let data = ServerChartDataBuilder.build(result, layout: layout, config: cfg)
        expect(data.series.first?.points.first?.xLabel == "0\u{2013}12.50", "numeric: 2dp label for fractional bound")
    }

    // MARK: heatmap
    do {
        let result = makeResult([("_x", "text"), ("_y", "text"), ("_val", "numeric")],
                                 [["a", "p", "1"], [nil, "q", "2"]])
        let xRef = ColumnRef(index: 0, name: "status")
        let yRef = ColumnRef(index: 2, name: "region")
        var cfg = ChartConfig(chartType: .heatmap)
        cfg.mappings[.x] = xRef
        cfg.mappings[.y] = yRef
        let layout = PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil)

        let data = ServerChartDataBuilder.build(result, layout: layout, config: cfg)
        expect(data.heatmapCells.count == 2, "heatmap: 2 cells")
        let c0 = data.heatmapCells[0]
        expect(c0.x == "a" && c0.y == "p" && c0.value == 1, "heatmap: cell 0 fields")
        expect(c0.drill == .compound([.anyOf(xRef, ["a"]), .anyOf(yRef, ["p"])]), "heatmap: cell 0 compound drill")
        let c1 = data.heatmapCells[1]
        expect(c1.x == "" && c1.y == "q" && c1.value == 2, "heatmap: cell 1 fields")
        expect(c1.drill == .compound([.blank(xRef), .anyOf(yRef, ["q"])]), "heatmap: cell 1 blank-x compound drill")
        expect(data.plottedRowCount == 2, "heatmap: plottedRowCount")
    }

    // MARK: truncation flows through from hasMore
    do {
        let result = makeResult([("_cat", "text"), ("_val", "numeric")], [["a", "1"]], hasMore: true)
        var cfg = ChartConfig(chartType: .bar)
        cfg.mappings[.category] = ColumnRef(index: 0, name: "status")
        let layout = PushdownLayout(kind: .categorical, hasSeries: false, numericBins: nil)
        let data = ServerChartDataBuilder.build(result, layout: layout, config: cfg)
        expect(data.wasTruncated == true, "hasMore true -> wasTruncated true")
    }

    // Scatter: raw _x/_y points, wasSampled when the row count hits the cap.
    let scLayout = PushdownLayout(kind: .scatter, hasSeries: false, numericBins: nil, sampleCap: 3)
    var scCfg = ChartConfig(chartType: .scatter)
    scCfg.mappings[.x] = ColumnRef(index: 0, name: "amt")
    scCfg.mappings[.y] = ColumnRef(index: 1, name: "age")
    let scRes = QueryResult(
        columns: [ColumnDef(name: "_x", dataType: "numeric"), ColumnDef(name: "_y", dataType: "numeric")],
        rows: [[AnyCodable("1.5"), AnyCodable("10")], [AnyCodable("2.0"), AnyCodable("20")], [AnyCodable("3.0"), AnyCodable("30")]],
        rowCount: 3, executionTimeMs: 1, hasMore: false, historyEntryId: nil)
    let scData = ServerChartDataBuilder.build(scRes, layout: scLayout, config: scCfg)
    expect(scData.series.first?.points.count == 3, "scatter maps 3 points")
    expect(scData.series.first?.points.first?.xValue == 1.5, "scatter reads _x as xValue")
    expect(scData.series.first?.points.first?.y == 10, "scatter reads _y as y")
    expect(scData.wasSampled == true, "row count == sampleCap → wasSampled")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
