import AppKit

/// Represents a single result produced by executing a SQL segment.
/// Distinct from QueryTab (which is an editor tab).
struct ResultTab: Identifiable {
    let id: String
    var segmentIndex: Int
    let sql: String
    /// Raw editor segment text (still containing `{{var}}` tokens) captured at
    /// execution time. Used ONLY to re-locate this query's segment in the editor.
    /// Distinct from `sql`, which holds the substituted text that actually ran.
    let rawSQL: String
    var lineRange: ClosedRange<Int>  // 1-based, captured at execution time
    let color: NSColor
    let timestamp: Date

    var customLabel: String?

    /// Whether the user has ever had this result on screen.
    ///
    /// Only read by the result-tab limit (Settings ▸ Results ▸ Result tabs),
    /// which closes the OLDEST tab nobody has looked at and nobody has named
    /// — a tab the user has seen, or has renamed, is theirs and is never
    /// taken away to make room.
    var hasBeenViewed: Bool = false
    var queryResult: QueryResult?
    var executeResult: ExecuteResult?
    var executionTimeMs: UInt64 = 0

    /// History-source metadata. Set only on the result tab that holds the
    /// rows of a re-opened query history entry; the grid's history banner is
    /// shown only when this specific result tab is the active one.
    var historySchema: String?
    var historyTimestamp: String?

    /// The `query_history` row this result was recorded as, when it has one.
    ///
    /// The address a rename is persisted to (`PharosCore.updateResultMeta`
    /// takes exactly this id). `queryResult?.historyEntryId` almost serves and
    /// deliberately is not used: it is nil for a statement, which reports its
    /// history id on `ExecuteResult` instead, and nil again for a restored
    /// "SQL only" stub, which has a stored row but no rows in memory. Nil means
    /// there is nothing to write to, not that the result is invalid — a rename
    /// still applies on screen.
    var historyResultId: String?

    /// Captured grid state (column widths, scroll position, sort, filters, selection).
    var gridState: ResultsGridState?

    /// Cell edits made in this result and not yet applied.
    ///
    /// Beside `gridState` and captured and restored on the same path, so
    /// switching result tabs and coming back does not lose a change the user
    /// made — the rows in memory have not moved, and the set is keyed on their
    /// data indices.
    ///
    /// Deliberately NOT in the workspace snapshot. A pending edit is a change
    /// the user has not agreed to make yet, and restoring one from disk days
    /// later — against rows that may since have changed — would put an
    /// unreviewed UPDATE in front of them with no memory of writing it.
    var pendingEdits = PendingCellEdits()

    // MARK: - Plan tabs

    /// The decoded `EXPLAIN` plan, when this tab holds one.
    ///
    /// A plan tab is a result tab like any other — same bar, same close, same
    /// selection — but it carries neither rows nor an affected count, so
    /// `plan != nil` is what tells every consumer to show the plan view instead
    /// of the grid. A separate `ResultViewMode` case was the obvious
    /// alternative and is deliberately not used: that enum is persisted as the
    /// grid/chart preference of a *restored* result, and a plan is never
    /// restored (see `planJSON`).
    var plan: QueryPlan?

    /// The server's own `EXPLAIN (FORMAT JSON)` text, for the copy button.
    var planJSON: String?

    /// Whether the plan carries measured numbers (⌥⇧⌘E) or estimates only (⇧⌘E).
    var planIsAnalyze: Bool = false

    /// A plan tab shows a plan, not rows.
    var isPlan: Bool { plan != nil }

    /// Chart configuration for this result (nil until the user opens Chart mode).
    var chartConfig: ChartConfig?

    /// Whether this result tab currently shows the grid or a chart.
    var resultViewMode: ResultViewMode = .grid

    /// Total row count reported by the source (live `QueryResult.rowCount` on
    /// execute, `WorkspaceResultMeta.rowCount` on reopen). Used by the chart
    /// banner to show "N of M loaded rows" when only a subset is in memory.
    var totalRowCountHint: Int?

    /// Whether the editor text has been modified since this result was produced.
    var isStale: Bool = false

    /// Short label for the tab, e.g. "L1-3: users" or a custom name for browse
    /// actions. The name the user renamed it to, if any, otherwise the name
    /// derived from the query.
    var label: String { customLabel ?? automaticLabel }

    /// The name derived from the query itself, with no custom name applied.
    ///
    /// Split out of `label` for the rename dialog, which prefills with the name
    /// on screen: a user who opens it and confirms without typing would
    /// otherwise freeze this string as a custom name, and the tab would silently
    /// stop following its statement as the editor text moves. `ResultTabName`
    /// compares against this to refuse that.
    ///
    /// The rule itself lives in `ResultTabName`, beside the rename rule that
    /// must compare against it, and where it is tested without AppKit.
    var automaticLabel: String {
        let derived = ResultTabName.derived(lineRange: lineRange, sql: sql)
        // A plan tab sits beside the result tabs of the same statement, so the
        // derived name alone would name two tabs identically. The prefix goes
        // in front of the whole derivation rather than replacing it, so the
        // line reference the user navigates by is still there: "Plan L3: users".
        guard isPlan else { return derived }
        return String(localized: "Plan \(derived)")
    }

    // MARK: - Color Palette

    /// Cycling color palette for result tab indicators.
    static let palette: [NSColor] = [
        .systemBlue,
        .systemPurple,
        .systemTeal,
        .systemIndigo,
        .systemMint,
        .systemCyan,
        .systemBrown,
        .systemPink,
    ]

    @MainActor private static var colorIndex = 0

    /// Returns the next color in the cycling palette.
    @MainActor static func nextColor() -> NSColor {
        let color = palette[colorIndex % palette.count]
        colorIndex += 1
        return color
    }

    /// Reset the color cycle (e.g. when all result tabs are cleared).
    @MainActor static func resetColorCycle() {
        colorIndex = 0
    }
}

extension ResultTab {
    /// The view-model handed to the vertical result-tabs panel. The mapping
    /// lives here (not in the cell file) because it reads QueryResult /
    /// ExecuteResult, which the standalone cell test cannot link.
    var rowModel: ResultTabRowModel {
        let counts: String
        if let plan {
            // A plan has no rows and no columns, so the size caption reports
            // what it does have: how many nodes the tree holds.
            counts = CountedNounText.phrase(plan.nodeCount, "node")
        } else if let result = queryResult {
            counts = ResultTabRowText.countsText(
                columnCount: result.columns.count,
                rowCount: totalRowCountHint ?? result.rowCount
            )
        } else if let exec = executeResult {
            counts = ResultTabRowText.affectedText(rowsAffected: exec.rowsAffected)
        } else {
            counts = ""
        }
        return ResultTabRowModel(id: id, label: label, color: color, countsText: counts, isStale: isStale)
    }
}
