// Standalone test runner for FilterValueCount + FilterValueSort — no Xcode project.
// Compiled with the two source files by scripts/test-filter-value-counts.sh.
import Foundation

var failures = 0

func expectStr(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectArr(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // FilterValueCount.display
    expectStr(FilterValueCount(filtered: 10, total: 100).display, "10/100", "display differs → f/t")
    expectStr(FilterValueCount(filtered: 100, total: 100).display, "100", "display equal → total only")
    expectStr(FilterValueCount(filtered: 0, total: 0).display, "0", "display zero")
    expectStr(FilterValueCount(filtered: 1, total: 8).display, "1/8", "display small")

    // FilterValueSort.ordered — canonical (value-ascending) input
    let values = ["a", "b", "c"]
    let counts: [String: FilterValueCount] = [
        "a": FilterValueCount(filtered: 10, total: 100),
        "b": FilterValueCount(filtered: 3, total: 42),
        "c": FilterValueCount(filtered: 1, total: 8),
    ]
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .value, ascending: true),
              ["a", "b", "c"], "value asc → as-provided")
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .value, ascending: false),
              ["c", "b", "a"], "value desc → reversed")
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .count, ascending: false),
              ["a", "b", "c"], "count desc → heavy first")
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .count, ascending: true),
              ["c", "b", "a"], "count asc → light first")

    // Tie-break: equal filtered & total → stable by original order
    let tied = ["x", "y"]
    let tiedCounts: [String: FilterValueCount] = [
        "x": FilterValueCount(filtered: 5, total: 5),
        "y": FilterValueCount(filtered: 5, total: 5),
    ]
    expectArr(FilterValueSort.ordered(tied, counts: tiedCounts, field: .count, ascending: false),
              ["x", "y"], "count tie → stable original order")

    // Missing count entry → treated as zero, sorts last on desc
    expectArr(FilterValueSort.ordered(["a", "z"], counts: ["a": FilterValueCount(filtered: 4, total: 4)],
                                      field: .count, ascending: false),
              ["a", "z"], "missing count → zero")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
