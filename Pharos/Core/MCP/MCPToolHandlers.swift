import AppKit
import Foundation

/// What each MCP tool does, on the main actor, through the same paths the
/// editor uses: a card a client creates goes into the tab's document and the
/// card stack shows it; a run goes through `ContentViewController.runCard`,
/// so the run queue, the variable substitution and the destructive-SQL
/// confirmation apply exactly as for ⌘↩. The schemas are `MCPToolCatalog`.
@MainActor
enum MCPToolHandlers {

    static func call(_ name: String, _ args: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        switch name {
        case "list_connections": return listConnections()
        case "connect": return try await connect(args)
        case "list_tabs": return listTabs()
        case "list_saved_sessions": return try listSavedSessions(args)
        case "list_workspaces": return try listWorkspaces(args)
        case "search_history": return try searchHistory(args)
        case "list_variables": return try listVariables(args)
        case "open_session": return try await openSession(args)
        case "create_tab": return try createTab(args, client: client)
        case "list_cards": return try listCards(args)
        case "get_card": return try getCard(args)
        case "create_card": return try createCard(args, client: client)
        case "update_card": return try updateCard(args, client: client)
        case "run_card": return try await runCard(args, client: client)
        case "get_card_result": return try await getCardResult(args)
        case "cancel_card": return try cancelCard(args)
        case "save_session": return try await saveSession(args, client: client)
        default: throw MCPToolError.notFound("Pharos has no tool named \(name).")
        }
    }

    // MARK: - Lookups

    private static var state: AppStateManager { AppStateManager.shared }
    private static var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    private struct Located {
        let session: WindowSession
        let tab: QueryTab
        let controller: ContentViewController
    }

    /// Whether this call comes from an app the user marked Local.
    private static var isLocal: Bool { MCPCallContext.isLocal }

    /// Whether the user shares `config` with this call's app.
    private static func shares(_ config: ConnectionConfig) -> Bool {
        config.mcpAccess.allows(isLocal: isLocal)
    }

    /// The connections the user shares with this call's app
    /// (`ConnectionConfig.mcpAccess`).
    private static var allowed: Set<String> {
        Set(state.connections.filter(shares).map(\.id))
    }

    /// The workspace connections of a tab bound to a workspace, nil for one
    /// that is not. Read per call: a run adds to them.
    private static func workspaceConnections(_ workspaceId: String?) -> [String]? {
        guard let workspaceId, let detail = (try? PharosCore.loadWorkspace(id: workspaceId)) ?? nil else { return nil }
        return detail.connectionIds ?? [detail.connectionId]
    }

    private static func isShared(_ tab: QueryTab, allowed: Set<String>) -> Bool {
        MCPAccessPolicy.allowsTab(connectionId: tab.connectionId, document: tab.document,
                                  workspaceConnectionIds: workspaceConnections(tab.workspaceId), allowed: allowed)
    }

    /// A tab the client may use. A tab that is not shared reads as one that
    /// does not exist, so a client cannot learn what it cannot see.
    private static func locate(_ tabId: String) throws -> Located {
        guard let session = state.session(owningTabId: tabId),
              let tab = session.tabs.first(where: { $0.id == tabId }),
              isShared(tab, allowed: allowed),
              let controller = delegate?.contentController(for: session) else {
            throw MCPToolError.notFound("No open tab shared with this app has the id \(tabId). Call list_tabs for the tabs you can use.")
        }
        return Located(session: session, tab: tab, controller: controller)
    }

    private static func card(_ cardId: String, in located: Located) throws -> QueryCard {
        guard let card = located.tab.document.card(cardId) else {
            throw MCPToolError.notFound("Tab “\(located.tab.name)” has no card with the id \(cardId). Call list_cards for its cards.")
        }
        return card
    }

    /// A connection the client may use. One the user has not shared reads
    /// as one that does not exist.
    private static func connection(_ id: String) throws -> ConnectionConfig {
        guard let config = state.connections.first(where: { $0.id == id }), shares(config) else {
            throw MCPToolError.notFound("No connection shared with this app has the id \(id). Call list_connections for the ones you can use.")
        }
        return config
    }

    /// The window to open things in: the frontmost Pharos window, made
    /// (without activating Pharos) when there is none.
    private static func ensureWindow() {
        guard let delegate, delegate.windowControllers.isEmpty else { return }
        delegate.showMainWindow()
    }

