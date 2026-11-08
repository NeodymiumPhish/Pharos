import Foundation

/// The app that launched `Pharos --mcp`, by its code signature
/// (`MCPAppIdentifier`). Pharos's permissions are keyed by `id`.
struct MCPAppIdentity: Equatable {
    /// `team:<team id>:<bundle id>`, or `path:<executable>` when unsigned.
    let id: String
    let name: String
    /// The signing certificate's summary or team id, or the path.
    let detail: String
    let signed: Bool
}

/// Who is on the other end of an MCP connection: the app its signature names
/// (`app`), and what its `initialize` said (`name`, `version`).
struct MCPClientInfo: Equatable {
    var name: String?
    var version: String?
    /// Nil when no app could be named (`Pharos --mcp` run from Terminal).
    var app: MCPAppIdentity?

    /// The signed app's name, else the name the client gave, else "An AI app".
    var displayName: String {
        if let app { return app.name }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "An AI app") : trimmed
    }
}

/// What carries out a tool call. The app's is `MCPServerController`; the
/// stdio bridge has one that says Pharos is not reachable; the tests have
/// stubs. Called off the main thread.
protocol MCPToolHost: AnyObject {
    func callTool(name: String, arguments: MCPArguments, client: MCPClientInfo) async throws -> JSONValue
}

/// One MCP connection's JSON-RPC: a line in, a line (or nothing) out.
///
/// The transport is newline-delimited JSON-RPC 2.0, as MCP's stdio transport
/// defines it; the socket server and the bridge both speak it. Foundation
/// only (scripts/test-mcp-protocol.sh).
final class MCPSession {

    /// Newest first. A client asking for one of these gets it back; any other
    /// gets the newest.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
        /// Pharos itself is not reachable (the bridge's own error).
        static let unavailable = -32000
    }

    private let host: MCPToolHost
    private let serverVersion: String
    private let lock = NSLock()
    private var _client = MCPClientInfo()
    private var _protocolVersion: String?

    /// Called once the client has said who it is.
    var onInitialize: ((MCPClientInfo) -> Void)?

    init(host: MCPToolHost, serverVersion: String, app: MCPAppIdentity? = nil) {
        self.host = host
        self.serverVersion = serverVersion
        _client.app = app
    }

    var client: MCPClientInfo { lock.withLock { _client } }
    var protocolVersion: String? { lock.withLock { _protocolVersion } }

    /// Answer one line. Nil for a notification, a response, or a blank line.
    func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(trimmed) else {
            return Self.errorLine(id: .null, code: ErrorCode.parseError, message: "Parse error: the line is not JSON.")
        }
        guard case let .object(fields) = message else {
            // MCP 2025-06-18 has no batches; an array is not a request.
            return Self.errorLine(id: .null, code: ErrorCode.invalidRequest,
                                  message: "Invalid request: send one JSON-RPC object per line.")
        }
        let id = fields["id"]
        guard let method = fields["method"]?.stringValue else {
            // A response to a request of ours (Pharos makes none) or junk.
            if id == nil || fields["result"] != nil || fields["error"] != nil { return nil }
            return Self.errorLine(id: id ?? .null, code: ErrorCode.invalidRequest, message: "Invalid request: no method.")
        }
        let params = fields["params"]?.objectValue ?? [:]
        guard let id, !id.isNull else {
            // A notification (`notifications/initialized`, a cancel): nothing
            // to answer.
            return nil
        }
        switch await respond(method: method, params: params) {
        case let .success(result):
            return Self.resultLine(id: id, result: result)
        case let .failure(error):
            return Self.errorLine(id: id, code: error.code, message: error.message)
        }
    }

    struct RPCError: Error { let code: Int; let message: String }

    private func respond(method: String, params: [String: JSONValue]) async -> Result<JSONValue, RPCError> {
        switch method {
        case "initialize":
            return .success(initialize(params))
        case "ping":
            return .success([:])
        case "tools/list":
            return .success(MCPToolCatalog.listResult)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .failure(RPCError(code: ErrorCode.invalidParams, message: "tools/call needs a tool name."))
            }
            guard let tool = MCPToolCatalog.tool(named: name) else {
                return .failure(RPCError(code: ErrorCode.invalidParams, message: "Unknown tool: \(name)"))
            }
            let arguments = MCPArguments(params["arguments"]?.objectValue ?? [:])
            return .success(await call(tool, arguments))
        case "resources/list":
            return .success(["resources": []])
        case "resources/templates/list":
            return .success(["resourceTemplates": []])
        case "prompts/list":
            return .success(["prompts": []])
        default:
            return .failure(RPCError(code: ErrorCode.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let asked = params["protocolVersion"]?.stringValue
        let version = asked.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        let info = params["clientInfo"]
        let client = lock.withLock { () -> MCPClientInfo in
            MCPClientInfo(name: info?["name"]?.stringValue, version: info?["version"]?.stringValue, app: _client.app)
        }
        lock.withLock {
            _client = client
            _protocolVersion = version
        }
        onInitialize?(client)
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "pharos", "title": "Pharos", "version": .string(serverVersion)],
            "instructions": .string(MCPToolCatalog.instructions),
        ]
    }

    /// A tool's outcome as a `tools/call` result. A tool's own failure is a
    /// result with `isError`, not a JSON-RPC error: the model reads it and
    /// can try something else.
    private func call(_ tool: MCPToolCatalog.Tool, _ arguments: MCPArguments) async -> JSONValue {
        let unknown = arguments.unknownKeys(for: tool)
        if !unknown.isEmpty {
            let known = tool.properties.keys.sorted().joined(separator: ", ")
            return Self.toolError("Unknown argument\(unknown.count == 1 ? "" : "s") for \(tool.name): "
                                  + unknown.joined(separator: ", ") + ". It takes: " + (known.isEmpty ? "nothing" : known) + ".")
        }
        do {
            let value = try await host.callTool(name: tool.name, arguments: arguments, client: client)
            return Self.toolResult(value)
        } catch let error as MCPToolError {
            return Self.toolError(error.message)
        } catch {
            return Self.toolError(error.localizedDescription)
        }
    }

    static func toolResult(_ value: JSONValue) -> JSONValue {
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(value.prettySerialized)]],
            "isError": false,
        ]
        // Structured content must be an object.
        if case .object = value { result["structuredContent"] = value }
        return .object(result)
    }

    static func toolError(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    static func resultLine(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).serialized
    }

    static func errorLine(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id,
                          "error": ["code": .int(code), "message": .string(message)]]).serialized
    }
}

