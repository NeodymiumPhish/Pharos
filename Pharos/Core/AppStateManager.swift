import Foundation
import Combine
import AppKit

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
    @Published var tabs: [QueryTab] = []
    @Published var activeTabId: String?
    private var closedTabHistory: [QueryTab] = []
    private let maxClosedHistory = 20

    // Pane management
    @Published var panes: [EditorPane] = []
    @Published var focusedPaneId: String?

    // Pin state
    @Published var pinnedResult: QueryResult?
    @Published var pinnedTabId: String?
    @Published var pinnedTabName: String?

    // MARK: - Notifications

    /// Posted when connections list changes. Object is the AppStateManager.
    static let connectionsDidChange = Notification.Name("PharosConnectionsDidChange")
    /// Posted when a connection's status changes. UserInfo has "connectionId" key.
    static let connectionStatusDidChange = Notification.Name("PharosConnectionStatusDidChange")
    /// Posted just before tabs are removed via close/closeOthers/closeToRight/closePane.
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
            NSLog("Failed to load connections: \(error)")
        }
    }

    func saveConnection(_ config: ConnectionConfig) {
        do {
            try PharosCore.saveConnection(config)
            loadConnections()
        } catch {
            NSLog("Failed to save connection: \(error)")
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
            NSLog("Failed to delete connection: \(error)")
            lastError = "Failed to delete connection: \(error.localizedDescription)"
        }
    }

    /// Persist a new ordering for all connections. Pass the full ordered ID list.
    func reorderConnections(ids: [String]) {
        do {
            try PharosCore.reorderConnections(ids: ids)
            loadConnections()
        } catch {
            NSLog("Failed to reorder connections: \(error)")
            lastError = "Failed to reorder connections: \(error.localizedDescription)"
        }
    }

    func connect(id: String) {
        connectionStatuses[id] = .connecting
        postStatusChange(id)

        Task {
            do {
                let info = try await PharosCore.connect(connectionId: id)
                self.connectionStatuses[id] = info.status
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
                self.postStatusChange(id)
                NSLog("Connection failed: \(error)")
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
                NSLog("Disconnect failed: \(error)")
            }
        }
    }

    // MARK: - Settings

    func loadSettings() {
        do {
            settings = try PharosCore.loadSettings()
        } catch {
            NSLog("Failed to load settings: \(error)")
        }
    }

    func saveSettings(_ newSettings: AppSettings) {
        do {
            try PharosCore.saveSettings(newSettings)
            settings = newSettings
        } catch {
            NSLog("Failed to save settings: \(error)")
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

    /// Ensure at least one tab exists. Call after connections load.
    func ensureTab() {
        ensurePaneAndTab()
    }

    // MARK: - Pane Management

    /// Ensure at least one pane with one tab exists.
    /// Also adopts any orphaned tabs (paneId == nil) into the first pane.
    func ensurePaneAndTab() {
        if panes.isEmpty {
            let pane = EditorPane(id: UUID().uuidString)
            panes.append(pane)
            focusedPaneId = pane.id
        }

        // Adopt orphaned tabs (created before pane system) into the first pane
        let paneId = panes[0].id
        for i in tabs.indices where tabs[i].paneId == nil {
            tabs[i].paneId = paneId
            if !panes[0].tabIds.contains(tabs[i].id) {
                panes[0].tabIds.append(tabs[i].id)
            }
        }

        if panes[0].tabIds.isEmpty {
            createTab(inPane: paneId)
        } else if panes[0].activeTabId == nil {
            panes[0].activeTabId = activeTabId ?? panes[0].tabIds.first
            syncActiveTabId()
        }
    }

    /// Create a new pane with a default tab and focus it.
    @discardableResult
    func addPane() -> EditorPane {
        // Collapse any expanded pane
        for i in panes.indices {
            panes[i].isExpanded = false
        }
        var pane = EditorPane(id: UUID().uuidString)
        let tab = QueryTab(name: "Query \(tabs.count + 1)", paneId: pane.id)
        tabs.append(tab)
        pane.tabIds = [tab.id]
        pane.activeTabId = tab.id
        panes.append(pane)
        focusedPaneId = pane.id
        activeTabId = tab.id
        return pane
    }

    /// Close a pane and archive its tabs. If it's the last pane, create a new empty one.
    func closePane(id: String) {
        guard let paneIdx = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes[paneIdx]

        // Cancel in-flight queries for all tabs in this pane
        let closingTabs = tabs.filter { pane.tabIds.contains($0.id) }
        cancelQueriesBeforeClose(for: closingTabs)

        // Archive tabs from this pane
        for tabId in pane.tabIds {
            if let tab = tabs.first(where: { $0.id == tabId }) {
                closedTabHistory.append(tab)
            }
        }
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }

        // Remove the tabs belonging to this pane
        tabs.removeAll { pane.tabIds.contains($0.id) }

        // Auto-unpin if the pinned tab was in this pane
        if let pinnedId = pinnedTabId, pane.tabIds.contains(pinnedId) {
            unpinResults()
        }

        panes.remove(at: paneIdx)

        if panes.isEmpty {
            // Always keep at least one pane
            ensurePaneAndTab()
        } else {
            // Focus adjacent pane
            let newIdx = min(paneIdx, panes.count - 1)
            focusedPaneId = panes[newIdx].id
            syncActiveTabId()
        }
    }

    /// Toggle a pane's expanded state.
    func togglePaneExpansion(id: String) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[idx].isExpanded.toggle()
        // If expanding, collapse all others
        if panes[idx].isExpanded {
            for i in panes.indices where i != idx {
                panes[i].isExpanded = false
            }
        }
    }

    /// Set the focused pane.
    func focusPane(id: String) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneId = id
        syncActiveTabId()
    }

    /// Create a tab in a specific pane (defaults to focused pane).
    @discardableResult
    func createTab(inPane paneId: String? = nil, sql: String = "", name: String? = nil) -> QueryTab {
        let targetPaneId = paneId ?? focusedPaneId ?? panes.first?.id
        guard let targetPaneId, let paneIdx = panes.firstIndex(where: { $0.id == targetPaneId }) else {
            // Fallback: create without pane (backward compat)
            let tabName = name ?? "Query \(tabs.count + 1)"
            var tab = QueryTab(name: tabName, sql: sql)
            applyDefaultSchema(&tab)
            tabs.append(tab)
            activeTabId = tab.id
            return tab
        }

        let tabName = name ?? "Query \(tabs.count + 1)"
        var tab = QueryTab(name: tabName, sql: sql, paneId: targetPaneId)
        applyDefaultSchema(&tab)
        tabs.append(tab)
        panes[paneIdx].tabIds.append(tab.id)
        panes[paneIdx].activeTabId = tab.id
        focusedPaneId = targetPaneId
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

    /// Select a tab within its pane and focus that pane.
    func selectTab(id: String, inPane paneId: String? = nil) {
        let targetPaneId = paneId ?? tabs.first(where: { $0.id == id })?.paneId ?? focusedPaneId
        if let targetPaneId, let paneIdx = panes.firstIndex(where: { $0.id == targetPaneId }) {
            panes[paneIdx].activeTabId = id
            focusedPaneId = targetPaneId
        }
        activeTabId = id
    }

    /// Reorder tab IDs within a pane.
    func reorderTabs(_ newTabIds: [String], inPane paneId: String) {
        guard let paneIdx = panes.firstIndex(where: { $0.id == paneId }) else { return }
        panes[paneIdx].tabIds = newTabIds
    }

    /// Get ordered tabs for a specific pane.
    func tabs(forPane paneId: String) -> [QueryTab] {
        guard let pane = panes.first(where: { $0.id == paneId }) else { return [] }
        return pane.tabIds.compactMap { tabId in
            tabs.first { $0.id == tabId }
        }
    }

    /// Sync `activeTabId` from the focused pane's active tab.
    private func syncActiveTabId() {
        guard let focusedId = focusedPaneId,
              let pane = panes.first(where: { $0.id == focusedId }) else {
            activeTabId = nil
            return
        }
        activeTabId = pane.activeTabId
    }

    // MARK: - Pane-Aware Tab Closing

    /// Close a tab, removing it from its pane's tab list.
    func closeTab(id: String) {
        if let tab = tabs.first(where: { $0.id == id }) {
            cancelQueriesBeforeClose(for: [tab])
        }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closedTab = tabs[idx]
        closedTabHistory.append(closedTab)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory.removeFirst()
        }

        // Remove from pane
        if let paneId = closedTab.paneId,
           let paneIdx = panes.firstIndex(where: { $0.id == paneId }) {
            panes[paneIdx].tabIds.removeAll { $0 == id }

            // Update pane's active tab
            if panes[paneIdx].activeTabId == id {
                let remainingIds = panes[paneIdx].tabIds
                if remainingIds.isEmpty {
                    // If this is the only pane, create a new tab; otherwise close the pane
                    if panes.count == 1 {
                        panes[paneIdx].activeTabId = nil
                        tabs.remove(at: idx)
                        if pinnedTabId == id { unpinResults() }
                        // Create a fresh tab in this pane
                        createTab(inPane: paneId)
                        return
                    } else {
                        tabs.remove(at: idx)
                        if pinnedTabId == id { unpinResults() }
                        closePane(id: paneId)
                        return
                    }
                } else {
                    // Select adjacent tab within the pane
                    let tabIdxInPane = min(panes[paneIdx].tabIds.count - 1,
                                           max(0, (closedTab.paneId != nil ? panes[paneIdx].tabIds.firstIndex(of: id) ?? 0 : 0)))
                    // The tab is already removed from tabIds, so just pick last valid
                    let newIdx = min(remainingIds.count - 1, max(0, tabIdxInPane))
                    panes[paneIdx].activeTabId = remainingIds[newIdx]
                }
            }
        }

        tabs.remove(at: idx)
        if pinnedTabId == id { unpinResults() }
        syncActiveTabId()
    }

    func closeOtherTabs(exceptId id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let paneId = tab.paneId

        if let paneId, let paneIdx = panes.firstIndex(where: { $0.id == paneId }) {
            // Close other tabs within the same pane
            let otherIds = panes[paneIdx].tabIds.filter { $0 != id }
            let closingTabs = tabs.filter { otherIds.contains($0.id) }
            cancelQueriesBeforeClose(for: closingTabs)
            for otherId in otherIds {
                if let t = tabs.first(where: { $0.id == otherId }) {
                    closedTabHistory.append(t)
                }
            }
            if closedTabHistory.count > maxClosedHistory {
                closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
            }
            tabs.removeAll { otherIds.contains($0.id) }
            panes[paneIdx].tabIds = [id]
            panes[paneIdx].activeTabId = id
        } else {
            // Fallback: close all others globally
            for t in tabs where t.id != id {
                closedTabHistory.append(t)
            }
            if closedTabHistory.count > maxClosedHistory {
                closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
            }
            tabs = tabs.filter { $0.id == id }
        }
        activeTabId = id
    }

    func closeTabsToRight(ofId id: String) {
        guard let tab = tabs.first(where: { $0.id == id }),
              let paneId = tab.paneId,
              let paneIdx = panes.firstIndex(where: { $0.id == paneId }),
              let idxInPane = panes[paneIdx].tabIds.firstIndex(of: id) else { return }

        let toCloseIds = Array(panes[paneIdx].tabIds[(idxInPane + 1)...])
        let closingTabs = tabs.filter { toCloseIds.contains($0.id) }
        cancelQueriesBeforeClose(for: closingTabs)
        for closeId in toCloseIds {
            if let t = tabs.first(where: { $0.id == closeId }) {
                closedTabHistory.append(t)
            }
        }
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs.removeAll { toCloseIds.contains($0.id) }
        panes[paneIdx].tabIds = Array(panes[paneIdx].tabIds[...idxInPane])

        if let activeId = activeTabId, toCloseIds.contains(activeId) {
            panes[paneIdx].activeTabId = id
            activeTabId = id
        }
    }

    func duplicateTab(id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let paneId = tab.paneId
        let newTab = QueryTab(name: "\(tab.name) Copy", connectionId: tab.connectionId, sql: tab.sql, paneId: paneId)

        if let paneId, let paneIdx = panes.firstIndex(where: { $0.id == paneId }),
           let idxInPane = panes[paneIdx].tabIds.firstIndex(of: id) {
            tabs.append(newTab)
            panes[paneIdx].tabIds.insert(newTab.id, at: idxInPane + 1)
            panes[paneIdx].activeTabId = newTab.id
        } else {
            tabs.append(newTab)
        }
        activeTabId = newTab.id
    }

    func reopenLastClosedTab() {
        guard !closedTabHistory.isEmpty else { return }
        let tab = closedTabHistory.removeLast()
        let targetPaneId = focusedPaneId ?? panes.first?.id
        let reopened = QueryTab(name: tab.name, connectionId: tab.connectionId, sql: tab.sql, paneId: targetPaneId)
        tabs.append(reopened)

        if let targetPaneId, let paneIdx = panes.firstIndex(where: { $0.id == targetPaneId }) {
            panes[paneIdx].tabIds.append(reopened.id)
            panes[paneIdx].activeTabId = reopened.id
        }
        activeTabId = reopened.id
    }

    func selectTabByIndex(_ index: Int) {
        // Select tab by index within the focused pane
        guard let focusedId = focusedPaneId,
              let pane = panes.first(where: { $0.id == focusedId }),
              index >= 0, index < pane.tabIds.count else { return }
        let tabId = pane.tabIds[index]
        selectTab(id: tabId, inPane: focusedId)
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