    /// Wait on the main actor, a little at a time, until `condition` holds.
    private static func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Connections

    private static func listConnections() -> JSONValue {
        let rows: [JSONValue] = state.connections.filter(shares).map { c in
            [
                "id": .string(c.id),
                "name": .string(c.name),
                "engine": .string(c.engine.rawValue),
                "database": .string(c.database),
                "default_schema": .string(c.effectiveDefaultSchema),
                "status": .string(state.status(for: c.id).rawValue),
                "read_only": .bool(c.readOnly),
            ]
        }
        var out: [String: JSONValue] = ["connections": .array(rows)]
        if rows.isEmpty {
            out["message"] = .string("The user has not shared any connection with \(isLocal ? "local" : "cloud") AI apps. In Pharos, File ▸ Manage Connections… has an “AI apps” choice for each connection.")
        }
        return .object(out)
    }

    private static func connect(_ args: MCPArguments) async throws -> JSONValue {
        let config = try connection(try args.string("connection_id"))
        try await ensureConnected(config.id)
        return ["connection_id": .string(config.id), "name": .string(config.name), "status": "connected"]
    }

    private static func ensureConnected(_ connectionId: String) async throws {
        do {
            try await PharosIntentBridge.ensureConnected(connectionId)
        } catch let error as PharosIntentError {
            throw MCPToolError.failed(String(localized: error.localizedStringResource))
        }
    }

    // MARK: - Tabs, Sessions, workspaces

    private static func describe(tab: QueryTab) -> JSONValue {
        let connectionName = tab.connectionId.flatMap { id in state.connections.first { $0.id == id }?.name }
        return [
            "id": .string(tab.id),
            "name": .string(tab.name),
            "connection_id": .optional(tab.connectionId),
            "connection_name": .optional(connectionName),
            "schema": .optional(tab.schemaName),
            "saved_session_id": .optional(tab.savedQueryId),
            "workspace_id": .optional(tab.workspaceId),
            "file": .optional(tab.sourceURL?.path),
            "card_count": .int(tab.document.cards.count),
            "has_unsaved_changes": .bool(tab.isDirty),
            "is_running": .bool(tab.isExecuting),
        ]
    }

    private static func listTabs() -> JSONValue {
        let key = state.keySession
        let allowed = allowed
        let tabs: [JSONValue] = state.sessions.flatMap { session in
            session.tabs.filter { isShared($0, allowed: allowed) }.map { tab -> JSONValue in
                guard case var .object(o) = describe(tab: tab) else { return .null }
                o["is_front"] = .bool(session === key)
                return .object(o)
            }
        }
        return ["tabs": .array(tabs)]
    }

    private static func listSavedSessions(_ args: MCPArguments) throws -> JSONValue {
        let all: [SavedQuery]
        do { all = try PharosCore.loadSavedQueries() } catch {
            throw MCPToolError.failed("Pharos could not read its library: \(error.localizedDescription)")
        }
        let search = args.optionalString("search")?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let allowed = allowed
        let rows: [JSONValue] = all
            .filter { search.isEmpty || $0.name.lowercased().contains(search) || ($0.folder ?? "").lowercased().contains(search) }
            .filter { isShared($0, allowed: allowed) }
            .map { q in
                let open = state.findTab { $0.savedQueryId == q.id && isShared($0, allowed: allowed) }?.tab.id
                return [
                    "id": .string(q.id),
                    "name": .string(q.name),
                    "folder": .optional(q.folder),
                    "connection_id": .optional(q.connectionId),
                    "updated_at": .string(q.updatedAt),
                    "has_saved_results": .bool(q.hasSavedResults),
                    "open_tab_id": .optional(open),
                ]
            }
        return ["saved_sessions": .array(rows)]
    }

    private static func isShared(_ session: SavedQuery, allowed: Set<String>) -> Bool {
        MCPAccessPolicy.allowsSession(connectionId: session.connectionId,
                                      document: CardPersistence.decode(json: session.cardsJson, text: session.sql),
                                      allowed: allowed)
    }

    private static func isShared(workspaceId: String, allowed: Set<String>) -> Bool {
        guard let ids = workspaceConnections(workspaceId) else { return false }
        return MCPAccessPolicy.allowsWorkspace(connectionIds: ids, allowed: allowed)
    }

