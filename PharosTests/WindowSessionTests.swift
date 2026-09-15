// Standalone test for `WindowSession` — compiled by scripts/test-window-session.sh.
//
// What this suite is FOR: these tab methods used to be one set on a global
// singleton, so "the tabs" and "this window's tabs" were the same thing and
// every rule below was trivially true. They are now per window, and each case
// here poses a rule that a careless move would break:
//
//   the last tab closing is replaced, not left empty
//   closing the ACTIVE tab picks the tab now at its index
//   closing a non-active tab leaves the active one alone
//   close-to-right keeps the anchor and moves the active tab only if it went
//   the closed-tab history is the window's, so a reopen cannot cross windows
//   a new tab inherits THIS window's connection, and a second window's does not
//   in-flight queries of a closing tab are handed to the canceller, once
//
// Two sessions are built side by side wherever a rule could leak across
// windows: a suite with one session could not tell "per window" from "global".
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
private func makeSession(defaultSchema: String? = nil) -> WindowSession {
    let session = WindowSession()
    session.hooks.defaultSchema = { _ in defaultSchema }
    return session
}

@MainActor
private func names(_ session: WindowSession) -> [String] {
    session.tabs.map { $0.name }
}

// MARK: - ensure / create / select

@MainActor
private func testEnsureAndCreate() {
    let session = makeSession()
    expect(session.tabs.count, 0, "a fresh session has no tab")

    session.ensureTab()
    expect(names(session), ["Query 1"], "ensureTab makes the first tab")
    expect(session.activeTabId, session.tabs[0].id, "the made tab is active")

    session.ensureTab()
    expect(session.tabs.count, 1, "ensureTab is a no-op once a tab is active")

    let second = session.createTab()
    expect(names(session), ["Query 1", "Query 2"], "createTab appends and numbers")
    expect(session.activeTabId, second.id, "a new tab becomes active")
    expect(session.activeTab?.id, second.id, "activeTab reads back the new tab")

    let named = session.createTab(sql: "select 1", name: "Report")
    expect(named.name, "Report", "a given name wins over the generated one")
    expect(named.sql, "select 1", "the SQL is carried in")

    session.selectTab(id: session.tabs[0].id)
    expect(session.activeTabId, session.tabs[0].id, "selectTab moves the active tab")

    session.selectTabByIndex(2)
    expect(session.activeTabId, session.tabs[2].id, "selectTabByIndex uses tab-bar order")
    session.selectTabByIndex(99)
    expect(session.activeTabId, session.tabs[2].id, "an out-of-range index changes nothing")
    session.selectTabByIndex(-1)
    expect(session.activeTabId, session.tabs[2].id, "a negative index changes nothing")
}

// MARK: - ensureTab while a stored session is being put back

@MainActor
private func testEnsureIsHeldBackDuringRestore() {
    let session = makeSession()
    var restoring = true
    session.hooks.isRestoringSession = { restoring }

    session.ensureTab()
    expect(session.tabs.count, 0, "ensureTab makes no stray tab during a restore")

    restoring = false
    session.ensureTab()
    expect(session.tabs.count, 1, "ensureTab works again once the restore is done")
}

// MARK: - closing

@MainActor
private func testCloseTab() {
    let session = makeSession()
    let a = session.createTab(name: "A")
    let b = session.createTab(name: "B")
    let c = session.createTab(name: "C")

    // Closing a tab that is NOT active must leave the active one where it is.
    session.selectTab(id: c.id)
    session.closeTab(id: a.id)
    expect(names(session), ["B", "C"], "the closed tab is gone")
    expect(session.activeTabId, c.id, "closing another tab does not move the active one")

    // Closing the ACTIVE tab takes the tab now at its index — the one to its
    // right, which is why this asserts C and not B.
    let d = session.createTab(name: "D")
    session.selectTab(id: c.id)
    session.closeTab(id: c.id)
    expect(names(session), ["B", "D"], "the active tab is gone")
    expect(session.activeTabId, d.id, "the tab now at that index becomes active")

    // Closing the LAST tab of a window replaces it rather than leaving an
    // empty window behind.
    session.closeTab(id: b.id)
    session.closeTab(id: d.id)
    expect(names(session), ["Query 1"], "the last tab closing is replaced by a fresh one")
    expectTrue(session.activeTabId == session.tabs[0].id, "the replacement is active")

    _ = b
}

@MainActor
private func testCloseOthersAndToRight() {
    let session = makeSession()
    let a = session.createTab(name: "A")
    let b = session.createTab(name: "B")
    let c = session.createTab(name: "C")
    session.selectTab(id: c.id)

    session.closeTabsToRight(ofId: b.id)
    expect(names(session), ["A", "B"], "close-to-right keeps the anchor and everything left of it")
    expect(session.activeTabId, b.id, "the active tab went, so the anchor takes over")

    session.selectTab(id: a.id)
    session.closeTabsToRight(ofId: a.id)
    expect(names(session), ["A"], "close-to-right from the left end leaves one tab")

    let d = session.createTab(name: "D")
    let e = session.createTab(name: "E")
    session.selectTab(id: d.id)
    session.closeOtherTabs(exceptId: e.id)
    expect(names(session), ["E"], "close-others keeps only the named tab")
    expect(session.activeTabId, e.id, "the kept tab is active")

    session.closeOtherTabs(exceptId: "no-such-tab")
    expect(names(session), ["E"], "close-others with an unknown id changes nothing")
    _ = c
}

