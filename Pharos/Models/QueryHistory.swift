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
    let schema: String?
    let columnCount: Int64?
    let tableNames: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        connectionId = try c.decode(String.self, forKey: .connectionId)
        connectionName = try c.decode(String.self, forKey: .connectionName)
        sql = try c.decode(String.self, forKey: .sql)
        rowCount = try c.decodeIfPresent(Int64.self, forKey: .rowCount)
        executionTimeMs = try c.decode(Int64.self, forKey: .executionTimeMs)
        executedAt = try c.decode(String.self, forKey: .executedAt)
        hasResults = try c.decodeIfPresent(Bool.self, forKey: .hasResults) ?? false
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        columnCount = try c.decodeIfPresent(Int64.self, forKey: .columnCount)
        tableNames = try c.decodeIfPresent(String.self, forKey: .tableNames)
    }
}

struct QueryHistoryFilter: Codable {
    var connectionId: String?
    var search: String?
    var limit: Int?
    var offset: Int?
}

struct QueryHistoryResultData: Codable {
    let columns: [ColumnDef]
    let rows: [[String: AnyCodable]]
}