    private static func listWorkspaces(_ args: MCPArguments) throws -> JSONValue {
        let limit = try args.int("limit", default: 25, range: 1...200)
        let search = args.optionalString("search")?.trimmingCharacters(in: .whitespaces)
        let allowed = allowed
        let summaries: [WorkspaceSummary]
        do {
            summaries = try MCPAccessPolicy.filteredPage(offset: 0, limit: limit, fetch: { offset, count in
                try PharosCore.loadWorkspaces(filter: .init(search: (search?.isEmpty ?? true) ? nil : search,
                                                            limit: count, offset: offset))
            }, keep: { isShared(workspaceId: $0.id, allowed: allowed) }).items
        } catch {
            throw MCPToolError.failed("Pharos could not read its Results History: \(error.localizedDescription)")
        }
        let rows: [JSONValue] = summaries.map { w -> JSONValue in
            [
                "id": .string(w.id),
                "name": .string(w.name),
                "connection_name": .string(w.connectionName),
                "query_count": .int(w.queryCount),
                "last_activity_at": .string(w.lastActivityAt),
                "open_tab_id": .optional(state.findTab { $0.workspaceId == w.id && isShared($0, allowed: allowed) }?.tab.id),
            ]
        }
        return ["workspaces": .array(rows)]
    }

    private static func searchHistory(_ args: MCPArguments) throws -> JSONValue {
        let limit = try args.int("limit", default: 25, range: 1...200)
        let offset = try args.int("offset", default: 0, range: 0...Int(Int32.max))
        let maxSQL = try args.int("max_sql_chars", default: 2_000, range: 50...MCPToolCatalog.maxCellChars)
        let statusText = args.optionalString("status") ?? "all"
        guard let status = QueryHistoryStatusScope(rawValue: statusText) else {
            throw MCPToolError.invalidArgument("“status” must be all, succeeded or failed.")
        }
        let connectionId = args.optionalString("connection_id")
        if let connectionId { _ = try connection(connectionId) }
        let search = args.optionalString("search")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = allowed
        let page: (items: [QueryHistoryEntry], next: Int?)
        do {
            // Read in pages and keep the shared connections' entries; offsets
            // count history rows, so paging on never repeats or skips one.
            page = try MCPAccessPolicy.filteredPage(offset: offset, limit: limit, fetch: { from, count in
                var filter = QueryHistoryFilter(connectionId: connectionId,
                                                search: (search?.isEmpty ?? true) ? nil : search,
                                                limit: count, offset: from)
                filter.status = status
                return try PharosCore.loadQueryHistory(filter: filter)
            }, keep: { MCPAccessPolicy.allowsHistoryEntry(connectionId: $0.connectionId, allowed: allowed) })
        } catch {
            throw MCPToolError.failed("Pharos could not read its query history: \(error.localizedDescription)")
        }
        let rows: [JSONValue] = page.items.map { e in
            let (sql, _) = MCPResultShaper.cut(e.sql, to: maxSQL)
            var o: [String: JSONValue] = [
                "id": .string(e.id),
                "connection_id": .string(e.connectionId),
                "connection_name": .string(e.connectionName),
                "sql": .string(sql),
                "executed_at": .string(e.executedAt),
                "execution_time_ms": .int(Int(e.executionTimeMs)),
                "status": .string(e.isSucceeded ? "succeeded" : e.status),
                "schema": .optional(e.schema),
                "tables": .optional(e.tableNames),
            ]
            if let n = e.rowCount { o["row_count"] = .int(Int(n)) }
            if let error = e.errorMessage { o["error"] = .string(error) }
            return .object(o)
        }
        return [
            "entries": .array(rows),
            "next_offset": .optional(page.next),
        ]
    }

