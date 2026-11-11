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
    /// Apps already asked about this launch.
    private var askedForApproval: Set<String> = []

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
        let server = MCPSocketServer(path: MCPSocketPath.socket()) { app in
            MCPSession(host: host, serverVersion: version, app: app)
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

    /// "No variable is shared." or "3 variables shared.": each variable has its
    /// own AI apps choice in the Variable Manager, off until the user chooses.
    static func sharedVariablesText(_ count: Int) -> String {
        count == 0 ? String(localized: "No variable is shared.")
            : CountedNounText.phrase(count, "variable") + " " + String(localized: "shared.")
    }

    /// The Settings caption: who is connected, or why the server is not running.
    var statusText: String {
        if let lastError { return String(localized: "The server could not start: \(lastError)") }
        guard isRunning else { return String(localized: "Off. AI apps cannot reach Pharos.") }
        let shared = AppStateManager.shared.connections.filter { $0.mcpAccess != .off }.count
        let sharing = shared == 0
            ? String(localized: "No connection is shared yet: choose who may use a connection under “AI apps” in File ▸ Manage Connections….")
            : CountedNounText.phrase(shared, "connection") + " " + String(localized: "shared.")
                + " " + Self.sharedVariablesText(QueryVariableStore.shared.variables.filter { $0.mcpAccess != .off }.count)
        let names = Array(Set(clients.map(\.displayName))).sorted()
        if names.isEmpty { return String(localized: "On. No AI app is connected.") + " " + sharing }
        return String(localized: "Connected: \(names.joined(separator: ", ")).") + " " + sharing
    }
}

// MARK: - Which apps may call tools

extension MCPServerController {

    /// What a tool call from `client` may do: refused, or run as a Local or
    /// a Cloud app. An app seen for the first time is recorded Not approved
    /// (Settings ▸ Security & Privacy ▸ AI Apps) and the user is told.
    func admit(_ client: MCPClientInfo) throws -> Bool {
        guard let app = client.app else {
            throw MCPToolError.refused("Pharos cannot tell which app started `Pharos --mcp` (it was started from Terminal or another system program, not from an app). Pharos works only with apps it can identify by their signature.")
        }
        let state = AppStateManager.shared
        let approval = String(localized: "In Pharos, choose Settings ▸ Security & Privacy ▸ AI Apps, and set \(app.name) to Local or Cloud.")
        guard let record = state.settings.security.mcpApps.first(where: { $0.id == app.id }) else {
            var settings = state.settings
            settings.security.mcpApps.append(MCPAppRecord(
                id: app.id, name: app.name, detail: app.detail, signed: app.signed, trust: .unapproved,
                firstSeenAt: ISO8601DateFormatter().string(from: Date())))
            state.saveSettings(settings)
            Log.ui.info("MCP: new app \(app.id, privacy: .public) waits for approval")
            askForApproval(app)
            throw MCPToolError.refused("The user has not approved \(app.name) to use Pharos yet. Pharos has asked them. " + approval)
        }
        switch record.trust {
        case .local: return true
        case .cloud: return false
        case .unapproved:
            askForApproval(app)
            throw MCPToolError.refused("The user has not approved \(app.name) to use Pharos yet. " + approval)
        case .blocked:
            throw MCPToolError.refused("The user has blocked \(app.name) from using Pharos.")
        }
    }

    /// Once per app per launch: a notice in the front window that opens the
    /// pane, and a bounce of the Dock icon.
    private func askForApproval(_ app: MCPAppIdentity) {
        guard askedForApproval.insert(app.id).inserted else { return }
        NSApp.requestUserAttention(.informationalRequest)
        guard let session = AppStateManager.shared.keySession,
              let controller = (NSApp.delegate as? AppDelegate)?.contentController(for: session) else { return }
        controller.showAgentNotice(
            String(localized: "\(app.name) wants to use Pharos. Click to choose its access."),
            duration: 10) {
            SettingsWindowController.shared.show(pane: .security)
        }
    }
}

/// The tier of the tool call running now: an app the user marked Local, or
/// Cloud. Task-local, because calls from two apps can interleave.
enum MCPCallContext {
    @TaskLocal static var isLocal = false
}

/// Tool calls from the socket, carried onto the main actor.
final class MCPAppHost: MCPToolHost {
    func callTool(name: String, arguments: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        let isLocal = try await MainActor.run { try MCPServerController.shared.admit(client) }
        return try await MCPCallContext.$isLocal.withValue(isLocal) {
            try await MCPToolHandlers.call(name, arguments, client: client)
        }
    }
}
