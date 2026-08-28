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

    // A user CAN empty the selection by hand: Command-click the highlighted row,
    // or click the empty space below the last row. The delegate reports nothing
    // for an empty selection, so controller state does not move and the next
    // push carries the SAME rows and the SAME activeId. That push must still put
    // the highlight back — in the default vertical mode this panel is the only
    // surface saying which result the grid is showing, so without this the user
    // is left unable to tell what is on screen, permanently.
    vc.update(rows: rows, activeId: "b")
    expectEqual("\(vc.selectedRowIndex)", "1", "the active row starts highlighted")
    var afterDeselect: [String] = []
    vc.onSelectRow = { afterDeselect.append($0) }
    vc.simulateDeselectAll()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    expectEqual("\(vc.selectedRowIndex)", "-1", "the deselect gesture empties the selection")
    expectEqual("\(afterDeselect.count)", "0", "an empty selection reports nothing to the controller")
    vc.update(rows: rows, activeId: "b")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    expectEqual("\(vc.selectedRowIndex)", "1", "an identical push restores the lost highlight")
    expectEqual("\(afterDeselect.count)", "0", "restoring the highlight does not re-enter the controller")

    // An unchanged push must not disturb the user's scroll position.
    // ContentViewController re-pushes on the 250 ms re-resolve tick that fires
    // while the user types, so a reload here would snap the list back to the
    // active row on the next keystroke. 40 rows overflow the 400pt host, and the
    // active row is the FIRST one, so a reload has somewhere to drag the list to.
    let manyRows = (0..<40).map { model("r\($0)", label: "row \($0)") }
    vc.update(rows: manyRows, activeId: "r0")
    vc.view.layoutSubtreeIfNeeded()
    vc.simulateScroll(toY: 300)
    let scrolled = vc.scrollOffsetY
    // Asserted first: on a panel that never scrolled, everything below would
    // hold at zero and prove nothing at all.
    expectTrue(scrolled > 0, "the panel scrolls away from the top")
    vc.update(rows: manyRows, activeId: "r0")
    vc.view.layoutSubtreeIfNeeded()
    expectEqual("\(vc.scrollOffsetY)", "\(scrolled)",
                "an unchanged push leaves the user's scroll position alone")

    // The other half of the guard: a real change must still reload, or the panel
    // would silently stop tracking result tabs at all.
    let shortened = Array(manyRows.dropLast())
    vc.update(rows: shortened, activeId: "r0")
    vc.view.layoutSubtreeIfNeeded()
    expectEqual("\(vc.numberOfRowsShown)", "39", "a changed push still reloads")

    // The third concern, gated on its own: a push whose activeId MOVED must
    // scroll to the new row even though `rows` did not change, or a result made
    // active from elsewhere — the other pane, or a query finishing — would be
    // highlighted off the bottom of the list where the user cannot see it.
    expectTrue(vc.scrollOffsetY == 0, "the reload left the list at the active row")
    vc.update(rows: shortened, activeId: "r38")
    vc.view.layoutSubtreeIfNeeded()
    expectEqual("\(vc.selectedRowIndex)", "38", "the moved activeId highlights its row")
    expectTrue(vc.scrollOffsetY > 0, "an activeId change scrolls the new row into view")

    // Opening the row menu must have no side effects. onSelectRow is wired to
    // the cross-pane path, so selecting here focuses the pane, changes the
    // active editor tab and swaps the results grid — before the user has chosen
    // a menu item, and even if they press Escape and choose nothing.
    vc.update(rows: rows, activeId: "a")
    var menuSelected: [String] = []
    var menuClosed: [String] = []
    var menuDetailed: [String] = []
    vc.onSelectRow = { menuSelected.append($0) }
    vc.onCloseRow = { menuClosed.append($0) }
    vc.onViewDetail = { menuDetailed.append($0) }

    let menu = vc.simulateRightClickMenu(at: 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    expectEqual("\(menuSelected.count)", "0", "opening the row menu does not fire onSelectRow")
    expectEqual("\(menuClosed.count)", "0", "opening the row menu does not fire onCloseRow")

    // …and the menu it built still works.
    expectEqual("\(menu.items.count)", "2", "the row menu carries two items")
    expectEqual(menu.items.map { $0.title }.joined(separator: ","), "View SQL Query,Close",
                "the row menu lists View SQL Query then Close")
    for item in menu.items {
        guard let action = item.action, let target = item.target else {
            failures += 1
            print("FAIL a row menu item is wired to a target — \(item.title) has none")
            continue
        }
        _ = (target as AnyObject).perform(action, with: item)
    }
    expectEqual(menuDetailed.joined(separator: ","), "c", "View SQL Query reports the clicked row")
    expectEqual(menuClosed.joined(separator: ","), "c", "Close reports the clicked row")
    expectEqual("\(menuSelected.count)", "0", "invoking a menu item still does not select")

    // A row's contents must fill the panel after a resize that pushes NO rows.
    // This is the divider-drag path: `update` is not called, so nothing reloads
    // the table and nothing rebuilds the cells. The reported symptom was a row
    // whose highlight filled the panel while its contents sat in the leftmost
    // part of it, with a gap beyond the counts — which is what a column
    // narrower than the clip view looks like, because the highlight is drawn by
    // the full-width ROW view and the contents live in the CELL view.
    //
    // Read as a regression guard, not as a proof: these assertions also hold
    // with `viewDidLayout` removed, because the column's `.autoresizingMask`
    // already tracks the clip view in every condition reproducible here. They
    // pin the invariant both mechanisms exist to keep.
    let sizeVC = ResultTabsPanelVC()
    let sizeWindow = host(sizeVC, width: 300, height: 200)
    defer { sizeWindow.orderOut(nil) }

    // Pushed ONCE. Every measurement below resizes without pushing again.
    sizeVC.update(rows: rows, activeId: "a")
    sizeVC.view.layoutSubtreeIfNeeded()

    /// Resize the panel the way a divider drag does and report the realised row.
    /// Deliberately no `update` call: a reload would rebuild the cells at the
    /// current width and hide exactly what this is testing.
    func resize(to width: CGFloat) -> (cell: ResultTabRowCell?, clip: CGFloat) {
        sizeVC.view.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        sizeVC.view.needsLayout = true
        sizeVC.view.layoutSubtreeIfNeeded()
        return (sizeVC.cellForTesting(row: 0), sizeVC.clipWidth)
    }

    /// The three things the user can see: the row fills the visible width, the
    /// trailing group sits at the row's right edge, and the dot stays put.
    func expectRowFills(_ width: CGFloat, _ stage: String) {
        let (cell, clip) = resize(to: width)
        guard let cell else {
            failures += 1
            print("FAIL \(stage) — no cell view at row 0")
            return
        }
        expectEqual("\(abs(cell.frame.width - clip) < 1.0)", "true",
                    "\(stage): the row fills the visible width (cell \(cell.frame.width), clip \(clip))")
        // The close button is pinned 6pt inside the trailing edge, so its right
        // edge must land just short of the row's. This is the user's complaint:
        // the counts and the close button stranding mid-row.
        let trailingGap = cell.frame.width - cell.closeButton.frame.maxX
        expectEqual("\(trailingGap > 0 && trailingGap < 10)", "true",
                    "\(stage): the close button sits at the row's right edge (gap \(trailingGap))")
        expectEqual("\(cell.dot.frame.minX)", "8.0",
                    "\(stage): the dot keeps its 8pt leading inset")
    }

    // Non-vacuity: the two widths must actually differ, or none of this proves
    // the row tracked anything.
    let narrowClip = resize(to: 200).clip
    let wideClip = resize(to: 460).clip
    expectTrue(wideClip > narrowClip + 100,
               "the panel really resized (clip \(narrowClip) -> \(wideClip))")

    // Both directions, because the user hit both.
    expectRowFills(200, "narrow")
    expectRowFills(460, "widened")
    expectRowFills(200, "narrowed again")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
