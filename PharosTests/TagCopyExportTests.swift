// Standalone test runner for the "Tagged Rows Only" copy/export scope as
// ResultsCopyExport actually applies it. Uses real AppKit: a real NSTableView,
// a real CellSelectionState and the real context-menu items, like
// scripts/test-tag-removal-sheet.sh hosts the real sheet.
// Compiled with ResultsCopyExport.swift and TagCopyScope.swift by
// scripts/test-tag-copy-export.sh.
//
// What this suite is FOR: TagCopyScopeTests proves the RULE; this proves the
// WIRING, which is where the rule can be applied to the wrong thing without
// any test noticing. Specifically:
//
//  - the map is keyed by DATA index while the table speaks DISPLAY indices, so
//    every call site must translate through displayRows and the two disagree
//    whenever the grid is filtered or sorted;
//  - selectionSummary() must mirror gatherData() exactly, or the popover
//    caption promises a copy the copy does not make;
//  - a cell range the scope empties must be terminal, never widening to the
//    whole visible set;
//  - the menu item must DISABLE with no tag map, which puts it outside the
//    blanket enable that switches every other item back on.
//
// The toggle is private and is flipped here only through the real tag-11 menu
// item — a test-only setter would prove the setter works, not the item.
import AppKit

// MARK: - Test double

/// A headless NSTableView reports `numberOfRows == 0` when it has no data
/// source, and `selectRowIndexes` is then SILENTLY IGNORED. Without this
/// override the row-selection cases fall through to the no-selection branch
/// and pass while asserting nothing — they did, until a mutation that broke
/// the row-selection path survived and exposed it. Overriding `numberOfRows`
/// is enough to make a real selection stick; no data source, so no cell views
/// and nothing to lay out.
private final class ProbeTableView: NSTableView {
    var rowCount = 0
    override var numberOfRows: Int { rowCount }
}

// MARK: - Assertions

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name) — got \(actual), want \(expected)") }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

// MARK: - Fixtures

/// A grid of `rowCount` single-column data rows valued "r0"…"r<n-1>", showing
/// `displayRows` in that order. The default [7, 2, 5] is deliberately filtered
/// AND reordered so no display index equals its data index.
///
/// That is necessary but NOT sufficient. `selectionSummary()` returns a COUNT,
/// and a count is blind to direction: over the range 0…2 with `taggedRows`
/// [2], reading the map by data index keeps display 1 and reading it by
/// display index keeps display 2 — one row either way, so the assertion holds
/// while the site is wrong. A summary case must therefore choose a tagged set
/// whose two readings give different COUNTS (see
/// `testCellRangeSummaryCountsTheDataIndexedRow`), and assert the copied
/// VALUES beside the count.
private func makeSubject(rowCount: Int = 8,
                         displayRows: [Int] = [7, 2, 5],
                         taggedRows: Set<Int>) -> (ResultsCopyExport, ProbeTableView) {
    let table = ProbeTableView()
    table.rowCount = displayRows.count
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_0")))
    let subject = ResultsCopyExport(tableView: table,
                                    copyButton: NSButton(), exportButton: NSButton())
    subject.columns = [ColumnDef(name: "c", dataType: "text")]
    subject.rows = (0..<rowCount).map { [AnyCodable("r\($0)")] }
    subject.displayRows = displayRows
    subject.taggedRows = taggedRows
    return (subject, table)
}

/// Flips the private toggle the way a user does: through the real menu item.
private func setTaggedOnly(_ subject: ResultsCopyExport) {
    let item = taggedItem(of: subject).item
    _ = item.target?.perform(item.action, with: item)
}

private func taggedItem(of subject: ResultsCopyExport) -> (menu: NSMenu, item: NSMenuItem) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    subject.addCopyItems(to: menu)
    return (menu, menu.items.first { $0.tag == 11 }!)
}

/// The copied cell values, one row per element, joined so a miscount reads
/// plainly in the failure line.
private func copied(_ subject: ResultsCopyExport) -> String {
    guard let data = subject.gatherData() else { return "<nil>" }
    return data.rows.map { $0.joined() }.joined(separator: ",")
}

private func cellRange(_ subject: ResultsCopyExport, fromDisplayRow lo: Int, to hi: Int) {
    var sel = CellSelectionState()
    sel.anchor = CellPosition(row: lo, column: 0)
    sel.active = CellPosition(row: hi, column: 0)
    subject.cellSelection = sel
}

