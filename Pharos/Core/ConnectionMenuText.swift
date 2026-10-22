import Foundation

/// The words of one row of the tab's connection pop-up: where the database is,
/// its badge and its tooltip. The state word comes first in the row's subtitle
/// and is the view's (`TabContextBar.ConnectionItem.subtitle`).
///
/// Every stored field is escaped on its own before it is joined
/// (`DisplayEscape`), so a control or direction character in a name, host or
/// path cannot reorder the text around it. No user name is shown: it makes the
/// line longer and puts an account name on screen for nothing. Pure
/// (`scripts/test-connection-menu-text.sh`).
enum ConnectionMenuText {
    enum Kind: Equatable {
        case server, file, memory
    }

    static func kind(of config: ConnectionConfig) -> Kind {
        guard config.isDuckDB else { return .server }
        return config.isInMemoryDuckDB ? .memory : .file
    }

    /// "analytics on db.internal:5432", "~/Data/sales.duckdb" (shortened in the
    /// middle when long), "In memory".
    static func place(of config: ConnectionConfig) -> String {
        switch kind(of: config) {
        case .memory:
            return String(localized: "In memory", comment: "Where an in-memory DuckDB database is, in the connection pop-up.")
        case .file:
            return PathAbbreviation.middle(DisplayEscape.escaped(ConnectionConfig.abbreviatingHome(config.database)))
        case .server:
            let host = "\(DisplayEscape.escaped(config.host)):\(config.port)"
            let database = DisplayEscape.escaped(config.database)
            return database.isEmpty ? host
                : String(localized: "\(database) on \(host)", comment: "A server connection's place: the database, then host:port.")
        }
    }

    /// "SSH", "Read-only", or both. `readOnlyNow`: the connection is open read-only
    /// for another reason (another app holds the file).
    static func badge(of config: ConnectionConfig, readOnlyNow: Bool = false) -> String? {
        let ssh = config.sshTunnel != nil
        let readOnly = config.readOnly || readOnlyNow
        switch (ssh, readOnly) {
        case (true, true): return String(localized: "SSH · Read-only", comment: "A connection pop-up badge.")
        case (true, false): return String(localized: "SSH", comment: "A connection pop-up badge: the connection goes through an SSH tunnel.")
        case (false, true): return String(localized: "Read-only", comment: "A connection pop-up badge.")
        case (false, false): return nil
        }
    }

    /// The name, the full place (the whole path for a file) and the tunnel's
    /// host, one per line.
    static func toolTip(of config: ConnectionConfig) -> String {
        var lines = [DisplayEscape.escaped(config.name)]
        switch kind(of: config) {
        case .file: lines.append(DisplayEscape.escaped(config.database))
        case .memory, .server: lines.append(place(of: config))
        }
        if let tunnel = config.sshTunnel {
            lines.append(String(localized: "Through an SSH tunnel via \(DisplayEscape.escaped(tunnel.host))",
                                comment: "A connection pop-up tooltip line."))
        }
        return lines.joined(separator: "\n")
    }
}

/// A path cut in the middle so the file name always shows:
/// "~/Projects/…/q3-sales.duckdb".
enum PathAbbreviation {
    static func middle(_ path: String, limit: Int = 48) -> String {
        guard path.count > limit else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 3, let last = parts.last else { return path }
        // "~/first" or "/first": the start, then the file.
        let head = parts.prefix(2).joined(separator: "/")
        let kept = "\(head)/…/\(last)"
        return kept.count <= limit ? kept : "…/\(last)"
    }
}
