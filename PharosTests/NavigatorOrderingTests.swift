// Standalone test runner for NavigatorOrdering — how the Database Navigator
// orders schemas and the objects inside them, and when it auto-expands.
// Compiled by scripts/test-navigator-ordering.sh. No outline view, no database.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private typealias Object = NavigatorOrdering.Object

private let objects: [Object] = [
    Object(name: "orders", kindRank: 0, sizeBytes: 500, rowEstimate: 10),
    Object(name: "Accounts", kindRank: 0, sizeBytes: 100, rowEstimate: 90),
    Object(name: "v_active", kindRank: 1, sizeBytes: 900, rowEstimate: 5),
    Object(name: "audit", kindRank: 0, sizeBytes: nil, rowEstimate: nil),
]

private func names(_ list: [Object]) -> [String] { list.map(\.name) }

private func testKindThenName() {
    expectEqual(names(NavigatorOrdering.sorted(objects, by: .kindThenName)),
                ["Accounts", "audit", "orders", "v_active"],
                "tables first by name, then views — today's order")
    // Case-insensitive, which is what "by name" means to a person.
    expectEqual(names(NavigatorOrdering.sorted(
        [Object(name: "b", kindRank: 0), Object(name: "A", kindRank: 0)], by: .kindThenName)),
        ["A", "b"], "name comparison ignores case")
}

private func testName() {
    expectEqual(names(NavigatorOrdering.sorted(objects, by: .name)),
                ["Accounts", "audit", "orders", "v_active"],
                "by name puts the view in among the tables")
    let mixed = [Object(name: "zz", kindRank: 1), Object(name: "aa", kindRank: 0)]
    expectEqual(names(NavigatorOrdering.sorted(mixed, by: .name)), ["aa", "zz"], "kind is ignored")
}

private func testSize() {
    expectEqual(names(NavigatorOrdering.sorted(objects, by: .size)),
                ["v_active", "orders", "Accounts", "audit"],
                "largest first, and the unmeasured object falls to the end")
    // The defect this rule exists to prevent: an unknown size must not read
    // as zero, or a table would claim to be the smallest until it is measured
    // and the list would reshuffle underneath the user.
    let unknownFirst = [
        Object(name: "unmeasured", kindRank: 0, sizeBytes: nil),
        Object(name: "tiny", kindRank: 0, sizeBytes: 1),
    ]
    expectEqual(names(NavigatorOrdering.sorted(unknownFirst, by: .size)), ["tiny", "unmeasured"],
                "an unknown size sorts last, not as zero")
    // A tie is broken by name, so the order is stable across rebuilds.
    let tied = [
        Object(name: "b", kindRank: 0, sizeBytes: 10),
        Object(name: "a", kindRank: 0, sizeBytes: 10),
    ]
    expectEqual(names(NavigatorOrdering.sorted(tied, by: .size)), ["a", "b"], "equal sizes are ordered by name")
}

private func testRowEstimate() {
    expectEqual(names(NavigatorOrdering.sorted(objects, by: .rowEstimate)),
                ["Accounts", "orders", "v_active", "audit"],
                "most rows first, unknown last")
}

private func testSchemas() {
    let schemas = ["public", "audit", "Billing"]
    expectEqual(NavigatorOrdering.sortedSchemas(schemas, by: .name, defaultSchema: "public"),
                ["audit", "Billing", "public"], "by name, ignoring case")
    expectEqual(NavigatorOrdering.sortedSchemas(schemas, by: .defaultFirst, defaultSchema: "public"),
                ["public", "audit", "Billing"], "the default schema is lifted to the top")
    expectEqual(NavigatorOrdering.sortedSchemas(schemas, by: .defaultFirst, defaultSchema: "no_such"),
                ["audit", "Billing", "public"], "a default that is not in the list changes nothing")
    expectEqual(NavigatorOrdering.sortedSchemas(schemas, by: .defaultFirst, defaultSchema: nil),
                ["audit", "Billing", "public"], "no default schema changes nothing")
    expectEqual(NavigatorOrdering.sortedSchemas([], by: .defaultFirst, defaultSchema: "public"), [],
                "an empty list stays empty")
}

private func testAutoExpand() {
    expectEqual(NavigatorOrdering.shouldAutoExpand(childCount: 12, enabled: true, threshold: 500), true,
                "a small schema expands")
    expectEqual(NavigatorOrdering.shouldAutoExpand(childCount: 500, enabled: true, threshold: 500), true,
                "the threshold itself is included")
    expectEqual(NavigatorOrdering.shouldAutoExpand(childCount: 501, enabled: true, threshold: 500), false,
                "one over the threshold does not expand — expanding it blocks the main thread")
    expectEqual(NavigatorOrdering.shouldAutoExpand(childCount: 1, enabled: false, threshold: 500), false,
                "the switch wins over the threshold")
    expectEqual(NavigatorOrdering.shouldAutoExpand(childCount: 0, enabled: true, threshold: 0), true,
                "an empty schema expands at any threshold")
}

private func testLabels() {
    expectEqual(ObjectSortMode.allCases.count, 4, "four object sort modes")
    expectEqual(SchemaSortMode.allCases.count, 2, "two schema sort modes")
    expectEqual(NavigatorDoubleClickAction.allCases.count, 4, "four double-click actions")
    expectEqual(ObjectSortMode.kindThenName.rawValue, "kindThenName", "the stored value is camelCase")
    for mode in ObjectSortMode.allCases { expectEqual(mode.displayLabel.isEmpty, false, "\(mode.rawValue) has a label") }
    for mode in SchemaSortMode.allCases { expectEqual(mode.displayLabel.isEmpty, false, "\(mode.rawValue) has a label") }
    for mode in NavigatorDoubleClickAction.allCases { expectEqual(mode.displayLabel.isEmpty, false, "\(mode.rawValue) has a label") }
}

func runTests() {
    testKindThenName()
    testName()
    testSize()
    testRowEstimate()
    testSchemas()
    testAutoExpand()
    testLabels()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