// MARK: - Tests

private func testDisplayVersusDataIndex() {
    // Display 0→data 7, display 1→data 2, display 2→data 5. Tagging DATA row 2
    // must keep "r2"; reading the map with the display index would keep "r5".
    let (s, _) = makeSubject(taggedRows: [2])
    expect(copied(s), "r7,r2,r5", "toggle off copies every display row")
    setTaggedOnly(s)
    expect(copied(s), "r2", "tagged-only keeps the DATA-indexed tagged row")
    expect("\(s.selectionSummary().rows)", "1", "whole-set summary mirrors the filter")
}

private func testEveryRowInTheSetIsInScope() {
    // Whatever put a row in `taggedRows` — solid match or dashed — this class
    // treats it the same, because the set is the only thing it is given.
    //
    // NOTE this canNOT prove the "dashed counts too" decision: `Set<Int>`
    // carries no match state, so the suite cannot tell a dashed row from a
    // solid one. That decision lives in `ResultsGridVC.applyTagMap`, which
    // passes `Set(map.keys)` — every row `TagRuleMatcher.match` recorded, at
    // either state — and no harness compiles that file. Verified by reading.
    let (s, _) = makeSubject(taggedRows: [7, 5])
    setTaggedOnly(s)
    expect(copied(s), "r7,r5", "every row in the set is in scope, whatever put it there")
}

private func testCellRangeSummaryCountsTheDataIndexedRow() {
    // The direction case a count alone cannot make. Data row 7 is display 0;
    // no display index in 0…2 equals 7, so reading the map by display index
    // yields ZERO rows here while reading it by data index yields one. The
    // count and the copied value both move, so both assertions bite.
    let (s, _) = makeSubject(taggedRows: [7])
    cellRange(s, fromDisplayRow: 0, to: 2)
    setTaggedOnly(s)
    expect(copied(s), "r7", "cell range keeps the data-7 row")
    expect("\(s.selectionSummary().rows)", "1",
           "cell-range summary counts the DATA-indexed row")
}

private func testRowSelectionSpansTaggedAndUntagged() {
    let (s, table) = makeSubject(taggedRows: [2, 5])
    table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
    expectTrue(!table.selectedRowIndexes.isEmpty, "the row selection really took")
    expect(copied(s), "r7,r2,r5", "row selection, toggle off, copies all three")
    expect("\(s.selectionSummary().rows)", "3", "row-selection summary counts three")

    setTaggedOnly(s)
    expect(copied(s), "r2,r5", "row selection drops the untagged row")
    expect("\(s.selectionSummary().rows)", "2", "row-selection summary mirrors the filter")
    expectTrue(s.selectionSummary().isSelection, "a filtered row selection is still a selection")
}

private func testCellRange() {
    let (s, _) = makeSubject(taggedRows: [2])
    cellRange(s, fromDisplayRow: 0, to: 2)
    expect(copied(s), "r7,r2,r5", "cell range, toggle off, copies the range")
    expect("\(s.selectionSummary().rows)", "3", "cell-range summary counts the range")

    setTaggedOnly(s)
    expect(copied(s), "r2", "cell range, toggle on, keeps only the tagged row")
    expect("\(s.selectionSummary().rows)", "1", "cell-range summary mirrors the filter")
}

private func testScopeEmptiedCellRangeIsTerminal() {
    // Display rows 0 and 1 are data 7 and 2; only data 5 is tagged, so the
    // scope empties this range. The copy must produce NOTHING — the bug being
    // guarded is a fall-through to the row path, which would copy "r5": a row
    // the user did not select, from outside the block they chose.
    let (s, _) = makeSubject(taggedRows: [5])
    cellRange(s, fromDisplayRow: 0, to: 1)
    setTaggedOnly(s)
    expect(copied(s), "<nil>", "a scope-emptied cell range copies nothing")

    let summary = s.selectionSummary()
    expect("\(summary.rows)", "0", "its summary reports zero rows")
    expectTrue(summary.isSelection, "and still reports a selection, not the whole set")
    expect(s.summaryCaption(), "Tagged selection: 1 column × 0 rows",
           "the caption states the empty scoped selection")
}

