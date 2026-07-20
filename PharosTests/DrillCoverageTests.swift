import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let x = ColumnRef(index: 0, name: "x"); let y = ColumnRef(index: 1, name: "y")

    // anyOf membership.
    let mA: [DrillKey] = [.anyOf(x, ["a", "b"])]
    expect(DrillCoverage.covers(mA, .anyOf(x, ["a"])), "value in selection → lit")
    expect(!DrillCoverage.covers(mA, .anyOf(x, ["c"])), "value not in selection → dim")

    // null via sentinel.
    let mNull: [DrillKey] = [.anyOf(x, ["a", PharosBlanks.sentinel])]
    expect(DrillCoverage.covers(mNull, .blank(x)), "null mark lit when sentinel selected")

    // range containment (coalesced span lights in-between bins).
    let merged = DrillMerge.merge([.range(x, 0, 10, .numeric), .range(x, 40, 50, .numeric)])  // → [.range(x,0,50)]
    expect(DrillCoverage.covers(merged, .range(x, 20, 30, .numeric)), "in-between bin lit under coalesced span")
    expect(!DrillCoverage.covers(merged, .range(x, 50, 60, .numeric)), "bin outside span dim")

    // compound heatmap cell — cross product is honest.
    let mCross: [DrillKey] = [.anyOf(x, ["a", "b"]), .anyOf(y, ["p", "q"])]
    expect(DrillCoverage.covers(mCross, .compound([.anyOf(x, ["a"]), .anyOf(y, ["q"])])), "cross-product cell lit")
    expect(!DrillCoverage.covers(mCross, .compound([.anyOf(x, ["c"]), .anyOf(y, ["p"])])), "cell outside x-set dim")

    // dropped null: range + blank on one column merges to range only → null dims.
    let mDrop = DrillMerge.merge([.range(x, 0, 10, .numeric), .blank(x)])  // → [.range(x,0,10)]
    expect(!DrillCoverage.covers(mDrop, .blank(x)), "null dims when merge dropped it beside a range")

    // empty selection covers nothing (caller treats empty as 'all lit', not via covers()).
    expect(!DrillCoverage.covers([], .anyOf(x, ["a"])), "empty merged covers nothing")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
