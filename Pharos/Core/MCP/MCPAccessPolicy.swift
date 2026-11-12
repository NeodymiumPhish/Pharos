import Foundation

/// Which databases an MCP client may reach: only connections whose "AI apps"
/// choice (`ConnectionConfig.mcpAccess`, off by default) includes the app's
/// tier, Local or Cloud. The caller turns that into the `allowed` set.
/// Query variables have the same choice of their own (`allowsVariable`).
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

    /// A history entry: the connection it ran on, and no `{{name}}` in it
    /// that the client may not have filled in (`withheld`, from
    /// `withheldNames`): the entry's SQL carries the value.
    static func allowsHistoryEntry(connectionId: String, withheld: [String] = [], allowed: Set<String>) -> Bool {
        allowed.contains(connectionId) && withheld.isEmpty
    }

    /// A query variable: a global one is shared (it names no database); a
    /// linked one only when one of its connections is. `links` are the
    /// shared ones among them, which is all a client is told.
    static func variableLinks(_ connectionIds: [String], allowed: Set<String>) -> (shared: Bool, links: [String]) {
        guard !connectionIds.isEmpty else { return (true, []) }
        let links = connectionIds.filter(allowed.contains)
        return (!links.isEmpty, links)
    }

    /// A query variable a client may use: the user shares it with the app's
    /// tier (`sharedWithApp`: the variable's own "AI apps" choice, off until
    /// they choose), and it is global or linked to a shared connection. Both,
    /// because either can hold a secret: the value, or where it is used.
    static func allowsVariable(connectionIds: [String], sharedWithApp: Bool, allowed: Set<String>) -> Bool {
        sharedWithApp && variableLinks(connectionIds, allowed: allowed).shared
    }

    /// The `{{name}}` tokens of a card or a past run (`referenced`) that the
    /// client may not have filled in, sorted: every one that is not the name
    /// of a variable it may use now (`usable`). A name that is no longer
    /// defined counts, since nothing says what value it stood for; so does
    /// one whose variable took the name after the run, which the caller
    /// leaves out of `usable` (`MCPVariableAccess.withheldNames`). While any
    /// is left, what the run sent, returned and failed with is withheld.
    static func withheldNames(referenced: Set<String>, usable: Set<String>) -> [String] {
        referenced.subtracting(usable).sorted()
    }

    /// Whether a client may change or delete a query variable: every
    /// connection it is linked to is shared. A variable also linked to one
    /// the client cannot see would change there unseen. A global one names
    /// no database and is allowed; the user confirms each change.
    static func allowsVariableChange(_ connectionIds: [String], allowed: Set<String>) -> Bool {
        connectionIds.allSatisfy(allowed.contains)
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
