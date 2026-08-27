// Standalone test runner for ResultTabsPanelVC. Compiled by
// scripts/test-result-tabs-panel-vc.sh with the row cell and its pure deps.
// Headless: the panel is hosted in a never-shown NSWindow so Auto Layout runs
// and the table's selection notifications actually fire.
import AppKit

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

private func model(_ id: String, label: String, stale: Bool = false) -> ResultTabRowModel {
    ResultTabRowModel(id: id, label: label, color: .systemBlue, countsText: "3×4", isStale: stale)
}

/// Host the panel in a headless, never-shown `NSWindow` so Auto Layout runs and
/// the table's selection notifications actually fire — the same technique
/// `TagManagerSheetTests` and `SavedQueryCellViewTests` use. The view goes into
/// a plain root subview rather than the window's own `contentView`, because a
/// window resizes its content view and would fight the frame under test.
/// The window is returned so the caller can keep it alive: releasing it tears
/// down the view tree mid-test.
private func host(_ vc: ResultTabsPanelVC, width: CGFloat = 220, height: CGFloat = 400) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width + 100, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 100, height: height))
    vc.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    root.addSubview(vc.view)
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    return window
}

func runTests() {
    // Every AppKit suite in this repo bootstraps the app object first — the
    // table, its symbol images and its resolved colours need it. Activation is
    // prohibited so the binary stays headless and never steals focus.
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    let vc = ResultTabsPanelVC()
    // Held for the whole suite: dropping the window tears down the view tree.
    let window = host(vc)
    defer { window.orderOut(nil) }

    // Empty state.
    vc.update(rows: [], activeId: nil)
    expectEqual(vc.headerText, "Results", "empty header carries no count")
    expectFalse(vc.isEmptyLabelHidden, "empty label shows with no rows")

    // Three rows, middle one active.
    let rows = [model("a", label: "one"), model("b", label: "two"), model("c", label: "three")]
    vc.update(rows: rows, activeId: "b")
    expectEqual(vc.headerText, "Results · 3", "header counts the rows")
    expectTrue(vc.isEmptyLabelHidden, "empty label hides when rows exist")
    expectEqual("\(vc.numberOfRowsShown)", "3", "table shows one row per model")
    expectEqual("\(vc.selectedRowIndex)", "1", "active id selects its row")

    // Selection callback fires for user selection, not for programmatic update.
    var selected: [String] = []
    vc.onSelectRow = { selected.append($0) }
    vc.update(rows: rows, activeId: "c")
    // Let any deferred notification arrive, so this holds regardless of how
    // AppKit chooses to deliver the selection change.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    expectEqual("\(selected.count)", "0", "programmatic update does not fire onSelectRow")
    vc.simulateRowClick(at: 0)
    expectEqual(selected.joined(separator: ","), "a", "clicking row 0 reports id a")

    // A row's own close button reaches onCloseRow, driven through the cell the
    // user actually clicks rather than through a seam that would only re-state
    // the wiring.
    var closed: [String] = []
    vc.onCloseRow = { closed.append($0) }
    vc.update(rows: rows, activeId: "a")
    if let cell = vc.cellForTesting(row: 1) {
        cell.closeButton.performClick(nil)
        expectEqual(closed.joined(separator: ","), "b", "a cell's close button reports its own row")
    } else {
        failures += 1
        print("FAIL a cell's close button reports its own row — no cell view at row 1")
    }

    // Active id no longer present -> no selection.
    vc.update(rows: [model("a", label: "one")], activeId: nil)
    expectEqual("\(vc.selectedRowIndex)", "-1", "nil activeId clears selection")

    // Stale rows still render; the panel does not filter them out.
    vc.update(rows: [model("a", label: "one", stale: true), model("b", label: "two")], activeId: "b")
    expectEqual("\(vc.numberOfRowsShown)", "2", "a stale row is still listed")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
