// What the results grid's header publishes to a screen reader.
//
// `NSTableHeaderView` publishes one rectangle. Every column name, every sort
// chevron and every filter funnel in this app's header is painted into that one
// rectangle by `FilterableHeaderView.draw(_:)`, so without the elements this
// suite asserts, a screen reader can see that a table has a header and nothing
// whatever about what is in it.
//
// Real AppKit, in a headless never-shown window: an accessibility frame is in
// SCREEN coordinates, so the header needs a window to convert through.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name) [\(actual ?? "nil")]") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected ?? "nil")\n  actual:   \(actual ?? "nil")")
    }
}

// MARK: - Delegate spy

private final class DelegateSpy: NSObject, FilterableHeaderViewDelegate {
    var filtered: [String] = []
    var filterRects: [NSRect] = []
    var autoFitted: [Int] = []

    func headerView(_ headerView: FilterableHeaderView,
                    didClickFilterForColumn column: NSTableColumn, at rect: NSRect) {
        filtered.append(column.identifier.rawValue)
        filterRects.append(rect)
    }

    func headerView(_ headerView: FilterableHeaderView, didDoubleClickResizeForColumn columnIndex: Int) {
        autoFitted.append(columnIndex)
    }
}

// MARK: - Fixture

private struct Fixture {
    let header: FilterableHeaderView
    let table: NSTableView
    let spy: DelegateSpy
}

/// The real grid's column shape: the row-number column, then two data columns
/// named as `ResultsGridVC.rebuildColumns` names them.
private func makeFixture() -> Fixture {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    window.contentView = host

    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 360))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    scroll.documentView = table
    host.addSubview(scroll)

    let rownum = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rownum__"))
    rownum.title = "#"
    rownum.width = 40
    table.addTableColumn(rownum)

    for (index, name) in ["a", "b"].enumerated() {
        let colId = "col_\(index)"
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colId))
        column.headerCell = SortAwareHeaderCell()
        column.title = name
        column.width = 120
        column.sortDescriptorPrototype = NSSortDescriptor(key: colId, ascending: true)
        table.addTableColumn(column)
    }

    let header = FilterableHeaderView(frame: NSRect(x: 0, y: 0, width: 800, height: 34))
    let spy = DelegateSpy()
    header.filterDelegate = spy
    table.headerView = header
    header.columnTypes = ["col_0": "INT4", "col_1": "TEXT"]
    host.layoutSubtreeIfNeeded()

    return Fixture(header: header, table: table, spy: spy)
}

private func label(_ element: AccessibilityProxyElement) -> String {
    element.accessibilityLabel() ?? "nil"
}

func runTests() {
    let fixture = makeFixture()
    let header = fixture.header

    // 1. One element per drawn thing, in reading order. The `#` column has no
    //    name and no sort — its only affordance is the tag funnel — so it
    //    contributes a funnel and no title.
    let elements = header.accessibilityElementsForTesting()
    expectEqual(elements.map(label).joined(separator: " | "),
                "Filter tags | a | Filter a | b | Filter b",
                "the header names every column and every funnel")
    expect(elements.allSatisfy { $0.accessibilityRole() == .button },
           "every header element is a button")
    expect(elements.allSatisfy { $0.accessibilityFrame() != .zero },
           "every header element has a real screen frame")

    // 2. Identity survives a redraw. A fresh element per draw would throw a
    //    screen reader back to the first column on every hover sweep.
    let again = header.accessibilityElementsForTesting()
    expect(zip(elements, again).allSatisfy { $0 === $1 },
           "the elements are cached, not rebuilt per query")

    // 3. State the header DRAWS, said in words.
    header.sortDirections = ["col_0": .ascending]
    header.activeFilterColumns = ["col_1"]
    let stated = header.accessibilityElementsForTesting()
    expectEqual(stated[1].accessibilityValue() as? String, "sorted ascending",
                "a sorted column says which way")
    expectEqual(stated[3].accessibilityValue() as? String, "filtered",
                "a filtered column says so")
    header.sortDirections = ["col_1": .descending]
    expectEqual(header.accessibilityElementsForTesting()[3].accessibilityValue() as? String,
                "sorted descending, filtered",
                "a column that is both says both")
    header.sortDirections = [:]
    header.activeFilterColumns = []
    expect(header.accessibilityElementsForTesting()[1].accessibilityValue() == nil,
           "a plain column has no value")

    // 4. Pressing a column title sorts it, the same way a click does: through
    //    the column's sort descriptor prototype.
    let titleA = header.accessibilityElementsForTesting()[1]
    expect(titleA.accessibilityPerformPress(), "pressing a column title reports that it acted")
    expectEqual(fixture.table.sortDescriptors.first?.key, "col_0", "the press sorts THAT column")
    expect(fixture.table.sortDescriptors.first?.ascending == true, "the first press sorts ascending")
    _ = titleA.accessibilityPerformPress()
    expect(fixture.table.sortDescriptors.first?.ascending == false, "the second press reverses it")

    // 5. Pressing a funnel is the funnel click: same delegate call, same rect,
    //    so the popover opens where the icon is drawn.
    let funnelB = header.accessibilityElementsForTesting()[4]
    expect(funnelB.accessibilityPerformPress(), "pressing a funnel reports that it acted")
    expectEqual(fixture.spy.filtered.last, "col_1", "the funnel press asks to filter THAT column")
    expect(fixture.spy.filterRects.last.map { !$0.isEmpty } == true,
           "the funnel press carries a rect for the popover to hang from")

    // 6. A removed column takes its elements with it.
    fixture.table.removeTableColumn(fixture.table.tableColumns[2])
    header.columnTypes = ["col_0": "INT4"]
    expectEqual(header.accessibilityElementsForTesting().map(label).joined(separator: " | "),
                "Filter tags | a | Filter a",
                "a removed column drops out of the header's children")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
