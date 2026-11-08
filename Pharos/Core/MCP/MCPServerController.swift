import AppKit
import Foundation

/// The app's MCP server: on while Settings ▸ Security & Privacy ▸ Allow AI
/// apps to use Pharos is on (`SettingsEffects`), off otherwise.
///
/// Turning it off closes every client's connection and removes the socket;
/// a client's bridge then says the server is off, until it is on again.
@MainActor
final class MCPServerController {

    static let shared = MCPServerController()

    private var server: MCPSocketServer?
    /// The clients connected now.
    private(set) var clients: [MCPClientInfo] = []
    /// Why the last start failed, for the Settings caption.
    private(set) var lastError: String?

    /// Posted on the main queue when `clients` or `lastError` change.
    static let didChange = Notification.Name("PharosMCPServerDidChange")

    private init() {}

    var isRunning: Bool { server != nil }

    /// What MCP clients run: this copy of the app's own executable.
    static var commandPath: String {
        Bundle.main.executablePath ?? "/Applications/Pharos.app/Contents/MacOS/Pharos"
    }

    /// The `mcpServers` entry for Claude desktop and LM Studio, as JSON text.
    static var clientConfigJSON: String {
        let config: JSONValue = ["mcpServers": ["pharos": ["command": .string(commandPath), "args": ["--mcp"]]]]
        return config.prettySerialized
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard server == nil else { return }
        let version = AppInfo.version
        let host = MCPAppHost()
        let server = MCPSocketServer(path: MCPSocketPath.socket()) {
            MCPSession(host: host, serverVersion: version)
        }
        server.onConnectionsChanged = { clients in
            DispatchQueue.main.async {
                MCPServerController.shared.clientsChanged(clients)
            }
        }
        do {
            try server.start()
            self.server = server
            lastError = nil
            Log.ui.info("MCP server listening at \(server.path, privacy: .public)")
        } catch {
            lastError = String(describing: error)
            Log.ui.error("MCP server did not start: \(String(describing: error), privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func stop() {
        guard let server else { return }
        server.onConnectionsChanged = nil
        server.stop()
        self.server = nil
        clients = []
        Log.ui.info("MCP server stopped")
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func clientsChanged(_ clients: [MCPClientInfo]) {
        guard server != nil else { return }
        let before = Set(self.clients.compactMap(\.name))
        self.clients = clients
        for client in clients where client.name != nil && !before.contains(client.name!) {
            Log.ui.info("MCP client connected: \(client.displayName, privacy: .public) \(client.version ?? "", privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The Settings caption: who is connected, or why the server is not running.
    var statusText: String {
        if let lastError { return String(localized: "The server could not start: \(lastError)") }
        guard isRunning else { return String(localized: "Off. AI apps cannot reach Pharos.") }
        let names = Array(Set(clients.map(\.displayName))).sorted()
        if names.isEmpty { return String(localized: "On. No AI app is connected.") }
        return String(localized: "Connected: \(names.joined(separator: ", "))")
    }
}

/// Tool calls from the socket, carried onto the main actor.
final class MCPAppHost: MCPToolHost {
    func callTool(name: String, arguments: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        try await MCPToolHandlers.call(name, arguments, client: client)
    }
}
