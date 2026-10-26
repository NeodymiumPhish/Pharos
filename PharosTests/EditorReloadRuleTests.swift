// Standalone test runner for EditorReloadRule.
// Compiled with the implementation by scripts/test-editor-reload-rule.sh.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // Table columns: 0 is `#`, data column N shows at table column N + 1
    // unless the test hides or moves it.
    let shown: (Int) -> Int? = { $0 + 1 }
    let editable: (Int, Int) -> Bool = { _, _ in true }

    func outcome(_ dataRow: Int, _ dataColumn: Int, _ displayRows: [Int],
                 tableColumn: @escaping (Int) -> Int? = shown,
                 isEditable: @escaping (Int, Int) -> Bool = editable) -> EditorReloadRule.Outcome {
        EditorReloadRule.outcome(dataRow: dataRow, dataColumn: dataColumn, displayRows: displayRows,
                                 tableColumn: tableColumn, isEditable: isEditable)
    }

    // MARK: - The editor follows its RECORD, not its display row

    expectEqual(outcome(2, 0, [0, 1, 2, 3]), .reopen(row: 2, column: 1),
                "nothing moved: it reopens where it was")
    expectEqual(outcome(2, 0, [3, 2, 1, 0]), .reopen(row: 1, column: 1),
                "a sort moved the record: it reopens on the record's new row")
    expectEqual(outcome(7, 0, [0, 5, 7]), .reopen(row: 2, column: 1),
                "a filter removed rows above it: it follows the record down the list")
    expectEqual(outcome(4, 0, [0, 1, 2, 3, 4, 5, 6]), .reopen(row: 4, column: 1),
                "a page of rows arrived below it: same row")

    // MARK: - The editor follows its COLUMN

    expectEqual(outcome(1, 2, [0, 1, 2], tableColumn: { $0 == 2 ? 1 : nil }), .reopen(row: 1, column: 1),
                "a column before it was hidden: it reopens in the column's new place")

    // MARK: - Gone or locked: commit, never discard

    expectEqual(outcome(2, 0, [0, 1, 3]), .commit,
                "its record is filtered out of view: the text is committed as a pending edit")
    expectEqual(outcome(2, 0, []), .commit, "no rows at all: committed")
    expectEqual(outcome(1, 3, [0, 1, 2], tableColumn: { _ in nil }), .commit,
                "its column is hidden: committed")
    expectEqual(outcome(1, 0, [0, 1, 2], isEditable: { _, _ in false }), .commit,
                "editing was turned off in Settings: committed, not left open")

    // The editability question is asked about the NEW place, not the old one.
    var asked: [String] = []
    _ = outcome(5, 2, [9, 5], isEditable: { asked.append("\($0),\($1)"); return true })
    expectEqual(asked, ["1,3"], "editability is checked at the new display row and table column")

    if failures == 0 {
        print("\nAll EditorReloadRule tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