/// Bounded pages of a result's rows, so a large result cannot fill a
/// client's context. Foundation only: the rows come through a closure, so the
/// tests need no `ResultTable`.
enum MCPResultShaper {

    struct Column: Equatable {
        let name: String
        let type: String
    }

    /// `rowCount` rows are loaded; `cell(row, column)` reads one as text, nil
    /// for NULL. `serverHasMore`: the database had more than were loaded.
    static func page(columns: [Column], rowCount: Int, serverHasMore: Bool,
                     offset: Int, limit: Int, maxCellChars: Int,
                     byteBudget: Int = MCPToolCatalog.rowByteBudget,
                     cell: (Int, Int) -> String?) -> JSONValue {
        let start = min(max(0, offset), rowCount)
        let end = min(rowCount, start + max(0, limit))
        var rows: [JSONValue] = []
        var bytes = 0
        var cutCells = 0
        var stoppedForSize = false
        var row = start
        while row < end {
            var cells: [JSONValue] = []
            var rowBytes = 2
            for c in 0..<columns.count {
                guard let text = cell(row, c) else {
                    cells.append(.null)
                    rowBytes += 5
                    continue
                }
                let (shown, wasCut) = cut(text, to: maxCellChars)
                if wasCut { cutCells += 1 }
                rowBytes += shown.utf8.count + 3
                cells.append(.string(shown))
            }
            // Always at least one row, so a page moves forward.
            if !rows.isEmpty, bytes + rowBytes > byteBudget {
                stoppedForSize = true
                break
            }
            bytes += rowBytes
            rows.append(.array(cells))
            row += 1
        }
        let next: Int? = row < rowCount ? row : nil
        var page: [String: JSONValue] = [
            "columns": .array(columns.map { ["name": .string($0.name), "type": .string($0.type)] }),
            "rows": .array(rows),
            "offset": .int(start),
            "returned_rows": .int(rows.count),
            "loaded_rows": .int(rowCount),
            "next_offset": .optional(next),
            "server_has_more": .bool(serverHasMore),
        ]
        if cutCells > 0 { page["cut_cells"] = .int(cutCells) }
        if stoppedForSize { page["stopped_for_size"] = true }
        return .object(page)
    }

    /// `text` cut to `limit` characters, with an ellipsis and how much was cut.
    static func cut(_ text: String, to limit: Int) -> (String, Bool) {
        guard text.count > limit else { return (text, false) }
        let kept = text.prefix(limit)
        return ("\(kept)… [\(text.count - limit) more characters]", true)
    }
}
