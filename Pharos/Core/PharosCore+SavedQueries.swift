import Foundation
import CPharosCore

// MARK: - Saved Queries

extension PharosCore {

    /// Load saved queries.
    static func loadSavedQueries() throws -> [SavedQuery] {
        try callSync { pharos_load_saved_queries() }
    }

    /// Create a saved query.
    static func createSavedQuery(_ query: CreateSavedQuery) throws -> SavedQuery {
        try callSync(input: query) { pharos_create_saved_query($0) }
    }

    /// Update a saved query.
    static func updateSavedQuery(_ query: UpdateSavedQuery) throws -> SavedQuery {
        try callSync(input: query) { pharos_update_saved_query($0) }
    }

    /// Delete a saved query.
    static func deleteSavedQuery(id: String) throws -> Bool {
        guard let ptr = id.withCString({ pharos_delete_saved_query($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        return String(cString: ptr) == "true"
    }

    /// Batch delete saved queries by IDs.
    static func batchDeleteSavedQueries(ids: [String]) throws -> Int {
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(ids), as: UTF8.self)
        guard let ptr = jsonStr.withCString({ pharos_batch_delete_saved_queries($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        guard let count = Int(result) else {
            throw PharosCoreError.rustError(result)
        }
        return count
    }

    /// Extract table names from SQL for display.
    static func extractTableNames(from sql: String) -> String? {
        guard let ptr = sql.withCString({ pharos_extract_table_names($0) }) else { return nil }
        defer { pharos_free_string(ptr) }
        return String(cString: ptr)
    }
}
