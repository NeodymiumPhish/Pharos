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

    // Value ties keep original relative order (deterministic stable tiebreak).
    let ties = mkData([("x", 5), ("y", 5), ("z", 5)])
    expect(labels(ChartSorter.sorted(ties, by: .valueDesc, chartType: .bar)) == ["x", "y", "z"], "value ties preserve original order (desc)")
    expect(labels(ChartSorter.sorted(ties, by: .valueAsc, chartType: .bar)) == ["x", "y", "z"], "value ties preserve original order (asc)")

    // Sparse series: s2 is missing category "b"; both series reorder to the same
    // sequence, and the missing category is simply absent (no crash).
    var sparse = ChartData()
    sparse.series = [
        ChartSeries(name: "s1", points: [ChartPoint(xLabel: "a", xValue: nil, y: 1), ChartPoint(xLabel: "b", xValue: nil, y: 2), ChartPoint(xLabel: "c", xValue: nil, y: 3)]),
        ChartSeries(name: "s2", points: [ChartPoint(xLabel: "a", xValue: nil, y: 1), ChartPoint(xLabel: "c", xValue: nil, y: 1)]),
    ]
    let sp = ChartSorter.sorted(sparse, by: .categoryDesc, chartType: .bar)
    expect(sp.series[0].points.map { $0.xLabel } == ["c", "b", "a"], "sparse: full series reordered")
    expect(sp.series[1].points.map { $0.xLabel } == ["c", "a"], "sparse: subset series reordered, missing category absent")

    // Numeric-bin range labels spanning negatives sort by value, not lexically.
    let negBins = mkData([
        ("-100\u{2013}0", 1), ("-500\u{2013}-400", 1), ("0\u{2013}100", 1), ("-300\u{2013}-200", 1),
    ])
    expect(labels(ChartSorter.sorted(negBins, by: .categoryAsc, chartType: .bar))
           == ["-500\u{2013}-400", "-300\u{2013}-200", "-100\u{2013}0", "0\u{2013}100"],
           "numeric-bin labels sort by value across negatives (asc)")
    expect(labels(ChartSorter.sorted(negBins, by: .categoryDesc, chartType: .bar))
           == ["0\u{2013}100", "-100\u{2013}0", "-300\u{2013}-200", "-500\u{2013}-400"],
           "numeric-bin labels sort by value across negatives (desc)")
    // Non-numeric (plain) labels still sort lexically.
    let plain = mkData([("banana", 1), ("apple", 1), ("cherry", 1)])
    expect(labels(ChartSorter.sorted(plain, by: .categoryAsc, chartType: .bar)) == ["apple", "banana", "cherry"], "plain labels still sort lexically")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
