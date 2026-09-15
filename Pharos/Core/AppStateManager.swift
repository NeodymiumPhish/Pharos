import Foundation
import Combine
import AppKit
import LocalAuthentication
import os

/// The device-owner authentication gate: Touch ID, an unlocked Apple Watch, or
/// the login password, whichever the Mac offers.
///
/// It guards two ACTIONS — connecting with a record, and showing that record's
/// stored password — for connections whose `requiresAuthentication` is set. It
/// does not change where the password is stored: the Keychain item is written
/// and read exactly as before.
///
/// A cancel is reported apart from a failure, because the two mean different
/// things to the caller: nothing went wrong when the user changed their mind,
/// so the caller must not leave an error behind.
enum DeviceOwnerGate {

    enum Outcome {
        /// The device owner proved who they are.
        case authenticated
        /// The user dismissed the prompt, or the system withdrew it. Nothing failed.
        case cancelled
        /// No policy is available on this Mac, or the attempt was refused.
        case failed(reason: String)
    }

    /// Asks the device owner to authenticate. `reason` completes the system's
    /// own sentence, so it reads as a verb phrase ("connect to prod-db").
    ///
    /// `evaluatePolicy` is callback-based and answers on a private queue, so it
    /// is bridged with a continuation: the caller awaits, and the main actor
    /// keeps running while the prompt is up.
    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()

        // `.deviceOwnerAuthentication` already falls back to the login password,
        // so this only fails where NO policy is available at all — no biometry
        // enrolled and no password set. Asking first turns that into a sentence
        // the user can act on instead of a bare refusal.
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failed(reason: policyError?.localizedDescription
                ?? String(localized: "This Mac cannot ask you to authenticate."))
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .authenticated)
                    return
                }
                switch (error as? LAError)?.code {
                case .userCancel, .appCancel, .systemCancel:
                    continuation.resume(returning: .cancelled)
                default:
                    continuation.resume(returning: .failed(
                        reason: error?.localizedDescription
                            ?? String(localized: "Authentication did not succeed.")))
                }
            }
        }
    }
}

/// Central state manager for the Pharos app. Observable via Combine.
/// Manages connections, active connection, settings, and connection status.
@MainActor
final class AppStateManager: ObservableObject {

    static let shared = AppStateManager()

