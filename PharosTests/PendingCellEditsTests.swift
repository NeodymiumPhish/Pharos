// Standalone test for `PendingCellEdits` — compiled by
// scripts/test-pending-cell-edits.sh.
//
// What this suite is FOR: the pending set is the only record of a change the
// user has made and not yet written. Two properties matter more than the rest.
//
// 1. An edit that restores the loaded value must REMOVE its entry, not store a
//    no-op — otherwise the bar counts changes that are not changes, the review
//    sheet shows a statement that writes nothing, and "Discard" has something
//    to discard when the user has undone everything by hand.
// 2. The set is keyed on the DATA row, so a sort or a column filter cannot
//    move an edit onto a different row. That one is asserted with a fixture in
//    which the two readings DISAGREE, because a fixture where display index and
//    data index happen to coincide would pass under either rule.
import Foundation

var failures = 0

private func expect(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expect(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected ?? "nil")\n  actual:   \(actual ?? "nil")") }
}

private func expect(_ actual: [Int], _ expected: [Int], _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}

private func edit(_ row: Int, _ column: Int, old: String?, new: String?) -> PendingEdit {
    PendingEdit(dataRow: row, columnIndex: column, oldText: old, newText: new)
}

// MARK: - Adding

private func testAddAndRead() {
    var set = PendingCellEdits()
    expectTrue(set.isEmpty, "a new set is empty")
    set.set(edit(3, 1, old: "alice", new: "Zed"))
    expect(set.count, 1, "one edit counts one")
    expectTrue(!set.isEmpty, "a set with an edit is not empty")
    expect(set.edit(at: 3, columnIndex: 1)?.newText, "Zed", "the edit is readable at its own address")
    expect(set.edit(at: 3, columnIndex: 1)?.oldText, "alice", "the loaded value is kept beside it")
    expectTrue(set.edit(at: 1, columnIndex: 3) == nil, "the address is (row, column) and not (column, row)")
}

private func testReplacingTheSameCellDoesNotAdd() {
    var set = PendingCellEdits()
    set.set(edit(3, 1, old: "alice", new: "Zed"))
    set.set(edit(3, 1, old: "alice", new: "Ann"))
    expect(set.count, 1, "editing the same cell twice is still one change")
    expect(set.edit(at: 3, columnIndex: 1)?.newText, "Ann", "the later edit wins")
}

// MARK: - Reverting

private func testRestoringTheLoadedValueRemovesTheEntry() {
    var set = PendingCellEdits()
    set.set(edit(3, 1, old: "alice", new: "Zed"))
    set.set(edit(3, 1, old: "alice", new: "alice"))
    expect(set.count, 0, "typing the original value back removes the entry")
    expectTrue(set.edit(at: 3, columnIndex: 1) == nil, "and the cell reads as unedited again")
}

private func testSetNullOnAnAlreadyNullCellIsNotAChange() {
    var set = PendingCellEdits()
    set.set(edit(0, 0, old: nil, new: nil))
    expect(set.count, 0, "NULL over NULL is not a change")
}

private func testEmptyStringIsNotNull() {
    // In a text column these are different values, and the whole NULL design
    // rests on the two never being conflated.
    var set = PendingCellEdits()
    set.set(edit(0, 0, old: "x", new: ""))
    set.set(edit(0, 1, old: "x", new: nil))
    expect(set.count, 2, "an empty string and a NULL are two different changes")
    expect(set.edit(at: 0, columnIndex: 0)?.newText, "", "the empty string survives as an empty string")
    expectTrue(set.edit(at: 0, columnIndex: 1)?.newText == nil, "the NULL survives as nil")
    // And neither is a no-op against the other.
    var nullSet = PendingCellEdits()
    nullSet.set(edit(0, 0, old: nil, new: ""))
    expect(nullSet.count, 1, "emptying a NULL cell to the empty string IS a change")
}

private func testRemoveDropsOneCell() {
    var set = PendingCellEdits()
    set.set(edit(3, 1, old: "alice", new: "Zed"))
    set.set(edit(3, 2, old: "1", new: "2"))
    set.remove(dataRow: 3, columnIndex: 1)
    expect(set.count, 1, "Revert Edit drops exactly one cell")
    expect(set.edit(at: 3, columnIndex: 2)?.newText, "2", "and leaves the other one alone")
}

