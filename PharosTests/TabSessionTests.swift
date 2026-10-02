// Standalone test for the tab session's Swift side: the report and result
// decoding, the banner's states and view, the open-transaction warning, and
// TabSessionMonitor. Compiled by scripts/test-tab-session.sh.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

/// Stand-in for the FFI the monitor calls; the harness has no core.
enum PharosCore {
    nonisolated(unsafe) static var stateAnswer: TabSessionReport?
    static func tabSessionState(tabId: String) -> TabSessionReport? { stateAnswer }
    static func closeTabSession(tabId: String) async -> TabSessionCloseOutcome? { nil }
}

private func report(_ tab: String = "t1", connection: String = "c1", open: Bool = true, txn: TabSessionTxn = .idle,
                    elapsed: Double? = nil, idleLimit: UInt32 = 600, reset: TabSessionReset? = nil) -> TabSessionReport {
    TabSessionReport(sessionId: tab, connectionId: connection, open: open, generation: 1, backendPid: 42, txn: txn,
                     txnElapsedSeconds: elapsed, idleInTransactionTimeoutSeconds: idleLimit, readOnly: false,
                     waiting: 0, reset: reset)
}

private let sessionJSON = """
{"sessionId":"t1","connectionId":"c1","open":true,"generation":2,"backendPid":77,"txn":"inTransaction",
 "txnElapsedSeconds":3.5,"idleInTransactionTimeoutSeconds":600,"readOnly":false,"waiting":1,
 "reset":{"reason":"The connection was lost","at":"2026-10-02T10:00:00Z"}}
"""

private func testDecoding() {
    let query = """
    {"columns":[{"name":"n","data_type":"INT4","relation_oid":null,"relation_attno":null}],"rows":[["1"]],
     "row_count":1,"execution_time_ms":4,"has_more":true,"history_entry_id":"h1","row_identity":null,
     "session":\(sessionJSON)}
    """
    do {
        let r = try JSONDecoder().decode(SessionResult<QueryResult>.self, from: Data(query.utf8))
        expect(r.payload.rowCount == 1 && r.payload.hasMore && r.payload.historyEntryId == "h1", "decode: the pool's fields")
        expect(r.session.txn == .inTransaction && r.session.waiting == 1 && r.session.backendPid == 77, "decode: the session report")
        expect(r.session.reset?.reason == "The connection was lost", "decode: the reset")
        expect(r.session.hasOpenTransaction, "decode: an open transaction")
    } catch { expect(false, "decode: query result", "\(error)") }

    let edit = """
    {"rowsUpdated":2,"executionTimeMs":3,"historyEntryId":"h2","inTransaction":true,"session":\(sessionJSON)}
    """
    do {
        let r = try JSONDecoder().decode(SessionResult<SessionRowUpdate>.self, from: Data(edit.utf8))
        expect(r.payload.result.rowsUpdated == 2 && r.payload.inTransaction, "decode: row edits joined the transaction")
    } catch { expect(false, "decode: row edits", "\(error)") }

    let closed = #"{"closed":true,"hadOpenTransaction":true,"rolledBack":true}"#
    let outcome = try? JSONDecoder().decode(TabSessionCloseOutcome?.self, from: Data(closed.utf8))
    expect(outcome?.rolledBack == true, "decode: close outcome")
    let none = try? JSONDecoder().decode(TabSessionCloseOutcome?.self, from: Data("null".utf8))
    expect(none == nil, "decode: null close outcome is nil")
}

private func testMarkers() {
    expect(TabSessionMarker.isLimit("[PHAROS_SESSION_LIMIT] This server already has 8"), "marker: limit")
    expect(TabSessionMarker.isUnavailable("[PHAROS_SESSION_UNAVAILABLE] nope"), "marker: unavailable")
    expect(!TabSessionMarker.isLimit("syntax error"), "marker: an SQL error is not a marker")
    expect(TabSessionMarker.stripped("[PHAROS_SESSION_LIMIT] Close a tab.") == "Close a tab.", "marker: stripped for the user")
}

private func testBannerModel() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    expect(TabSessionBannerModel.state(report: nil, receivedAt: nil, pendingReset: nil, now: now) == nil, "banner: no connection, no banner")
    expect(TabSessionBannerModel.state(report: report(), receivedAt: now, pendingReset: nil, now: now) == nil, "banner: idle, no banner")

    let open = report(txn: .inTransaction, elapsed: 30, idleLimit: 600)
    let s = TabSessionBannerModel.state(report: open, receivedAt: now.addingTimeInterval(-90), pendingReset: nil, now: now)
    expect(s == .transaction(elapsed: 120, idleRemaining: 510), "banner: age and countdown run from the report", "\(String(describing: s))")
    expect(s?.message == "Transaction open for 2 min. The server rolls it back after 8 min more idle.", "banner: transaction text",
           s?.message ?? "nil")
    expect(s?.actions == [.rollBack, .commit], "banner: Roll Back then Commit")

    let passed = TabSessionBannerModel.state(report: open, receivedAt: now.addingTimeInterval(-700), pendingReset: nil, now: now)
    if case let .transaction(_, remaining?) = passed { expect(remaining < 0, "banner: countdown passes zero") }
    expect(passed?.message.contains("probably rolled the transaction back") == true, "banner: limit passed text")

    let noLimit = TabSessionBannerModel.state(report: report(txn: .inTransaction, elapsed: 5, idleLimit: 0),
                                              receivedAt: now, pendingReset: nil, now: now)
    expect(noLimit == .transaction(elapsed: 5, idleRemaining: nil), "banner: no idle limit, no countdown")

    let reset = TabSessionReset(reason: "The server ended the idle session", at: "x")
    expect(TabSessionBannerModel.state(report: report(txn: .failed), receivedAt: now, pendingReset: reset, now: now) == .failed,
           "banner: a failed transaction wins over an older reset")
    expect(TabSessionBannerModel.state(report: report(), receivedAt: now, pendingReset: reset, now: now)
           == .reset(reason: "The server ended the idle session"), "banner: reset while idle")
    expect(TabSessionBannerModel.state(report: report(open: false, txn: .unknown), receivedAt: now, pendingReset: reset, now: now)
           == .reset(reason: "The server ended the idle session"), "banner: reset with the connection gone")
    expect(TabSessionBannerState.failed.actions == [.rollBack], "banner: failed offers only Roll Back")
    expect(TabSessionBannerState.reset(reason: "r").actions == [.dismiss], "banner: reset offers OK")

    expect(TabSessionBannerModel.duration(45) == "45 s", "duration: seconds")
    expect(TabSessionBannerModel.duration(125) == "2 min", "duration: minutes")
    expect(TabSessionBannerModel.duration(3600) == "1 h", "duration: hours")
    expect(TabSessionBannerModel.duration(3900) == "1 h 5 min", "duration: hours and minutes")
}

