// Standalone test for `WindowSession` — compiled by scripts/test-window-session.sh.
//
// Every query tab is its own window (a native window tab), so a session holds
// exactly ONE tab. What this suite pins:
//
//   ensureTab makes the one tab, once, and not while a session is restored
//   the tab takes THIS window's connection and default schema
//   install replaces the tab (an opened item filling a fresh window)
//   the window's connection and schema follow its tab
//   a closing window hands its running queries to the canceller, once
//   the settled publishers carry the new value, not the old
//   an untouched blank tab is "pristine", and anything typed or opened is not
//
// Two sessions are built side by side where a rule could leak across windows.
//
// `MainActor.assumeIsolated` is what lets a `@MainActor` type be tested in this
// harness at all — `PharosTests/main.swift` calls `runTests()` from nonisolated
// top-level scope, and the binary's main IS the main thread.
import Foundation

private var failures = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else {
        failures += 1
        print("FAIL \(name)")
    }
}

@MainActor
private func makeSession(defaultSchema: String? = nil, nextName: String = "Query 1") -> WindowSession {
    let session = WindowSession()
    session.hooks.defaultSchema = { _ in defaultSchema }
    session.hooks.nextTabName = { nextName }
    return session
}

// MARK: - one tab

@MainActor
private func testEnsureMakesTheOneTab() {
    let session = makeSession(nextName: "Query 3")
    expectTrue(session.tab == nil, "a new session has no tab yet")
    session.ensureTab()
    expect(session.tabs.count, 1, "ensureTab makes one tab")
    expect(session.tab?.name, "Query 3", "named by the app-wide counter")
    expect(session.activeTabId, session.tab?.id, "and it is the active tab")
    let id = session.tab?.id
    session.ensureTab()
    expect(session.tabs.count, 1, "a second ensureTab makes no second tab")
    expect(session.tab?.id, id, "and keeps the same tab")
}

@MainActor
private func testEnsureIsHeldBackDuringRestore() {
    let session = makeSession()
    var restoring = true
    session.hooks.isRestoringSession = { restoring }
    session.ensureTab()
    expectTrue(session.tab == nil, "no tab is made while a session is being restored")
    restoring = false
    session.ensureTab()
    expect(session.tabs.count, 1, "and one is made once the restore is over")
}

@MainActor
private func testEnsureIsHeldBackWhileATabIsOnItsWay() {
    let session = makeSession()
    session.awaitsTab = true
    session.ensureTab()
    expectTrue(session.tab == nil, "no blank tab while the window's own tab is on its way")
    let opened = QueryTab(name: "Opened")
    session.install(opened)
    expectTrue(!session.awaitsTab, "installing the tab ends the wait")
    session.ensureTab()
    expect(session.tabs.map(\.id), [opened.id], "and ensureTab then leaves it alone")
}

@MainActor
private func testTheTabTakesThisWindowsConnection() {
    let one = makeSession(defaultSchema: "sales")
    one.activeConnectionId = "conn-a"
    one.ensureTab()
    expect(one.tab?.connectionId, "conn-a", "the tab takes its window's connection")
    expect(one.tab?.schemaName, "sales", "and that connection's default schema")

    let two = makeSession(defaultSchema: "sales")
    two.ensureTab()
    expect(two.tab?.connectionId, nil, "a second window with no connection does not take the first one's")
}

@MainActor
private func testInstallReplacesTheTab() {
    let session = makeSession()
    session.ensureTab()
    var seen: [String?] = []
    let token = session.activeTabIdSettled.sink { seen.append($0) }
    let opened = QueryTab(name: "Expiring certs", connectionId: "conn-b", schemaName: "zeek")
    session.install(opened)
    expect(session.tabs.map(\.id), [opened.id], "install leaves exactly the installed tab")
    expect(session.activeTabId, opened.id, "and makes it active")
    expect(seen.last ?? nil, opened.id, "the settled publisher carries the installed tab's id")
    expect(session.activeConnectionId, "conn-b", "the window follows the installed tab's connection")
    expect(session.activeSchema, "zeek", "and its schema")
    token.cancel()
}