    private static func listVariables(_ args: MCPArguments) throws -> JSONValue {
        let store = QueryVariableStore.shared
        try? store.loadIfNeeded()
        let connectionId = args.optionalString("connection_id")
        if let connectionId { _ = try connection(connectionId) }
        let variables = connectionId.map { store.available(for: $0) } ?? store.variables
        let shareValues = state.settings.security.mcpVariableValues.allows(isLocal: isLocal)
        let allowed = allowed
        let rows: [JSONValue] = variables.filter { !$0.name.isEmpty }.compactMap { v in
            // A variable linked only to connections the user has not shared
            // is not shown; a linked one shows only its shared links.
            let access = MCPAccessPolicy.variableLinks(v.connectionIds, allowed: allowed)
            guard access.shared else { return nil }
            var o: [String: JSONValue] = [
                "name": .string(v.name),
                "type": .string(v.type.rawValue),
                "scope": .string(v.isGlobal ? "global" : "linked"),
                "connection_ids": .array(access.links.map(JSONValue.string)),
            ]
            if shareValues { o["value"] = .string(v.value) }
            return .object(o)
        }
        var out: [String: JSONValue] = ["variables": .array(rows), "values_shared": .bool(shareValues)]
        if !shareValues {
            out["message"] = "Values are not shared with this app: the user can allow it in Pharos, Settings ▸ Security & Privacy ▸ AI apps that can read variable values. run_card fills them in either way."
        }
        return .object(out)
    }

    private static func openSession(_ args: MCPArguments) async throws -> JSONValue {
        let sessionId = args.optionalString("saved_session_id")
        let workspaceId = args.optionalString("workspace_id")
        guard (sessionId == nil) != (workspaceId == nil) else {
            throw MCPToolError.invalidArgument("Give saved_session_id or workspace_id, not both and not neither.")
        }
        ensureWindow()
        if let sessionId {
            guard let stored = SavedQueryEntity.stored(id: sessionId), isShared(stored, allowed: allowed) else {
                throw MCPToolError.notFound("No saved Session shared with this app has the id \(sessionId). Call list_saved_sessions.")
            }
            // "Open in Tab", the sidebar's own path: an open tab is fronted,
            // not opened twice.
            NotificationCenter.default.post(name: .openSavedQuery, object: nil,
                                            userInfo: ["query": stored, "mode": SessionOpenMode.restore.rawValue])
            guard await wait(seconds: 5, until: { state.findTab { $0.savedQueryId == sessionId } != nil }),
                  let found = state.findTab(where: { $0.savedQueryId == sessionId }) else {
                throw MCPToolError.failed("Pharos did not open “\(stored.name)”.")
            }
            guard isShared(found.tab, allowed: allowed) else { throw notSharedAfterOpening }
            return ["tab": describe(tab: found.tab)]
        }
        let id = workspaceId!
        guard isShared(workspaceId: id, allowed: allowed) else {
            throw MCPToolError.notFound("No workspace shared with this app has the id \(id). Call list_workspaces.")
        }
        NotificationCenter.default.post(name: .openWorkspace, object: nil, userInfo: ["workspaceId": id])
        guard await wait(seconds: 5, until: { state.findTab { $0.workspaceId == id } != nil }),
              let found = state.findTab(where: { $0.workspaceId == id }) else {
            throw MCPToolError.notFound("Pharos did not open a workspace with the id \(id). Call list_workspaces.")
        }
        guard isShared(found.tab, allowed: allowed) else { throw notSharedAfterOpening }
        return ["tab": describe(tab: found.tab)]
    }

    /// The item was already open in a tab the user has since moved to a
    /// connection they do not share.
    private static let notSharedAfterOpening = MCPToolError.refused(
        "Pharos showed it in a tab that is not shared with AI apps (its connection, or a result in it, is on a connection the user has not shared).")

    /// A new tab on `connectionId`, connecting in the background.
    private static func makeTab(connectionId: String, name: String?) throws -> Located {
        let config = try connection(connectionId)
        guard let delegate else { throw MCPToolError.failed("Pharos has no window to open a tab in.") }
        let controller = delegate.openItem(QueryTab(name: state.nextTabName()))
        guard let tab = controller.session.tab else { throw MCPToolError.failed("Pharos could not open a tab.") }
        state.useConnection(config.id, forTabId: tab.id, in: controller.session)
        if let name = name.map(AuthoredLabelSanitizer.committed), !name.isEmpty {
            controller.session.updateTab(id: tab.id) {
                $0.name = name
                $0.nameIsCustom = true
            }
        }
        if state.status(for: config.id) == .disconnected || state.status(for: config.id) == .error {
            state.markQuietConnect(config.id)
            state.connect(id: config.id)
        }
        return try locate(tab.id)
    }

