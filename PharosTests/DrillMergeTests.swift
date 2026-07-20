import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let x = ColumnRef(index: 0, name: "x"); let y = ColumnRef(index: 1, name: "y")

    let m1 = DrillMerge.merge([.anyOf(x, ["a"]), .anyOf(x, ["b", "a"])])
    if case .anyOf(_, let vs) = m1.first { expect(vs == ["a", "b"], "anyOf unioned + deduped") } else { expect(false, "anyOf unioned") }

    let m2 = DrillMerge.merge([.anyOf(x, ["a"]), .blank(x)])
    if case .anyOf(_, let vs) = m2.first { expect(vs.contains(PharosBlanks.sentinel) && vs.contains("a"), "blank folds to sentinel in anyOf") }
    else { expect(false, "blank folds to sentinel") }

    let m3 = DrillMerge.merge([.blank(x)])
    if case .blank = m3.first { expect(true, "lone blank stays blank") } else { expect(false, "lone blank stays blank") }

    let m4 = DrillMerge.merge([.range(x, 0, 10, .numeric), .range(x, 10, 20, .numeric)])
    if case .range(_, let lo, let hi, _) = m4.first { expect(lo == 0 && hi == 20, "ranges coalesced") } else { expect(false, "ranges coalesced") }

    let m5 = DrillMerge.merge([.compound([.anyOf(x, ["a"]), .anyOf(y, ["p"])]), .compound([.anyOf(x, ["b"]), .anyOf(y, ["q"])])])
    expect(m5.count == 2, "two columns yield two merged keys")

    // range + lone blank on one column → keep the range, drop the null (a
    // range-OR-null can't be expressed as one filter; ANDing them matches nothing).
    let m6 = DrillMerge.merge([.range(x, 0, 10, .numeric), .blank(x)])
    expect(m6.count == 1, "range+blank on one column collapses to a single key")
    if case .range = m6.first { expect(true, "range kept when blank also present") } else { expect(false, "range kept") }

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
