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
