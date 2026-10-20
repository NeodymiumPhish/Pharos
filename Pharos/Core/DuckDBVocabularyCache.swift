import Foundation

/// DuckDB's function names per connected database, read once from
/// `duckdb_functions()` for the editor's completion list.
///
/// Cached per connection id for the life of the connection: the function
/// list changes only when an extension loads or a macro is created, and a
/// disconnect forgets it. A failed read is not cached, so the next ask tries
/// again.
@MainActor
final class DuckDBVocabularyCache {
    static let shared = DuckDBVocabularyCache()

    private var functions: [String: [String]] = [:]
    private var waiting: [String: [([String]) -> Void]] = [:]

    private init() {}

    /// The names for a connection, from the cache or read now.
    func functionNames(for connectionId: String, completion: @escaping ([String]) -> Void) {
        if let cached = functions[connectionId] {
            completion(cached)
            return
        }
        if waiting[connectionId] != nil {
            waiting[connectionId]?.append(completion)
            return
        }
        waiting[connectionId] = [completion]
        Task { @MainActor in
            let names: [String]
            do {
                names = try await PharosCore.duckDBVocabulary(connectionId: connectionId).functions
                self.functions[connectionId] = names
            } catch {
                Log.ui.error("DuckDB vocabulary read failed: \(error.localizedDescription, privacy: .public)")
                names = []
            }
            let callbacks = self.waiting.removeValue(forKey: connectionId) ?? []
            callbacks.forEach { $0(names) }
        }
    }

    func forget(_ connectionId: String) {
        functions.removeValue(forKey: connectionId)
    }
}
