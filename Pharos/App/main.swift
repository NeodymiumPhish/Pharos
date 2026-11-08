import AppKit

// `Pharos --mcp`: the stdio end of the MCP server, which an MCP client
// (Claude, LM Studio) launches. It carries JSON-RPC between the client and the
// running app's socket and never starts the app (`MCPStdioBridge`).
if CommandLine.arguments.dropFirst().contains("--mcp") {
    MCPStdioBridge.run(socketPath: MCPSocketPath.socket())
}

CrashLogger.install()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
