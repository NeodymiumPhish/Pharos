import Foundation

// A saved query is a saved Session: one tab of cards and, since Sessions, the
// result each card held when it was saved (`saved_query_results`). The types
// keep the old name because `Session` already means relaunch restore
// (`Session.swift`, `WindowSession`). Only the UI says "Session".

struct SavedQuery: Codable, Identifiable {
    let id: String
    var name: String
    var folder: String?
    var sql: String
    var connectionId: String?
    /// LEGACY. Saved queries once carried their own `[QueryVariable]` JSON here;
    /// variables are app-wide now (`QueryVariableStore`) and this column is
    /// neither written (every writer passes `nil`, which the Rust update treats
    /// as "leave unchanged") nor read. It stays on the wire because the Rust
    /// struct still has the field.
    var variables: String?
    /// The query's cards (`CardPersistence`): a saved query is a full tab of
    /// cards. Nil on queries saved before cards existed; `sql` is split then.
    var cardsJson: String? = nil
    let createdAt: String
    let updatedAt: String
    /// The schema the Session's tab was on when it was saved.
    var schemaName: String? = nil
    /// The stored results, or nil when the Session was never saved with any
    /// (every saved query from before Sessions).
    var resultsSnapshotId: String? = nil
    var resultsSavedAt: String? = nil
    /// Compressed size of the stored results.
    var resultsBytes: Int64? = nil
    /// Results in the snapshot, with or without their rows.
    var resultCount: Int? = nil
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly

    /// Whether opening the Session can put results back.
    var hasSavedResults: Bool { resultsSnapshotId != nil && (resultCount ?? 0) > 0 }
}

struct CreateSavedQuery: Codable {
    let name: String
    let folder: String?
    let sql: String
    let connectionId: String?
    /// Legacy; always `nil`. See `SavedQuery.variables`.
    let variables: String?
    var cardsJson: String? = nil
    var schemaName: String? = nil
}

struct UpdateSavedQuery: Codable {
    let id: String
    let name: String?
    let folder: String?
    let sql: String?
    /// Legacy; always `nil`. See `SavedQuery.variables`.
    let variables: String?
    /// nil leaves the stored cards alone.
    var cardsJson: String? = nil
}

// MARK: - Opening a Session

/// How a Session opens.
enum SessionOpenMode: String {
    /// The cards and the results saved with them, in a tab bound to the
    /// Session (⌘S saves back to it).
    case restore
    /// The cards only, with no runs, in a new unsaved tab.
    case template
}

// MARK: - Session results

/// One result of a Session save, staged before the save commits. Its
/// `columns`, `rows` and `rowIdentity` are the grid's, encoded the way a
/// history result is, so `QueryHistoryResultData` decodes them back.
struct StageSavedQueryResult: Encodable {
    enum Kind: String, Codable { case rows, affected }

    let savedQueryId: String
    let snapshotId: String
    /// The card's `lastRun.runId`: the key a restore matches on.
    let runId: String
    let cardId: String
    /// 0 keeps its rows first when the Session is over its budget.
    let priority: Int
    let kind: Kind
    let sql: String
    let rawSql: String?
    let schemaName: String?
    let executedAt: String
    let executionTimeMs: UInt64
    let rowsAffected: UInt64?
    let rowCount: Int?
    let hasMore: Bool
    let chartViewStateJson: String?
    let columns: [ColumnDef]?
    let rows: [[AnyCodable]]?
    let rowIdentity: RowIdentity?
}

struct StagedSavedQueryResult: Decodable {
    let id: String
    /// False when the rows did not fit in the budget.
    let stored: Bool
    let compressedBytes: Int64
}

struct KeepSavedQueryResult: Encodable, Equatable {
    let runId: String
    let priority: Int
}

struct CommitSavedQuerySnapshot: Encodable {
    let savedQueryId: String
    let snapshotId: String
    let sql: String
    /// Nil when the cards did not encode: the Session then splits `sql`.
    let cardsJson: String?
    let connectionId: String?
    let schemaName: String?
    let keep: [KeepSavedQueryResult]
}

struct CommittedSavedQuerySnapshot: Decodable {
    let savedQuery: SavedQuery
    /// Runs whose rows were dropped to keep the Session under its budget.
    let droppedRunIds: [String]
}

/// One stored result of a Session, without its rows.
struct SavedQueryResultMeta: Codable, Equatable {
    let id: String
    let runId: String
    let cardId: String
    let kind: StageSavedQueryResult.Kind
    let sql: String
    let rawSql: String?
    let schemaName: String?
    let executedAt: String
    let executionTimeMs: Int64
    let rowsAffected: Int64?
    let rowCount: Int?
    let hasMore: Bool
    let chartViewStateJson: String?
    /// False when the budget dropped the rows.
    let hasRows: Bool
    let compressedBytes: Int64
}
