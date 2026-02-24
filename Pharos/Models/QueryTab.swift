import Foundation

/// Represents a single query editor tab.
struct QueryTab: Identifiable {
    let id: String
    var name: String
    var connectionId: String?
    var sql: String
    var cursorPosition: Int = 0
    var isDirty: Bool = false
    var isExecuting: Bool = false
    var queryId: String?
    var result: QueryResult?
    var executeResult: ExecuteResult?
    var error: String?
    var executionTime: UInt64?
    var savedQueryId: String?
    var historySchema: String?
    var historyTimestamp: String?

    init(id: String = UUID().uuidString, name: String = "Query 1", connectionId: String? = nil, sql: String = "") {
        self.id = id
        self.name = name
        self.connectionId = connectionId
        self.sql = sql
    }
}
