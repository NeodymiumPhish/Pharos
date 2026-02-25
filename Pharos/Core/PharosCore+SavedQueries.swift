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
}
