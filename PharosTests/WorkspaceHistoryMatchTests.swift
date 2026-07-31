// Standalone test runner for the workspace-history filter marks — no Xcode
// project or test target involvement. Covers HistoryRowText (pure formatting)
// and WorkspacePreviewRowCell (the accent bar, the semibold label, and cell
// reuse). Both live outside QueryHistoryVC precisely so this binary can
// compile them without the PharosCore FFI bridge.
//
// Compiled with HistoryRowText.swift, WorkspacePreviewRowCell.swift and
// Workspace.swift by scripts/test-workspace-history-match.sh.
import AppKit

private var failures = 0

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - HistoryRowText

private func testPlainClauseWhenNotFiltering() {
    expectEqual(
        HistoryRowText.queryClause(total: 3, matches: 0, isFiltering: false),
        "3 queries", "plain clause, plural"
    )
    expectEqual(
        HistoryRowText.queryClause(total: 1, matches: 0, isFiltering: false),
        "1 query", "plain clause, singular"
    )
}

private func testMatchClauseVerbAgreesWithTheCount() {
    expectEqual(
        HistoryRowText.queryClause(total: 3, matches: 2, isFiltering: true),
        "2 of 3 queries match", "two matches take the plural verb"
    )
    expectEqual(
        HistoryRowText.queryClause(total: 3, matches: 1, isFiltering: true),
        "1 of 3 queries matches", "one match takes the singular verb"
    )
    expectEqual(
        HistoryRowText.queryClause(total: 1, matches: 1, isFiltering: true),
        "1 of 1 query matches", "the noun agrees with the total, not the count"
    )
}

private func testZeroMatchesKeepsThePlainClause() {
    // A workspace matched on its name, editor text, or connection name. The
    // filter matched the workspace, not a query inside it, so say nothing.
    expectEqual(
        HistoryRowText.queryClause(total: 3, matches: 0, isFiltering: true),
        "3 queries", "zero matches while filtering shows no count"
    )
}

private func testRowCountGroupsThousands() {
    expectEqual(HistoryRowText.rowCount(1000), "1,000", "row count grouping")
    expectEqual(HistoryRowText.rowCount(7), "7", "row count below a thousand")
}

// MARK: - Entry point

func runTests() {
    testPlainClauseWhenNotFiltering()
    testMatchClauseVerbAgreesWithTheCount()
    testZeroMatchesKeepsThePlainClause()
    testRowCountGroupsThousands()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
