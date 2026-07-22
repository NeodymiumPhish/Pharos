// Standalone test for ChartSorter (pure). Compiled by scripts/test-chart-sorter.sh.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

private func mkData(_ pairs: [(String, Double)], name: String = "") -> ChartData {
    var d = ChartData()
    d.series = [ChartSeries(name: name, points: pairs.map { ChartPoint(xLabel: $0.0, xValue: nil, y: $0.1) })]
    return d
}
private func labels(_ d: ChartData) -> [String] { d.series.first?.points.map { $0.xLabel } ?? [] }

func runTests() {
    let base = mkData([("b", 3), ("a", 1), ("c", 2)])

    // queryOrder = identity.
    expect(labels(ChartSorter.sorted(base, by: .queryOrder, chartType: .bar)) == ["b", "a", "c"], "queryOrder preserves order")

    // categoryAsc / categoryDesc (lexical).
    expect(labels(ChartSorter.sorted(base, by: .categoryAsc, chartType: .bar)) == ["a", "b", "c"], "categoryAsc lexical")
    expect(labels(ChartSorter.sorted(base, by: .categoryDesc, chartType: .bar)) == ["c", "b", "a"], "categoryDesc lexical")

    // valueAsc / valueDesc (a=1, b=3, c=2).
    expect(labels(ChartSorter.sorted(base, by: .valueAsc, chartType: .bar)) == ["a", "c", "b"], "valueAsc by y")
    expect(labels(ChartSorter.sorted(base, by: .valueDesc, chartType: .bar)) == ["b", "c", "a"], "valueDesc by y")

    // Padded temporal labels sort chronologically under categoryAsc.
    let temporal = mkData([("2024-03", 5), ("2024-01", 5), ("2024-02", 5)])
    expect(labels(ChartSorter.sorted(temporal, by: .categoryAsc, chartType: .bar)) == ["2024-01", "2024-02", "2024-03"], "temporal labels sort chronologically")

    // "Other" pinned last regardless of sort.
    let withOther = mkData([("b", 3), ("Other", 99), ("a", 1)])
    expect(labels(ChartSorter.sorted(withOther, by: .categoryAsc, chartType: .bar)) == ["a", "b", "Other"], "Other pinned last (categoryAsc)")
    expect(labels(ChartSorter.sorted(withOther, by: .valueDesc, chartType: .bar)) == ["b", "a", "Other"], "Other pinned last (valueDesc)")

    // Multi-series: value = per-category total across series; all series reorder consistently.
    var multi = ChartData()
    multi.series = [
        ChartSeries(name: "s1", points: [ChartPoint(xLabel: "a", xValue: nil, y: 1), ChartPoint(xLabel: "b", xValue: nil, y: 1)]),
        ChartSeries(name: "s2", points: [ChartPoint(xLabel: "a", xValue: nil, y: 10), ChartPoint(xLabel: "b", xValue: nil, y: 0)]),
    ]
    let ms = ChartSorter.sorted(multi, by: .valueDesc, chartType: .bar)   // totals: a=11, b=1
    expect(ms.series[0].points.map { $0.xLabel } == ["a", "b"], "multi-series s1 reordered by total")
    expect(ms.series[1].points.map { $0.xLabel } == ["a", "b"], "multi-series s2 reordered consistently")

    // Non-applicable chart types = no-op.
    expect(labels(ChartSorter.sorted(base, by: .valueDesc, chartType: .scatter)) == ["b", "a", "c"], "scatter = no-op")
    expect(labels(ChartSorter.sorted(base, by: .valueDesc, chartType: .heatmap)) == ["b", "a", "c"], "heatmap = no-op")
    expect(labels(ChartSorter.sorted(base, by: .categoryAsc, chartType: .gantt)) == ["b", "a", "c"], "gantt = no-op")

    // Empty data = no crash, returned unchanged.
    let empty = ChartSorter.sorted(ChartData(), by: .valueDesc, chartType: .bar)
    expect(empty.series.isEmpty, "empty data returns empty, no crash")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
