// Standalone runner for GridDerivedCache — when a card switch may reuse the
// sort order and tag map it computed earlier. Compiled by
// scripts/test-grid-derived-cache.sh.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected))\n  actual:   \(String(describing: actual))")
    }
}

func runTests() {
    let rows = UUID()
    let otherRows = UUID()
    let cache = GridDerivedCache<[Int: String]>(
        contentToken: rows, sortColumn: "col_2", sortAscending: false,
        sortedRows: [2, 0, 1], tagMap: [1: "tag"], tagGeneration: 7)

    // MARK: Sort order

    expectEqual(cache.sortedRows(contentToken: rows, column: "col_2", ascending: false), [2, 0, 1],
                "same rows, same sort: the kept order is reused")
    expectEqual(cache.sortedRows(contentToken: otherRows, column: "col_2", ascending: false), nil,
                "new rows (a re-run, a page, a refresh): sort again")
    expectEqual(cache.sortedRows(contentToken: rows, column: "col_3", ascending: false), nil,
                "another column: sort again")
    expectEqual(cache.sortedRows(contentToken: rows, column: "col_2", ascending: true), nil,
                "the other direction: sort again")

    let unsorted = GridDerivedCache<[Int: String]>(
        contentToken: rows, sortColumn: nil, sortAscending: true,
        sortedRows: nil, tagMap: nil, tagGeneration: nil)
    expectEqual(unsorted.sortedRows(contentToken: rows, column: "col_2", ascending: true), nil,
                "kept while unsorted: a sort asked for now is computed")

    // MARK: Tag map

    expectEqual(cache.tagMap(contentToken: rows, tagGeneration: 7), [1: "tag"],
                "same rows, same tag rules: the kept map is reused")
    expectEqual(cache.tagMap(contentToken: rows, tagGeneration: 8), nil,
                "a tag changed since: match again")
    expectEqual(cache.tagMap(contentToken: otherRows, tagGeneration: 7), nil,
                "new rows: match again")
    expectEqual(unsorted.tagMap(contentToken: rows, tagGeneration: 0), nil,
                "no complete map was kept (an async match was running): match again")

    let emptyMap = GridDerivedCache<[Int: String]>(
        contentToken: rows, sortColumn: nil, sortAscending: true,
        sortedRows: nil, tagMap: [:], tagGeneration: 3)
    expectEqual(emptyMap.tagMap(contentToken: rows, tagGeneration: 3), [:],
                "an EMPTY complete map is a real answer and is reused")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