    // MARK: - Published State

    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var connectionStatuses: [String: ConnectionStatus] = [:]
    @Published var activeConnectionId: String? {
        didSet {
            if activeConnectionId != oldValue {
                // Save current schema selection for the old connection
                if let oldId = oldValue, let schema = activeSchema {
                    schemaSelections[oldId] = schema
                }
                // Restore schema selection for new connection (nil if none saved)
                activeSchema = activeConnectionId.flatMap { schemaSelections[$0] }

                // Tags are global; this is a cheap no-op after the first call.
                // It stays on the connection hook so a first connection still
                // primes the cache before the first result arrives.
                //
                // It sits OUTSIDE the `if let`, so it also runs when the id goes
                // to nil — a disconnect, or a tab that is bound to nothing. That
                // is harmless by design: the call is idempotent, and a nil id
                // does not mean "drop the tags". Tags outlive a connection, so
                // there is nothing to clear and nothing to reload.
                do {
                    try TagStore.shared.loadTagsIfNeeded()
                } catch {
                    // A failure must not block the connection. The user then has
                    // a working database and no tags, which is a degraded view,
                    // not a broken state.
                    Log.state.warning("Failed to load tags: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    @Published var activeSchema: String? {
        didSet {
            // Keep per-connection selection in sync
            if let connId = activeConnectionId {
                if let schema = activeSchema {
                    schemaSelections[connId] = schema
                } else {
                    schemaSelections.removeValue(forKey: connId)
                }
            }
        }
    }
    private var schemaSelections: [String: String] = [:]  // connectionId → schemaName
    @Published private(set) var settings: AppSettings = AppSettings()

    /// Last error from a state operation (save, delete, load). Observed by UI to show alerts.
    @Published var lastError: String?

    // Tab management
    @Published var tabs: [QueryTab] = [] {
        didSet {
            sessionDirty = true
            tabsSettled.send(tabs)
        }
    }
    @Published var activeTabId: String? {
        didSet {
            sessionDirty = true
            activeTabIdSettled.send(activeTabId)
        }
    }
    private var closedTabHistory: [QueryTab] = []
    private let maxClosedHistory = 20

    // Pin state
    @Published var pinnedResult: QueryResult?
    @Published var pinnedTabId: String? {
        didSet { pinnedTabIdSettled.send(pinnedTabId) }
    }
    @Published var pinnedTabName: String?

    // MARK: - Settled publishers

    // `@Published` emits from `willSet`: a subscriber that runs on the same
    // stack reads the OLD value back through the manager, which is why every
    // sink used to hop to `RunLoop.main` and every caller that then needed
    // the UI to have caught up waited one turn (`DispatchQueue.main.async`).
    // These emit from `didSet`, carry the current value, and are delivered
    // synchronously: when `selectTab` or `createTab` returns, the content
    // controller and the editor have already applied the change. The class
    // is `@MainActor`, so every send is on main.
    let tabsSettled = CurrentValueSubject<[QueryTab], Never>([])
    let activeTabIdSettled = CurrentValueSubject<String?, Never>(nil)
    let pinnedTabIdSettled = CurrentValueSubject<String?, Never>(nil)

    // MARK: - Notifications

    /// Posted when connections list changes. Object is the AppStateManager.
    static let connectionsDidChange = Notification.Name("PharosConnectionsDidChange")
    /// Posted when a connection's status changes. UserInfo has "connectionId" key.
    static let connectionStatusDidChange = Notification.Name("PharosConnectionStatusDidChange")
    /// Posted just before tabs are removed via close/closeOthers/closeToRight.
    /// userInfo carries `queryIds: [String]` — the queryIds whose completion
    /// notifications should be suppressed.
    static let queriesWillBeCancelled = Notification.Name("PharosQueriesWillBeCancelled")

    // MARK: - Init

    private init() {}

    // MARK: - Connection Management

    func loadConnections() {
        do {
            connections = try PharosCore.loadConnections()
            // Initialize all as disconnected
            for config in connections {
                if connectionStatuses[config.id] == nil {
                    connectionStatuses[config.id] = .disconnected
                }
            }
            NotificationCenter.default.post(name: Self.connectionsDidChange, object: self)
        } catch {
            Log.state.error("Failed to load connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveConnection(_ config: ConnectionConfig) {
        do {
            try PharosCore.saveConnection(config)
            loadConnections()
        } catch {
            Log.state.error("Failed to save connection: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to save connection: \(error.localizedDescription)"
        }
    }

    func deleteConnection(id: String) {
        do {
            try PharosCore.deleteConnection(id: id)
            connectionStatuses.removeValue(forKey: id)
            if activeConnectionId == id {
                activeConnectionId = nil
            }
            loadConnections()
        } catch {
            Log.state.error("Failed to delete connection: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to delete connection: \(error.localizedDescription)"
        }
    }

    /// Persist a new ordering for all connections. Pass the full ordered ID list.
    func reorderConnections(ids: [String]) {
        do {
            try PharosCore.reorderConnections(ids: ids)
            loadConnections()
        } catch {
            Log.state.error("Failed to reorder connections: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to reorder connections: \(error.localizedDescription)"
        }
    }

    /// Binds tab `tabId` to `connectionId`: applies the connection's default
    /// schema when the connection changes, syncs the global active connection
    /// and schema when the tab is the active one, and connects when the
    /// connection is idle. The toolbar pull-down goes through here.
    func useConnection(_ connectionId: String, forTabId tabId: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let connectionChanged = tab.connectionId != connectionId
        let newSchema = connections.first(where: { $0.id == connectionId })?.defaultSchema ?? "public"
        updateTab(id: tabId) {
            $0.connectionId = connectionId
            if connectionChanged { $0.schemaName = newSchema }
        }
        if tabId == activeTabId {
            activeConnectionId = connectionId
            if connectionChanged { activeSchema = newSchema }
        }
        if status(for: connectionId) == .disconnected {
            connect(id: connectionId)
        }
    }

    /// Why the last connect attempt for a connection did not succeed, keyed by
    /// connection id. A `.error` status says THAT it failed; this says why, so
    /// the connections form can show the reason beside the badge.
    @Published private(set) var connectionErrors: [String: String] = [:]

    func connectionError(for connectionId: String) -> String? {
        connectionErrors[connectionId]
    }

    /// Connects, asking the device owner to authenticate first when the record
    /// requires it.
    ///
    /// The status goes to `.connecting` before the prompt, so the toolbar is not
    /// silent while the sheet is up. A CANCEL returns it to `.disconnected`, not
    /// `.error`: nothing failed, and an error state here would be sticky.
    func connect(id: String) {
        guard let config = connections.first(where: { $0.id == id }),
              config.requiresAuthentication else {
            performConnect(id: id)
            return
        }

        connectionStatuses[id] = .connecting
        connectionErrors.removeValue(forKey: id)
        postStatusChange(id)

        let name = DisplayEscape.escapedTrimmed(config.name)
        Task { @MainActor in
            switch await DeviceOwnerGate.authenticate(
                reason: String(localized: "connect to \(name)")
            ) {
            case .authenticated:
                self.performConnect(id: id)
            case .cancelled:
                self.connectionStatuses[id] = .disconnected
                self.postStatusChange(id)
            case .failed(let reason):
                self.connectionErrors[id] = reason
                self.connectionStatuses[id] = .error
                self.postStatusChange(id)
                Log.state.error("Connection gate refused: \(reason, privacy: .public)")
            }
        }
    }

    private func performConnect(id: String) {
        connectionStatuses[id] = .connecting
        connectionErrors.removeValue(forKey: id)
        postStatusChange(id)

        Task {
            do {
                let info = try await PharosCore.connect(connectionId: id)
                self.connectionStatuses[id] = info.status
                // A refused connection comes back as a value, not a throw, so
                // without this the reason was lost and the toolbar only turned
                // red.
                if info.status == .error {
                    let reason = info.error ?? String(localized: "No reason given.")
                    self.connectionErrors[id] = reason
                    Log.state.error("Connection failed: \(reason, privacy: .public)")
                }
                self.activeConnectionId = id
                // Apply default schema from connection config, falling back to "public"
                let defaultSchema: String = {
                    if let config = self.connections.first(where: { $0.id == id }),
                       let ds = config.defaultSchema {
                        return ds
                    }
                    return "public"
                }()
                if self.schemaSelections[id] == nil {
                    self.activeSchema = defaultSchema
                }
                // Also update the active tab's schema to match
                if let tabId = self.activeTabId {
                    self.updateTab(id: tabId) { tab in
                        if tab.connectionId == id && tab.schemaName == nil {
                            tab.schemaName = self.activeSchema ?? defaultSchema
                        }
                    }
                }
                self.postStatusChange(id)
            } catch {
                self.connectionStatuses[id] = .error
                self.connectionErrors[id] = error.localizedDescription
                self.postStatusChange(id)
                Log.state.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func disconnect(id: String) {
        Task {
            do {
                try await PharosCore.disconnect(connectionId: id)
                self.connectionStatuses[id] = .disconnected
                if self.activeConnectionId == id {
                    self.activeConnectionId = nil
                }
                self.postStatusChange(id)
            } catch {
                Log.state.error("Disconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Settings

    func loadSettings() {
        do {
            settings = try PharosCore.loadSettings()
        } catch {
            Log.state.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveSettings(_ newSettings: AppSettings) {
        do {
            try PharosCore.saveSettings(newSettings)
            settings = newSettings
        } catch {
            Log.state.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Tab Management

    var activeTab: QueryTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    func unpinResults() {
        pinnedResult = nil
        pinnedTabId = nil
        pinnedTabName = nil
    }

    func updateTab(id: String, _ updater: (inout QueryTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        updater(&tabs[idx])
    }

    // MARK: - Workspace History Snapshots

    /// Build the upsert payload capturing a tab's current editor snapshot for the
    /// given workspace id. Returns nil if the tab has no connection.
    func workspaceUpsertPayload(for tab: QueryTab, workspaceId: String) -> WorkspaceUpsert? {
        guard let connId = tab.connectionId else { return nil }
        let connName = connections.first { $0.id == connId }?.name ?? connId
        let varsJson = (try? String(decoding: JSONEncoder.pharos.encode(tab.variables), as: UTF8.self)) ?? "[]"
        return WorkspaceUpsert(
            id: workspaceId,
            name: nil,
            nameIsCustom: false,
            connectionId: connId,
            connectionName: connName,
            editorText: tab.sql,
            variablesJson: varsJson,
            cursorPosition: tab.cursorPosition
        )
    }

    /// Flush a final editor snapshot for every tab already bound to a workspace.
    /// Called on tab close and app termination so the last edits are persisted.
    func snapshotWorkspaces() {
        for tab in tabs where tab.workspaceId != nil {
            guard let payload = workspaceUpsertPayload(for: tab, workspaceId: tab.workspaceId!) else { continue }
            try? PharosCore.upsertWorkspace(payload)
        }
    }

    // MARK: - Session (open tabs across launches)

    /// Set by the `tabs` / `activeTabId` hooks. The autosave timer writes only
    /// when it is set, so an idle app never touches the database.
    private var sessionDirty = false
    private var sessionAutosaveTimer: Timer?
    /// True from `prepareSessionRestore()` until the restore finishes. It gates
    /// `ensureTab()` (no stray "Query 1") and `snapshotSession()` (a half-built
    /// tab set must never overwrite the stored one).
    private(set) var isRestoringSession = false
    private var pendingSession: Session?

    /// A name the user authored, as opposed to the generated "Query <n>".
    ///
    /// A name the on-device model suggested is NOT covered here — it does not
    /// read as "Query <n>", so this answers true for it. `QueryTab
    /// .nameIsSuggested` is what tells the two apart, and `snapshotSession`
    /// consults both.
    static func isCustomTabName(_ name: String) -> Bool {
        let generated = try? Regex("^Query [0-9]+$")
        guard let generated else { return true }
        return name.wholeMatch(of: generated) == nil
    }

    /// Write the open tabs, their order and the active one to the store.
    /// Called from the autosave timer and from `applicationShouldTerminate`.
    func snapshotSession() {
        guard !isRestoringSession else { return }
        let saved = tabs.enumerated().map { idx, tab -> SessionTab in
            // Same encoder the workspace snapshot uses, so the two copies of a
            // tab's variables are byte-identical and decode the same way back.
            let varsJson = (try? String(decoding: JSONEncoder.pharos.encode(tab.variables), as: UTF8.self)) ?? "[]"
            return SessionTab(
                tabIndex: idx,
                workspaceId: tab.workspaceId,
                name: tab.name,
                nameIsCustom: !tab.nameIsSuggested && Self.isCustomTabName(tab.name),
                connectionId: tab.connectionId,
                schemaName: tab.schemaName,
                sql: tab.sql,
                cursorPosition: tab.cursorPosition,
                variablesJson: varsJson,
                isActive: tab.id == activeTabId
            )
        }
        do {
            try PharosCore.saveSession(Session(tabs: saved))
            sessionDirty = false
        } catch {
            Log.state.error("Failed to save session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start the 30-second autosave. Idempotent.
    func startSessionAutosave() {
        guard sessionAutosaveTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionDirty else { return }
                self.snapshotSession()
            }
        }
        timer.tolerance = 5
        sessionAutosaveTimer = timer
    }

    /// Read the stored session and, if it has tabs, hold back `ensureTab()`.
    /// Call BEFORE the main window is built: its content controller asks for a
    /// tab as soon as its view loads.
    func prepareSessionRestore() {
        guard settings.query.restoreOpenTabs else { return }
        guard let session = try? PharosCore.loadSession(), !session.tabs.isEmpty else { return }
        pendingSession = session
        isRestoringSession = true
    }

    /// Put the stored tabs back. Call AFTER the main window is on screen: a tab
    /// bound to a workspace is rebuilt by `ContentViewController`, which must be
    /// alive and observing `.openWorkspace`.
    func restoreSession() {
        guard let session = pendingSession else {
            startSessionAutosave()
            return
        }
        pendingSession = nil

        Task { @MainActor in
            // One tab at a time: the workspace handler rebuilds off the main
            // thread, so posting the whole set at once would land the tabs in
            // completion order rather than in the order they were saved.
            var restoredIds: [String] = []
            for saved in session.tabs {
                if let wsId = saved.workspaceId,
                   let id = await self.restoreWorkspaceTab(saved, workspaceId: wsId) {
                    restoredIds.append(id)
                } else {
                    // No workspace, or the workspace row is gone: the session's
                    // own copy of the editor text still brings the tab back.
                    restoredIds.append(self.restoreDraftTab(saved).id)
                }
            }

            if let idx = session.tabs.firstIndex(where: { $0.isActive }), idx < restoredIds.count {
                self.selectTab(id: restoredIds[idx])
            }

            self.isRestoringSession = false
            self.ensureTab()
            self.sessionDirty = false
            self.startSessionAutosave()
        }
    }

    /// Ask `ContentViewController` to rebuild a workspace tab, then wait for it
    /// to appear. Returns nil when the workspace no longer exists (the handler
    /// stays silent in that case, so the wait is what detects it).
    private func restoreWorkspaceTab(_ saved: SessionTab, workspaceId: String) async -> String? {
        if let existing = tabs.first(where: { $0.workspaceId == workspaceId }) { return existing.id }
        NotificationCenter.default.post(
            name: .openWorkspace, object: nil, userInfo: ["workspaceId": workspaceId]
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let tab = tabs.first(where: { $0.workspaceId == workspaceId }) else { continue }
            // The workspace row owns the editor text, variables and cursor. It
            // does not store the schema, so that comes from the session.
            updateTab(id: tab.id) { $0.schemaName = saved.schemaName }
            return tab.id
        }
        return nil
    }

    /// Rebuild a tab that never ran a query straight from the session row.
    @discardableResult
    private func restoreDraftTab(_ saved: SessionTab) -> QueryTab {
        let tab = createTab(sql: saved.sql, name: saved.name)
        let variables: [QueryVariable] = saved.variablesJson.flatMap {
            try? JSONDecoder.pharos.decode([QueryVariable].self, from: Data($0.utf8))
        } ?? []
        // The connection is recorded, not dialled: restoring must never open a
        // database connection the user did not ask for.
        updateTab(id: tab.id) {
            $0.connectionId = saved.connectionId
            $0.schemaName = saved.schemaName
            $0.cursorPosition = saved.cursorPosition
            $0.variables = variables
            $0.isDirty = false
        }
        return tab
    }

    /// Ensure at least one tab exists and one of them is active. Call after
    /// connections load.
    ///
    /// While a saved session is being put back this is a no-op: the content
    /// controller calls it as soon as its view loads, which is before the
    /// restored tabs exist, and an empty "Query 1" made here would survive as
    /// an extra tab beside them.
    func ensureTab() {
        guard !isRestoringSession else { return }
        if tabs.isEmpty {
            createTab()
        } else if !tabs.contains(where: { $0.id == activeTabId }) {
            activeTabId = tabs.first?.id
            syncActiveConnectionAndSchema()
        }
    }

    // MARK: - Tab Management

    /// Append a tab and make it active.
    @discardableResult
    func createTab(sql: String = "", name: String? = nil) -> QueryTab {
        let tabName = name ?? "Query \(tabs.count + 1)"
        var tab = QueryTab(name: tabName, sql: sql)
        applyDefaultSchema(&tab)
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    /// Apply the active connection's default schema to a new tab.
    private func applyDefaultSchema(_ tab: inout QueryTab) {
        guard let connId = activeConnectionId else { return }
        if let config = connections.first(where: { $0.id == connId }),
           let defaultSchema = config.defaultSchema {
            tab.connectionId = connId
            tab.schemaName = defaultSchema
        }
    }

    /// Make a tab active. Assigns even when the tab is already active; the
    /// settled publisher's subscribers dedupe.
    func selectTab(id: String) {
        activeTabId = id
    }

    /// Sync the global active connection/schema to the active tab's values so
    /// the sidebar/schema browser follows the active tab. Guarded sets + the
    /// `didSet` dedup on these properties make redundant calls (e.g. when
    /// EditorPaneVC.tabChanged also runs) a no-op.
    private func syncActiveConnectionAndSchema() {
        guard let tab = activeTab else { return }
        if let connId = tab.connectionId, connId != activeConnectionId {
            activeConnectionId = connId
        } else if tab.connectionId == nil && activeConnectionId != nil {
            activeConnectionId = nil
        }
        if tab.schemaName != activeSchema {
            activeSchema = tab.schemaName
        }
    }

    // MARK: - Tab Closing

    /// Close a tab. Closing the active tab makes the tab now at its index
    /// active (the one to its right, or the last). Closing the last tab
    /// replaces it with a fresh one.
    func closeTab(id: String) {
        if let tab = tabs.first(where: { $0.id == id }) {
            cancelQueriesBeforeClose(for: [tab])
        }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        closedTabHistory.append(tabs[idx])
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory.removeFirst()
        }

        tabs.remove(at: idx)
        if pinnedTabId == id { unpinResults() }

        if tabs.isEmpty {
            createTab()
        } else if activeTabId == id {
            activeTabId = tabs[min(idx, tabs.count - 1)].id
            syncActiveConnectionAndSchema()
        }
    }

    func closeOtherTabs(exceptId id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let others = tabs.filter { $0.id != id }
        cancelQueriesBeforeClose(for: others)
        closedTabHistory.append(contentsOf: others)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs = tabs.filter { $0.id == id }
        activeTabId = id
    }

    func closeTabsToRight(ofId id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = Array(tabs[(idx + 1)...])
        guard !closing.isEmpty else { return }
        cancelQueriesBeforeClose(for: closing)
        closedTabHistory.append(contentsOf: closing)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs = Array(tabs[...idx])

        if let activeId = activeTabId, closing.contains(where: { $0.id == activeId }) {
            activeTabId = id
        }
    }

    /// Insert a copy right after the source and make it active.
    func duplicateTab(id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        let newTab = QueryTab(name: "\(tab.name) Copy", connectionId: tab.connectionId, sql: tab.sql)
        tabs.insert(newTab, at: idx + 1)
        activeTabId = newTab.id
    }

    func reopenLastClosedTab() {
        guard !closedTabHistory.isEmpty else { return }
        let tab = closedTabHistory.removeLast()
        let reopened = QueryTab(name: tab.name, connectionId: tab.connectionId, sql: tab.sql)
        tabs.append(reopened)
        activeTabId = reopened.id
    }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectTab(id: tabs[index].id)
    }

    // MARK: - Helpers

    var activeConnection: ConnectionConfig? {
        guard let id = activeConnectionId else { return nil }
        return connections.first { $0.id == id }
    }

    func status(for connectionId: String) -> ConnectionStatus {
        connectionStatuses[connectionId] ?? .disconnected
    }

    private func postStatusChange(_ connectionId: String) {
        NotificationCenter.default.post(
            name: Self.connectionStatusDidChange,
            object: self,
            userInfo: ["connectionId": connectionId]
        )
    }

    /// Cancel in-flight queries for the given tabs (FFI cancel) and post a
    /// notification so observers (e.g. ContentViewController) can suppress
    /// completion notifications for these queryIds.
    private func cancelQueriesBeforeClose(for closingTabs: [QueryTab]) {
        var queryIds: [String] = []
        for tab in closingTabs {
            guard let connectionId = tab.connectionId else { continue }
            for q in tab.runningQueries {
                queryIds.append(q.id)
                Task {
                    _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: q.id)
                }
            }
        }
        if !queryIds.isEmpty {
            NotificationCenter.default.post(
                name: Self.queriesWillBeCancelled,
                object: nil,
                userInfo: ["queryIds": queryIds]
            )
        }
    }

    /// Open a file as a new editor tab. Ensures the main window exists
    /// and is frontmost, then routes to its `ContentViewController`.
    ///
    /// This is the single entry point used by `File > Open…`,
    /// `application(_:open:)`, and any future drag-to-dock handlers.
    @MainActor
    func openTextFile(at url: URL) {
        let app = NSApp.delegate as? AppDelegate
        if app?.mainWindowController == nil {
            // App launched via file-open with no window yet — create one.
            app?.mainWindowController = MainWindowController()
        }
        guard let controller = app?.mainWindowController else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // Walk the split-view children to find the ContentViewController.
        guard let split = controller.contentViewController as? PharosSplitViewController else { return }
        for item in split.splitViewItems {
            if let content = item.viewController as? ContentViewController {
                content.openTextFile(at: url)
                return
            }
        }
    }
}
