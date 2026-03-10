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

/// Represents a single query editor tab.
struct QueryTab: Identifiable {
    let id: String
    var name: String
    var connectionId: String?
    var schemaName: String?
    var sql: String
    var cursorPosition: Int = 0
    var isDirty: Bool = false
    var isExecuting: Bool = false
    var queryId: String?
    var result: QueryResult?
    var executeResult: ExecuteResult?
    var error: String?
    var savedQueryId: String?
    var historySchema: String?
    var historyTimestamp: String?
    var gridState: ResultsGridState?
    var paneId: String?

    init(id: String = UUID().uuidString, name: String = "Query 1", connectionId: String? = nil, schemaName: String? = nil, sql: String = "", paneId: String? = nil) {
        self.id = id
        self.name = name
        self.connectionId = connectionId
        self.schemaName = schemaName
        self.sql = sql
        self.paneId = paneId
    }
}