// MARK: - the window's connection follows its tab

@MainActor
private func testSyncActiveConnectionAndSchema() {
    let session = makeSession()
    session.activeConnectionId = "conn-a"
    session.activeSchema = "public"
    session.ensureTab()
    let id = session.tab!.id
    session.updateTab(id: id) {
        $0.connectionId = "conn-b"
        $0.schemaName = "sales"
    }
    session.syncActiveConnectionAndSchema()
    expect(session.activeConnectionId, "conn-b", "the window follows its tab's connection")
    expect(session.activeSchema, "sales", "and its schema")

    // Coming BACK to conn-a must restore the schema this window had chosen
    // for it, not leave the other connection's schema behind.
    session.activeConnectionId = "conn-a"
    expect(session.activeSchema, "public", "a window remembers its schema per connection")
}

// MARK: - a closing window's queries are cancelled, once

@MainActor
private func testClosingHandsRunningQueriesToTheCanceller() {
    let session = makeSession()
    var cancelled: [String] = []
    var closed: [String] = []
    session.hooks.cancelQueries = { tabs in
        cancelled.append(contentsOf: tabs.flatMap { $0.runningQueries.map(\.id) })
    }
    session.hooks.tabsDidClose = { closed.append(contentsOf: $0) }
    session.ensureTab()
    let id = session.tab!.id
    session.updateTab(id: id) { $0.runningQueries = [running("q1"), running("q2")] }

    session.cancelAllRunningQueries()
    expect(cancelled, ["q1", "q2"], "closing the window cancels its tab's queries")
    expect(closed, [id], "and closes the tab's own connection")
}

private func running(_ id: String) -> RunningQuery {
    RunningQuery(id: id, cardId: nil, kind: .card, label: "Query", normalizedSQL: "select 1", startTime: 0)
}

// MARK: - pristine

@MainActor
private func testPristine() {
    expectTrue(QueryTab().isPristine, "a fresh tab is pristine")
    expectTrue(QueryTab(connectionId: "conn-a", schemaName: "public").isPristine,
               "a connection alone does not make a tab worth keeping")
    var typed = QueryTab()
    typed.document = CardDocument(cards: [QueryCard(sql: "SELECT 1")])
    expectTrue(!typed.isPristine, "a card with SQL is not pristine")
    var blankCards = QueryTab()
    blankCards.document = CardDocument(cards: [QueryCard(sql: "  \n"), QueryCard(sql: "")])
    expectTrue(blankCards.isPristine, "blank cards are still pristine")
    var dirty = QueryTab()
    dirty.isDirty = true
    expectTrue(!dirty.isPristine, "a dirty tab is not pristine")
    var file = QueryTab()
    file.sourceURL = URL(fileURLWithPath: "/tmp/a.sql")
    expectTrue(!file.isPristine, "a tab from a file is not pristine")
    var saved = QueryTab()
    saved.savedQueryId = "s1"
    expectTrue(!saved.isPristine, "a saved query's tab is not pristine")
    var workspace = QueryTab()
    workspace.workspaceId = "w1"
    expectTrue(!workspace.isPristine, "a workspace's tab is not pristine")
    var busy = QueryTab()
    busy.runningQueries = [running("q")]
    expectTrue(!busy.isPristine, "a tab with a running query is not pristine")
}

// MARK: - entry point

func runTests() {
    MainActor.assumeIsolated {
        testEnsureMakesTheOneTab()
        testEnsureIsHeldBackDuringRestore()
        testEnsureIsHeldBackWhileATabIsOnItsWay()
        testTheTabTakesThisWindowsConnection()
        testInstallReplacesTheTab()
        testSyncActiveConnectionAndSchema()
        testClosingHandsRunningQueriesToTheCanceller()
        testPristine()
    }
    if failures == 0 { print("\nAll WindowSession tests passed") } else { print("\n\(failures) failure(s)"); exit(1) }
}
