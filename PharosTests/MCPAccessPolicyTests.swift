// Standalone test for MCPAccessPolicy: which tabs, Sessions, workspaces,
// history entries and variables an MCP client may reach, given the
// connections the user shares. Compiled by scripts/test-mcp-access-policy.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private let shared: Set<String> = ["A"]

/// A document whose cards ran on `connections` (nil: a run recorded before
/// runs kept their connection; "-": never run).
private func document(_ connections: [String?]) -> CardDocument {
    CardDocument(cards: connections.map { c in
        var card = QueryCard(sql: "SELECT 1")
        if c != "-" {
            card.lastRun = CardRunRecord(runId: UUID().uuidString, rawSQL: "SELECT 1", renderedSQL: "SELECT 1",
                                         finishedAt: Date(), executionTimeMs: 1, summary: .rows(count: 1, hasMore: false),
                                         historyResultId: nil, connectionId: c)
        }
        return card
    })
}

private func testTabs() {
    expect(MCPAccessPolicy.allowsTab(connectionId: "A", document: document(["A", "-"]), workspaceConnectionIds: nil, allowed: shared),
           "tab: on a shared connection, its runs there → shared")
    expect(!MCPAccessPolicy.allowsTab(connectionId: "B", document: document(["-"]), workspaceConnectionIds: nil, allowed: shared),
           "tab: on a connection not shared → not shared")
    expect(!MCPAccessPolicy.allowsTab(connectionId: nil, document: document(["-"]), workspaceConnectionIds: nil, allowed: shared),
           "tab: with no connection → not shared")
    expect(!MCPAccessPolicy.allowsTab(connectionId: "A", document: document(["A", "B"]), workspaceConnectionIds: nil, allowed: shared),
           "tab: moved to a shared connection but holding a run from another → not shared")
    expect(MCPAccessPolicy.allowsTab(connectionId: "A", document: document([nil]), workspaceConnectionIds: nil, allowed: shared),
           "tab: a run that does not say where it went goes by the tab's connection")
    expect(!MCPAccessPolicy.allowsTab(connectionId: "A", document: document([nil]), workspaceConnectionIds: ["A", "B"], allowed: shared),
           "tab: bound to a workspace that also ran on another connection → not shared")
    expect(MCPAccessPolicy.allowsTab(connectionId: "A", document: document([nil]), workspaceConnectionIds: ["A"], allowed: shared),
           "tab: bound to a workspace on the shared connection only → shared")
    expect(!MCPAccessPolicy.allowsTab(connectionId: "A", document: document(["-"]), workspaceConnectionIds: nil, allowed: []),
           "tab: nothing shared → nothing is")
}

private func testSessionsWorkspacesHistory() {
    expect(MCPAccessPolicy.allowsSession(connectionId: "A", document: document(["A", nil]), allowed: shared),
           "Session: on a shared connection → shared")
    expect(!MCPAccessPolicy.allowsSession(connectionId: "B", document: document(["-"]), allowed: shared),
           "Session: on a connection not shared → not shared")
    expect(!MCPAccessPolicy.allowsSession(connectionId: nil, document: document(["-"]), allowed: shared),
           "Session: saved with no connection → not shared")
    expect(!MCPAccessPolicy.allowsSession(connectionId: "A", document: document(["B"]), allowed: shared),
           "Session: holding a run from a connection not shared → not shared")
    expect(MCPAccessPolicy.allowsWorkspace(connectionIds: ["A"], allowed: shared), "workspace: on the shared connection → shared")
    expect(!MCPAccessPolicy.allowsWorkspace(connectionIds: ["A", "B"], allowed: shared),
           "workspace: one result on another connection → not shared")
    expect(!MCPAccessPolicy.allowsWorkspace(connectionIds: [], allowed: shared), "workspace: unknown connections → not shared")
    expect(MCPAccessPolicy.allowsHistoryEntry(connectionId: "A", allowed: shared)
           && !MCPAccessPolicy.allowsHistoryEntry(connectionId: "B", allowed: shared), "history: by the entry's connection")
}

