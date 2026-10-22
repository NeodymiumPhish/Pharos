import Foundation

/// The connection a saved Session opens on.
///
/// Its own connection and schema when that record still exists. Otherwise —
/// the record was deleted, or the Session never had one — NO connection, so
/// the tab shows "Choose Connection". It never falls back to the connection
/// of the tab it was opened from: that can be another database altogether,
/// and a Run would send the Session's queries there. Pure
/// (`scripts/test-session-connection-rule.sh`).
enum SessionConnectionRule {
    static func resolve(connectionId: String?, schemaName: String?,
                        exists: (String) -> Bool) -> (connectionId: String?, schemaName: String?) {
        guard let id = connectionId, exists(id) else { return (nil, nil) }
        return (id, schemaName)
    }
}