    private static func createTab(_ args: MCPArguments, client: MCPClientInfo) throws -> JSONValue {
        let located = try makeTab(connectionId: try args.string("connection_id"), name: args.optionalString("name"))
        located.controller.showAgentNotice(String(localized: "\(client.displayName) opened this tab."))
        return ["tab": describe(tab: located.tab)]
    }

    // MARK: - Cards

    private static func describe(card: QueryCard, in located: Located) -> JSONValue {
        let phase = located.controller.runPhase(ofCard: card.id, inTab: located.tab.id)
        let status: String
        if phase != .idle {
            status = phase.rawValue
        } else if card.lastFailureId != nil {
            status = "failed"
        } else if card.lastRun != nil {
            status = "succeeded"
        } else {
            status = "never_run"
        }
        var o: [String: JSONValue] = [
            "id": .string(card.id),
            "name": .optional(card.name),
            "version": .int(card.version),
            "lineage_id": .string(card.lineageId),
            "locked": .bool(card.isLocked),
            "kind": .string(card.kind.rawValue),
            "sql": .string(card.sql),
            "notes": .optional(card.hasNotes ? card.notes : nil),
            "status": .string(status),
            "has_result": .bool(located.session.resultStore[located.tab.id].result(forCard: card.id)?.hasResult ?? false),
            "is_displayed": .bool(located.tab.document.displayedCardId == card.id),
        ]
        if let run = card.lastRun {
            var r: [String: JSONValue] = [
                "run_id": .string(run.runId),
                "finished_at": .string(isoFormatter.string(from: run.finishedAt)),
                "execution_time_ms": .int(Int(run.executionTimeMs)),
                "ran_sql": .string(run.renderedSQL),
            ]
            switch run.summary {
            case let .rows(count, hasMore):
                r["rows"] = .int(count)
                r["server_has_more"] = .bool(hasMore)
            case let .affected(n):
                r["rows_affected"] = .int(n)
            }
            o["last_run"] = .object(r)
        }
        if let failureId = card.lastFailureId,
           let failure = located.tab.failureLog.entries.first(where: { $0.id == failureId }) {
            o["last_error"] = .string(failure.message)
        }
        if card.resultsRemoved { o["results_removed"] = true }
        return .object(o)
    }

    private static func listCards(_ args: MCPArguments) throws -> JSONValue {
        let located = try locate(try args.string("tab_id"))
        return [
            "tab": describe(tab: located.tab),
            "cards": .array(located.tab.document.cards.map { describe(card: $0, in: located) }),
        ]
    }

    private static func getCard(_ args: MCPArguments) throws -> JSONValue {
        let located = try locate(try args.string("tab_id"))
        let card = try card(try args.string("card_id"), in: located)
        return ["tab_id": .string(located.tab.id), "card": describe(card: card, in: located)]
    }

    private static func createCard(_ args: MCPArguments, client: MCPClientInfo) throws -> JSONValue {
        let sql = try args.string("sql")
        let tabId = args.optionalString("tab_id")
        let connectionId = args.optionalString("connection_id")
        guard (tabId == nil) != (connectionId == nil) else {
            throw MCPToolError.invalidArgument("Give tab_id (an open tab) or connection_id (a new tab), not both and not neither.")
        }
        var located = try tabId.map(locate) ?? makeTab(connectionId: connectionId!, name: nil)
        let after = args.optionalString("after_card_id")
        if let after { _ = try card(after, in: located) }
        let name = args.optionalString("name").map(AuthoredLabelSanitizer.committed).flatMap { $0.isEmpty ? nil : $0 }
        let notes = args.optionalString("notes")
        var newId = ""
        located.session.updateTab(id: located.tab.id) { tab in
            newId = after.map { tab.document.insertCard(after: $0, sql: sql, name: name) }
                ?? tab.document.appendCard(sql: sql, name: name)
            if let notes { tab.document.setNotes(cardId: newId, notes) }
        }
        located.controller.agentChangedCards(inTab: located.tab.id, anchor: newId)
        located.controller.showAgentNotice(String(localized: "\(client.displayName) added a card."))
        Log.ui.info("MCP client \(client.displayName, privacy: .public) added a card")
        located = try locate(located.tab.id)
        let card = try card(newId, in: located)
        return ["tab_id": .string(located.tab.id), "card": describe(card: card, in: located)]
    }

