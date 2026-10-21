import Foundation

/// Which connections relaunch restore opens again (Q4, owner decision 3):
/// the DuckDB FILE databases that the restored tabs use. A local file opens
/// in an instant and the tab was in use when Pharos quit; a server
/// connection stays closed (it can need a password, a tunnel, Touch ID).
///
/// Pure: `scripts/test-restore-connect-policy.sh` pins it.
enum RestoreConnectPolicy {

    /// The records to connect, each once, in the order the tabs name them.
    /// In-memory databases are not opened (an empty one helps nobody), and a
    /// record already connecting or connected is left alone. A record whose
    /// file is gone IS opened: the core refuses it, and the tab then says
    /// "File not found" with Locate…, quietly (the caller marks the connect
    /// quiet).
    static func recordsToOpen(tabConnectionIds: [String?], connections: [ConnectionConfig],
                              status: (String) -> ConnectionStatus) -> [String] {
        var out: [String] = []
        for id in tabConnectionIds.compactMap({ $0 }) where !out.contains(id) {
            guard let config = connections.first(where: { $0.id == id }), config.isDuckDB,
                  !config.isInMemoryDuckDB, !config.database.isEmpty else { continue }
            let s = status(id)
            guard s != .connecting && s != .connected else { continue }
            out.append(id)
        }
        return out
    }
}
