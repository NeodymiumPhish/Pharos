import Foundation

/// When Pharos closes a DuckDB file: a few seconds after the last tab that
/// uses it closes or moves to another connection. A read-write open locks the
/// file against every other process (readers too), so a file no tab shows
/// should not stay locked until Quit. NSDocument closes a document with its
/// last window in the same way.
///
/// Pure: `scripts/test-duckdb-close-rule.sh` pins it.
enum DuckDBCloseRule {

    /// The records to disconnect now. Records on one file share one instance
    /// (plan C9), so a file counts as used when ANY record on it is in a tab.
    /// A file is kept when:
    /// - a tab uses it,
    /// - it is in-memory (closing loses its tables; F7 asks first),
    /// - a record on it is set to connect when Pharos starts (the user wants
    ///   it open),
    /// - a record on it is still connecting,
    /// - Pharos is quitting (Quit closes everything its own way).
    static func recordsToClose(connections: [ConnectionConfig], tabConnectionIds: [String?],
                               status: (String) -> ConnectionStatus, isTerminating: Bool,
                               canonicalPath: (String) -> String = DuckDBFiles.canonicalPath) -> [String] {
        guard !isTerminating else { return [] }
        let used = Set(tabConnectionIds.compactMap { $0 })
        let files = connections.filter { $0.isDuckDB && !$0.isInMemoryDuckDB && !$0.database.isEmpty }
        let byPath = Dictionary(grouping: files) { canonicalPath($0.database) }
        var close: [String] = []
        for (_, records) in byPath.sorted(by: { $0.key < $1.key }) {
            guard !records.contains(where: { used.contains($0.id) }),
                  !records.contains(where: \.connectOnLaunch),
                  !records.contains(where: { status($0.id) == .connecting }) else { continue }
            close += records.filter { status($0.id) == .connected }.map(\.id)
        }
        return close
    }
}