private func testVariables() {
    let global = MCPAccessPolicy.variableLinks([], allowed: shared)
    expect(global.shared && global.links.isEmpty, "variable: a global one is shared")
    let mixed = MCPAccessPolicy.variableLinks(["B", "A"], allowed: shared)
    expect(mixed.shared && mixed.links == ["A"], "variable: linked to a shared connection → shown, with only that link")
    expect(!MCPAccessPolicy.variableLinks(["B"], allowed: shared).shared, "variable: linked only to others → hidden")
    expect(MCPAccessPolicy.allowsVariableChange([], allowed: shared), "variable change: a global one may change")
    expect(MCPAccessPolicy.allowsVariableChange(["A"], allowed: shared), "variable change: linked only to shared connections")
    expect(!MCPAccessPolicy.allowsVariableChange(["A", "B"], allowed: shared), "variable change: also linked to a hidden connection → refused")
    expect(!MCPAccessPolicy.allowsVariableChange(["B"], allowed: shared), "variable change: linked only to a hidden connection → refused")

    // The variable's own AI apps choice, on top of its connections.
    expect(MCPAccessPolicy.allowsVariable(connectionIds: [], sharedWithApp: true, allowed: shared),
           "variable: global and shared with the app → usable")
    expect(!MCPAccessPolicy.allowsVariable(connectionIds: [], sharedWithApp: false, allowed: shared),
           "variable: global but not shared with the app → hidden")
    expect(MCPAccessPolicy.allowsVariable(connectionIds: ["A", "B"], sharedWithApp: true, allowed: shared),
           "variable: shared, and linked to a shared connection → usable")
    expect(!MCPAccessPolicy.allowsVariable(connectionIds: ["B"], sharedWithApp: true, allowed: shared),
           "variable: shared, but linked only to hidden connections → hidden")
    expect(!MCPAccessPolicy.allowsVariable(connectionIds: ["A"], sharedWithApp: false, allowed: shared),
           "variable: on a shared connection but not shared itself → hidden")

    expect(MCPAccessPolicy.withheldNames(referenced: ["a", "b"], usable: ["a", "b", "c"]).isEmpty,
           "withheld: every token is a variable the app may use → nothing")
    expect(MCPAccessPolicy.withheldNames(referenced: ["token", "a", "gone"], usable: ["a"]) == ["gone", "token"],
           "withheld: a token not shared, and one no longer defined, sorted")
    expect(MCPAccessPolicy.withheldNames(referenced: [], usable: []).isEmpty, "withheld: no tokens → nothing")
    expect(MCPAccessPolicy.allowsHistoryEntry(connectionId: "A", withheld: [], allowed: shared),
           "history: on a shared connection, no withheld token → shown")
    expect(!MCPAccessPolicy.allowsHistoryEntry(connectionId: "A", withheld: ["token"], allowed: shared),
           "history: a run that used a variable the app may not → left out")
    expect(!MCPAccessPolicy.allowsHistoryEntry(connectionId: "B", withheld: [], allowed: shared),
           "history: on a hidden connection → left out")
}

