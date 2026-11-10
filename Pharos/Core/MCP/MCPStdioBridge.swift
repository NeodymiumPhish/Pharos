import Darwin
import Foundation

/// `Pharos --mcp`: what an MCP client (Claude, LM Studio) launches.
///
/// MCP clients start a local server as a process and speak JSON-RPC on its
/// stdin and stdout. Pharos's server lives in the running app, beside its
/// tabs and its confirmation sheets, so this process only carries the lines
/// between the client and the app's socket (`MCPSocketServer`). It never
/// starts the app's UI: `main.swift` comes here before `NSApplication`.
///
/// While the app is not reachable (not running, or the setting is off) the
/// bridge answers `initialize`, `ping` and `tools/list` itself, from the same
/// catalog, so the client still lists Pharos's tools; a tool call then says how
/// to turn the server on. It connects again on the next line, so starting
/// Pharos (or turning the setting on) needs no restart of the client.
final class MCPStdioBridge {

    /// The id of the `initialize` the bridge replays when it reaches the app
    /// after the client's own went unanswered by it. Its response is dropped.
    static let replayId = "pharos-bridge-initialize"

    static let unavailableMessage = """
    Pharos is not running, or its MCP server is off. Open Pharos and turn on Settings ▸ Security & Privacy ▸ Allow AI apps to use Pharos, then try again.
    """

    static let disconnectedMessage = "Pharos closed the connection (it quit, or its MCP server was turned off) before answering."

    /// How long the bridge waits, once stdin closes, for the app to answer
    /// what it already sent: the longest a `run_card` may wait, and a margin.
    static let drainTimeout = TimeInterval(MCPToolCatalog.maxWaitSeconds + 15)

    private let socketPath: String
    private let output: Int32
    /// Guards the socket and `pending`; signalled when `pending` empties.
    private let lock = NSCondition()
    private let outputLock = NSLock()
    private var socketFD: Int32?
    /// Ids (serialized) sent to the app and not yet answered.
    private var pending: Set<String> = []
    /// The client's `initialize` line, replayed to an app reached later.
    private var initializeLine: String?
    private let localSession: MCPSession

    init(socketPath: String, output: Int32 = STDOUT_FILENO, version: String) {
        self.socketPath = socketPath
        self.output = output
        localSession = MCPSession(host: UnavailableHost(), serverVersion: version)
    }

    /// Run until stdin closes, then exit.
    static func run(socketPath: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let bridge = MCPStdioBridge(socketPath: socketPath, version: version)
        bridge.pump(input: STDIN_FILENO)
        exit(0)
    }

    /// Read lines from `input` until it closes, then wait (up to
    /// `drainTimeout`) for the app to answer the requests already sent to it,
    /// so `printf '…' | Pharos --mcp` prints its answer.
    func pump(input: Int32, drainTimeout: TimeInterval = MCPStdioBridge.drainTimeout) {
        var buffer = MCPLineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            guard let lines = buffer.append(Data(chunk[0..<n])) else { break }
            for line in lines { handle(line) }
        }
        let deadline = Date().addingTimeInterval(drainTimeout)
        lock.withLock {
            // `dropConnection` empties `pending` when the app goes away.
            while !pending.isEmpty, lock.wait(until: deadline) {}
        }
        lock.withLock {
            if let fd = socketFD { close(fd) }
            socketFD = nil
        }
    }

    /// One line from the client.
    func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = try? JSONValue.parse(trimmed)
        let method = message?["method"]?.stringValue
        let id = message?["id"].flatMap { $0.isNull ? nil : $0 }
        if method == "initialize" { lock.withLock { initializeLine = trimmed } }

        if let fd = connectedSocket(sendingInitialize: method == "initialize") {
            if let id { lock.withLock { _ = pending.insert(id.serialized) } }
            if MCPSocketIO.writeAll(fd, Data((trimmed + "\n").utf8)) { return }
            // Answered below, not by `dropConnection`'s error.
            if let id { lock.withLock { _ = pending.remove(id.serialized) } }
            dropConnection(fd)
        }
        // Not reachable: answer here.
        guard id != nil || message == nil else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let session = localSession
        Task.detached {
            box.line = await session.handle(line: trimmed)
            semaphore.signal()
        }
        semaphore.wait()
        if let response = box.line { emit(response) }
    }

    /// The app's socket, connecting when there is none. A new connection
    /// first gets the client's `initialize` (unless this line is one), so the
    /// app knows which client it serves.
    private func connectedSocket(sendingInitialize isInitialize: Bool) -> Int32? {
        lock.lock()
        if let fd = socketFD {
            lock.unlock()
            return fd
        }
        lock.unlock()
        guard let fd = MCPSocketIO.connect(to: socketPath) else { return nil }
        lock.lock()
        socketFD = fd
        let replay = isInitialize ? nil : initializeLine
        lock.unlock()
        let reader = Thread { [weak self] in self?.readResponses(from: fd) }
        reader.name = "pharos-mcp-bridge-reader"
        reader.start()
        if let replay, var message = try? JSONValue.parse(replay), case var .object(fields) = message {
            fields["id"] = .string(Self.replayId)
            message = .object(fields)
            MCPSocketIO.writeAll(fd, Data((message.serialized + "\n").utf8))
            // The client already had its `initialized` notification answered
            // by nobody; the app needs no copy of it.
        }
        return fd
    }

    private func readResponses(from fd: Int32) {
        var buffer = MCPLineBuffer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            guard let lines = buffer.append(Data(chunk[0..<n])) else { break }
            for line in lines {
                let id = (try? JSONValue.parse(line))?["id"]
                if id == .string(Self.replayId) { continue }
                // Emit first: once `pending` empties, `pump` may close and exit.
                emit(line)
                if let id {
                    lock.withLock {
                        _ = pending.remove(id.serialized)
                        if pending.isEmpty { lock.broadcast() }
                    }
                }
            }
        }
        dropConnection(fd)
    }

    /// The app went away: answer what it left unanswered.
    private func dropConnection(_ fd: Int32) {
        var unanswered: Set<String> = []
        var dropped = false
        lock.withLock {
            guard socketFD == fd else { return }
            close(fd)
            socketFD = nil
            unanswered = pending
            dropped = true
        }
        guard dropped else { return }
        for raw in unanswered {
            let id = (try? JSONValue.parse(raw)) ?? .null
            emit(MCPSession.errorLine(id: id, code: MCPSession.ErrorCode.unavailable, message: Self.disconnectedMessage))
        }
        // Only now, so `pump` doesn't exit before these errors are out.
        lock.withLock {
            pending.subtract(unanswered)
            lock.broadcast()
        }
    }

    private func emit(_ line: String) {
        outputLock.withLock {
            _ = MCPSocketIO.writeAll(output, Data((line + "\n").utf8))
        }
    }

    private final class ResponseBox: @unchecked Sendable { var line: String? }

    /// Tool calls while Pharos is not reachable.
    final class UnavailableHost: MCPToolHost {
        func callTool(name: String, arguments: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
            throw MCPToolError.failed(MCPStdioBridge.unavailableMessage)
        }
    }
}
