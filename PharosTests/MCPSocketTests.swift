// Standalone test for the MCP transport: the app's socket server and the
// `Pharos --mcp` stdio bridge, over a real Unix socket with a stub tool host.
// Compiled by scripts/test-mcp-socket.sh.
import Darwin
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

/// A tool host whose `slow_tool`… is `run_card`, held until released.
private final class StubHost: MCPToolHost, @unchecked Sendable {
    let lock = NSLock()
    var clients: [String?] = []
    let release = DispatchSemaphore(value: 0)

    func callTool(name: String, arguments: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        lock.withLock { clients.append(client.name) }
        if name == "run_card" {
            // Held until the test lets it go: a long query.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { self.release.wait(); c.resume() }
            }
            return ["status": "succeeded"]
        }
        return ["tool": .string(name)]
    }
}

/// Reads newline-terminated lines from a descriptor, with a timeout.
private final class LineReader {
    let fd: Int32
    var buffer = MCPLineBuffer()
    var ready: [String] = []
    init(_ fd: Int32) { self.fd = fd }

    func next(timeout: Double = 3) -> JSONValue? {
        let deadline = Date().addingTimeInterval(timeout)
        while ready.isEmpty {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(left * 1000)) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }
            ready += buffer.append(Data(chunk[0..<n])) ?? []
        }
        return try? JSONValue.parse(ready.removeFirst())
    }
}

private func send(_ fd: Int32, _ line: String) {
    MCPSocketIO.writeAll(fd, Data((line + "\n").utf8))
}

private func tempSocketPath(_ name: String) -> String {
    // Short: a Unix socket path must fit in 104 bytes.
    let dir = "/tmp/pharos-mcp-\(getpid())-\(name)"
    try? FileManager.default.removeItem(atPath: dir)
    return dir + "/MCP/pharos.sock"
}

