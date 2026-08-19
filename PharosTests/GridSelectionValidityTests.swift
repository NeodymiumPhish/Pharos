// Standalone test runner for GridSelectionValidity — the rule that decides
// whether the grid's DISPLAY-coordinate selection still addresses the same
// records after the visible row list was rebuilt.
//
// It also pins the AppKit fact the rule exists to compensate for. Compiled
// with the implementation by scripts/test-grid-selection-validity.sh.
import AppKit

var failures = 0

func expect(_ actual: Bool, _ expected: Bool, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectRows(_ actual: [Int], _ expected: [Int], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - The rule

private func testRule() {
    let identity = [0, 1, 2, 3, 4]

    // Nothing selected: nothing can be invalidated. This case carries weight —
    // the grid reloads constantly, and a rule that reported "does not survive"
    // here would blank the Inspector on every one of them.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(), before: identity, after: [4, 3, 2, 1, 0]),
        true, "an empty selection survives any rebuild")

    // The B11 case: a re-sort hands display position 1 to a different record.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 1), before: identity, after: [4, 3, 2, 1, 0]),
        false, "a re-sort that moves the selected record invalidates it")

    // A rebuild that produces the same map changes nothing.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 1), before: identity, after: identity),
        true, "an unchanged row list keeps the selection")

    // Load More: rows are APPENDED, so every existing position keeps its
    // record. The selection must not be thrown away for that.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 2), before: identity, after: identity + [5, 6]),
        true, "appending rows leaves an earlier selection addressing its record")

    // A filter that only removes rows BELOW the selection also leaves the
    // selected position addressing the same record. The rule is about
    // identity, not about whether the list is equal.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 0), before: identity, after: [0, 1]),
        true, "removing rows below the selection keeps it valid")

    // A filter that removes a row ABOVE the selection shifts it onto another
    // record — same shape of lie as the sort.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 1), before: identity, after: [1, 2, 3, 4]),
        false, "removing a row above the selection invalidates it")

    // The selected position falls off the end of the shorter new list.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 4), before: identity, after: [0, 1]),
        false, "a selection past the end of the new list does not survive")

    // Exactly ONE past the end — the boundary the bounds check has to get
    // right. An off-by-one here reads past the end of `after` and traps
    // instead of answering.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 2), before: identity, after: [0, 1]),
        false, "a selection exactly at the new list's length does not survive")

    // A multi-row selection is only as valid as its worst member: index 0
    // still addresses record 0, but index 3 does not.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet([0, 3]), before: identity, after: [0, 1, 2, 9, 4]),
        false, "one moved row invalidates the whole selection")

    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet([0, 1]), before: identity, after: [0, 1, 9, 9, 9]),
        true, "a selection is unaffected by movement below it")

    // The mirror boundary: an index the OLD list never held. A selection can
    // only come from the old list, so this is defensive — but the guard that
    // makes it defensive has to be there, and unbounded it would trap.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 2), before: [0, 1], after: identity),
        false, "an index the before-list never held does not survive")

    // Degenerate lists must not trap.
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(integer: 0), before: [], after: []),
        false, "a selection into an empty before-list does not survive")
    expect(GridSelectionValidity.survivesRebuild(
        selected: IndexSet(), before: [], after: []),
        true, "an empty selection over empty lists survives")
}

// MARK: - AppKit fact pin

/// `reconcileSelection` in ResultsGridVC exists because `reloadData()` drops
/// the table's row selection AND posts no `tableViewSelectionDidChange`, so
/// nothing downstream can notice. That is not documented anywhere we control;
/// if a future AppKit changes it, the workaround and its comment become false
/// silently. Pin it here.
private final class ProbeSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var rowCount = 10
    var selectionNotifications = 0
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "r\(row)")
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionNotifications += 1 }
}

private func testReloadDataDropsSelectionSilently() {
    _ = NSApplication.shared
    let tableView = NSTableView()
    tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
    let source = ProbeSource()
    tableView.dataSource = source
    tableView.delegate = source
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scrollView.documentView = tableView
    tableView.reloadData()
    tableView.layoutSubtreeIfNeeded()

    tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
    expectRows(Array(tableView.selectedRowIndexes), [3], "the probe table can be selected at all")

    source.selectionNotifications = 0
    tableView.reloadData()
    expectRows(Array(tableView.selectedRowIndexes), [],
               "reloadData() drops the row selection even when the row count is unchanged")
    expect(source.selectionNotifications == 0, true,
           "reloadData() posts no tableViewSelectionDidChange when it drops the selection")
}

func runTests() {
    testRule()
    testReloadDataDropsSelectionSilently()

    if failures == 0 {
        print("\nAll GridSelectionValidity tests passed.")
    } else {
        print("\n\(failures) test(s) failed.")
        exit(1)
    }
}
