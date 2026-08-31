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
        ResultTabName.derived(lineRange: lineRange, sql: sql)
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
        if let result = queryResult {
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
