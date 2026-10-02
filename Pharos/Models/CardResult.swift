import AppKit

/// What a query card's last successful run produced, and how the user is
/// looking at it. A card holds at most one: a new run replaces it, and a run
/// after an edit puts its result on the new version's card instead.
///
/// `id` IS the card's id, so "the result the grid shows" and "the card whose
/// results are shown" are the same value (`CardDocument.displayedCardId`).
struct CardResult: Identifiable {
    /// The card's id.
    let id: String
    /// The run this result came from. A page loaded for an older run must
    /// not be merged into a newer one.
    let runId: String
    /// The substituted SQL that ran.
    let sql: String
    /// The card's text when the run started, `{{var}}` tokens and all.
    let rawSQL: String
    let timestamp: Date

    /// Whether the user has ever had this result on screen. The result limit
    /// (Settings ▸ Results) lets go only of results nobody has looked at.
    var hasBeenViewed: Bool = false
    var queryResult: QueryResult?
    var executeResult: ExecuteResult?
    var executionTimeMs: UInt64 = 0

    /// History-source metadata, for a result restored from a workspace or a
    /// history entry: the banner shows the original schema and time.
    var historySchema: String?
    var historyTimestamp: String?

    /// The `query_history` row this result was recorded as. The address a
    /// rename and the chart state are persisted to. Nil means there is nothing
    /// to write to, not that the result is invalid.
    var historyResultId: String?

    /// Captured grid state (column widths, scroll position, sort, filters, selection).
    var gridState: ResultsGridState?

    /// Cell edits made in this result and not yet applied. Captured and
    /// restored with `gridState`, never persisted: a pending edit is a change
    /// the user has not agreed to make yet.
    var pendingEdits = PendingCellEdits()

    // MARK: - Plan

    /// The card's `EXPLAIN` plan, when it has been explained. A plan is a view
    /// of the card's results, not a run: it never locks the card or makes a
    /// version, and it is never written to history.
    var plan: QueryPlan?
    /// The server's own `EXPLAIN (FORMAT JSON)` text, for the copy button.
    var planJSON: String?
    /// Whether the plan carries measured numbers (⌥⇧⌘E) or estimates only (⇧⌘E).
    var planIsAnalyze: Bool = false
    /// The results area shows the plan rather than the grid or chart.
    var showsPlan: Bool = false

    /// Chart configuration for this result (nil until the user opens Chart mode).
    var chartConfig: ChartConfig?
    /// Whether this result shows the grid or a chart.
    var resultViewMode: ResultViewMode = .grid

    /// Total row count reported by the source (live `QueryResult.rowCount` on
    /// execute, `WorkspaceResultMeta.rowCount` on reopen). The chart banner
    /// says "N of M loaded rows" from it.
    var totalRowCountHint: Int?

    /// Rows or an affected count are in memory.
    var hasPayload: Bool { queryResult != nil || executeResult != nil }

    init(cardId: String, runId: String = UUID().uuidString, sql: String, rawSQL: String, timestamp: Date = Date()) {
        self.id = cardId
        self.runId = runId
        self.sql = sql
        self.rawSQL = rawSQL
        self.timestamp = timestamp
    }
}