private func permissions(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func makeServer(_ path: String, _ host: StubHost) -> MCPSocketServer {
    MCPSocketServer(path: path) { MCPSession(host: host, serverVersion: "1.2.3") }
}

// MARK: - Line buffer

private func testLineBuffer() {
    var b = MCPLineBuffer()
    expect(b.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"], "lines: a complete line comes out, a partial one waits")
    expect(b.append(Data(":2}\r\n\n".utf8)) == ["{\"b\":2}", ""], "lines: the rest arrives; CRLF is trimmed")
    var big = MCPLineBuffer()
    expect(big.append(Data(count: MCPLineBuffer.maxLine + 1)) == nil, "lines: a line past the limit is refused")
}

// MARK: - Server

private func testServer() {
    let path = tempSocketPath("server")
    let host = StubHost()
    let server = makeServer(path, host)
    var changes: [[MCPClientInfo]] = []
    let changeLock = NSLock()
    server.onConnectionsChanged = { c in changeLock.withLock { changes.append(c) } }
    do { try server.start() } catch { expect(false, "server: starts", "\(error)"); return }
    expect(server.isListening, "server: listening")
    expect(permissions((path as NSString).deletingLastPathComponent) == 0o700, "server: the socket's folder is 0700",
           String(permissions((path as NSString).deletingLastPathComponent), radix: 8))
    expect(permissions(path) == 0o600, "server: the socket is 0600", String(permissions(path), radix: 8))

    guard let fd = MCPSocketIO.connect(to: path) else { expect(false, "server: accepts a connection"); return }
    let reader = LineReader(fd)
    send(fd, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Test Client"}}}"#)
    let initialized = reader.next()
    expect(initialized?["result"]?["serverInfo"]?["version"] == "1.2.3", "server: answers initialize")
    usleep(100_000)
    expect(changeLock.withLock { changes.last?.first?.name } == "Test Client", "server: reports who connected")

    // A long run does not hold up the next request.
    send(fd, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_card","arguments":{"tab_id":"t","card_id":"c"}}}"#)
    send(fd, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tabs"}}"#)
    let quick = reader.next()
    expect(quick?["id"]?.intValue == 3, "server: a quick call answers while a slow one runs", quick?.serialized ?? "nothing")
    host.release.signal()
    let slow = reader.next()
    expect(slow?["id"]?.intValue == 2 && slow?["result"]?["structuredContent"]?["status"] == "succeeded",
           "server: the slow call answers when it ends")
    expect(host.clients.allSatisfy { $0 == "Test Client" }, "server: tool calls carry the client's name")

    // A large response is written whole.
    send(fd, #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
    let list = reader.next()
    expect(list?["result"]?["tools"]?.arrayValue?.count == MCPToolCatalog.tools.count, "server: a large response arrives whole")

    // A second copy cannot take the socket from a live one.
    do {
        try makeServer(path, host).start()
        expect(false, "server: a second server on a live socket is refused")
    } catch {
        expect("\(error)".contains("already listening"), "server: a second server on a live socket is refused", "\(error)")
    }

    server.stop()
    expect(!FileManager.default.fileExists(atPath: path), "server: stop removes the socket file")
    expect(reader.next(timeout: 1) == nil, "server: stop closes the client's connection")
    close(fd)
    expect(MCPSocketIO.connect(to: path) == nil, "server: nothing answers after stop")

    // A socket file left behind by a crash is replaced.
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    if let (addr, len) = try? MCPSocketIO.address(path) {
        var a = addr
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, len) } }
    }
    close(stale)
    expect(FileManager.default.fileExists(atPath: path), "server: (a stale socket file is in place)")
    let again = makeServer(path, host)
    do { try again.start(); expect(true, "server: starts over a stale socket file") }
    catch { expect(false, "server: starts over a stale socket file", "\(error)") }
    again.stop()
    try? FileManager.default.removeItem(atPath: "/tmp/pharos-mcp-\(getpid())-server")
}

// MARK: - Bridge

private func testBridge() {
    let path = tempSocketPath("bridge")
    var pipeFDs: [Int32] = [0, 0]
    pipe(&pipeFDs)
    let out = LineReader(pipeFDs[0])
    let bridge = MCPStdioBridge(socketPath: path, output: pipeFDs[1], version: "7.0")

    // Pharos not running: the bridge answers for it.
    bridge.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Claude"}}}"#)
    let initialized = out.next()
    expect(initialized?["result"]?["serverInfo"]?["version"] == "7.0", "bridge: answers initialize while Pharos is away")
    bridge.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    bridge.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    expect(out.next()?["result"]?["tools"]?.arrayValue?.count == MCPToolCatalog.tools.count,
           "bridge: lists the tools while Pharos is away (the notification got no answer)")
    bridge.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tabs"}}"#)
    let away = out.next()
    let awayText = away?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    expect(away?["result"]?["isError"] == true && awayText.contains("Allow AI apps to use Pharos"),
           "bridge: a tool call says how to turn the server on", awayText)

    // Pharos starts: the next line reaches it, after the client's initialize.
    let host = StubHost()
    let server = makeServer(path, host)
    do { try server.start() } catch { expect(false, "bridge: (server starts)", "\(error)"); return }
    bridge.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_cards","arguments":{"tab_id":"t"}}}"#)
    let reached = out.next()
    expect(reached?["id"]?.intValue == 4 && reached?["result"]?["structuredContent"]?["tool"] == "list_cards",
           "bridge: once Pharos listens, calls go to it", reached?.serialized ?? "nothing")
    expect(host.clients.last == "Claude", "bridge: the app learns the client's name from the replayed initialize")
    expect(out.next(timeout: 0.5) == nil, "bridge: the replayed initialize's answer is not passed to the client")

    // Pharos goes away mid-call: the client hears so instead of waiting.
    bridge.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"run_card","arguments":{"tab_id":"t","card_id":"c"}}}"#)
    usleep(200_000)
    server.stop()
    let dropped = out.next()
    expect(dropped?["id"]?.intValue == 5 && dropped?["error"]?["code"]?.intValue == MCPSession.ErrorCode.unavailable,
           "bridge: a call Pharos left unanswered gets an error", dropped?.serialized ?? "nothing")
    host.release.signal()
    usleep(100_000)
    bridge.handle(#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
    expect(out.next()?["id"]?.intValue == 6, "bridge: still answers after Pharos went away")
    close(pipeFDs[0]); close(pipeFDs[1])
    try? FileManager.default.removeItem(atPath: "/tmp/pharos-mcp-\(getpid())-bridge")
}

func runTests() {
    signal(SIGPIPE, SIG_IGN)
    testLineBuffer()
    testServer()
    testBridge()
    if failures == 0 { print("\nAll MCP socket tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
