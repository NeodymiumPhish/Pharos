// Standalone test runner for SQL autocomplete accessibility — no Xcode
// project or test target involvement.
//
// The completion popover never takes focus (key events have to keep reaching
// the text view so typing filters the list), so VoiceOver never walks into
// the table on its own. Two things therefore carry the whole experience: the
// row's own accessibility label, and the announcements the provider posts.
// The label is checked by driving the table delegate directly against a stub
// table; the announcements are checked through the pure text helpers the
// provider calls, since a posted announcement leaves nothing observable
// behind in a headless process.
//
// Compiled with SQLCompletionProvider.swift, SQLTextView.swift and their
// dependencies by scripts/test-completion-accessibility.sh.
import AppKit

private var failures = 0

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private typealias Completion = SQLCompletionProvider.Completion

/// Every kind, with the detail text the real builders give it.
private let items: [Completion] = [
    Completion(label: "SELECT", detail: "keyword", insertText: "SELECT", kind: .keyword),
    Completion(label: "count", detail: "function", insertText: "count()", kind: .function),
    Completion(label: "insert-row", detail: "snippet", insertText: "", kind: .snippet),
    Completion(label: "public", detail: "schema", insertText: "public", kind: .schema),
    Completion(label: "orders", detail: "table", insertText: "orders", kind: .table),
    Completion(label: "order_id", detail: "integer PK", insertText: "order_id", kind: .column),
    Completion(label: "active_users", detail: "view", insertText: "active_users", kind: .view),
    Completion(label: "start_date", detail: "2026-01-01", insertText: "start_date", kind: .variable),
    Completion(label: "zone", detail: "new variable", insertText: "zone", kind: .newVariable),
]

private let expectedKindNames = [
    "Keyword", "Function", "Snippet", "Schema", "Table", "Column", "View",
    "Variable", "New Variable",
]

/// A bare table carrying the same column identifier the provider builds its
/// popover with. `makeView(withIdentifier:owner:)` finds nothing on it, so the
/// delegate takes its build-a-fresh-cell path — which is the path under test.
private func makeStubTable() -> (NSTableView, NSTableColumn) {
    let table = NSTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
    column.width = 300
    table.addTableColumn(column)
    table.headerView = nil
    return (table, column)
}

func runTests() {
    let provider = SQLCompletionProvider()
    provider.setFilteredCompletionsForTesting(items)
    let (table, column) = makeStubTable()

    // --- One row per kind: the icon names its kind, the row reads as a unit ---
    for (row, item) in items.enumerated() {
        let kindName = expectedKindNames[row]
        guard let cell = provider.tableView(table, viewFor: column, row: row) as? NSTableCellView else {
            failures += 1
            print("FAIL row \(row) (\(kindName)) produced no NSTableCellView")
            continue
        }
        expectEqual(cell.imageView?.image?.accessibilityDescription ?? "(none)", kindName,
                    "\(kindName) icon has an accessibility description")
        expectEqual(cell.accessibilityLabel() ?? "(none)",
                    SQLCompletionProvider.rowLabel(for: item),
                    "\(kindName) row label matches rowLabel(for:)")
    }

    // --- Row label wording ---
    expectEqual(SQLCompletionProvider.rowLabel(for: items[0]), "SELECT, Keyword",
                "a keyword's detail repeats its kind and is dropped")
    expectEqual(SQLCompletionProvider.rowLabel(for: items[5]), "order_id, Column, integer PK",
                "a column keeps its type detail")
    expectEqual(SQLCompletionProvider.rowLabel(for: items[6]), "active_users, View",
                "a view's detail repeats its kind and is dropped")

    expectEqual(SQLCompletionProvider.rowLabel(for: items[7]), "start_date, Variable, 2026-01-01",
                "a variable keeps its value preview")
    expectEqual(SQLCompletionProvider.rowLabel(for: items[8]), "zone, New Variable",
                "the new-variable row's detail repeats its kind and is dropped")

    // --- Announcement wording ---
    expectEqual(SQLCompletionProvider.announcementText(for: items[0], count: 7),
                "7 completions. SELECT, Keyword", "show announcement")
    expectEqual(SQLCompletionProvider.announcementText(for: items[4], count: 1),
                "1 completion. orders, Table", "a single match is not \"completions\"")
    expectEqual(SQLCompletionProvider.announcementText(for: nil, count: 0),
                "0 completions", "an empty list announces no row")
    expectEqual(SQLCompletionProvider.selectionAnnouncementText(for: items[5]),
                "order_id, Column", "arrow-key announcement names the row and its kind")

    // --- Hostile text is escaped before it is spoken ---
    let hostile = Completion(
        label: "ord\u{202E}ers", detail: "table", insertText: "x", kind: .table)
    expectTrue(!SQLCompletionProvider.rowLabel(for: hostile).unicodeScalars.contains("\u{202E}"),
               "a bidi override in a label never reaches the spoken string")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