// MARK: - closed-tab history is the window's

@MainActor
private func testReopenIsPerWindow() {
    let one = makeSession()
    let two = makeSession()

    let a = one.createTab(name: "A")
    _ = one.createTab(name: "B")
    one.closeTab(id: a.id)

    two.createTab(name: "Elsewhere")
    two.reopenLastClosedTab()
    expect(names(two), ["Elsewhere"], "a reopen in window two cannot reach window one's closed tab")

    one.reopenLastClosedTab()
    expect(names(one), ["B", "A"], "the closed tab comes back in the window that closed it")
    expect(one.activeTabId, one.tabs[1].id, "the reopened tab is active")
}

// MARK: - a new tab inherits ITS window's connection

@MainActor
private func testNewTabInheritsItsOwnWindowsConnection() {
    let one = makeSession(defaultSchema: "reporting")
    let two = makeSession(defaultSchema: "reporting")

    one.activeConnectionId = "conn-a"
    let inOne = one.createTab()
    expect(inOne.connectionId, "conn-a", "a tab takes its own window's connection")
    expect(inOne.schemaName, "reporting", "and that connection's default schema")

    let inTwo = two.createTab()
    expect(inTwo.connectionId, nil, "a second window with no connection makes an unbound tab")
    expect(inTwo.schemaName, nil, "and no schema")

    // A window with no default schema on the record binds nothing, exactly as
    // the singleton did: the tab stays unbound rather than guessing "public".
    let three = makeSession(defaultSchema: nil)
    three.activeConnectionId = "conn-c"
    expect(three.createTab().connectionId, nil, "no default schema on the record means no binding")
}

// MARK: - the active connection follows the active tab

@MainActor
private func testSyncActiveConnectionAndSchema() {
    let session = makeSession()
    session.activeConnectionId = "conn-a"
    session.activeSchema = "public"

    let bound = session.createTab(name: "bound")
    session.updateTab(id: bound.id) {
        $0.connectionId = "conn-b"
        $0.schemaName = "sales"
    }
    session.syncActiveConnectionAndSchema()
    expect(session.activeConnectionId, "conn-b", "the window follows its active tab's connection")
    expect(session.activeSchema, "sales", "and its schema")

    // Coming BACK to conn-a must restore the schema this window had chosen for
    // it, not leave the other connection's schema behind.
    session.activeConnectionId = "conn-a"
    expect(session.activeSchema, "public", "a window remembers its schema per connection")
}

// MARK: - pin state

@MainActor
private func testClosingThePinnedTabUnpins() {
    let session = makeSession()
    let a = session.createTab(name: "A")
    _ = session.createTab(name: "B")
    session.pinnedTabId = a.id
    session.pinnedTabName = "A"

    session.closeTab(id: a.id)
    expect(session.pinnedTabId, nil, "closing the pinned tab unpins")
    expect(session.pinnedTabName, nil, "and drops its name")
}

// MARK: - a closing tab's queries are cancelled, once

@MainActor
private func testClosingHandsRunningQueriesToTheCanceller() {
    let session = makeSession()
    var cancelled: [String] = []
    session.hooks.cancelQueries = { tabs in
        cancelled.append(contentsOf: tabs.flatMap { $0.runningQueries.map(\.id) })
    }

    let a = session.createTab(name: "A")
    let b = session.createTab(name: "B")
    session.updateTab(id: a.id) { $0.runningQueries = [running("q1")] }
    session.updateTab(id: b.id) { $0.runningQueries = [running("q2"), running("q3")] }

    session.closeTab(id: a.id)
    expect(cancelled, ["q1"], "closing a tab cancels only that tab's queries")

    session.closeAllForTest()
    expect(cancelled, ["q1", "q2", "q3"], "closing the window cancels what is left")
}

private func running(_ id: String) -> RunningQuery {
    RunningQuery(id: id, normalizedSQL: "select 1", segmentIndex: -1, lineRange: 1...1, startTime: 0)
}

private extension WindowSession {
    /// The window-close path, named for the test.
    @MainActor func closeAllForTest() { cancelAllRunningQueries() }
}

// MARK: - the settled publishers carry the CURRENT value

@MainActor
private func testSettledPublishersCarryTheNewValue() {
    let session = makeSession()
    var seen: [String?] = []
    let token = session.activeTabIdSettled.sink { seen.append($0) }

    let a = session.createTab(name: "A")
    // `@Published` emits from `willSet` and would hand the subscriber the OLD
    // id; these subjects emit from `didSet`. A regression here is invisible in
    // the UI until a pane reads back one tab behind.
    expect(seen.last ?? nil, a.id, "the settled publisher carries the id that was just set")
    token.cancel()
}

// MARK: - entry point

func runTests() {
    MainActor.assumeIsolated {
        testEnsureAndCreate()
        testEnsureIsHeldBackDuringRestore()
        testCloseTab()
        testCloseOthersAndToRight()
        testReopenIsPerWindow()
        testNewTabInheritsItsOwnWindowsConnection()
        testSyncActiveConnectionAndSchema()
        testClosingThePinnedTabUnpins()
        testClosingHandsRunningQueriesToTheCanceller()
        testSettledPublishersCarryTheNewValue()
    }
    if failures > 0 {
        print("\(failures) FAILURE(S)")
        exit(1)
    }
    print("All WindowSession tests passed")
}
