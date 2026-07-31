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

private func expectEqual(_ actual: CGFloat, _ expected: CGFloat, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectEqual(_ actual: NSColor, _ expected: NSColor, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - FFI decode

/// The exact payload Rust emits for one `WorkspaceSummary`, copied from the
/// `assert_eq!` in `matching_result_ids_serialises_as_matching_result_ids_camel_case`
/// (`pharos-core/src/db/sqlite.rs`). The two are a pair: the Rust test pins what
/// Rust produces, this one pins that Swift can read it.
///
/// `matchingResultIds` is non-optional on the Swift side, so a casing slip makes
/// every history load fail to decode at run time — an empty sidebar with no
/// compile-time signal on either side of the FFI.
private let rustWorkspaceSummaryJSON = """
{"id":"ws1","name":"prod-db","connectionName":"prod-db","distinctDbCount":1,\
"queryCount":1,"lastActivityAt":"2026-07-31T00:00:00Z","matchingResultIds":["h1"]}
"""

private func testWorkspaceSummaryDecodesRustPayload() {
    let decoder = JSONDecoder() // Matches JSONDecoder.pharos: no key strategy.
    guard let data = rustWorkspaceSummaryJSON.data(using: .utf8),
          let summary = try? decoder.decode(WorkspaceSummary.self, from: data)
    else {
        failures += 1
        print("FAIL WorkspaceSummary decodes the Rust payload")
        return
    }
    expectEqual(summary.id, "ws1", "decoded id")
    expectEqual(summary.matchingResultIds.joined(separator: ","), "h1", "decoded matchingResultIds")
    expectEqual("\(summary.queryCount)", "1", "decoded queryCount")
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
    expectEqual(HistoryRowText.rowCountText(1000), "1,000", "row count grouping")
    expectEqual(HistoryRowText.rowCountText(7), "7", "row count below a thousand")
}

/// A workspace whose editor holds text but that never ran a query. It is listed,
/// so its clause has to read sensibly with nothing to count.
private func testNoQueriesAtAll() {
    expectEqual(
        HistoryRowText.queryClause(total: 0, matches: 0, isFiltering: false),
        "0 queries", "a workspace with no executed query"
    )
}

// MARK: - WorkspacePreviewRowCell

private func makeMeta(
    id: String = "h1",
    sql: String = "SELECT * FROM orders",
    customLabel: String? = nil,
    tableNames: String? = nil,
    rowCount: Int? = nil,
    columnCount: Int? = nil,
    hasResults: Bool = true
) -> WorkspaceResultMeta {
    WorkspaceResultMeta(
        id: id, sql: sql, resultOrder: 0, colorIndex: 0, customLabel: customLabel,
        rowCount: rowCount, columnCount: columnCount, schema: nil, tableNames: tableNames,
        hasResults: hasResults, executionTimeMs: 5, executedAt: "2026-07-31T00:00:00Z",
        chartViewStateJson: nil, rawSql: nil
    )
}

/// A cell with a resolved layout. No window is needed: a view with a real frame
/// resolves its own subview constraints under `layoutSubtreeIfNeeded()`.
private func makeCell(width: CGFloat = 320, height: CGFloat = 34) -> WorkspacePreviewRowCell {
    let cell = WorkspacePreviewRowCell()
    cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
    return cell
}

private func testUnmatchedRowHasNoMark() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(), dotColor: .systemBlue, isMatch: false)
    expectTrue(cell.matchBar.isHidden, "unmatched row hides the bar")
    expectTrue(
        cell.primaryLabel.font == .systemFont(ofSize: 12),
        "unmatched row keeps the regular label font"
    )
}

private func testMatchedRowIsMarked() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(), dotColor: .systemBlue, isMatch: true)
    expectTrue(!cell.matchBar.isHidden, "matched row shows the bar")
    expectTrue(
        cell.primaryLabel.font == .systemFont(ofSize: 12, weight: .semibold),
        "matched row uses the semibold label font"
    )
}

/// The one test that catches the reuse defect: `makeView` recycles cells, so a
/// configure that only *adds* the mark leaves it on the next row. Two separate
/// cells would pass while the defect stayed.
private func testReusedCellDropsThePreviousRowsMark() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(id: "h1"), dotColor: .systemBlue, isMatch: true)
    cell.configure(meta: makeMeta(id: "h2"), dotColor: .systemBlue, isMatch: false)
    expectTrue(cell.matchBar.isHidden, "reused cell hides the bar again")
    expectTrue(
        cell.primaryLabel.font == .systemFont(ofSize: 12),
        "reused cell returns to the regular label font"
    )
}

private func testMatchBarLayoutDoesNotDisturbTheDot() {
    let cell = makeCell(height: 34)
    cell.configure(meta: makeMeta(), dotColor: .systemBlue, isMatch: true)
    cell.layoutSubtreeIfNeeded()
    expectEqual(cell.matchBar.frame.width, 3, "bar is 3pt wide")
    expectEqual(cell.matchBar.frame.height, 34, "bar spans the row height")
    expectEqual(cell.matchBar.frame.minX, 0, "bar sits on the leading edge")
    expectEqual(cell.dot.frame.minX, 8, "the dot is not pushed by the bar")
}

