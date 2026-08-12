import Foundation
import CPharosCore

// MARK: - Query History

extension PharosCore {

    /// Load query history with optional filters.
    static func loadQueryHistory(filter: QueryHistoryFilter = QueryHistoryFilter()) throws -> [QueryHistoryEntry] {
        try callSync(input: filter) { pharos_load_query_history($0) }
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
}
