// Standalone test for the MCP server's protocol layer: JSON values, the
// JSON-RPC session, the tool catalog and the result pages. Compiled by
// scripts/test-mcp-protocol.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

/// Runs `body` to completion from synchronous test code.
private func blocking<T>(_ body: @escaping () async -> T) -> T {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}

private final class StubHost: MCPToolHost, @unchecked Sendable {
    var calls: [(name: String, args: [String: JSONValue], client: MCPClientInfo)] = []
    var reply: JSONValue = ["ok": true]
    var error: Error?

    func callTool(name: String, arguments: MCPArguments, client: MCPClientInfo) async throws -> JSONValue {
        calls.append((name, arguments.values, client))
        if let error { throw error }
        return reply
    }
}

private func respond(_ session: MCPSession, _ line: String) -> JSONValue? {
    blocking { await session.handle(line: line) }.flatMap { try? JSONValue.parse($0) }
}

// MARK: - JSON values

private func testJSONValue() {
    let v = try? JSONValue.parse(#"{"a":1,"b":true,"c":null,"d":[1.5,"x"],"e":{"f":"g"}}"#)
    expect(v?["a"]?.intValue == 1, "json: a whole number reads as an int")
    expect(v?["b"] == .bool(true), "json: true is a bool, not the number 1")
    expect(v?["c"] == .null, "json: null")
    expect(v?["d"]?.arrayValue == [.number(1.5), .string("x")], "json: arrays keep their order and types")
    expect(v?["e"]?["f"]?.stringValue == "g", "json: nested objects")
    expect(JSONValue.int(7).serialized == "7", "json: a whole number is written without a fraction",
           JSONValue.int(7).serialized)
    expect(JSONValue.bool(false).serialized == "false", "json: false stays false")
    let multi = JSONValue.object(["sql": "SELECT 1\nFROM t"]).serialized
    expect(!multi.contains("\n"), "json: a value with a newline still serializes to one line", multi)
    expect((try? JSONValue.parse(multi))?["sql"]?.stringValue == "SELECT 1\nFROM t", "json: the newline survives the round trip")
    expect((try? JSONValue.parse("{nope")) == nil, "json: text that is not JSON throws")
    expect(JSONValue.object(["a/b": "c/d"]).serialized == #"{"a/b":"c/d"}"#, "json: slashes are not escaped")
}

// MARK: - JSON-RPC

private func testInitialize() {
    let session = MCPSession(host: StubHost(), serverVersion: "9.9.9")
    var seen: MCPClientInfo?
    session.onInitialize = { seen = $0 }
    let r = respond(session, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-ai","version":"0.1"}}}"#)
    expect(r?["id"]?.intValue == 1 && r?["jsonrpc"] == "2.0", "initialize: answers with the request's id")
    expect(r?["result"]?["protocolVersion"] == "2025-03-26", "initialize: a supported version is echoed")
    expect(r?["result"]?["serverInfo"]?["name"] == "pharos" && r?["result"]?["serverInfo"]?["version"] == "9.9.9",
           "initialize: server info names Pharos and its version")
    expect(r?["result"]?["capabilities"]?["tools"] != nil, "initialize: the tools capability is declared")
    expect(r?["result"]?["instructions"]?.stringValue?.isEmpty == false, "initialize: instructions for the model")
    expect(seen?.name == "claude-ai" && session.client.version == "0.1", "initialize: the client's name is kept")
    expect(session.protocolVersion == "2025-03-26", "initialize: the negotiated version is kept")

    let other = MCPSession(host: StubHost(), serverVersion: "1")
    let r2 = respond(other, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
    expect(r2?["result"]?["protocolVersion"]?.stringValue == MCPSession.supportedProtocolVersions[0],
           "initialize: an unknown version gets the newest supported")
    expect(r2?["id"] == "a", "initialize: a string id goes back as a string")
    expect(other.client.displayName == "An AI app", "client: no name reads as “An AI app”")
}

private func testMessagesWithoutAnswers() {
    let session = MCPSession(host: StubHost(), serverVersion: "1")
    expect(blocking { await session.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) } == nil,
           "notification: not answered")
    expect(blocking { await session.handle(line: #"{"jsonrpc":"2.0","id":4,"result":{}}"#) } == nil,
           "a response from the client: not answered")
    expect(blocking { await session.handle(line: "   ") } == nil, "a blank line: not answered")
    expect(blocking { await session.handle(line: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) } == nil,
           "a null id is a notification: not answered")
}

private func testErrors() {
    let session = MCPSession(host: StubHost(), serverVersion: "1")
    let parse = respond(session, "{not json")
    expect(parse?["error"]?["code"]?.intValue == -32700 && parse?["id"] == .null, "error: unparseable → -32700, id null")
    let batch = respond(session, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
    expect(batch?["error"]?["code"]?.intValue == -32600, "error: a batch array → -32600")
    let unknown = respond(session, #"{"jsonrpc":"2.0","id":2,"method":"sampling/createMessage"}"#)
    expect(unknown?["error"]?["code"]?.intValue == -32601 && unknown?["id"]?.intValue == 2, "error: unknown method → -32601")
    let tool = respond(session, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"drop_everything"}}"#)
    expect(tool?["error"]?["code"]?.intValue == -32602, "error: unknown tool → -32602")
    let noName = respond(session, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)
    expect(noName?["error"]?["code"]?.intValue == -32602, "error: tools/call without a name → -32602")
    let ping = respond(session, #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#)
    expect(ping?["result"] == .object([:]), "ping: an empty result")
    let prompts = respond(session, #"{"jsonrpc":"2.0","id":7,"method":"prompts/list"}"#)
    expect(prompts?["result"]?["prompts"] == .array([]), "prompts/list: empty, not an error")
}

// MARK: - Tool calls

private func testToolCalls() {
    let host = StubHost()
    let session = MCPSession(host: host, serverVersion: "1")
    _ = respond(session, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"LM Studio"}}}"#)

    host.reply = ["cards": [["id": "c1"]]]
    let r = respond(session, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_cards","arguments":{"tab_id":"t1"}}}"#)
    expect(host.calls.last?.name == "list_cards" && host.calls.last?.args["tab_id"] == "t1",
           "call: the host gets the tool and its arguments")
    expect(host.calls.last?.client.name == "LM Studio", "call: the host knows which client asked")
    expect(r?["result"]?["isError"] == false, "call: success is not an error")
    expect(r?["result"]?["structuredContent"]?["cards"] != nil, "call: an object result is also structured content")
    let text = r?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    expect((try? JSONValue.parse(text))?["cards"]?.arrayValue?.count == 1, "call: the text content is the same JSON", text)

    let before = host.calls.count
    let typo = respond(session, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_card","arguments":{"tab_id":"t","card":"c"}}}"#)
    expect(host.calls.count == before, "call: a misspelt argument never reaches the host")
    expect(typo?["result"]?["isError"] == true, "call: a misspelt argument is a tool error")
    let typoText = typo?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    expect(typoText.contains("card") && typoText.contains("card_id"), "call: the error names the argument and what is taken", typoText)

    host.error = MCPToolError.refused("Pharos does not let AI apps run statements that change data.")
    let refused = respond(session, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_card","arguments":{"tab_id":"t","card_id":"c"}}}"#)
    expect(refused?["result"]?["isError"] == true && refused?["error"] == nil,
           "call: a refusal is a tool result with isError, not a JSON-RPC error")
    expect(refused?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("change data") == true,
           "call: the refusal's message reaches the model")

    host.error = nil
    host.reply = .array([1, 2])
    let array = respond(session, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tabs"}}"#)
    expect(array?["result"]?["structuredContent"] == nil, "call: a non-object result has no structured content")
}

// MARK: - Catalog

private func testCatalog() {
    let tools = MCPToolCatalog.tools
    let names = tools.map(\.name)
    expect(Set(names).count == names.count, "catalog: tool names are unique")
    let wanted = ["list_connections", "connect", "list_tabs", "list_saved_sessions", "list_workspaces", "open_session",
                  "create_tab", "list_cards", "get_card", "create_card", "update_card", "run_card", "get_card_result",
                  "cancel_card", "save_session"]
    expect(names == wanted, "catalog: the tools, in order", "\(names)")
    for tool in tools {
        expect(tool.name.range(of: "^[a-z_]+$", options: .regularExpression) != nil, "catalog: \(tool.name) is snake_case")
        expect(Set(tool.required).isSubset(of: Set(tool.properties.keys)), "catalog: \(tool.name)'s required arguments exist")
        expect(tool.inputSchema["type"] == "object" && tool.inputSchema["additionalProperties"] == false,
               "catalog: \(tool.name)'s schema is a closed object")
        expect(tool.description.count > 40, "catalog: \(tool.name) says what it does")
        for (key, schema) in tool.properties {
            expect(schema["type"]?.stringValue != nil && schema["description"]?.stringValue != nil,
                   "catalog: \(tool.name).\(key) has a type and a description")
        }
    }
    expect(MCPToolCatalog.tool(named: "run_card")?.destructive == true, "catalog: run_card is marked destructive")
    expect(tools.filter(\.readOnly).map(\.name).contains("get_card_result"), "catalog: reads are marked read-only")
    expect(!(MCPToolCatalog.tool(named: "create_card")?.readOnly ?? true), "catalog: create_card is not read-only")
    let session = MCPSession(host: StubHost(), serverVersion: "1")
    let list = respond(session, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    expect(list?["result"]?["tools"]?.arrayValue?.count == tools.count, "tools/list: every tool")
    expect(list?["result"]?["tools"]?.arrayValue?.first?["inputSchema"] != nil, "tools/list: each with its schema")
}

// MARK: - Arguments

private func testArguments() {
    let args = MCPArguments(["n": 5, "f": .number(2.5), "s": "  ", "b": "yes", "t": "x", "z": .null])
    expect((try? args.int("n", default: 1, range: 0...10)) == 5, "args: an int in range")
    expect((try? args.int("missing", default: 3, range: 0...10)) == 3, "args: a missing int takes the default")
    expect((try? args.int("z", default: 3, range: 0...10)) == 3, "args: a null int takes the default")
    do { _ = try args.int("n", default: 1, range: 0...4); expect(false, "args: out of range throws") }
    catch { expect((error as? MCPToolError)?.message.contains("0 to 4") == true, "args: out of range says the range") }
    expect((try? args.int("f", default: 1, range: 0...10)) == nil, "args: a fraction is not an int")
    expect((try? args.string("s")) == nil, "args: a blank required string throws")
    expect((try? args.string("t")) == "x", "args: a required string")
    expect((try? args.bool("b", default: false)) == nil, "args: a string is not a bool")
    expect(args.has("t") && !args.has("z") && !args.has("missing"), "args: has() ignores null and missing")
    let tool = MCPToolCatalog.tool(named: "get_card")!
    expect(MCPArguments(["tab_id": "a", "card_id": "b"]).unknownKeys(for: tool).isEmpty, "args: known keys pass")
    expect(MCPArguments(["tab_id": "a", "cardid": "b"]).unknownKeys(for: tool) == ["cardid"], "args: unknown keys are named")
}

// MARK: - Result pages

private func testResultPages() {
    let columns = [MCPResultShaper.Column(name: "id", type: "int4"), MCPResultShaper.Column(name: "note", type: "text")]
    let data: [[String?]] = (0..<10).map { ["\($0)", $0 == 3 ? nil : String(repeating: "x", count: $0 * 10)] }
    func page(_ offset: Int, _ limit: Int, cell: Int = 1000, budget: Int = 100_000) -> JSONValue {
        MCPResultShaper.page(columns: columns, rowCount: data.count, serverHasMore: true, offset: offset, limit: limit,
                             maxCellChars: cell, byteBudget: budget) { data[$0][$1] }
    }
    let first = page(0, 4)
    expect(first["returned_rows"]?.intValue == 4 && first["next_offset"]?.intValue == 4, "page: limit and next offset")
    expect(first["columns"]?.arrayValue?.first == ["name": "id", "type": "int4"], "page: columns with their types")
    expect(first["loaded_rows"]?.intValue == 10 && first["server_has_more"] == true, "page: loaded rows and server_has_more")
    expect(first["rows"]?.arrayValue?[3].arrayValue?[1] == .null, "page: NULL stays null, not text")
    let last = page(8, 50)
    expect(last["returned_rows"]?.intValue == 2 && last["next_offset"] == .null, "page: the last page has no next offset")
    let past = page(40, 5)
    expect(past["returned_rows"]?.intValue == 0 && past["offset"]?.intValue == 10, "page: an offset past the end is empty")
    let cut = page(9, 1, cell: 20)
    let cell = cut["rows"]?.arrayValue?.first?.arrayValue?[1].stringValue ?? ""
    expect(cell.hasPrefix(String(repeating: "x", count: 20)) && cell.contains("70 more characters"),
           "page: a long cell is cut and says how much", cell)
    expect(cut["cut_cells"]?.intValue == 1, "page: cut cells are counted")
    let small = page(0, 10, budget: 60)
    let n = small["returned_rows"]?.intValue ?? 0
    expect(n >= 1 && n < 10 && small["stopped_for_size"] == true && small["next_offset"]?.intValue == n,
           "page: a page stops at the byte budget and says where to go on", small.serialized)
    let tiny = page(9, 1, budget: 1)
    expect(tiny["returned_rows"]?.intValue == 1, "page: at least one row, so paging always moves")
    expect(MCPResultShaper.cut("héllo", to: 10) == ("héllo", false), "cut: short text is untouched")
}

func runTests() {
    testJSONValue()
    testInitialize()
    testMessagesWithoutAnswers()
    testErrors()
    testToolCalls()
    testCatalog()
    testArguments()
    testResultPages()
    if failures == 0 { print("\nAll MCP protocol tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
