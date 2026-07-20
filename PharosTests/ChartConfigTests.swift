// Standalone test runner for ChartConfig — no Xcode project involvement.
// Compiled with Pharos/Models/Charts/ChartTypes.swift, ChartConfig.swift,
// and Pharos/Models/QueryResult.swift by scripts/test-chart-config.sh.
import Foundation

var failures = 0

func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    // Codable round-trip, incl. [ChartColumnRole: ColumnRef] as a JSON object.
    var cfg = ChartConfig(chartType: .bar)
    cfg.mappings[.category] = ColumnRef(index: 0, name: "month")
    cfg.mappings[.value] = ColumnRef(index: 1, name: "revenue")
    cfg.aggregation = .sum

    let data = try! JSONEncoder().encode(cfg)
    let json = String(decoding: data, as: UTF8.self)
    expect(json.contains("\"category\""), "mappings encode role keys as JSON object")
    let back = try! JSONDecoder().decode(ChartConfig.self, from: data)
    expect(back.chartType == .bar, "chartType round-trips")
    expect(back.mappings[.value]?.index == 1, "ColumnRef round-trips by index")
    expect(back.mappings[.value]?.name == "revenue", "ColumnRef round-trips name")

    // PersistedResultViewState round-trip.
    let state = PersistedResultViewState(chartConfig: cfg, viewMode: .chart)
    let sdata = try! JSONEncoder().encode(state)
    let sback = try! JSONDecoder().decode(PersistedResultViewState.self, from: sdata)
    expect(sback.viewMode == .chart, "viewMode round-trips")
    expect(sback.chartConfig?.chartType == .bar, "nested config round-trips")

    // infer(): a categorical + a numeric column → bar with those mapped.
    let cols = [ColumnDef(name: "month", dataType: "text"),
                ColumnDef(name: "revenue", dataType: "numeric")]
    let inferred = ChartConfig.infer(from: cols)
    expect(inferred.mappings[.category]?.name == "month", "infer picks categorical for category")
    expect(inferred.mappings[.value]?.name == "revenue", "infer picks numeric for value")

    // validate(): a re-run that drops the value column clears that role.
    let newCols = [ColumnDef(name: "month", dataType: "text")]
    var stale = cfg
    stale.validate(against: newCols)
    expect(stale.mappings[.value] == nil, "validate clears role whose column vanished")
    expect(stale.mappings[.category]?.index == 0, "validate keeps still-valid role")

    // numericBin round-trips.
    var nb = ChartConfig(chartType: .bar)
    nb.numericBin = .b20
    let nbData = try! JSONEncoder().encode(nb)
    expect(try! JSONDecoder().decode(ChartConfig.self, from: nbData).numericBin == .b20, "numericBin round-trips")

    // Backward compat: a phase-1 blob WITHOUT numericBin decodes with .auto default.
    // Note: [ChartColumnRole: ColumnRef] is not CodingKeyRepresentable, so Swift
    // encodes/decodes it as a flat alternating array, not a JSON object — hence
    // "mappings":[] here (matches actual phase-1 persisted shape), not "{}".
    let legacy = #"{"chartType":"bar","mappings":[],"aggregation":"sum","temporalBin":"auto","display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let old = try! JSONDecoder().decode(ChartConfig.self, from: Data(legacy.utf8))
    expect(old.numericBin == .auto, "legacy config defaults numericBin to .auto")
    expect(old.chartType == .bar, "legacy config still decodes chartType")

    // heatmap is a valid chart type.
    expect(ChartType(rawValue: "heatmap") == .heatmap, "heatmap chart type decodes")

    // serverAggregation + lastServerRun round-trip.
    var sa = ChartConfig(chartType: .bar)
    sa.serverAggregation = true
    sa.lastServerRun = LastServerRun(sql: "SELECT 1", executedAt: "2026-07-17T00:00:00Z", rowCount: 5, truncated: false)
    let saData = try! JSONEncoder().encode(sa)
    let saBack = try! JSONDecoder().decode(ChartConfig.self, from: saData)
    expect(saBack.serverAggregation == true, "serverAggregation round-trips")
    expect(saBack.lastServerRun?.rowCount == 5, "lastServerRun round-trips")
    // legacy blob (no phase-3 keys) still decodes.
    let legacy3 = #"{"chartType":"bar","mappings":[],"aggregation":"sum","temporalBin":"auto","numericBin":"auto","display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let old3 = try! JSONDecoder().decode(ChartConfig.self, from: Data(legacy3.utf8))
    expect(old3.serverAggregation == false && old3.lastServerRun == nil, "legacy config defaults phase-3 fields")

    // axisBins: per-axis granularity round-trips; resolvedBin falls back to globals.
    var ab = ChartConfig(chartType: .heatmap, temporalBin: .month, numericBin: .b20)
    ab.axisBins[.x] = AxisBin(temporal: .day, numeric: .auto)
    let abData = try! JSONEncoder().encode(ab)
    let abBack = try! JSONDecoder().decode(ChartConfig.self, from: abData)
    expect(abBack.axisBins[.x]?.temporal == .day, "axisBins[.x] round-trips")
    expect(abBack.resolvedBin(for: .x).temporal == .day, "resolvedBin(.x) uses axisBins override")
    expect(abBack.resolvedBin(for: .y).temporal == .month, "resolvedBin(.y) falls back to global temporalBin")
    expect(abBack.resolvedBin(for: .y).numeric == .b20, "resolvedBin(.y) falls back to global numericBin")
    // legacy blob (no axisBins) → empty, global behavior preserved.
    let legacy4 = #"{"chartType":"heatmap","mappings":[],"aggregation":"count","temporalBin":"month","numericBin":"20","display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let old4 = try! JSONDecoder().decode(ChartConfig.self, from: Data(legacy4.utf8))
    expect(old4.axisBins.isEmpty, "legacy config has empty axisBins")
    expect(old4.resolvedBin(for: .x).temporal == .month, "legacy resolvedBin uses globals")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