    private static func updateCard(_ args: MCPArguments, client: MCPClientInfo) throws -> JSONValue {
        var located = try locate(try args.string("tab_id"))
        let cardId = try args.string("card_id")
        let original = try card(cardId, in: located)
        guard args.has("sql") || args.has("name") || args.has("notes") else {
            throw MCPToolError.invalidArgument("Give sql, name or notes to change.")
        }
        if args.has("sql") {
            guard original.kind == .sql else {
                throw MCPToolError.refused("This card holds a psql command or COPY data, which Pharos does not run; its text cannot be edited here.")
            }
            if original.isLocked {
                let newest = located.tab.document.cards.last { $0.lineageId == original.lineageId }
                throw MCPToolError.refused("This card is a locked version: its SQL is what its results came from. Edit the newest version (card \(newest?.id ?? cardId)), or create_card for a new query.")
            }
            guard located.controller.runPhase(ofCard: cardId, inTab: located.tab.id) == .idle else {
                throw MCPToolError.refused("This card is running or waiting to run. Wait for it (get_card) or cancel_card first.")
            }
        }
        let sql = args.optionalString("sql")
        let name = args.optionalString("name")
        let notes = args.optionalString("notes")
        located.session.updateTab(id: located.tab.id) { tab in
            if let sql { tab.document.updateSQL(cardId: cardId, sql) }
            if let name { tab.document.rename(cardId: cardId, name: AuthoredLabelSanitizer.committed(name)) }
            if let notes { tab.document.setNotes(cardId: cardId, notes.isEmpty ? nil : notes) }
        }
        located.controller.agentChangedCards(inTab: located.tab.id, anchor: cardId)
        located.controller.showAgentNotice(String(localized: "\(client.displayName) edited a card."))
        located = try locate(located.tab.id)
        return ["tab_id": .string(located.tab.id), "card": describe(card: try card(cardId, in: located), in: located)]
    }

    private static func runCard(_ args: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        var located = try locate(try args.string("tab_id"))
        let cardId = try args.string("card_id")
        let replace = try args.bool("replace", default: false)
        let waitSeconds = try args.int("wait_seconds", default: MCPToolCatalog.defaultWaitSeconds,
                                       range: 0...MCPToolCatalog.maxWaitSeconds)
        let limit = try args.int("limit", default: 20, range: 0...MCPToolCatalog.maxRowLimit)
        let maxCell = try args.int("max_cell_chars", default: MCPToolCatalog.defaultMaxCellChars,
                                   range: 1...MCPToolCatalog.maxCellChars)
        let card = try card(cardId, in: located)
        guard card.kind == .sql else {
            throw MCPToolError.refused("This card holds a psql command or COPY data, which Pharos does not run.")
        }
        guard !card.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError.refused("This card has no SQL. Give it some with update_card.")
        }
        guard let connectionId = located.tab.connectionId else {
            throw MCPToolError.refused("Tab “\(located.tab.name)” has no connection. Create a card with connection_id for a tab that has one.")
        }
        let tabId = located.tab.id
        let controller = located.controller
        // What the tab held before this run, to tell which card it lands on.
        var runIdsBefore = Set(located.tab.document.cards.compactMap { $0.lastRun?.runId })
        var failureBefore = card.lastFailureId

        if controller.runPhase(ofCard: cardId, inTab: tabId) == .idle {
            // Checked here as well as in `startJob`, so the client hears why
            // instead of the Variable Manager opening in front of the user.
            let rendered = VariableSubstitutor.render(card.sql, with: QueryVariableStore.shared.available(for: connectionId))
            if !rendered.unresolved.isEmpty || !rendered.invalid.isEmpty {
                let parts = rendered.unresolved.map { "{{\($0)}} is not defined for this connection" }
                    + rendered.invalid.map { "{{\($0.name)}}: \($0.reason)" }
                throw MCPToolError.refused("The card's variables cannot be filled in: \(parts.joined(separator: "; ")). The user defines variables in Pharos's Variable Manager.")
            }
            let keywords = DestructiveSQLScanner.destructiveKeywords(in: rendered.sql)
            if !keywords.isEmpty && !state.settings.security.mcpWrites.allows(isLocal: isLocal) {
                throw MCPToolError.refused("Pharos does not let this app run statements that change data (\(keywords.joined(separator: ", "))). The user can allow it in Pharos: Settings ▸ Security & Privacy ▸ AI apps that can change data. Each run is still confirmed in Pharos.")
            }
            try await ensureConnected(connectionId)
            located = try locate(tabId)
            guard located.tab.document.card(cardId) != nil else {
                throw MCPToolError.notFound("The card was deleted.")
            }
            runIdsBefore = Set(located.tab.document.cards.compactMap { $0.lastRun?.runId })
            failureBefore = located.tab.document.card(cardId)?.lastFailureId
            controller.agentRunCardIds[cardId] = client
            controller.runCard(cardId, mode: replace ? .replace : .run, inTab: tabId)
            controller.showAgentNotice(String(localized: "\(client.displayName) ran a card."))
        }

