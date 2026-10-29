// Standalone test runner for ChartGridFilters (the chart honours the grid's
// filters, minus its own drill). Compiled by scripts/test-chart-grid-filters.sh.
// Drives the REAL ResultsColumnFilterController and DisplayRowPipeline.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private final class Rows: ResultsColumnFilterControllerDelegate {
    var filterableRows: [[AnyCodable]]
    var filterableColumnCategories: [PGTypeCategory]
    init(_ rows: [[String]], _ cats: [PGTypeCategory]) {
        filterableRows = rows.map { $0.map { AnyCodable($0) } }
        filterableColumnCategories = cats
    }
}

private func anyOf(_ col: String, _ values: [String]) -> ColumnFilter {
    ColumnFilter(columnName: col, op: .isAnyOf, value: "", value2: nil, values: values, dataType: "text")
}

func runTests() {
    // ip, port, service — the open-ports shape.
    let rows = Rows([["10.0.0.1", "80", "http"], ["10.0.0.1", "443", "https"],
                     ["10.0.0.2", "80", "http"], ["10.0.0.3", "22", "ssh"]],
                    [.string, .numeric, .string])
    let fc = ResultsColumnFilterController()
    fc.delegate = rows

    // No filter: every row (nil).
    expect(ChartGridFilters.rowIndices(rowCount: 4, controller: fc, filters: fc.activeFilters, forceShowTagged: nil) == nil,
           "no grid filter → chart plots every row")

    // A manual filter: the chart keeps the grid's rows, in query order.
    fc.setFilter(anyOf("service", ["http"]), forColumn: "col_2")
    let manual = ChartGridFilters.filters(active: fc.activeFilters, drillColumns: [], displaced: [:])
    expect(ChartGridFilters.rowIndices(rowCount: 4, controller: fc, filters: manual, forceShowTagged: nil) == [0, 2],
           "manual filter service=http → rows 0 and 2")

    // A drill on another column is left out: the chart still plots both http rows.
    fc.setFilter(anyOf("ip", ["10.0.0.2"]), forColumn: "col_0")
    let withDrill = ChartGridFilters.filters(active: fc.activeFilters, drillColumns: ["col_0"], displaced: [:])
    expect(withDrill["col_0"] == nil && withDrill["col_2"] != nil, "drill column dropped, manual kept")
    expect(ChartGridFilters.rowIndices(rowCount: 4, controller: fc, filters: withDrill, forceShowTagged: nil) == [0, 2],
           "chart ignores its own drill filter")

    // A drill that displaced a manual filter: the manual filter counts.
    fc.setFilter(anyOf("service", ["ssh"]), forColumn: "col_2")   // drill replaced service=http
    let displaced = ChartGridFilters.filters(active: fc.activeFilters, drillColumns: ["col_0", "col_2"],
                                             displaced: ["col_2": anyOf("service", ["http"])])
    expect(ChartGridFilters.rowIndices(rowCount: 4, controller: fc, filters: displaced, forceShowTagged: nil) == [0, 2],
           "displaced manual filter replaces the drill's filter")

    // Force-show re-admits a tagged row the column filter dropped.
    expect(ChartGridFilters.rowIndices(rowCount: 4, controller: fc, filters: manual, forceShowTagged: [3]) == [0, 2, 3],
           "force-shown tagged row is plotted, in query order")

    // Banner.
    expect(ChartGridFilters.bannerText(kept: 2, loaded: 4, total: 4) == "Charting 2 of 4 loaded rows that match the grid's filters.",
           "banner names the grid's filters")
    expect(ChartGridFilters.bannerText(kept: 4, loaded: 4, total: 10) == "Charting 4 of 10 loaded rows, aggregated client-side.",
           "banner without filters keeps the old text")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