/// `MCPVariableAccess`: the tier, the variable's choice and its links
/// together, and the tokens of a text.
private func testVariableAccess() {
    func connection(_ id: String, _ access: MCPScope) -> ConnectionConfig {
        var c = ConnectionConfig(id: id, name: id, host: "h", port: 5432, database: "d", username: "u")
        c.mcpAccess = access
        return c
    }
    let connections = [connection("all", .all), connection("local", .local), connection("off", .off)]
    let cloud = MCPVariableAccess.sharedConnectionIds(isLocal: false, connections: connections)
    let local = MCPVariableAccess.sharedConnectionIds(isLocal: true, connections: connections)
    expect(cloud == ["all"], "tier: a Cloud app reaches only the connections for all approved apps", "\(cloud)")
    expect(local == ["all", "local"], "tier: a Local app reaches those and the local ones", "\(local)")

    let secret = QueryVariable(name: "token", value: "s3cret", type: .text)
    let forLocal = QueryVariable(name: "region", value: "eu", type: .text, mcpAccess: .local)
    let forAll = QueryVariable(name: "day", value: "today", type: .date, mcpAccess: .all)
    let linkedOff = QueryVariable(name: "env", value: "prod", type: .text, connectionIds: ["off"], mcpAccess: .all)
    let linkedLocal = QueryVariable(name: "host", value: "db", type: .text, connectionIds: ["local", "off"], mcpAccess: .all)
    let unnamed = QueryVariable(name: "", value: "x", mcpAccess: .all)
    let all = [secret, forLocal, forAll, linkedOff, linkedLocal, unnamed]

    let cloudNames = MCPVariableAccess.usable(all, isLocal: false, allowed: cloud).map(\.name)
    let localNames = MCPVariableAccess.usable(all, isLocal: true, allowed: local).map(\.name)
    expect(cloudNames == ["day"], "usable: a Cloud app gets only what is for all approved apps", "\(cloudNames)")
    expect(localNames == ["region", "day", "host"], "usable: a Local app also gets the local ones, and a variable linked to a local connection", "\(localNames)")
    expect(!MCPVariableAccess.allows(secret, isLocal: true, allowed: local), "usable: a variable left Off is nobody's")
    expect(QueryVariable(name: "new").mcpAccess == .off, "default: a new variable is Off")

    let usable = MCPVariableAccess.usable(all, isLocal: false, allowed: cloud)
    expect(MCPVariableAccess.withheldNames(in: ["SELECT * FROM t WHERE d = {{day}}"], usable: usable).isEmpty,
           "tokens: a run that used only shared variables is shown")
    expect(MCPVariableAccess.withheldNames(in: ["SELECT {{ token }}, {{day}}", nil, "WHERE r = {{region}}"], usable: usable) == ["region", "token"],
           "tokens: the ones not shared with the app, across the texts")
    expect(MCPVariableAccess.withheldNames(in: ["SELECT {{deleted_since}}"], usable: usable) == ["deleted_since"],
           "tokens: a variable that no longer exists is withheld too")
    expect(MCPVariableAccess.withheldNames(in: ["SELECT 1", nil], usable: []).isEmpty, "tokens: no token, nothing withheld")
    expect(MCPVariableAccess.tokenList(["a", "b"]) == "{{a}}, {{b}}", "tokens: listed in braces")

    // A run filled in with the usable variables only: the others are undefined.
    let rendered = VariableSubstitutor.render("SELECT {{token}}, {{day}}", with: usable)
    expect(rendered.unresolved == ["token"], "render: a variable not shared reads as undefined", "\(rendered.unresolved)")

    // Stored: off is left out of the document, an unknown value reads as off.
    let json = String(data: try! JSONEncoder().encode([secret, forLocal]), encoding: .utf8)!
    expect(!json.contains("\"mcpAccess\":\"off\"") && json.contains("\"mcpAccess\":\"local\""),
           "coding: Off is left out, a choice is written", json)
    let decoded = try! JSONDecoder().decode([QueryVariable].self, from: Data("""
        [{"id":"\(UUID().uuidString)","name":"a","mcpAccess":"all"},
         {"id":"\(UUID().uuidString)","name":"b","mcpAccess":"everyone"},
         {"id":"\(UUID().uuidString)","name":"c"}]
        """.utf8))
    expect(decoded.map(\.mcpAccess) == [.all, .off, .off], "coding: an unknown or missing choice is Off", "\(decoded.map(\.mcpAccess))")
}

private func testFilteredPage() {
    // 0..<23, shared when even.
    let source = Array(0..<23)
    var fetches = 0
    func fetch(_ offset: Int, _ count: Int) -> [Int] {
        fetches += 1
        return Array(source.dropFirst(offset).prefix(count))
    }
    let first = MCPAccessPolicy.filteredPage(offset: 0, limit: 3, batch: 4, fetch: fetch, keep: { $0 % 2 == 0 })
    expect(first.items == [0, 2, 4] && first.next == 6, "page: the first page, and the source row to go on from",
           "\(first)")
    let second = MCPAccessPolicy.filteredPage(offset: first.next!, limit: 3, batch: 4, fetch: fetch, keep: { $0 % 2 == 0 })
    expect(second.items == [6, 8, 10] && second.next == 12, "page: going on repeats and skips nothing", "\(second)")
    let last = MCPAccessPolicy.filteredPage(offset: 18, limit: 10, batch: 4, fetch: fetch, keep: { $0 % 2 == 0 })
    expect(last.items == [18, 20, 22] && last.next == nil, "page: the last page has no next", "\(last)")
    let exact = MCPAccessPolicy.filteredPage(offset: 16, limit: 4, batch: 4, fetch: fetch, keep: { $0 % 2 == 0 })
    expect(exact.items == [16, 18, 20, 22] && exact.next == nil, "page: a page that ends the source exactly has no next",
           "\(exact)")
    let none = MCPAccessPolicy.filteredPage(offset: 0, limit: 5, batch: 4, fetch: fetch, keep: { _ in false })
    expect(none.items.isEmpty && none.next == nil, "page: nothing shared → empty, and no next")
    fetches = 0
    let capped = MCPAccessPolicy.filteredPage(offset: 0, limit: 5, batch: 4, scanLimit: 8, fetch: fetch, keep: { _ in false })
    expect(capped.items.isEmpty && capped.next == 8 && fetches == 2, "page: a scan stops at its limit and says where it stopped",
           "\(capped), \(fetches) fetches")
}