private func testWarning() {
    let one = OpenTransactionWarning.title(tabNames: ["Orders"], action: .closeTab)
    expect(one == "“Orders” has an open transaction.", "warning: one tab title", one)
    let two = OpenTransactionWarning.title(tabNames: ["A", "B"], action: .quit)
    expect(two == "2 tabs have open transactions.", "warning: several tabs title", two)
    let message = OpenTransactionWarning.message(tabNames: ["A", "B"], action: .quit)
    expect(message.contains("A and B") && message.contains("Quitting rolls them back."), "warning: names the tabs and the action", message)
    expect(OpenTransactionWarning.Action.disconnect.buttonTitle == "Roll Back and Disconnect", "warning: button names the rollback")
}

@MainActor
private func testMonitor() {
    let monitor = TabSessionMonitor()
    var posted: [String] = []
    let token = NotificationCenter.default.addObserver(forName: TabSessionMonitor.didChange, object: monitor, queue: nil) {
        if let id = $0.userInfo?["tabId"] as? String { posted.append(id) }
    }
    defer { NotificationCenter.default.removeObserver(token) }

    monitor.record(report("t1", txn: .inTransaction))
    monitor.record(report("t2", txn: .idle))
    expect(monitor.hasOpenTransaction("t1") && !monitor.hasOpenTransaction("t2"), "monitor: open transaction per tab")
    expect(monitor.tabsWithOpenTransaction(["t1", "t2", "t3"]) == ["t1"], "monitor: tabs with an open transaction")
    expect(posted == ["t1", "t2"], "monitor: posts per tab", "\(posted)")

    let reset = TabSessionReset(reason: "lost", at: "x")
    monitor.record(report("t2", reset: reset))
    monitor.record(report("t2"))
    expect(monitor.pendingResets["t2"] == reset, "monitor: a reset stays until dismissed")
    monitor.dismissReset("t2")
    expect(monitor.pendingResets["t2"] == nil, "monitor: dismissed")

    monitor.fetchState = { _ in report("t1", txn: .failed) }
    monitor.refresh("t1")
    expect(monitor.report(for: "t1")?.txn == .failed, "monitor: refresh after a failed call reads the core")
    monitor.fetchState = { _ in nil }
    monitor.refresh("t1")
    expect(monitor.report(for: "t1") == nil, "monitor: a tab the core no longer has is forgotten")

    monitor.record(report("t3", connection: "c9", txn: .inTransaction))
    monitor.markUnavailable("c9")
    expect(!monitor.canUseSession(connectionId: "c9"), "monitor: unavailable server")
    monitor.forgetConnection("c9")
    expect(monitor.report(for: "t3") == nil && monitor.canUseSession(connectionId: "c9"), "monitor: disconnect forgets the tabs")
}

@MainActor
private func testBannerView() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 100))
    window.contentView = root
    let banner = TabSessionBanner(frame: NSRect(x: 0, y: 40, width: 700, height: TabSessionBanner.height))
    root.addSubview(banner)
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()

    banner.apply(nil)
    expect(banner.isHidden, "view: nil hides the banner")
    banner.apply(.transaction(elapsed: 65, idleRemaining: 300))
    expect(!banner.isHidden, "view: a transaction shows it")
    expect(banner.button(for: .commit) != nil && banner.button(for: .rollBack) != nil, "view: Commit and Roll Back")
    expect(banner.accessibilityLabel()?.hasPrefix("Transaction open for 1 min.") == true, "view: VoiceOver reads the message")
    expect(banner.button(for: .commit)?.accessibilityIdentifier() == "editor.sessionBanner.commit", "view: AX id")

    var pressed: [TabSessionBannerAction] = []
    banner.onAction = { pressed.append($0) }
    banner.layoutSubtreeIfNeeded()
    for action in [TabSessionBannerAction.rollBack, .commit] {
        guard let button = banner.button(for: action) else { continue }
        let centre = root.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        if let hit = root.hitTest(centre) as? NSButton, hit === button { hit.performClick(nil) }
    }
    expect(pressed == [.rollBack, .commit], "view: clicks reach the buttons through hit-testing", "\(pressed)")

    banner.apply(.failed)
    expect(banner.button(for: .commit) == nil && banner.button(for: .rollBack) != nil, "view: failed has no Commit")
    banner.apply(.reset(reason: "lost"))
    expect(banner.button(for: .dismiss)?.title == "OK", "view: reset has OK")
}

func runTests() {
    testDecoding()
    testMarkers()
    testBannerModel()
    testWarning()
    MainActor.assumeIsolated {
        testMonitor()
        testBannerView()
    }
    if failures == 0 { print("\nAll tab session tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
