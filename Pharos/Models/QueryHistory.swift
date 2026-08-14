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
    var onlyLegacy: Bool = false
}

/// The cached result of a history entry, so a reopened workspace restores its grid.
///
/// CASING: this one payload mixes both conventions, deliberately. The Rust struct
/// (`pharos-core/src/commands/query_history.rs`) carries
/// `#[serde(rename_all = "camelCase")]`, which renames ITS OWN fields — hence the
/// outer key `rowIdentity`, needing no CodingKeys here. `rename_all` does not
/// reach inside a nested `serde_json::Value`, so the identity block itself keeps
/// the snake_case keys that `execute_query` wrote (`table_key`, `key_columns`, …),
/// which is why `RowIdentity` carries snake_case CodingKeys. Do not unify them.
struct QueryHistoryResultData: Codable {
    let columns: [ColumnDef]
    let rows: [[AnyCodable]]
    /// nil for an entry cached before the identity column existed. Those entries
    /// also carry columns with no `relation_oid` key at all, and Rust never
    /// re-decodes that cached string — so `ColumnDef`'s OID fields must stay
    /// optional or older history stops opening.
    let rowIdentity: RowIdentity?
}

// MARK: - Building a result from history

// This extension lives HERE, not in QueryResult.swift, so the general result model
// keeps no dependency on a history payload. The direction matters: history knows how
// to make a QueryResult, not the other way round. Putting it in QueryResult.swift
// forced fifteen standalone harnesses that compile that file to also compile this one.

extension QueryResult {
    /// Build a result from a stored history payload.
    ///
    /// This exists so no caller has to remember `rowIdentity`. `init` defaults that
    /// parameter to nil, so a history-restore path that omits it silently drops the
    /// identity block the entry was cached WITH — no crash, no warning, and the
    /// reopened result then disagrees with the one that was stored. Two call sites
    /// did exactly that. Route every future history restore through here.
    ///
    /// This costs provenance, not tags: a tag is matched on cell values, so a
    /// restored result shows the same tags with or without the block.
    static func fromHistory(
        _ data: QueryHistoryResultData,
        historyEntryId: String,
        executionTimeMs: UInt64
    ) -> QueryResult {
        QueryResult(
            columns: data.columns,
            rows: data.rows,
            rowCount: data.rows.count,
            executionTimeMs: executionTimeMs,
            hasMore: false,
            historyEntryId: historyEntryId,
            rowIdentity: data.rowIdentity
        )
    }
}
