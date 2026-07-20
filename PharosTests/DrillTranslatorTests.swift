import AppKit

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let cols = [ColumnDef(name: "status", dataType: "text"),
                ColumnDef(name: "age", dataType: "int4"),
                ColumnDef(name: "ts", dataType: "timestamptz")]

    // anyOf → col_N + isAnyOf + dataType.
    let a = DrillTranslator.filters(for: [.anyOf(ColumnRef(index: 0, name: "status"), ["done","open"])], columns: cols)
    expect(a.count == 1 && a[0].columnId == "col_0", "anyOf keyed col_0")
    expect(a[0].filter.op == .isAnyOf && a[0].filter.values == ["done","open"], "anyOf → isAnyOf values")
    expect(a[0].filter.dataType == "text", "dataType populated from ColumnDef")

    // blank → isAnyOf [blanksSentinel].
    let b = DrillTranslator.filters(for: [.blank(ColumnRef(index: 0, name: "status"))], columns: cols)
    expect(b[0].filter.op == .isAnyOf && b[0].filter.values == [ColumnFilter.blanksSentinel], "blank → sentinel")

    // numeric range → between.
    let r = DrillTranslator.filters(for: [.range(ColumnRef(index: 1, name: "age"), 10, 20, .numeric)], columns: cols)
    expect(r[0].columnId == "col_1" && r[0].filter.op == .between && r[0].filter.value == "10" && r[0].filter.value2 == "20", "numeric range → between 10..20")

    // temporal range → between with last-instant hi that dominates +00 strings.
    let t = DrillTranslator.filters(for: [.range(ColumnRef(index: 2, name: "ts"),
        DrillTranslatorTestsDate("2026-07-01T00:00:00Z"), DrillTranslatorTestsDate("2026-08-01T00:00:00Z") - 0.000001, .temporal)], columns: cols)
    expect(t[0].filter.op == .between, "temporal → between")
    expect(t[0].filter.value2! > "2026-07-31 12:00:00+00", "hi dominates a mid-bucket +00 cell string")
    expect(t[0].filter.value2! < "2026-08-01", "hi excludes the next bucket")

    // compound → one filter per column.
    let c = DrillTranslator.filters(for: [.compound([.anyOf(ColumnRef(index:0,name:"status"),["x"]), .anyOf(ColumnRef(index:1,name:"age"),["9"])])], columns: cols)
    expect(Set(c.map { $0.columnId }) == ["col_0","col_1"], "compound → two column filters")

    // same-column anyOf coalesced.
    let m = DrillTranslator.filters(for: [.anyOf(ColumnRef(index:0,name:"status"),["a"]), .anyOf(ColumnRef(index:0,name:"status"),["b"])], columns: cols)
    expect(m.count == 1 && Set(m[0].filter.values ?? []) == ["a","b"], "same-column anyOf coalesced")

    // overlap (temporal): start ≤ hi (lessOrEqual) AND end ≥ lo (greaterOrEqual).
    let cols2 = [ColumnDef(name: "id", dataType: "int4"), ColumnDef(name: "start", dataType: "timestamptz"), ColumnDef(name: "end", dataType: "timestamptz")]
    let ovT = DrillTranslator.filters(for: [.overlap(ColumnRef(index: 1, name: "start"), ColumnRef(index: 2, name: "end"), 0, 86400, .temporal)], columns: cols2)
    expect(ovT.count == 2, "overlap yields two filters")
    expect(ovT.contains { $0.columnId == "col_1" && $0.filter.op == .lessOrEqual }, "start ≤ hi")
    expect(ovT.contains { $0.columnId == "col_2" && $0.filter.op == .greaterOrEqual }, "end ≥ lo")
    // overlap (numeric): bounds are numeric literals, not ISO.
    let cols3 = [ColumnDef(name: "id", dataType: "int4"), ColumnDef(name: "s", dataType: "int8"), ColumnDef(name: "e", dataType: "int8")]
    let ovN = DrillTranslator.filters(for: [.overlap(ColumnRef(index: 1, name: "s"), ColumnRef(index: 2, name: "e"), 10, 20, .numeric)], columns: cols3)
    expect(ovN.first(where: { $0.columnId == "col_1" })?.filter.value == "20", "numeric hi literal on start ≤ hi")
    expect(ovN.first(where: { $0.columnId == "col_2" })?.filter.value == "10", "numeric lo literal on end ≥ lo")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}

// Helper: epoch for an ISO string (test only).
func DrillTranslatorTestsDate(_ iso: String) -> Double {
    let f = ISO8601DateFormatter(); return f.date(from: iso)!.timeIntervalSince1970
}
