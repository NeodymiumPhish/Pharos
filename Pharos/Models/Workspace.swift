import Foundation

// Rust workspace models use `#[serde(rename_all = "camelCase")]` and
// JSONDecoder/Encoder.pharos apply NO key strategy, so these Swift structs use
// plain camelCase property names (matching the JSON keys exactly) with NO
// CodingKeys. Do not add snake_case CodingKeys here.

/// Payload sent to Rust to create/refresh a workspace snapshot.
struct WorkspaceUpsert: Codable {
    var id: String
    var name: String?
    var nameIsCustom: Bool
    var connectionId: String
    var connectionName: String
    var editorText: String
    var variablesJson: String
    var cursorPosition: Int?
}

/// A row in the workspace list.
struct WorkspaceSummary: Codable {
    let id: String
    let name: String
    let connectionName: String
    let distinctDbCount: Int
    let queryCount: Int
    let lastActivityAt: String
}

/// One child result's metadata.
struct WorkspaceResultMeta: Codable {
    let id: String
    let sql: String
    let resultOrder: Int?
    let colorIndex: Int?
    let customLabel: String?
    let rowCount: Int?
    let columnCount: Int?
    let schema: String?
    let tableNames: String?
    let hasResults: Bool
    let executionTimeMs: Int
    let executedAt: String
    let chartViewStateJson: String?
}

/// Full workspace payload for reopen.
struct WorkspaceDetail: Codable {
    let id: String
    let name: String
    let connectionId: String
    let connectionName: String
    let editorText: String
    let variablesJson: String
    let cursorPosition: Int?
    let results: [WorkspaceResultMeta]
}
