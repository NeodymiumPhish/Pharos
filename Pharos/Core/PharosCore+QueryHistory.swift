import Foundation
import CPharosCore

// MARK: - Query History

extension PharosCore {

    /// Load query history with optional filters.
    static func loadQueryHistory(filter: QueryHistoryFilter = QueryHistoryFilter()) throws -> [QueryHistoryEntry] {
        try callSync(input: filter) { pharos_load_query_history($0) }
    }

    /// Everything about a failed run that only the Swift session knows.
    ///
    /// The core learns a query failed inside `commands::query`, but not which
    /// workspace the editor tab belongs to nor which editor lines the
    /// statement came from — both live here — so the record is driven from
    /// Swift rather than from the failure site.
    struct FailedQueryRecord: Codable {
        /// The connection the run was made on.
        let connectionId: String
        /// The substituted SQL that actually ran.
        let sql: String
        /// The pre-substitution `{{var}}` form, when the run had one.
        var rawSql: String? = nil
        /// What the server (or the client) said.
        let message: String
        /// `QueryHistoryStatus.error` or `.cancelled`.
        var status: String = QueryHistoryStatus.error
        var schema: String? = nil
        var tableNames: String? = nil
        /// The editor tab's workspace, when it has one.
        var workspaceId: String? = nil
        /// 1-based and inclusive; both nil when the run came from no editor
        /// segment.
        var lineStart: Int? = nil
        var lineEnd: Int? = nil
        /// How long the run took before it failed.
        var executionTimeMs: Int = 0
    }

    /// Record a query that FAILED, and return the new entry's id.
    ///
    /// Whether a failure is worth recording at all is NOT decided here: the
    /// caller asks `HistoryFailureFilter.shouldRecord` and reads
    /// Settings ▸ Library & History ▸ Record failed queries first. This
    /// records what it is given.
    ///
    /// The success return is the new id — a scalar, not JSON — which is the
    /// single-channel convention the workspace calls use, so it goes through
    /// `scalarResult` rather than `callSync`.
    @discardableResult
    static func recordFailedQuery(_ record: FailedQueryRecord) throws -> String {
        try scalarResult(input: record) { pharos_record_failed_query($0) }
    }

    /// Delete a query history entry. Returns true when a row was removed, false
    /// when no entry had that id.
    ///
    /// A core failure throws. It used to read as `false`, which the caller showed
    /// as "the row is still there" with no reason given.
    static func deleteQueryHistoryEntry(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_query_history_entry($0) } } == "true"
    }

    /// Get cached result data for a history entry.
    ///
    /// This cannot use `jsonResult`: a decode failure here means an old cached
    /// format, which must give nil rather than throw. Only the error object
    /// throws.
    static func getQueryHistoryResult(id: String) throws -> QueryHistoryResultData? {
        // NULL = no cached results.
        guard let json = try checkedText({ id.withCString { pharos_get_query_history_result($0) } })
        else { return nil }
        do {
            return try JSONDecoder.pharos.decode(QueryHistoryResultData.self, from: Data(json.utf8))
        } catch {
            // Old cached results were name-keyed objects; new format is index-based arrays.
            // Gracefully return nil so the history entry is still visible but without cached result preview.
            return nil
        }
    }

    /// Batch delete query history entries and return how many were removed.
    ///
    /// The count can be less than `ids.count`: an id that no longer exists is
    /// skipped, not an error.
    static func batchDeleteQueryHistory(ids: [String]) throws -> Int {
        let text = try scalarResult(input: ids) { pharos_batch_delete_query_history($0) }
        guard let count = Int(text) else {
            throw PharosCoreError.rustError("Unexpected delete count result: \(text)")
        }
        return count
    }

    /// How many history entries a clear would remove, without removing them.
    /// `olderThanDays` of 0 means everything.
    ///
    /// The confirmation dialog names this number before the user agrees, so a
    /// clear can never take more than it said it would.
    static func countQueryHistory(olderThanDays: UInt32 = 0) throws -> Int {
        try clearHistoryCall(olderThanDays: olderThanDays, preview: true)
    }

    /// Clear Query History and return how many entries went. `olderThanDays`
    /// of 0 clears all of it.
    ///
    /// Workspaces left with no entries go with them; a workspace that still
    /// has entries is untouched, so an open tab does not lose its own.
    @discardableResult
    static func clearQueryHistory(olderThanDays: UInt32 = 0) throws -> Int {
        try clearHistoryCall(olderThanDays: olderThanDays, preview: false)
    }

    private struct ClearHistoryRequest: Encodable {
        let olderThanDays: UInt32
        let preview: Bool
    }

    private struct ClearHistoryResponse: Decodable {
        let deleted: Int
    }

    private static func clearHistoryCall(olderThanDays: UInt32, preview: Bool) throws -> Int {
        let response: ClearHistoryResponse = try callSync(
            input: ClearHistoryRequest(olderThanDays: olderThanDays, preview: preview)
        ) { pharos_clear_query_history($0) }
        return response.deleted
    }
}
