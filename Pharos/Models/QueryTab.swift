import Foundation

/// Snapshot of the results grid view state for a tab.
struct ResultsGridState {
    var columnWidths: [String: CGFloat]
    var columnOrder: [String]?  // Column identifiers in display order (nil = default)
    var sortColumn: String?
    var sortAscending: Bool
    var columnFilters: [String: ColumnFilter]
    var scrollPosition: NSPoint
    var selectedRows: IndexSet
}

/// A single query currently executing for a tab. Multiple may be in flight
/// concurrently. `id` matches the `query_id` registered in pharos-core's
/// `running_queries` registry, so cancellation/lookup is symmetric across FFI.
struct RunningQuery: Identifiable, Equatable {
    let id: String
    let normalizedSQL: String       // trimmed + whitespace-collapsed, used for dedup
    let segmentIndex: Int           // -1 = direct-SQL (no parseable segment), >= 0 = segment
    let lineRange: ClosedRange<Int> // 1-based editor line range, for popover label
    let startTime: CFTimeInterval   // CACurrentMediaTime() at launch
}

/// Represents a single query editor tab.
struct QueryTab: Identifiable {
    let id: String
    var name: String
    var connectionId: String?
    var schemaName: String?
    var sql: String
    var cursorPosition: Int = 0
    var isDirty: Bool = false
    /// All in-flight queries launched from this tab, ordered by `startTime` ascending.
    var runningQueries: [RunningQuery] = []
    /// Computed: any in-flight query means this tab is executing.
    var isExecuting: Bool { !runningQueries.isEmpty }
    var result: QueryResult?
    var executeResult: ExecuteResult?
    var error: String?
    var savedQueryId: String?
    var historySchema: String?
    var historyTimestamp: String?
    var gridState: ResultsGridState?
    var paneId: String?
    /// Filesystem URL this tab was opened from, if any. Set when the tab is
    /// opened from a `.sql` or other plain-text file; ⌘S writes back here.
    var sourceURL: URL?

    init(id: String = UUID().uuidString, name: String = "Query 1", connectionId: String? = nil, schemaName: String? = nil, sql: String = "", paneId: String? = nil) {
        self.id = id
        self.name = name
        self.connectionId = connectionId
        self.schemaName = schemaName
        self.sql = sql
        self.paneId = paneId
    }
}
