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

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
