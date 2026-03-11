import Foundation
import CPharosCore

// MARK: - Saved Queries

extension PharosCore {

    /// Load saved queries.
    static func loadSavedQueries() throws -> [SavedQuery] {
        guard let ptr = pharos_load_saved_queries() else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        return try JSONDecoder.pharos.decode([SavedQuery].self, from: Data(json.utf8))
    }

    /// Create a saved query.
    static func createSavedQuery(_ query: CreateSavedQuery) throws -> SavedQuery {
        let json = try JSONEncoder.pharos.encode(query)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_create_saved_query($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        return try JSONDecoder.pharos.decode(SavedQuery.self, from: Data(result.utf8))
    }

    /// Update a saved query.
    static func updateSavedQuery(_ query: UpdateSavedQuery) throws -> SavedQuery {
        let json = try JSONEncoder.pharos.encode(query)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_update_saved_query($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        return try JSONDecoder.pharos.decode(SavedQuery.self, from: Data(result.utf8))
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
        let json = try JSONEncoder.pharos.encode(ids)
        let jsonStr = String(data: json, encoding: .utf8)!
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
    /// Returns formatted string like "users", "users, orders", or nil if no tables found.
    static func extractTableNames(from sql: String) -> String? {
        guard let ptr = sql.withCString({ pharos_extract_table_names($0) }) else {
            return nil  // NULL = no tables found
        }
        defer { pharos_free_string(ptr) }
        return String(cString: ptr)
    }
}
