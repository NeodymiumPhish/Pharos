import Foundation

struct QueryHistoryEntry: Codable, Identifiable {
    let id: String
    let connectionId: String
    let connectionName: String
    let sql: String
    let rowCount: Int64?
    let executionTimeMs: Int64
    let executedAt: String // ISO 8601
    let hasResults: Bool
}

struct QueryHistoryFilter: Codable {
    var connectionId: String?
    var search: String?
    var limit: Int?
    var offset: Int?
}
