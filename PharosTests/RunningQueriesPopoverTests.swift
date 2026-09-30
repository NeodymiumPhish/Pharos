// Standalone test runner for RunningQueriesPopoverVC — the list the toolbar
// Cancel opens when two or more queries run. The view controller's view is
// hosted in a window ordered front off screen (a headless popover never
// shows, so the content is tested without one). Compiled by
// scripts/test-running-queries-popover.sh.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

@MainActor
private final class Recorder: RunningQueriesPopoverDelegate {
    var cancelled: [String] = []
    var cancelAll = 0
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String) { cancelled.append(id) }
    func runningQueriesPopoverDidRequestCancelAll(_ vc: RunningQueriesPopoverVC) { cancelAll += 1 }
}

private func running(_ id: String, _ sql: String, lines: ClosedRange<Int>, startedAgo: Double) -> RunningQuery {
    RunningQuery(id: id, normalizedSQL: sql, segmentIndex: 0, lineRange: lines,
                 startTime: CACurrentMediaTime() - startedAgo)
}

@MainActor
private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

func runTests() {
    // `main.swift` calls this from nonisolated top-level scope on the main
    // thread; the session and the view controller are main-actor types.
    MainActor.assumeIsolated { runOnMain() }
}

@MainActor
private func runOnMain() {
    _ = NSApplication.shared
    let session = WindowSession()
    let tab = QueryTab(name: "Query 1")
    session.tabs = [tab]
    session.activeTabId = tab.id
    let long = "SELECT * FROM conn WHERE ( resp_h = '207.141.200.18' OR orig_h = '207.141.200.18' ) AND timestamp >= '2026-09-01' ORDER BY timestamp"
    session.updateTab(id: tab.id) { $0.runningQueries = [running("q1", long, lines: 1...13, startedAgo: 174)] }

    let vc = RunningQueriesPopoverVC(session: session, tabId: tab.id)
    let recorder = Recorder()
    vc.delegate = recorder
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = vc
    vc.viewWillAppear()
    window.orderFrontRegardless()
    window.layoutIfNeeded()
    settle()

    // MARK: one query
    expectEqual(vc.rows.count, 1, "one row per running query")
    expectEqual(vc.isCancelAllVisible, false, "Cancel All is hidden for one query")
    let row = vc.rows[0]
    expectEqual(row.previewLabel.stringValue, long, "the row carries the statement text")
    expectEqual(row.previewLabel.maximumNumberOfLines, 1, "…on one line")
    expectEqual(row.previewLabel.lineBreakMode, .byTruncatingTail, "…cut at the end")
    expectTrue(row.previewLabel.frame.maxX <= row.bounds.maxX - 18,
               "the preview stops before the cancel button (\(row.previewLabel.frame.maxX) of \(row.bounds.width))")
    expectTrue(row.previewLabel.frame.width > 150, "the preview has room for a useful start (\(row.previewLabel.frame.width) pt)")
    expectEqual(vc.view.frame.width, RunningQueriesPopoverVC.width, "the list is \(RunningQueriesPopoverVC.width) pt wide")

    // A hostile statement cannot rearrange the row.
    session.updateTab(id: tab.id) { $0.runningQueries.append(running("q2", "SELECT 'a\u{202E}b'", lines: 15...15, startedAgo: 145)) }
    settle()
    expectEqual(vc.rows.count, 2, "a second query adds a row")
    expectEqual(vc.rows[1].previewLabel.stringValue.contains("\u{202E}"), false, "a bidi override is escaped in the preview")

    // MARK: two queries
    expectEqual(vc.isCancelAllVisible, true, "Cancel All shows for two queries")
    window.layoutIfNeeded()
    let bottomRowMaxY = vc.rows.map { $0.convert($0.bounds, to: vc.view).minY }.min() ?? 0
    expectTrue(bottomRowMaxY > 20, "the rows sit above the Cancel All button (lowest row at y=\(bottomRowMaxY))")

    vc.pressCancelAll()
    expectEqual(recorder.cancelAll, 1, "Cancel All asks the delegate once")
    expectEqual(recorder.cancelled, [], "…not once per row")
    expectEqual(vc.rows.map(\.isCancelling), [true, true], "every row shows it is cancelling")

    // MARK: back to one
    session.updateTab(id: tab.id) { $0.runningQueries.removeAll { $0.id == "q2" } }
    settle()
    expectEqual(vc.isCancelAllVisible, false, "Cancel All hides again at one query")

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
