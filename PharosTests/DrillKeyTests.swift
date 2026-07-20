// Standalone test for DrillKey. Compiled with ChartTypes.swift + DrillKey.swift.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let ref = ColumnRef(index: 2, name: "status")
    let a = DrillKey.anyOf(ref, ["done", "open"])
    let b = DrillKey.blank(ref)
    let r = DrillKey.range(ColumnRef(index: 0, name: "age"), 10, 20, .numeric)
    let c = DrillKey.compound([a, b])

    expect(a.columnRefs == [ref], "anyOf exposes its ref")
    expect(c.columnRefs.count == 2, "compound exposes child refs")
    if case .range(_, let lo, let hi, let kind) = r { expect(lo == 10 && hi == 20 && kind == .numeric, "range payload") }
    else { expect(false, "range payload") }

    let ov = DrillKey.overlap(ColumnRef(index: 1, name: "start"), ColumnRef(index: 2, name: "end"), 100, 200, .temporal)
    expect(ov.columnRefs.map { $0.name } == ["start", "end"], "overlap exposes both refs")
    if case .overlap(_, _, let lo, let hi, let kind) = ov { expect(lo == 100 && hi == 200 && kind == .temporal, "overlap payload") }
    else { expect(false, "overlap payload") }

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
