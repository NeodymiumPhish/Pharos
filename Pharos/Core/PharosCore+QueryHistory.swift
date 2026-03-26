import Foundation
import CPharosCore

// MARK: - Query History

extension PharosCore {

    /// Load query history with optional filters.
    static func loadQueryHistory(filter: QueryHistoryFilter = QueryHistoryFilter()) throws -> [QueryHistoryEntry] {
        let json = try JSONEncoder.pharos.encode(filter)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_load_query_history($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        return try JSONDecoder.pharos.decode([QueryHistoryEntry].self, from: Data(result.utf8))
    }

    /// Delete a query history entry.
    static func deleteQueryHistoryEntry(id: String) throws -> Bool {
        guard let ptr = id.withCString({ pharos_delete_query_history_entry($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        return String(cString: ptr) == "true"
    }

    /// Get cached result data for a history entry.
    static func getQueryHistoryResult(id: String) throws -> QueryHistoryResultData? {
        guard let ptr = id.withCString({ pharos_get_query_history_result($0) }) else {
            return nil // NULL = no cached results
        }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        if let errorData = json.data(using: .utf8),
           let errorDict = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
           let errorMsg = errorDict["error"] as? String {
            throw PharosCoreError.rustError(errorMsg)
        }
        return try JSONDecoder.pharos.decode(QueryHistoryResultData.self, from: Data(json.utf8))
    }

    /// Batch delete query history entries.
    /// Returns the count of deleted entries.
    static func batchDeleteQueryHistory(ids: [String]) throws -> Int {
        let json = try JSONEncoder.pharos.encode(ids)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_batch_delete_query_history($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        if let errorData = result.data(using: .utf8),
           let errorDict = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
           let errorMsg = errorDict["error"] as? String {
            throw PharosCoreError.rustError(errorMsg)
        }
        guard let count = Int(result) else {
            throw PharosCoreError.rustError("Unexpected result: \(result)")
        }
        return count
    }
}
