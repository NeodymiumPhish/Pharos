// Standalone test runner for hiding and showing result columns from the
// header's context menu, compiled by scripts/test-grid-column-visibility.sh.
//
// Two things are under test, and they fail in different ways:
//
// 1. The MENU and its invariants — what it lists, what it check-marks, and the
//    one rule it must never let the user break: the last visible data column
//    cannot be hidden, because no header click would bring it back.
// 2. The GEOMETRY. A hidden `NSTableColumn` keeps its slot in `tableColumns`
//    and its `headerRect` collapses to a ZERO-WIDTH rect AT x = 0 — not to
//    nothing, and not off screen. Every per-column loop in the header that
//    reads `headerRect` therefore has to skip it, or it draws names, publishes
//    accessibility frames and offers resize handles at the header's left edge,
//    for a column the user has just taken away.
//
// The round trip through `ResultsGridState` is driven against a real
// `NSTableView` via `ResultsGridColumnState`, which is the production path
// `ResultsGridVC.captureGridState()`/`restoreGridState(_:)` call.
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

// MARK: - Delegate spy

private final class HeaderSpy: FilterableHeaderViewDelegate {
    var autofitColumns: [Int] = []
    var filterColumns: [String] = []

    func headerView(_ headerView: FilterableHeaderView, didClickFilterForColumn column: NSTableColumn, at rect: NSRect) {
        filterColumns.append(column.identifier.rawValue)
    }

    func headerView(_ headerView: FilterableHeaderView, didDoubleClickResizeForColumn columnIndex: Int) {
        autofitColumns.append(columnIndex)
    }
}

private final class Rows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 60 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "r\(row)" }
}

// MARK: - Rig

/// The grid's header in a never-shown window, laid out the way `ResultsGridVC`
/// lays its own out: a `#` column plus named data columns, no column
/// autoresizing (so hiding one may not silently redistribute the others),
/// zero intercell spacing and a 34pt two-row header.
private final class Rig {
    static let paneWidth: CGFloat = 600
    static let paneHeight: CGFloat = 300

    let window: NSWindow
    let scrollView: InsetScrollView
    let tableView: ResultsTableView
    let header: FilterableHeaderView
    let spy = HeaderSpy()
    private let rows = Rows()

    /// `titles` are the DATA columns; the `#` column is added ahead of them.
    init(titles: [String] = ["alpha", "beta", "gamma"], width: CGFloat = 120) {
        tableView = ResultsTableView()
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.style = .fullWidth
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true

        header = FilterableHeaderView()
        var headerFrame = header.frame
        headerFrame.size.height = 34
        header.frame = headerFrame
        header.filterDelegate = spy
        tableView.headerView = header
        tableView.dataSource = rows

        let rowNum = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rownum__"))
        rowNum.title = "#"
        rowNum.width = 40
        rowNum.minWidth = 30
        rowNum.maxWidth = 60
        tableView.addTableColumn(rowNum)

        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(index)"))
            column.title = title
            column.width = width
            column.minWidth = 50
            column.maxWidth = 1000
            column.sortDescriptorPrototype = NSSortDescriptor(key: "col_\(index)", ascending: true)
            tableView.addTableColumn(column)
        }

