// Standalone test runner for what a Results History row SAYS — in particular
// for a row whose query failed.
//
// The point of this file is the accessibility label. A failed row is marked
// with a warning glyph, and a glyph is invisible to a screen reader, so the
// row's spoken label has to name the failure in words. There is a project
// lesson about exactly that, and a lesson is not a test, so here is the test.
//
// Compiled with HistoryRowText.swift and QueryHistoryStatus.swift by
// scripts/test-history-row-text.sh. Pure Foundation — no AppKit, no FFI.
import Foundation

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
        print("FAIL \(name)  expected true")
    }
}

private func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)  expected false")
    }
}

private func expectContains(_ haystack: String, _ needle: String, _ name: String) {
    if haystack.contains(needle) { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  \(haystack.debugDescription) does not contain \(needle.debugDescription)")
    }
}

/// A successful row, built the way the navigator builds one.
private func okRow(
    columnCount: Int64? = 6,
    tableNames: String = "public.users",
    rowCount: Int64? = 1234
) -> HistoryRowText.LegacyRow {
    HistoryRowText.legacyRow(
        status: QueryHistoryStatus.ok,
        errorMessage: nil,
        columnCount: columnCount,
        tableNames: tableNames,
        firstSQLLine: "SELECT * FROM users",
        flatSQL: "SELECT * FROM users",
        rowCount: rowCount,
        connectionName: "prod-db",
        relativeTime: "2 min ago"
    )
}

/// A failed row: no columns, no rows, and a message instead.
private func failedRow(
    status: String = QueryHistoryStatus.error,
    message: String? = "relation \"userz\" does not exist",
    tableNames: String = ""
) -> HistoryRowText.LegacyRow {
    HistoryRowText.legacyRow(
        status: status,
        errorMessage: message,
        columnCount: nil,
        tableNames: tableNames,
        firstSQLLine: "SELECT * FROM userz",
        flatSQL: "SELECT * FROM userz",
        rowCount: nil,
        connectionName: "prod-db",
        relativeTime: "2 min ago"
    )
}

func runTests() {
    // MARK: - The word each status carries

    expectTrue(HistoryRowText.statusLabel(QueryHistoryStatus.ok) == nil,
               "statusLabel: a success carries no word")
    expectEqual(HistoryRowText.statusLabel(QueryHistoryStatus.error) ?? "", "Failed",
                "statusLabel: error")
    expectEqual(HistoryRowText.statusLabel(QueryHistoryStatus.cancelled) ?? "", "Cancelled",
                "statusLabel: cancelled")
    // A status from a newer build must not read as a success — the same rule
    // `HistoryStatusScope::Failed` applies in the store, so a row can never
    // fall out of both scopes.
    expectEqual(HistoryRowText.statusLabel("something-new") ?? "", "Failed",
                "statusLabel: an unknown status is a failure, not a success")

    // MARK: - A successful row reads exactly as it always has

    let ok = okRow()
    expectEqual(ok.primary, "6 Columns – public.users", "ok: primary is the subject")
    expectFalse(ok.isFailed, "ok: no glyph")
    expectEqual(ok.tooltip, "1,234 Rows – prod-db – SELECT * FROM users", "ok: tooltip")
    expectEqual(ok.accessibilityLabel, "6 Columns – public.users, prod-db, 2 min ago",
                "ok: spoken label")

    let okNoTable = okRow(columnCount: nil, tableNames: "", rowCount: nil)
    expectEqual(okNoTable.primary, "SELECT * FROM users",
                "ok: falls back to the first line of SQL")
    expectEqual(okNoTable.tooltip, "prod-db – SELECT * FROM users",
                "ok: no row count, no row-count clause")

    let okOne = okRow(columnCount: 1, rowCount: 1)
    expectEqual(okOne.primary, "1 Column – public.users", "ok: singular column")
    expectContains(okOne.tooltip, "1 Row –", "ok: singular row")

    // MARK: - A failed row

    let bad = failedRow()
    expectTrue(bad.isFailed, "failed: the glyph is on")
    expectEqual(bad.primary, "Failed – SELECT * FROM userz",
                "failed: the word comes first, then the subject")
    expectEqual(bad.tooltip,
                "Failed: relation \"userz\" does not exist – prod-db – SELECT * FROM userz",
                "failed: the message leads the tooltip")

    // THE test. The glyph says "this failed" to everyone who can see it; this
    // says it to everyone else. A spoken label that matched the successful
    // form would leave a screen-reader user with no way to tell the two apart.
    expectEqual(bad.accessibilityLabel,
                "Failed, relation \"userz\" does not exist, SELECT * FROM userz, prod-db, 2 min ago",
                "failed: the spoken label NAMES the failure")
    expectContains(bad.accessibilityLabel, "Failed",
                   "failed: the spoken label is not the glyph's job")

    let cancelled = failedRow(status: QueryHistoryStatus.cancelled, message: "cancelled by user")
    expectEqual(cancelled.primary, "Cancelled – SELECT * FROM userz",
                "cancelled: its own word, not \"Failed\"")
    expectContains(cancelled.accessibilityLabel, "Cancelled",
                   "cancelled: spoken as cancelled")

    // A failure with nothing to say is still a row that says it failed.
    let silent = failedRow(message: nil)
    expectEqual(silent.tooltip, "Failed – prod-db – SELECT * FROM userz",
                "failed: no message, no empty clause")
    expectEqual(silent.accessibilityLabel,
                "Failed, SELECT * FROM userz, prod-db, 2 min ago",
                "failed: no message, still spoken as a failure")

    let blank = failedRow(message: "")
    expectEqual(blank.tooltip, "Failed – prod-db – SELECT * FROM userz",
                "failed: a blank message is not a clause either")

    // A failed run that still knew its table keeps the subject.
    let named = failedRow(tableNames: "public.users")
    expectEqual(named.primary, "Failed – public.users",
                "failed: the table name is the subject when there is one")

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