private func testOutOfBoundsCellRangeKeepsItsFallThrough() {
    // Only the scope may end the action. A range that lands entirely outside
    // the displayed rows drops nothing by scope, so it keeps its old
    // fall-through to the visible set rather than becoming a silent refusal.
    let (s, _) = makeSubject(taggedRows: [2])
    cellRange(s, fromDisplayRow: 40, to: 41)
    expect(copied(s), "r7,r2,r5", "an out-of-bounds range still falls through")
}

private func testBlankMapPassesEverything() {
    // The async recompute window blanks the map; a copy landing in it must not
    // silently produce nothing.
    let (s, _) = makeSubject(taggedRows: [])
    setTaggedOnly(s)
    expect(copied(s), "r7,r2,r5", "toggle on with a blank map still copies everything")
    expect("\(s.selectionSummary().rows)", "3", "blank-map summary counts everything")

    cellRange(s, fromDisplayRow: 0, to: 1)
    expect(copied(s), "r7,r2", "a blank map cannot empty a cell range either")
}

private func testEveryRowTagged() {
    let (s, _) = makeSubject(taggedRows: [7, 2, 5])
    setTaggedOnly(s)
    expect(copied(s), "r7,r2,r5", "toggle on with every row tagged copies everything")
}

private func testCaptionTracksTheRealScope() {
    // The caption is the only signal that a copy was narrowed, so it must say
    // "Tagged" when — and only when — the filter actually engages.
    let (s, _) = makeSubject(taggedRows: [2])
    expect(s.summaryCaption(), "All 1 column × 3 rows", "toggle off: the plain caption")
    setTaggedOnly(s)
    expect(s.summaryCaption(), "Tagged: 1 column × 1 row", "toggle on: the caption says Tagged")

    // Pass-through: the toggle is on but the map is blank, so nothing is being
    // filtered and the caption must NOT claim a scope.
    let (blank, _) = makeSubject(taggedRows: [])
    setTaggedOnly(blank)
    expectFalse(blank.summaryCaption().contains("Tagged"),
                "a pass-through copy never claims to be tagged")
    expect(blank.summaryCaption(), "All 1 column × 3 rows", "pass-through keeps the plain caption")

    // Selection wording.
    let (sel, table) = makeSubject(taggedRows: [2, 5])
    table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
    expect(sel.summaryCaption(), "Selected: 1 column × 3 rows", "an unscoped selection caption")
    setTaggedOnly(sel)
    expect(sel.summaryCaption(), "Tagged selection: 1 column × 2 rows",
           "a scoped selection caption")
}

private func testMenuItem() {
    let (s, _) = makeSubject(taggedRows: [])
    let (menu, item) = taggedItem(of: s)
    expect(item.title, "Tagged Rows Only", "the menu item exists at tag 11")

    s.updateCopyItems(in: menu)
    expectFalse(item.isEnabled, "item 11 disables with no tagged rows")
    expectTrue(item.state == .off, "item 11 starts off")

    s.taggedRows = [2]
    s.updateCopyItems(in: menu)
    expectTrue(item.isEnabled, "item 11 enables once rows are tagged")

    _ = item.target?.perform(item.action, with: item)
    s.updateCopyItems(in: menu)
    expectTrue(item.state == .on, "item 11 shows the toggle on")

    // Item 11 sits outside the 1...10 blanket enable precisely so this holds.
    s.taggedRows = []
    s.updateCopyItems(in: menu)
    expectFalse(item.isEnabled, "the blanket enable leaves a disabled item 11 alone")
    let headers = menu.items.first { $0.tag == 10 }!
    expectTrue(headers.isEnabled, "the headers item stays enabled")
}

// MARK: - The popover surface

/// Every descendant of a view, so the real checkboxes and the caption label can
/// be found the way a user sees them rather than through a test-only accessor.
private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

private func checkbox(_ vc: CopyExportPopoverVC, titled title: String) -> NSButton? {
    descendants(of: vc.view).compactMap { $0 as? NSButton }.first { $0.title == title }
}

private func captionLabel(_ vc: CopyExportPopoverVC) -> NSTextField? {
    descendants(of: vc.view).compactMap { $0 as? NSTextField }
        .first { $0.stringValue.contains("×") }
}