        _ = await wait(seconds: Double(waitSeconds)) {
            controller.runPhase(ofCard: cardId, inTab: tabId) == .idle
        }

        located = try locate(tabId)
        let phase = controller.runPhase(ofCard: cardId, inTab: tabId)
        if phase != .idle {
            // `agentRunCardIds` stays: a card still queued must be confirmed
            // when its job starts; `startJob` takes the mark then.
            let note = phase == .awaitingConfirmation
                ? "The user has not answered Pharos's confirmation yet."
                : "The run has not finished yet."
            let current = located.tab.document.card(cardId)
            return [
                "tab_id": .string(tabId), "card_id": .string(cardId), "status": .string(phase.rawValue),
                "message": .string(note + " Call get_card to follow it, then get_card_result."),
                "card": current.map { describe(card: $0, in: located) } ?? .null,
            ]
        }

        // Which card the result went on: an edited card that had run splits,
        // and its new version carries the run (`CardDocument.completeRun`).
        if let resultCard = located.tab.document.cards.first(where: { c in
            c.lastRun.map { !runIdsBefore.contains($0.runId) } ?? false
        }) {
            var out: [String: JSONValue] = [
                "tab_id": .string(tabId), "card_id": .string(resultCard.id), "status": "succeeded",
                "card": describe(card: resultCard, in: located),
            ]
            if resultCard.id != cardId {
                out["message"] = .string("The card had run before and its SQL changed, so the result is on a new version: card \(resultCard.id). The old version is locked.")
            }
            if limit > 0, let result = located.session.resultStore[tabId].result(forCard: resultCard.id) {
                out["result"] = try await page(of: result, offset: 0, limit: limit, maxCellChars: maxCell)
            }
            return .object(out)
        }
        let current = located.tab.document.card(cardId)
        if let failureId = current?.lastFailureId, failureId != failureBefore {
            let message = located.tab.failureLog.entries.first { $0.id == failureId }?.message ?? "The run failed."
            return [
                "tab_id": .string(tabId), "card_id": .string(cardId), "status": "failed",
                "error": .string(message),
                "card": current.map { describe(card: $0, in: located) } ?? .null,
            ]
        }
        return [
            "tab_id": .string(tabId), "card_id": .string(cardId), "status": "cancelled",
            "message": "The run did not happen: the user cancelled it, or answered Cancel to Pharos's confirmation.",
            "card": current.map { describe(card: $0, in: located) } ?? .null,
        ]
    }

    private static func getCardResult(_ args: MCPArguments) async throws -> JSONValue {
        let located = try locate(try args.string("tab_id"))
        let cardId = try args.string("card_id")
        _ = try card(cardId, in: located)
        let offset = try args.int("offset", default: 0, range: 0...Int(Int32.max))
        let limit = try args.int("limit", default: MCPToolCatalog.defaultRowLimit, range: 1...MCPToolCatalog.maxRowLimit)
        let maxCell = try args.int("max_cell_chars", default: MCPToolCatalog.defaultMaxCellChars,
                                   range: 1...MCPToolCatalog.maxCellChars)
        guard let result = located.session.resultStore[located.tab.id].result(forCard: cardId), result.hasResult else {
            throw MCPToolError.notFound("This card holds no result. Run it with run_card first.")
        }
        return [
            "tab_id": .string(located.tab.id), "card_id": .string(cardId),
            "result": try await page(of: result, offset: offset, limit: limit, maxCellChars: maxCell),
        ]
    }

    /// A page of a result: rows in memory, or read from where a reopened
    /// workspace or Session stored them.
    private static func page(of result: CardResult, offset: Int, limit: Int, maxCellChars: Int) async throws -> JSONValue {
        if let affected = result.executeResult {
            return ["kind": "statement", "rows_affected": .int(Int(affected.rowsAffected)),
                    "execution_time_ms": .int(Int(affected.executionTimeMs))]
        }
        var rows = result.queryResult
        if rows == nil, result.isLoadable {
            let stored = result
            rows = await Task.detached(priority: .userInitiated) {
                ContentViewController.loadStoredRows(stored)
            }.value
        }
        guard let rows else { throw MCPToolError.failed("Pharos could not read this card's stored rows.") }
        let columns = rows.columns.map { MCPResultShaper.Column(name: $0.name, type: $0.dataType) }
        let page = MCPResultShaper.page(columns: columns, rowCount: rows.rows.rowCount, serverHasMore: rows.hasMore,
                                        offset: offset, limit: limit, maxCellChars: maxCellChars) { r, c in
            rows.rows.string(r, c)
        }
        guard case var .object(o) = page else { return page }
        o["kind"] = "rows"
        o["execution_time_ms"] = .int(Int(result.executionTimeMs))
        return .object(o)
    }

    private static func cancelCard(_ args: MCPArguments) throws -> JSONValue {
        let located = try locate(try args.string("tab_id"))
        let cardId = try args.string("card_id")
        _ = try card(cardId, in: located)
        let message: String
        switch located.controller.cancelCard(cardId, inTab: located.tab.id) {
        case .removedFromQueue: message = "The card was waiting to run; it no longer will."
        case .cancelling: message = "Pharos asked the server to cancel the run. Call get_card to see it end."
        case .awaitingConfirmation:
            throw MCPToolError.refused("The run is waiting for the user to answer Pharos's confirmation; only they can cancel it there.")
        case .notRunning: message = "The card was not running."
        }
        return ["tab_id": .string(located.tab.id), "card_id": .string(cardId), "message": .string(message)]
    }

    // MARK: - Saving

    private static func saveSession(_ args: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        let located = try locate(try args.string("tab_id"))
        let tabId = located.tab.id
        let controller = located.controller
        guard !ContentViewController.sessionWritesInFlight.contains(tabId) else {
            throw MCPToolError.refused("This tab is being saved already. Try again in a moment.")
        }

        if located.tab.savedQueryId != nil || located.tab.sourceURL != nil {
            let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                controller.saveTabInPlace(id: tabId, reportErrors: false) { done.resume(returning: $0) }
            }
            guard ok else { throw MCPToolError.failed("Pharos could not save the tab. The log has the reason.") }
            controller.showAgentNotice(String(localized: "\(client.displayName) saved this tab."))
            let tab = try locate(tabId).tab
            return ["saved": true, "saved_session_id": .optional(tab.savedQueryId),
                    "file": .optional(tab.sourceURL?.path), "name": .string(tab.name)]
        }

        let name = AuthoredLabelSanitizer.committed(args.optionalString("name") ?? located.tab.name)
        guard !name.isEmpty else { throw MCPToolError.invalidArgument("The Session needs a name.") }
        let folder = args.optionalString("folder").map(AuthoredLabelSanitizer.committed).flatMap { $0.isEmpty ? nil : $0 }
        let existing = (try? PharosCore.loadSavedQueries()) ?? []
        if existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && ($0.folder ?? "") == (folder ?? "") }) {
            throw MCPToolError.refused("A saved Session named “\(name)” is already in \(folder.map { "folder “\($0)”" } ?? "the library"). Choose another name.")
        }
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<Result<SavedQuery, MCPToolError>, Never>) in
            controller.saveAsNewSession(tabId: tabId, name: name, folder: folder) { done.resume(returning: $0) }
        }
        let saved = try outcome.get()
        controller.showAgentNotice(String(localized: "\(client.displayName) saved this tab as “\(saved.name)”."))
        Log.ui.info("MCP client \(client.displayName, privacy: .public) saved a Session")
        return ["saved": true, "saved_session_id": .string(saved.id), "name": .string(saved.name),
                "folder": .optional(saved.folder)]
    }
}
