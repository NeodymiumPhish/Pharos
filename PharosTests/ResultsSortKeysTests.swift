// Standalone test runner for ResultsSortKeys — the precomputed-key column sort.
// Compiled with the implementation by scripts/test-results-sort-keys.sh.
import Foundation

var failures = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func cells(_ values: [String?]) -> ResultTable { ResultTable(rows: values.map { [$0] }) }

/// The comparator `ResultsSortController` used before precomputed keys, kept
/// here as the reference: for DISTINCT values the new order must equal it.
/// It reads cells from the table one comparison at a time.
func referenceOrder(rows: ResultTable, column: Int, kind: ResultsSortKeys.Kind, ascending: Bool) -> [Int] {
    func numericValue(_ value: String) -> Double { Double(value) ?? 0 }
    let less: (String, String) -> Bool
    switch kind {
    case .numeric: less = { numericValue($0) < numericValue($1) }
    case .boolean: less = { $0 < $1 }
    case .text: less = { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var out = Array(0..<rows.rowCount)
    out.sort { a, b in
        let valA = rows.string(a, column)
        let valB = rows.string(b, column)
        let nullA = valA == nil
        let nullB = valB == nil
        if nullA || nullB { return !nullA && nullB }
        guard let valA, let valB else { return false }
        return ascending ? less(valA, valB) : less(valB, valA)
    }
    return out
}

func runTests() {
    // MARK: Numeric

    let nums = cells(["10", "9", nil, "-1.5", "100", "abc"])
    // "abc" does not parse and counts as 0, as before.
    expect(ResultsSortKeys.order(rows: nums, column: 0, kind: .numeric, ascending: true),
           [3, 5, 1, 0, 4, 2], "numeric ascending, NULL last, unparsable = 0")
    expect(ResultsSortKeys.order(rows: nums, column: 0, kind: .numeric, ascending: false),
           [4, 0, 1, 5, 3, 2], "numeric descending, NULL still last")

    // MARK: Text

    let text = cells(["b", "A10", nil, "a2", "a"])
    expect(ResultsSortKeys.order(rows: text, column: 0, kind: .text, ascending: true),
           [4, 3, 1, 0, 2], "text uses localizedStandardCompare (a < a2 < A10 < b)")
    expect(ResultsSortKeys.order(rows: text, column: 0, kind: .text, ascending: false),
           [0, 1, 3, 4, 2], "text descending, NULL last")

    // MARK: Boolean

    let bools = cells(["t", nil, "f", "f", "t"])
    expect(ResultsSortKeys.order(rows: bools, column: 0, kind: .boolean, ascending: true),
           [2, 3, 0, 4, 1], "boolean: f before t, ties by row")
    expect(ResultsSortKeys.order(rows: bools, column: 0, kind: .boolean, ascending: false),
           [0, 4, 2, 3, 1], "boolean descending: ties keep row order")

    // MARK: Ties and NULLs are stable in both directions

    let ties = cells(["x", nil, "x", "y", nil, "x"])
    expect(ResultsSortKeys.order(rows: ties, column: 0, kind: .text, ascending: true),
           [0, 2, 5, 3, 1, 4], "equal keys and NULLs keep data-row order (ascending)")
    expect(ResultsSortKeys.order(rows: ties, column: 0, kind: .text, ascending: false),
           [3, 0, 2, 5, 1, 4], "equal keys and NULLs keep data-row order (descending)")

    // MARK: Short rows count as NULL

    let short = ResultTable(rows: [["1", "5"], ["2"], ["3", "1"]])
    expect(ResultsSortKeys.order(rows: short, column: 1, kind: .numeric, ascending: true),
           [2, 0, 1], "a row too short for the column sorts as NULL")
    expect(ResultsSortKeys.order(rows: short, column: 5, kind: .numeric, ascending: true),
           [0, 1, 2], "a column past the last one sorts as NULL")

    // MARK: Same order as the old comparator for distinct values

    var rng = SystemRandomNumberGenerator()
    let distinctNums = Array(Set((0..<2000).map { _ in Int.random(in: -1_000_000...1_000_000, using: &rng) }))
    let numRows = ResultTable(rows: distinctNums.map { [String($0)] })
    for ascending in [true, false] {
        expect(ResultsSortKeys.order(rows: numRows, column: 0, kind: .numeric, ascending: ascending),
               referenceOrder(rows: numRows, column: 0, kind: .numeric, ascending: ascending),
               "numeric matches the old comparator (ascending: \(ascending))")
    }
    let distinctText = Array(Set((0..<2000).map { _ in "row \(Int.random(in: 0...10_000_000, using: &rng))" }))
    let textRows = ResultTable(rows: distinctText.map { [$0] })
    for ascending in [true, false] {
        expect(ResultsSortKeys.order(rows: textRows, column: 0, kind: .text, ascending: ascending),
               referenceOrder(rows: textRows, column: 0, kind: .text, ascending: ascending),
               "text matches the old comparator (ascending: \(ascending))")
    }

    // MARK: Timing (information only, never a failure)

    if ProcessInfo.processInfo.environment["SORT_BENCH"] == "1" {
        let n = 200_000
        let bigNum = ResultTable(rows: (0..<n).map { _ in [String(Double.random(in: 0...1e6))] })
        let bigText = ResultTable(rows: (0..<n).map { _ in ["value \(Int.random(in: 0...10_000_000))"] })
        func time(_ label: String, _ body: () -> [Int]) {
            let start = DispatchTime.now()
            _ = body()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            print("BENCH \(label): \(String(format: "%.0f", ms)) ms")
        }
        time("numeric old (\(n))") { referenceOrder(rows: bigNum, column: 0, kind: .numeric, ascending: true) }
        time("numeric new (\(n))") { ResultsSortKeys.order(rows: bigNum, column: 0, kind: .numeric, ascending: true) }
        time("text old (\(n))") { referenceOrder(rows: bigText, column: 0, kind: .text, ascending: true) }
        time("text new (\(n))") { ResultsSortKeys.order(rows: bigText, column: 0, kind: .text, ascending: true) }
    }

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
