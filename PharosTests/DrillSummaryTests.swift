import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let country = ColumnRef(index: 3, name: "dst_country")
    let proto = ColumnRef(index: 1, name: "protocol")
    let port = ColumnRef(index: 2, name: "dst_port")

    // Discrete counts, ordered by column index ascending.
    let heat: [DrillKey] = [.anyOf(proto, ["HTTPS", "DNS"]), .anyOf(country, ["DE", "SG"])]
    expect(DrillSummary.label(heat, prefix: "Filtered by Chart")
           == "Filtered by Chart — protocol (2); dst_country (2)", "discrete counts, index order")

    // Null bucket counts as one value.
    let withNull: [DrillKey] = [.anyOf(proto, ["HTTPS", PharosBlanks.sentinel])]
    expect(DrillSummary.parts(withNull).first?.detail == "(2)", "sentinel counts as a bucket")

    // Lone blank → (null).
    expect(DrillSummary.parts([.blank(proto)]).first?.detail == "(null)", "lone blank → (null)")

    // Range / overlap → (range).
    expect(DrillSummary.parts([.range(port, 0, 50, .numeric)]).first?.detail == "(range)", "range → (range)")
    let start = ColumnRef(index: 4, name: "started"); let end = ColumnRef(index: 5, name: "finished")
    let ov: [DrillKey] = [.overlap(start, end, 0, 100, .temporal)]
    expect(DrillSummary.parts(ov).first?.column == "started" && DrillSummary.parts(ov).first?.detail == "(range)",
           "overlap labelled by start column, (range)")

    // Compound (heatmap cell) flattens to two columns.
    let cell: [DrillKey] = [.compound([.anyOf(proto, ["HTTPS"]), .anyOf(country, ["DE"])])]
    expect(DrillSummary.parts(cell).count == 2, "compound flattens to per-column parts")

    // Empty → bare prefix.
    expect(DrillSummary.label([], prefix: "Filter in Grid") == "Filter in Grid", "empty selection → prefix only")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
