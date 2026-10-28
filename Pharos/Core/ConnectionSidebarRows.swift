import AppKit

/// The Connections Manager's sidebar rows: each connection record as a
/// `ManagerSidebarItem`, with no view in it.
///
/// Pulled out of `ConnectionsManagerVC`, which reaches `AppStateManager` and
/// through it the whole FFI and so cannot be compiled by a standalone harness.
/// `scripts/test-connection-sidebar-rows.sh` pins what a row says here.
///
/// A row is:
/// - the engine's symbol on its tinted square — the same symbol and colour as
///   the tile in the tab's connection pop-up (`ConnectionTile`), so a record
///   looks the same in both places;
/// - the name, escaped and trimmed, or "Untitled" when that leaves nothing;
/// - `host:port · database`, with ` · via <bastion>` for a tunnel; `DuckDB ·
///   <path>` for a file; "Not saved" for a record that has never been saved;
/// - the unsaved dot while the form holds edits to a SAVED record, then the
///   status dot — last, so the dots line up down the list.
enum ConnectionSidebarRows {

    /// One row per record, in the records' order.
    ///
    /// - Parameters:
    ///   - statuses: by record id; a record with no entry is disconnected.
    ///   - stubIds: records that have never been saved (the + button, a
    ///     `postgres://` link).
    ///   - dirtyId: the record whose form has unsaved edits, if any.
    static func items(for connections: [ConnectionConfig],
                      statuses: [String: ConnectionStatus],
                      stubIds: Set<String>,
                      dirtyId: String?) -> [ManagerSidebarItem] {
        connections.map { config in
            item(for: config,
                 status: statuses[config.id] ?? .disconnected,
                 isStub: stubIds.contains(config.id),
                 isDirty: config.id == dirtyId)
        }
    }

    static func item(for config: ConnectionConfig, status: ConnectionStatus,
                     isStub: Bool, isDirty: Bool) -> ManagerSidebarItem {
        var trailing: [ManagerSidebarItem.Accessory] = []
        // A stub is unsaved by definition: its status dot is already orange
        // and its subtitle says "Not saved", so a second orange dot would
        // say the same thing twice.
        if isDirty && !isStub { trailing.append(.unsavedDot) }
        let dot = statusDot(status: status, isStub: isStub)
        trailing.append(.statusDot(dot.color, accessibilityLabel: dot.label))
        return ManagerSidebarItem(
            id: config.id,
            title: title(for: config),
            subtitle: subtitle(for: config, isStub: isStub),
            // A file path loses its middle, where the folders are, and
            // keeps the file name at its end.
            subtitleTruncatesMiddle: config.isDuckDB && !isStub,
            badge: badge(for: config),
            trailing: trailing)
    }

    /// The name as a label: ESCAPED, so a bidi override cannot make it lie,
    /// and TRIMMED, because the save path trims. The placeholder is chosen
    /// after the trim: a name of nothing but spaces trims to nothing, and a
    /// blank row is less use than "Untitled".
    static func title(for config: ConnectionConfig) -> String {
        let name = DisplayEscape.escapedTrimmed(config.name)
        return name.isEmpty ? String(localized: "Untitled") : name
    }

    /// Where the record goes. Every stored string in it is escaped, as every
    /// other stored string shown as a label is.
    static func subtitle(for config: ConnectionConfig, isStub: Bool) -> String {
        guard !isStub else { return String(localized: "Not saved") }
        // A DuckDB record is a FILE: its path (with ~), or "In-memory".
        if config.isDuckDB {
            return "DuckDB · " + DisplayEscape.escaped(config.locationDescription)
        }
        let base = "\(DisplayEscape.escaped(config.host)):\(config.port) · \(DisplayEscape.escaped(config.database))"
        // The tunnel is part of WHERE this connection goes, and a bastion's
        // name is the one thing that tells two otherwise identical records
        // apart.
        return base + SshTunnelForm.viaSuffix(config.sshTunnel, escape: DisplayEscape.escaped)
    }

    /// The engine's symbol on its tint: a server, a DuckDB file, or an
    /// in-memory DuckDB database.
    static func badge(for config: ConnectionConfig) -> ManagerSidebarItem.Badge {
        let kind: ConnectionTile.Kind
        switch ConnectionMenuText.kind(of: config) {
        case .server: kind = .server
        case .file: kind = .file
        case .memory: kind = .memory
        }
        return .symbol(name: ConnectionTile.symbolName(of: kind), tint: ConnectionTile.color(of: kind))
    }

    /// The status dot's colour and what VoiceOver reads for it. The colours
    /// are the ones the list has always used: green connected, yellow
    /// connecting, red failed, grey not connected, orange not saved.
    static func statusDot(status: ConnectionStatus, isStub: Bool) -> (color: NSColor?, label: String) {
        if isStub { return (.systemOrange, String(localized: "Not saved")) }
        // The same words the native tab's dot reads.
        let label = TabConnectionState(connectionId: "", status: status).label
        switch status {
        case .connected: return (.systemGreen, label)
        case .connecting: return (.systemYellow, label)
        case .error: return (.systemRed, label)
        case .disconnected: return (.tertiaryLabelColor, label)
        }
    }
}