        scrollView = InsetScrollView(frame: NSRect(x: 0, y: 0, width: Rig.paneWidth, height: Rig.paneHeight))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.borderType = .noBorder

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Rig.paneWidth, height: Rig.paneHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Rig.paneWidth, height: Rig.paneHeight))
        root.addSubview(scrollView)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        scrollView.tile()
        // Until the window draws, the header has no superview at all, so it can
        // be asked neither where the grid ends nor for a screen frame.
        window.displayIfNeeded()
    }

    func column(_ id: String) -> NSTableColumn {
        tableView.tableColumns.first { $0.identifier.rawValue == id }!
    }

    func isHidden(_ id: String) -> Bool { column(id).isHidden }

    var visibleTitles: [String] {
        tableView.tableColumns.filter { !$0.isHidden && $0.identifier.rawValue != "__rownum__" }
            .map { $0.title }
    }

    var order: [String] { tableView.tableColumns.map { $0.identifier.rawValue } }

    func divider(ofColumn index: Int) -> CGFloat { header.headerRect(ofColumn: index).maxX }

    /// The context menu the header offers for a right-click at `x` in its own
    /// coordinates. A negative `x` stands for "nowhere near a column".
    func menu(atX x: CGFloat) -> NSMenu? {
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: header.convert(NSPoint(x: x, y: 17), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
        return header.menu(for: event)
    }

    /// Choose a menu item the way AppKit does when the user picks it, enabled
    /// or not — the invariant has to hold at the action, not only in the menu.
    func perform(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: header.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Press at `x`, drag by `dx`, release — the drag and the release posted
    /// first so the header's own tracking loop finds them, and the press
    /// delivered through hit-testing, as `GridColumnResizeTests` does.
    func drag(fromX x: CGFloat, dx: CGFloat) {
        let y: CGFloat = 17
        NSApp.postEvent(event(.leftMouseUp, at: NSPoint(x: x + dx, y: y)), atStart: false)
        NSApp.postEvent(event(.leftMouseDragged, at: NSPoint(x: x + dx, y: y)), atStart: true)
        hitView(at: event(.leftMouseDown, at: NSPoint(x: x, y: y)).locationInWindow)?
            .mouseDown(with: event(.leftMouseDown, at: NSPoint(x: x, y: y)))
        while let e = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { _ = e }
    }

    private func hitView(at locationInWindow: NSPoint) -> NSView? {
        guard let root = window.contentView, let frameView = root.superview else { return nil }
        return root.hitTest(frameView.convert(locationInWindow, from: nil))
    }
}

// MARK: - Menu readers

/// Titles in menu order, with a separator written as "-" and the check state
/// and enablement spelled out, so one assertion pins the whole menu.
private func describe(_ menu: NSMenu?) -> String {
    guard let menu else { return "nil" }
    return menu.items.map { item -> String in
        if item.isSeparatorItem { return "-" }
        // "·" rather than a space, so a missing check mark is visible in the
        // expectation string instead of hiding in the whitespace.
        let check = item.state == .on ? "✓" : "·"
        return "\(check)\(item.title)\(item.isEnabled ? "" : " (disabled)")"
    }.joined(separator: " | ")
}

private func item(_ menu: NSMenu?, titled title: String) -> NSMenuItem? {
    menu?.items.first { $0.title == title }
}

// MARK: - Cases

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // MARK: The menu's shape

    // Right-clicking ON a column: its own Hide first, then every data column
    // check-marked, then Show All Columns (nothing is hidden, so it is dead).
    let rig = Rig()
    let onBeta = rig.menu(atX: rig.header.headerRect(ofColumn: 2).midX)
    expectEqual(describe(onBeta),
                "·Hide Column | - | ✓alpha | ✓beta | ✓gamma | - | ·Show All Columns (disabled)",
                "the menu lists every data column, checked, with Show All dead")

    // The `#` column is not a data column: it is never listed, and a
    // right-click on it offers no Hide either.
    let onRowNum = rig.menu(atX: rig.header.headerRect(ofColumn: 0).midX)
    expectEqual(describe(onRowNum),
                "✓alpha | ✓beta | ✓gamma | - | ·Show All Columns (disabled)",
                "a right-click on the # column offers no Hide Column and never lists #")

    // Past the last column there is no clicked column, so no Hide Column.
    let pastEnd = rig.menu(atX: rig.divider(ofColumn: 3) + 40)
    expectEqual(describe(pastEnd),
                "✓alpha | ✓beta | ✓gamma | - | ·Show All Columns (disabled)",
                "a right-click past the last column offers the list without Hide Column")

    // MARK: Toggling

    let toggling = Rig()
    let betaItem = item(toggling.menu(atX: toggling.header.headerRect(ofColumn: 2).midX), titled: "beta")!
    toggling.perform(betaItem)
    expectTrue(toggling.isHidden("col_1"), "choosing a checked column hides it")
    expectEqual("\(toggling.visibleTitles)", "[\"alpha\", \"gamma\"]", "the hidden column leaves the grid")
    expectEqual("\(toggling.order)", "[\"__rownum__\", \"col_0\", \"col_1\", \"col_2\"]",
                "the hidden column keeps its slot in tableColumns")

    let afterHide = toggling.menu(atX: toggling.header.headerRect(ofColumn: 1).midX)
    expectEqual(describe(afterHide),
                "·Hide Column | - | ✓alpha | ·beta | ✓gamma | - | ·Show All Columns",
                "the hidden column is unchecked and Show All Columns comes alive")

    // And back again through the same item.
    toggling.perform(item(afterHide, titled: "beta")!)
    expectFalse(toggling.isHidden("col_1"), "choosing an unchecked column shows it again")
    expectEqual("\(toggling.visibleTitles)", "[\"alpha\", \"beta\", \"gamma\"]", "the column comes back in place")

    // "Hide Column" hides the column the pointer was over, not the first one.
    let hideClicked = Rig()
    let hideItem = item(hideClicked.menu(atX: hideClicked.header.headerRect(ofColumn: 3).midX),
                        titled: "Hide Column")!
    hideClicked.perform(hideItem)
    expectEqual("\(hideClicked.visibleTitles)", "[\"alpha\", \"beta\"]",
                "Hide Column hides the column that was right-clicked")

    // A right-click on an ALREADY hidden column cannot happen — `column(at:)`
    // skips it — so the Hide item is offered for whatever is really there.
    let hiddenUnderPointer = Rig()
    hiddenUnderPointer.header.setColumn(hiddenUnderPointer.column("col_0"), hidden: true)
    let shifted = hiddenUnderPointer.menu(atX: hiddenUnderPointer.header.headerRect(ofColumn: 2).midX)
    expectEqual(describe(shifted),
                "·Hide Column | - | ·alpha | ✓beta | ✓gamma | - | ·Show All Columns",
                "the menu over a shifted-up column reads the column that is really there")

    // MARK: The last visible column

    let last = Rig()
    last.header.setColumn(last.column("col_1"), hidden: true)
    last.header.setColumn(last.column("col_2"), hidden: true)
    let lastMenu = last.menu(atX: last.header.headerRect(ofColumn: 1).midX)
    expectEqual(describe(lastMenu),
                "·Hide Column (disabled) | - | ✓alpha (disabled) | ·beta | ·gamma | - | ·Show All Columns",
                "with one column left, its own item and Hide Column are both disabled")
    // Disabled in the menu is not enough: the rule is enforced where the change
    // happens, so choosing it anyway must still leave the column alone.
    last.perform(item(lastMenu, titled: "alpha")!)
    expectFalse(last.isHidden("col_0"), "the last visible column survives its own menu item being chosen")
    last.perform(item(lastMenu, titled: "Hide Column")!)
    expectFalse(last.isHidden("col_0"), "the last visible column survives Hide Column being chosen")
    expectEqual("\(last.visibleTitles)", "[\"alpha\"]", "the grid never runs out of data columns")

    // MARK: Show All Columns

    let showAll = Rig()
    expectFalse(item(showAll.menu(atX: -1), titled: "Show All Columns")!.isEnabled,
                "Show All Columns is disabled while nothing is hidden")
    showAll.header.setColumn(showAll.column("col_0"), hidden: true)
    showAll.header.setColumn(showAll.column("col_2"), hidden: true)
    let showAllItem = item(showAll.menu(atX: -1), titled: "Show All Columns")!
    expectTrue(showAllItem.isEnabled, "Show All Columns is enabled once a column is hidden")
    showAll.perform(showAllItem)
    expectEqual("\(showAll.visibleTitles)", "[\"alpha\", \"beta\", \"gamma\"]", "Show All Columns brings them all back")
    expectFalse(item(showAll.menu(atX: -1), titled: "Show All Columns")!.isEnabled,
                "Show All Columns goes dead again once nothing is hidden")

    // MARK: Accessibility

    let axe = Rig()
    let allLabels = axe.header.accessibilityElementsForTesting().map { $0.accessibilityLabel() ?? "" }
    expectEqual("\(allLabels)",
                "[\"Filter tags\", \"alpha\", \"Filter alpha\", \"beta\", \"Filter beta\", \"gamma\", \"Filter gamma\"]",
                "the header publishes a title and a funnel per visible column")
    axe.header.setColumn(axe.column("col_1"), hidden: true)
    let afterLabels = axe.header.accessibilityElementsForTesting().map { $0.accessibilityLabel() ?? "" }
    expectEqual("\(afterLabels)",
                "[\"Filter tags\", \"alpha\", \"Filter alpha\", \"gamma\", \"Filter gamma\"]",
                "a hidden column publishes neither its title nor its funnel")
    // Not merely absent from the list: nothing may be left sitting at the
    // header's left edge, which is where a hidden column's headerRect lands.
    let frames = axe.header.accessibilityElementsForTesting().map { $0.accessibilityFrame() }
    expectFalse(frames.contains { $0.width == 0 }, "no published element has a zero-width frame")

    // MARK: Geometry — the zero-width rect at x = 0

    // A hidden column's headerRect is (0, 0, 0, h). An edge grab that does not
    // skip it therefore answers "yes" for every point within 6pt of the
    // header's LEFT edge, and a drag there silently resizes a column the user
    // cannot see.
    let geometry = Rig()
    let betaBefore = geometry.header.headerRect(ofColumn: 2)
    expectTrue(betaBefore.minX > 0 && betaBefore.width == 120,
               "beta's header rect before it is hidden (\(betaBefore))")
    geometry.header.setColumn(geometry.column("col_1"), hidden: true)
    expectEqual("\(geometry.header.headerRect(ofColumn: 2))", "\(NSRect(x: 0, y: 0, width: 0, height: 34))",
                "a hidden column's header rect collapses to zero width AT x = 0")
    for x in [CGFloat(0), 2, 5] {
        expectFalse(geometry.header.claimsHeaderBandPoint(NSPoint(x: x, y: 17)),
                    "a point \(Int(x))pt from the header's left edge grabs no hidden column's edge")
    }
    let widthsBefore = geometry.tableView.tableColumns.map(\.width)
    geometry.drag(fromX: 1, dx: 60)
    expectEqual("\(geometry.tableView.tableColumns.map(\.width))", "\(widthsBefore)",
                "a drag at the header's left edge resizes nothing while a column is hidden")

    // The columns that are still there resize exactly as before.
    let stillResizes = Rig()
    stillResizes.header.setColumn(stillResizes.column("col_0"), hidden: true)
    let gammaBefore = stillResizes.column("col_2").width
    stillResizes.drag(fromX: stillResizes.divider(ofColumn: 3) - 2, dx: 40)
    expectEqual("\(stillResizes.column("col_2").width - gammaBefore)", "40.0",
                "a visible column still resizes from its divider with a column hidden")

    // The funnel and the sort of a visible column are unaffected, and they are
    // found at the column's NEW position — the one hiding moved it to.
    let funnel = Rig()
    funnel.header.setColumn(funnel.column("col_0"), hidden: true)
    funnel.header.activeFilterColumns = ["col_1"]
    let betaRect = funnel.header.headerRect(ofColumn: 2)
    expectTrue(betaRect.minX < 120, "beta slid left into the hidden column's place (minX \(betaRect.minX))")
    let y: CGFloat = 17
    let clickPoint = NSPoint(x: betaRect.maxX - 12.5, y: y)
    let down = NSEvent.mouseEvent(
        with: .leftMouseDown, location: funnel.header.convert(clickPoint, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: funnel.window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    funnel.header.mouseDown(with: down)
    expectEqual("\(funnel.spy.filterColumns)", "[\"col_1\"]",
                "the funnel of a column that moved up still opens that column's filter")
    funnel.header.sortDirections = ["col_1": .ascending]
    expectEqual("\(funnel.header.accessibilityElementsForTesting().first { $0.accessibilityLabel() == "beta" }?.accessibilityValue() ?? "nil")",
                "sorted ascending, filtered",
                "a visible column keeps its sort and filter state while another is hidden")

    // MARK: The round trip through ResultsGridState

    // Capture, hide a column, widen another, capture again, and put the second
    // snapshot into a FRESH grid — which is what a result-tab switch does.
    let source = Rig()
    source.tableView.moveColumn(3, toColumn: 1)     // gamma to the front
    expectEqual("\(source.order)", "[\"__rownum__\", \"col_2\", \"col_0\", \"col_1\"]", "the source grid is reordered")
    // beta is widened BEFORE it is hidden, to a width the fresh grid does not
    // start at — otherwise "the hidden column's width is restored" would pass
    // just as well for an implementation that skipped hidden columns.
    source.column("col_1").width = 310
    source.header.setColumn(source.column("col_1"), hidden: true)   // hide beta
    source.column("col_0").width = 275                              // widen alpha
    let captured = ResultsGridState.captureColumns(from: source.tableView)
    expectEqual("\(captured.hidden)", "[\"col_1\"]", "capture records the hidden column")
    expectEqual("\(captured.widths["col_1"] ?? -1)", "310.0",
                "capture records the hidden column's width like any other")

    let state = ResultsGridState(
        columnWidths: captured.widths, columnOrder: captured.order,
        sortColumn: nil, sortAscending: true, columnFilters: [:],
        scrollPosition: .zero, selectedRows: IndexSet(), hiddenColumns: captured.hidden)

    let target = Rig()
    state.applyColumns(to: target.tableView)
    expectEqual("\(target.order)", "[\"__rownum__\", \"col_2\", \"col_0\", \"col_1\"]", "restore reproduces the order")
    expectTrue(target.isHidden("col_1"), "restore hides the column that was hidden")
    expectEqual("\(target.visibleTitles)", "[\"gamma\", \"alpha\"]", "restore leaves the visible columns in order")
    expectEqual("\(target.column("col_0").width)", "275.0", "restore reproduces a visible column's width")
    expectEqual("\(target.column("col_1").width)", "310.0", "restore applies the hidden column's width too")
    expectFalse(target.isHidden("col_0"), "restore leaves the columns that were not hidden alone")

    // Showing it again must bring back the width restore put on it, without a
    // second visit to the state.
    target.header.setColumn(target.column("col_1"), hidden: false)
    expectEqual("\(target.column("col_1").width)", "310.0", "showing a restored column keeps its saved width")
    expectEqual("\(target.visibleTitles)", "[\"gamma\", \"alpha\", \"beta\"]", "the shown column returns in its saved slot")

    // A grid whose columns were all visible must not inherit a hidden one from
    // an empty set, and the default value keeps old call sites honest.
    let untouched = Rig()
    let plain = ResultsGridState(
        columnWidths: [:], columnOrder: nil, sortColumn: nil, sortAscending: true,
        columnFilters: [:], scrollPosition: .zero, selectedRows: IndexSet())
    expectEqual("\(plain.hiddenColumns)", "[]", "a state built without the new field hides nothing")
    plain.applyColumns(to: untouched.tableView)
    expectEqual("\(untouched.visibleTitles)", "[\"alpha\", \"beta\", \"gamma\"]",
                "restoring a state with no hidden columns shows them all")

    // A snapshot that would leave the grid with no data column at all — which
    // the menu cannot produce, but a future caller could — is refused whole.
    let allHidden = Rig()
    let bad = ResultsGridState(
        columnWidths: [:], columnOrder: nil, sortColumn: nil, sortAscending: true,
        columnFilters: [:], scrollPosition: .zero, selectedRows: IndexSet(),
        hiddenColumns: ["col_0", "col_1", "col_2"])
    bad.applyColumns(to: allHidden.tableView)
    expectEqual("\(allHidden.visibleTitles)", "[\"alpha\", \"beta\", \"gamma\"]",
                "a snapshot that would hide every data column is ignored")

    print(failures == 0 ? "\nAll grid column visibility tests passed" : "\n\(failures) failure(s)")
    if failures > 0 { exit(1) }
}
