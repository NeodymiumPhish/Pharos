// Standalone runner for ResultMemoryBudget — which held results spill to disk.
// Compiled by scripts/test-result-memory-budget.sh.
import Foundation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func held(_ id: String, _ mb: Int, shown: UInt64, displayed: Bool = false, spilled: Bool = false) -> ResultMemoryBudget.Held {
    .init(id: id, bytes: mb << 20, lastShown: shown, isDisplayed: displayed, isSpilled: spilled)
}

func runTests() {
    let MB = 1 << 20

    // MARK: The limit

    expect(ResultMemoryBudget.limitBytes(percent: 25, physicalMemory: 16 << 30), 4 << 30, "25% of 16 GB is 4 GB")
    expect(ResultMemoryBudget.limitBytes(percent: 0, physicalMemory: 16 << 30), nil, "0% turns the budget off")
    expect(ResultMemoryBudget.limitBytes(percent: 250, physicalMemory: 8 << 30), 8 << 30, "a percent over 100 is 100")

    // MARK: Under the limit nothing moves

    let few = [held("a", 100, shown: 1), held("b", 100, shown: 2)]
    expect(ResultMemoryBudget.toSpill(few, limit: 300 * MB), [], "under the limit: nothing spills")
    expect(ResultMemoryBudget.toSpill(few, limit: 200 * MB), [], "exactly at the limit: nothing spills")

    // MARK: Least recently shown first, until it fits

    let many = [
        held("old", 300, shown: 1),
        held("older", 300, shown: 0),
        held("recent", 300, shown: 5),
        held("shown", 300, shown: 9, displayed: true),
    ]
    expect(ResultMemoryBudget.toSpill(many, limit: 700 * MB), ["older", "old"],
           "oldest first, and only as many as it takes")
    expect(ResultMemoryBudget.toSpill(many, limit: 0), ["older", "old", "recent"],
           "a zero limit spills everything that may spill")

    // MARK: Never the displayed result, never twice

    let onlyShown = [held("a", 900, shown: 1, displayed: true), held("b", 900, shown: 2, displayed: true)]
    expect(ResultMemoryBudget.toSpill(onlyShown, limit: 100 * MB), [],
           "results on screen stay, even over the limit")
    let alreadyOut = [held("a", 900, shown: 1, spilled: true), held("b", 200, shown: 2)]
    expect(ResultMemoryBudget.toSpill(alreadyOut, limit: 300 * MB), [],
           "a spilled result does not count against the limit")
    expect(ResultMemoryBudget.toSpill(alreadyOut, limit: 100 * MB), ["b"],
           "a spilled result is never chosen again")

    // MARK: Ties are stable

    let ties = [held("b", 100, shown: 3), held("a", 100, shown: 3), held("c", 100, shown: 3)]
    expect(ResultMemoryBudget.toSpill(ties, limit: 100 * MB), ["a", "b"], "equal times go by id")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