private func popover(_ subject: ResultsCopyExport) -> CopyExportPopoverVC {
    let vc = subject.makePopoverVC(items: [("Copy as TSV", #selector(ResultsCopyExport.copyAsTSV))])
    _ = vc.view          // force loadView()
    return vc
}

private func testPopoverShowsTheScopeBoxOnlyWithATagMap() {
    let (tagged, _) = makeSubject(taggedRows: [2])
    expectTrue(checkbox(popover(tagged), titled: "Tagged Rows Only") != nil,
               "the popover offers the scope box when rows are tagged")

    let (blank, _) = makeSubject(taggedRows: [])
    expectTrue(checkbox(popover(blank), titled: "Tagged Rows Only") == nil,
               "the popover hides the scope box with no tag map")
    expectTrue(checkbox(popover(blank), titled: "Include Headers") != nil,
               "the headers box is still there when the scope box is hidden")
}

private func testPopoverBoxStartsOnTheCurrentScope() {
    let (off, _) = makeSubject(taggedRows: [2])
    expectTrue(checkbox(popover(off), titled: "Tagged Rows Only")?.state == .off,
               "the box opens unticked while the scope is off")

    let (on, _) = makeSubject(taggedRows: [2])
    setTaggedOnly(on)   // through the menu item, so the popover reads real state
    expectTrue(checkbox(popover(on), titled: "Tagged Rows Only")?.state == .on,
               "the box opens ticked while the scope is on")
}

private func testPopoverBoxDrivesTheScope() {
    let (s, _) = makeSubject(taggedRows: [2])
    let vc = popover(s)
    guard let box = checkbox(vc, titled: "Tagged Rows Only") else {
        failures += 1; print("FAIL the scope box exists to be pressed"); return
    }
    expect(copied(s), "r7,r2,r5", "before the press, every visible row copies")

    box.performClick(nil)
    expect(copied(s), "r2", "pressing the box scopes the copy")

    // A second press must UNscope. This is what catches taggedToggled() reading
    // the headers box instead of its own: the headers box is ticked by default,
    // so a mis-wired handler reports .on both times and the scope sticks.
    box.performClick(nil)
    expect(copied(s), "r7,r2,r5", "pressing it again unscopes the copy")
}

private func testPopoverHeadersBoxDoesNotDriveTheScope() {
    let (s, _) = makeSubject(taggedRows: [2])
    let vc = popover(s)
    guard let headers = checkbox(vc, titled: "Include Headers") else {
        failures += 1; print("FAIL the headers box exists to be pressed"); return
    }
    headers.performClick(nil)
    expect(copied(s), "r7,r2,r5", "the headers box leaves the scope alone")
}

private func testPopoverCaptionFollowsTheBox() {
    // The caption and the five format buttons share this popover, so a caption
    // frozen at open time would advertise a copy the buttons no longer make.
    let (s, _) = makeSubject(taggedRows: [2])
    let vc = popover(s)
    guard let box = checkbox(vc, titled: "Tagged Rows Only"),
          let label = captionLabel(vc) else {
        failures += 1; print("FAIL the popover has a caption and a scope box"); return
    }
    expect(label.stringValue, "All 1 column × 3 rows", "the caption opens unscoped")

    box.performClick(nil)
    expect(label.stringValue, "Tagged: 1 column × 1 row",
           "the caption follows the box to the scoped count")

    box.performClick(nil)
    expect(label.stringValue, "All 1 column × 3 rows", "and back again")
}

func runTests() {
    testDisplayVersusDataIndex()
    testEveryRowInTheSetIsInScope()
    testCellRangeSummaryCountsTheDataIndexedRow()
    testRowSelectionSpansTaggedAndUntagged()
    testCellRange()
    testScopeEmptiedCellRangeIsTerminal()
    testOutOfBoundsCellRangeKeepsItsFallThrough()
    testBlankMapPassesEverything()
    testEveryRowTagged()
    testCaptionTracksTheRealScope()
    testMenuItem()
    testPopoverShowsTheScopeBoxOnlyWithATagMap()
    testPopoverBoxStartsOnTheCurrentScope()
    testPopoverBoxDrivesTheScope()
    testPopoverHeadersBoxDoesNotDriveTheScope()
    testPopoverCaptionFollowsTheBox()

    if failures == 0 {
        print("\nAll TagCopyExport tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
