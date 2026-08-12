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

    /// Delete a saved query. Returns true when a row was removed, false when no
    /// query had that id.
    ///
    /// A core failure throws. It used to read as `false`, which the caller showed
    /// as "the row is still there" with no reason given.
    static func deleteSavedQuery(id: String) throws -> Bool {
        try scalarResult { id.withCString { pharos_delete_saved_query($0) } } == "true"
    }

    /// Batch delete saved queries by IDs and return how many were removed.
    ///
    /// The count can be less than `ids.count`: an id that no longer exists is
    /// skipped, not an error. A core failure now throws its own message; it used
    /// to throw the whole `{"error": ...}` object as the message text.
    static func batchDeleteSavedQueries(ids: [String]) throws -> Int {
        let text = try scalarResult(input: ids) { pharos_batch_delete_saved_queries($0) }
        guard let count = Int(text) else {
            throw PharosCoreError.rustError("Unexpected delete count result: \(text)")
        }
        return count
    }

    /// Extract table names from SQL for display.
    ///
    /// This does not throw, because the core answers NULL for SQL it cannot read
    /// and the caller only wants a caption. The error check is still necessary:
    /// the `ffi_sync!` macro turns a panic into `{"error": ...}`, and without this
    /// the object would be shown to the user as a table name.
    static func extractTableNames(from sql: String) -> String? {
        guard let ptr = sql.withCString({ pharos_extract_table_names($0) }) else { return nil }
        defer { pharos_free_string(ptr) }
        let text = String(cString: ptr)
        guard RustScalarError.message(in: text) == nil else { return nil }
        return text
    }
}
