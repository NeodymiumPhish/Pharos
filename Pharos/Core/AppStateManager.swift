import Foundation
import Combine

/// Central state manager for the Pharos app. Observable via Combine.
/// Manages connections, active connection, settings, and connection status.
final class AppStateManager: ObservableObject {

    static let shared = AppStateManager()

    // MARK: - Published State

    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var connectionStatuses: [String: ConnectionStatus] = [:]
    @Published var activeConnectionId: String?
    @Published private(set) var settings: AppSettings = AppSettings()

    // Tab management
    @Published var tabs: [QueryTab] = []
    @Published var activeTabId: String?
    private var closedTabHistory: [QueryTab] = []
    private let maxClosedHistory = 20

    // Pin state
    @Published var pinnedResult: QueryResult?
    @Published var pinnedTabId: String?
    @Published var pinnedTabName: String?

    // MARK: - Notifications

    /// Posted when connections list changes. Object is the AppStateManager.
    static let connectionsDidChange = Notification.Name("PharosConnectionsDidChange")
    /// Posted when a connection's status changes. UserInfo has "connectionId" key.
    static let connectionStatusDidChange = Notification.Name("PharosConnectionStatusDidChange")

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
        }
    }

    func connect(id: String) {
        connectionStatuses[id] = .connecting
        postStatusChange(id)

        Task {
            do {
                let info = try await PharosCore.connect(connectionId: id)
                await MainActor.run {
                    self.connectionStatuses[id] = info.status
                    self.activeConnectionId = id
                    self.postStatusChange(id)
                }
            } catch {
                await MainActor.run {
                    self.connectionStatuses[id] = .error
                    self.postStatusChange(id)
                    NSLog("Connection failed: \(error)")
                }
            }
        }
    }

    func disconnect(id: String) {
        Task {
            do {
                try await PharosCore.disconnect(connectionId: id)
                await MainActor.run {
                    self.connectionStatuses[id] = .disconnected
                    if self.activeConnectionId == id {
                        self.activeConnectionId = nil
                    }
                    self.postStatusChange(id)
                }
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
        }
    }

    // MARK: - Tab Management

    var activeTab: QueryTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeTabIndex: Int? {
        guard let id = activeTabId else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    @discardableResult
    func createTab(sql: String = "", name: String? = nil) -> QueryTab {
        let tabName = name ?? "Query \(tabs.count + 1)"
        let tab = QueryTab(name: tabName, connectionId: activeConnectionId, sql: sql)
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    func closeTab(id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closedTab = tabs[idx]
        closedTabHistory.append(closedTab)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory.removeFirst()
        }
        tabs.remove(at: idx)

        // Auto-unpin if closing the pinned source tab
        if pinnedTabId == id {
            unpinResults()
        }

        if activeTabId == id {
            if tabs.isEmpty {
                activeTabId = nil
            } else {
                let newIdx = min(idx, tabs.count - 1)
                activeTabId = tabs[newIdx].id
            }
        }
    }

    func unpinResults() {
        pinnedResult = nil
        pinnedTabId = nil
        pinnedTabName = nil
    }

    func closeOtherTabs(exceptId id: String) {
        for tab in tabs where tab.id != id {
            closedTabHistory.append(tab)
        }
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs = tabs.filter { $0.id == id }
        activeTabId = id
    }

    func closeTabsToRight(ofId id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let toClose = Array(tabs[(idx + 1)...])
        closedTabHistory.append(contentsOf: toClose)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs = Array(tabs[...idx])
        if let activeId = activeTabId, !tabs.contains(where: { $0.id == activeId }) {
            activeTabId = id
        }
    }

    func duplicateTab(id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let newTab = QueryTab(name: "\(tab.name) Copy", connectionId: tab.connectionId, sql: tab.sql)
        if let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs.insert(newTab, at: idx + 1)
        } else {
            tabs.append(newTab)
        }
        activeTabId = newTab.id
    }

    func reopenLastClosedTab() {
        guard !closedTabHistory.isEmpty else { return }
        let tab = closedTabHistory.removeLast()
        // Give it a new ID to avoid conflicts
        let reopened = QueryTab(name: tab.name, connectionId: tab.connectionId, sql: tab.sql)
        tabs.append(reopened)
        activeTabId = reopened.id
    }

    var canReopenTab: Bool { !closedTabHistory.isEmpty }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabId = tabs[index].id
    }

    func updateTab(id: String, _ updater: (inout QueryTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        updater(&tabs[idx])
    }

    func moveTab(from: Int, to: Int) {
        guard from != to, tabs.indices.contains(from), to >= 0, to <= tabs.count else { return }
        let tab = tabs.remove(at: from)
        let insertAt = to > from ? to - 1 : to
        tabs.insert(tab, at: min(insertAt, tabs.count))
    }

    /// Ensure at least one tab exists. Call after connections load.
    func ensureTab() {
        if tabs.isEmpty {
            createTab()
        }
    }

    // MARK: - Helpers

    var activeConnection: ConnectionConfig? {
        guard let id = activeConnectionId else { return nil }
        return connections.first { $0.id == id }
    }

    func status(for connectionId: String) -> ConnectionStatus {
        connectionStatuses[connectionId] ?? .disconnected
    }

    var connectedConnectionIds: [String] {
        connectionStatuses.compactMap { $0.value == .connected ? $0.key : nil }
    }

    private func postStatusChange(_ connectionId: String) {
        NotificationCenter.default.post(
            name: Self.connectionStatusDidChange,
            object: self,
            userInfo: ["connectionId": connectionId]
        )
    }
}