private func testRemoveAll() {
    var set = PendingCellEdits()
    set.set(edit(0, 0, old: "a", new: "b"))
    set.set(edit(1, 0, old: "a", new: "b"))
    set.removeAll()
    expect(set.count, 0, "removeAll empties the set")
    expectTrue(set.rows.isEmpty, "and leaves no rows behind")
}

// MARK: - Grouping

private func testRowsAndColumnsAreSortedAndDeduplicated() {
    var set = PendingCellEdits()
    set.set(edit(7, 3, old: "a", new: "b"))
    set.set(edit(2, 1, old: "a", new: "b"))
    set.set(edit(7, 1, old: "a", new: "b"))
    expect(set.rows, [2, 7], "rows are ascending and each row appears once")
    expect(set.columnIndices, [1, 3], "columns are ascending and each column appears once")
    expect(set.count, 3, "three cells across two rows count three")
}

private func testEditsForOneRowAreOrderedByColumn() {
    var set = PendingCellEdits()
    set.set(edit(4, 5, old: "a", new: "b"))
    set.set(edit(4, 0, old: "a", new: "b"))
    set.set(edit(9, 1, old: "a", new: "b"))
    let row4 = set.edits(forDataRow: 4)
    expect(row4.count, 2, "one row's edits are just that row's")
    expect(row4.map(\.columnIndex), [0, 5], "and come back in column order")
}

private func testAllIsOrderedByRowThenColumn() {
    var set = PendingCellEdits()
    set.set(edit(1, 9, old: "a", new: "b"))
    set.set(edit(0, 2, old: "a", new: "b"))
    set.set(edit(1, 3, old: "a", new: "b"))
    let ordered = set.all.map { "\($0.dataRow).\($0.columnIndex)" }
    expectTrue(ordered == ["0.2", "1.3", "1.9"], "all is ordered by row then column (got \(ordered))")
}

// MARK: - The data-row key

/// A sort reorders `displayRows` and never touches `rows`, so it cannot move a
/// pending edit — the model makes that true by construction, and this is the
/// assertion that says so.
///
/// The fixture is chosen so the two readings DISAGREE. Data rows 0 and 2 are
/// edited with different values; a sorted view shows them as
/// `displayRows = [2, 0, 1]`. Reading the set at display index 0 would return
/// data row 2's edit ("carol"), so an implementation that keyed on the display
/// row would give a visibly wrong answer here rather than the same one.
private func testASortCannotMoveAnEdit() {
    var set = PendingCellEdits()
    set.set(edit(0, 1, old: "alice", new: "Zed"))
    set.set(edit(2, 1, old: "carol", new: "Cara"))

    let unsorted = [0, 1, 2]
    let sorted = [2, 0, 1]

    // Before the sort: display 0 shows data 0.
    expect(set.edit(at: unsorted[0], columnIndex: 1)?.newText, "Zed", "before the sort, the first visible row holds its own edit")
    // After the sort: display 0 shows data 2, and the set answers for DATA 0
    // regardless of where it is now shown.
    expect(set.edit(at: 0, columnIndex: 1)?.newText, "Zed", "after the sort, data row 0 still holds its own edit")
    expect(set.edit(at: sorted[0], columnIndex: 1)?.newText, "Cara", "and the row now shown first holds ITS edit, not row 0's")
    expect(set.count, 2, "a sort adds and removes nothing")
    expect(set.rows, [0, 2], "and the edited rows are unchanged")
}

/// Load More only APPENDS to `rows`, so no existing data index moves. The set
/// is untouched and the appended rows simply have no entries.
private func testLoadMoreLeavesTheSetAlone() {
    var set = PendingCellEdits()
    set.set(edit(1, 0, old: "a", new: "b"))
    // Rows 100..199 arrive.
    expect(set.count, 1, "appending rows adds no edits")
    expect(set.edit(at: 1, columnIndex: 0)?.newText, "b", "and moves none")
    expectTrue(set.edit(at: 150, columnIndex: 0) == nil, "an appended row starts unedited")
}

func runTests() {
    testAddAndRead()
    testReplacingTheSameCellDoesNotAdd()
    testRestoringTheLoadedValueRemovesTheEntry()
    testSetNullOnAnAlreadyNullCellIsNotAChange()
    testEmptyStringIsNotNull()
    testRemoveDropsOneCell()
    testRemoveAll()
    testRowsAndColumnsAreSortedAndDeduplicated()
    testEditsForOneRowAreOrderedByColumn()
    testAllIsOrderedByRowThenColumn()
    testASortCannotMoveAnEdit()
    testLoadMoreLeavesTheSetAlone()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