/// Without this, the whole visible feature can be deleted with a green suite:
/// an unfilled bar shows the row background and reads as no mark at all.
private func testMatchBarIsFilledWithTheAccentTint() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(), dotColor: .systemBlue, isMatch: true)
    expectEqual(cell.matchBar.fillColor, WorkspacePreviewRowCell.matchTint, "bar is filled with the match tint")
    expectTrue(cell.matchBar.borderWidth == 0, "bar draws no border")
    expectTrue(cell.matchBar.titlePosition == .noTitle, "bar draws no title")
}

/// The bar and the semibold font say nothing to assistive technology. One
/// recycled cell, because the unmatched path has to *clear* the label.
private func testAccessibilityLabelTracksTheMark() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(customLabel: "Revenue"), dotColor: .systemBlue, isMatch: true)
    expectEqual(
        cell.accessibilityLabel() ?? "<nil>",
        "Revenue, matches the filter", "matched row announces the match"
    )

    cell.configure(meta: makeMeta(customLabel: "Revenue"), dotColor: .systemBlue, isMatch: false)
    expectTrue(cell.accessibilityLabel() == nil, "reused cell clears the announcement")
}

/// Nothing read the dot colour, so deleting the assignment passed everything.
/// One recycled cell: the colour has to change on the second configure.
private func testDotColourFollowsTheResult() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(), dotColor: .systemBlue, isMatch: false)
    let first = cell.dot.layer?.backgroundColor
    cell.configure(meta: makeMeta(), dotColor: .systemPink, isMatch: false)
    let second = cell.dot.layer?.backgroundColor

    expectTrue(first != nil && second != nil, "the dot is filled on both configures")
    expectTrue(first != second, "the reused dot takes the new result's colour")
    expectTrue(second == NSColor.systemPink.cgColor, "the dot's colour is the one passed in")
}

/// The only test that exercises `hasResults: false`, and it does so on a
/// recycled cell so the tertiary colour cannot stick.
private func testSecondaryLabelColourFollowsHasResults() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(rowCount: 1, hasResults: false), dotColor: .systemBlue, isMatch: false)
    expectEqual(cell.secondaryLabel.textColor ?? .clear, .tertiaryLabelColor, "a row with no stored result dims its caption")

    cell.configure(meta: makeMeta(rowCount: 1, hasResults: true), dotColor: .systemBlue, isMatch: false)
    expectEqual(cell.secondaryLabel.textColor ?? .clear, .secondaryLabelColor, "the reused caption brightens again")
}

private func testLabelsPreferCustomLabelThenTableNamesThenSQL() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(customLabel: "Revenue", tableNames: "orders"), dotColor: .systemBlue, isMatch: false)
    expectEqual(cell.primaryLabel.stringValue, "Revenue", "custom label wins")

    cell.configure(meta: makeMeta(tableNames: "orders"), dotColor: .systemBlue, isMatch: false)
    expectEqual(cell.primaryLabel.stringValue, "orders", "table names come next")

    cell.configure(meta: makeMeta(sql: "  SELECT 1\nFROM t"), dotColor: .systemBlue, isMatch: false)
    expectEqual(cell.primaryLabel.stringValue, "SELECT 1", "first SQL line is the fallback")
}

/// SQLite hands back `""` rather than NULL for a label the user cleared, so an
/// empty string has to fall through exactly as a nil does.
private func testEmptyStringsFallThroughLikeNil() {
    let cell = makeCell()
    cell.configure(
        meta: makeMeta(customLabel: "", tableNames: "orders"),
        dotColor: .systemBlue, isMatch: false
    )
    expectEqual(cell.primaryLabel.stringValue, "orders", "an empty custom label falls through to table names")

    cell.configure(
        meta: makeMeta(sql: "  SELECT 1\nFROM t", customLabel: "", tableNames: ""),
        dotColor: .systemBlue, isMatch: false
    )
    expectEqual(cell.primaryLabel.stringValue, "SELECT 1", "both empty falls through to the first SQL line")
}

private func testSizeCaption() {
    let cell = makeCell()
    cell.configure(meta: makeMeta(rowCount: 1000, columnCount: 1), dotColor: .systemBlue, isMatch: false)
    expectEqual(cell.secondaryLabel.stringValue, "1 col · 1,000 rows", "caption pluralises each part")
}

// MARK: - Entry point

func runTests() {
    testWorkspaceSummaryDecodesRustPayload()
    testUnmatchedRowHasNoMark()
    testMatchedRowIsMarked()
    testReusedCellDropsThePreviousRowsMark()
    testMatchBarLayoutDoesNotDisturbTheDot()
    testMatchBarIsFilledWithTheAccentTint()
    testAccessibilityLabelTracksTheMark()
    testDotColourFollowsTheResult()
    testSecondaryLabelColourFollowsHasResults()
    testLabelsPreferCustomLabelThenTableNamesThenSQL()
    testEmptyStringsFallThroughLikeNil()
    testSizeCaption()
    testPlainClauseWhenNotFiltering()
    testMatchClauseVerbAgreesWithTheCount()
    testZeroMatchesKeepsThePlainClause()
    testNoQueriesAtAll()
    testRowCountGroupsThousands()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