// MARK: - Which app launched the bridge

private typealias Facts = MCPAppIdentifier.ProcessFacts

private func walk(_ table: [pid_t: Facts], bundles: [String: (id: String, name: String)] = [:]) -> MCPAppIdentity? {
    MCPAppIdentifier.identify(bridgePid: 100, facts: { table[$0] }, bundle: { path in
        bundles.first { path.hasPrefix($0.key) }?.value
    })
}

private func testIdentify() {
    let bridge = Facts(parent: 50, path: "/Applications/Pharos.app/Contents/MacOS/Pharos", signer: .unsigned)
    let shell = Facts(parent: 40, path: "/bin/zsh", signer: .apple)
    let claudeHelper = Facts(parent: 30, path: "/Applications/Claude.app/Contents/Helpers/disclaimer",
                             signer: .team(id: "Q6L2SF6YDW", identifier: "disclaimer", summary: "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)"))
    let claude = [pid_t(100): bridge, 50: shell, 40: claudeHelper]
    let bundles = ["/Applications/Claude.app": (id: "com.anthropic.claudefordesktop", name: "Claude")]
    let found = walk(claude, bundles: bundles)
    expect(found == MCPAppIdentity(id: "team:Q6L2SF6YDW:com.anthropic.claudefordesktop", name: "Claude",
                                   detail: "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)", signed: true),
           "identify: past the shell, a helper inside Claude.app is Claude, by team and bundle", "\(String(describing: found))")
    let noBundle = walk([100: bridge, 50: Facts(parent: 1, path: "/usr/local/bin/tool", signer: .team(id: "T1", identifier: "com.x.tool", summary: nil))])
    expect(noBundle?.id == "team:T1:com.x.tool" && noBundle?.name == "com.x.tool" && noBundle?.detail == "T1",
           "identify: a signed tool outside an app goes by its signing identifier", "\(String(describing: noBundle))")
    let unsigned = walk([100: bridge, 50: Facts(parent: 1, path: "/opt/homebrew/bin/node", signer: .unsigned)])
    expect(unsigned == MCPAppIdentity(id: "path:/opt/homebrew/bin/node", name: "node", detail: "/opt/homebrew/bin/node", signed: false),
           "identify: an unsigned launcher is named by its path, and marked unsigned")
    expect(walk([100: bridge, 50: shell, 40: Facts(parent: 1, path: "/System/Applications/Utilities/Terminal.app", signer: .apple)]) == nil,
           "identify: Apple's programs all the way up (Terminal) → no app")
    expect(walk([100: bridge, 50: Facts(parent: 50, path: "/bin/sh", signer: .apple)]) == nil,
           "identify: a loop in the parents ends the walk")
    expect(walk([100: bridge]) == nil, "identify: a parent that cannot be read → no app")
    let spoof = walk([100: bridge, 50: Facts(parent: 1, path: "/tmp/LM Studio.app/Contents/MacOS/LM Studio", signer: .unsigned)],
                     bundles: ["/tmp/LM Studio.app": (id: "ai.elementlabs.lmstudio", name: "LM Studio")])
    expect(spoof?.signed == false && spoof?.id == "path:/tmp/LM Studio.app/Contents/MacOS/LM Studio",
           "identify: an unsigned copy calling itself LM Studio is not LM Studio's signed identity")
    let real = MCPAppIdentifier.systemFacts(getpid())
    expect(real?.path?.hasSuffix("pharos-mcp-access-policy-tests") == true && (real?.parent ?? 0) > 0,
           "facts: the real reader finds this test's own path and parent", "\(String(describing: real))")
}

func runTests() {
    testIdentify()
    testTabs()
    testSessionsWorkspacesHistory()
    testVariables()
    testVariableAccess()
    testFilteredPage()
    if failures == 0 { print("\nAll MCP access policy tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
