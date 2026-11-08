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

func runTests() {
    testTabs()
    testSessionsWorkspacesHistory()
    testVariables()
    testFilteredPage()
    if failures == 0 { print("\nAll MCP access policy tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
