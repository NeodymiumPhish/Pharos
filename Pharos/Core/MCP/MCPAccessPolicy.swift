import Foundation

/// Which databases an MCP client may reach: only connections whose record
/// has "Allow AI apps to use this connection" on (`ConnectionConfig.mcpAccess`),
/// off by default.
///
/// A client reaches a database through more than the connection: through a
/// tab on it, through cards that ran on it (a tab keeps its cards when it
/// changes connection), through history, workspaces and Sessions that ran
/// against it. Each rule below says when one of those is shared; anything
/// it cannot place on a shared connection is withheld. Foundation only
/// (scripts/test-mcp-access-policy.sh).
enum MCPAccessPolicy {

    /// A tab: on a shared connection, every card's run (where the run says
    /// where it went) on a shared one, and — for a tab bound to a workspace —
    /// every connection the workspace's results ran on shared too. A tab with
    /// no connection is not shared: nothing says where its results came from.
    static func allowsTab(connectionId: String?, document: CardDocument,
                          workspaceConnectionIds: [String]?, allowed: Set<String>) -> Bool {
        guard let connectionId, allowed.contains(connectionId) else { return false }
        guard runsAreShared(document, allowed: allowed) else { return false }
        return (workspaceConnectionIds ?? []).allSatisfy(allowed.contains)
    }

    /// A saved Session: its connection is shared, and so is every recorded
    /// run's. A Session saved with no connection is not shared.
    static func allowsSession(connectionId: String?, document: CardDocument, allowed: Set<String>) -> Bool {
        guard let connectionId, allowed.contains(connectionId) else { return false }
        return runsAreShared(document, allowed: allowed)
    }

    /// A workspace: every connection its results ran on, and its own.
    static func allowsWorkspace(connectionIds: [String], allowed: Set<String>) -> Bool {
        !connectionIds.isEmpty && connectionIds.allSatisfy(allowed.contains)
    }

    /// A history entry: the connection it ran on.
    static func allowsHistoryEntry(connectionId: String, allowed: Set<String>) -> Bool {
        allowed.contains(connectionId)
    }

    /// A query variable: a global one is shared (it names no database); a
    /// linked one only when one of its connections is. `links` are the
    /// shared ones among them, which is all a client is told.
    static func variableLinks(_ connectionIds: [String], allowed: Set<String>) -> (shared: Bool, links: [String]) {
        guard !connectionIds.isEmpty else { return (true, []) }
        let links = connectionIds.filter(allowed.contains)
        return (!links.isEmpty, links)
    }

    /// Every card whose run records its connection ran on a shared one. A
    /// run recorded before runs kept their connection goes by its tab's or
    /// Session's own, which the caller has checked.
    static func runsAreShared(_ document: CardDocument, allowed: Set<String>) -> Bool {
        document.cards.allSatisfy { card in
            card.lastRun?.connectionId.map(allowed.contains) ?? true
        }
    }

    /// Filter a source read in pages until `limit` items pass `keep` or the
    /// source runs out. `offset` and the returned `next` count rows of the
    /// SOURCE, so a client pages on without the withheld rows being counted
    /// or shown. At most `scanLimit` source rows are read per call.
    static func filteredPage<T>(offset: Int, limit: Int, batch: Int = 200, scanLimit: Int = 5_000,
                                fetch: (_ offset: Int, _ count: Int) throws -> [T],
                                keep: (T) -> Bool) rethrows -> (items: [T], next: Int?) {
        var items: [T] = []
        var position = offset
        var scanned = 0
        while scanned < scanLimit {
            let rows = try fetch(position, batch)
            for (i, row) in rows.enumerated() where keep(row) {
                if items.count == limit {
                    return (items, position + i)
                }
                items.append(row)
            }
            position += rows.count
            scanned += rows.count
            if rows.count < batch { return (items, nil) }
        }
        return (items, position)
    }
}
