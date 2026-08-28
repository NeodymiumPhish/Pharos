// Standalone test runner for the results grid's column-resize handle, compiled
// by scripts/test-grid-column-resize.sh.
//
// The header advertises a grab zone 6pt either side of a divider
// (`columnIndexForResizeEdge`). It used to hand a hit to `super.mouseDown`, and
// `NSTableHeaderView` starts a resize only within about 2pt — so 4 of the 6
// points did nothing. On the LAST column that is the whole target: its divider
// sits at the table's right edge, so once the grid is scrolled fully right the
// only points a pointer can reach are the ones on the inside, and only 1pt and
// 2pt of those worked.
//
// These tests therefore assert on POINTS, not on "resizing works": a real
// mouse-down is delivered at a measured distance from a divider, with a drag and
// a mouse-up already posted so the tracking loop consumes them, and the
// column's width is read back.
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

// MARK: - Rig

/// The grid's header in a never-shown window, laid out the way `ResultsGridVC`
/// lays its own out: a `#` column plus data columns, no column autoresizing,
/// zero intercell spacing, a 34pt two-row header, and always-visible legacy
/// scrollers — which is what insets the clip view and puts the last column's
/// divider hard against the scroller.
private final class Rig {
    static let paneWidth: CGFloat = 500
    static let paneHeight: CGFloat = 300

    let window: NSWindow
    let scrollView: NSScrollView
    let tableView: NSTableView
    let header: FilterableHeaderView
    let spy = HeaderSpy()

    init(widths: [CGFloat]) {
        tableView = NSTableView()
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.style = .fullWidth
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnResizing = true

        header = FilterableHeaderView()
        var headerFrame = header.frame
        headerFrame.size.height = 34
        header.frame = headerFrame
        header.filterDelegate = spy
        tableView.headerView = header

        for (index, width) in widths.enumerated() {
            let isRowNum = index == 0
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(isRowNum ? "__rownum__" : "col_\(index)"))
            column.title = isRowNum ? "#" : "col\(index)"
            column.width = width
            column.minWidth = isRowNum ? 30 : 50
            column.maxWidth = isRowNum ? 60 : 1000
            tableView.addTableColumn(column)
        }

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: Rig.paneWidth, height: Rig.paneHeight))
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
    }

    var lastColumnIndex: Int { tableView.tableColumns.count - 1 }

    func width(ofColumn index: Int) -> CGFloat { tableView.tableColumns[index].width }

    func divider(ofColumn index: Int) -> CGFloat { header.headerRect(ofColumn: index).maxX }

    /// The rightmost x, in the header's own coordinates, a pointer can reach.
    /// Past this the clip view ends and the vertical scroller begins.
    var reachableMaxX: CGFloat {
        scrollView.contentView.bounds.origin.x + scrollView.contentView.frame.width
    }

    /// Scroll as far right as the clip view allows, exactly as dragging the
    /// horizontal scroller to its end does.
    func scrollToRightEnd() {
        let want = NSRect(origin: NSPoint(x: 100_000, y: scrollView.contentView.bounds.origin.y),
                          size: scrollView.contentView.bounds.size)
        let allowed = scrollView.contentView.constrainBoundsRect(want)
        scrollView.contentView.scroll(to: allowed.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: header.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Press at `x`, drag by `dx`, release. The drag and the release are posted
    /// FIRST so whichever tracking loop the mouse-down starts — ours or
    /// AppKit's — finds them in the queue; a headless binary has no run loop
    /// pumping events behind it.
    func drag(fromX x: CGFloat, dx: CGFloat) {
        let y: CGFloat = 17
        NSApp.postEvent(event(.leftMouseUp, at: NSPoint(x: x + dx, y: y)), atStart: false)
        NSApp.postEvent(event(.leftMouseDragged, at: NSPoint(x: x + dx, y: y)), atStart: true)
        header.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: x, y: y)))
        drainEvents()
    }

    func click(atX x: CGFloat, clicks: Int = 1) {
        let y: CGFloat = 17
        NSApp.postEvent(event(.leftMouseUp, at: NSPoint(x: x, y: y)), atStart: false)
        header.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: x, y: y), clicks: clicks))
        drainEvents()
    }

    private func drainEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
            _ = event
        }
    }
}

// MARK: - Cases

/// Grab the divider of `column` at `offset` points to its LEFT and drag right by
/// `dx`. Returns the width change of that column.
private func grabInside(widths: [CGFloat], column: Int, offset: CGFloat, dx: CGFloat = 40,
                        scrollToEnd: Bool = false,
                        configure: ((Rig) -> Void)? = nil) -> (delta: CGFloat, others: Bool, reachable: Bool) {
    let rig = Rig(widths: widths)
    configure?(rig)
    if scrollToEnd { rig.scrollToRightEnd() }
    let before = rig.tableView.tableColumns.map(\.width)
    let x = rig.divider(ofColumn: column) - offset
    rig.drag(fromX: x, dx: dx)
    let after = rig.tableView.tableColumns.map(\.width)
    let othersMoved = before.indices.contains { $0 != column && before[$0] != after[$0] }
    return (after[column] - before[column], othersMoved, x <= rig.reachableMaxX)
}

func runTests() {
    // Every AppKit suite in this repo bootstraps the app object first, and
    // prohibits activation so the binary stays headless.
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // Columns narrower than the pane: the last divider sits well inside the
    // view, so nothing here depends on the edge — it is the plain promise that
    // the whole 6pt zone grabs.
    let narrow: [CGFloat] = [40, 100, 120]
    for offset in [CGFloat(0), 2, 4, 6] {
        let r = grabInside(widths: narrow, column: 2, offset: offset)
        expectEqual("\(r.delta)", "40.0", "a grab \(Int(offset))pt inside the divider resizes the column")
        expectFalse(r.others, "a grab \(Int(offset))pt inside moves no other column")
    }

    // Just past the divider is inside the zone too. This lands in the empty
    // header region past the last column, where `column(at:)` reports -1.
    let outside = grabInside(widths: narrow, column: 2, offset: -4)
    expectEqual("\(outside.delta)", "40.0", "a grab 4pt outside the last divider resizes it")

    // The `#` column's divider resizes through the same path, clamped by its
    // own 60pt maximum (40 + 40 would overshoot).
    let rowNum = grabInside(widths: narrow, column: 0, offset: 2)
    expectEqual("\(rowNum.delta)", "20.0", "the # column's divider resizes to its maximum")

    // THE REPORTED BUG. Columns wider than the pane, scrolled as far right as
    // the grid goes: the last divider lands exactly on the visible right edge,
    // so only the inside of the zone can be reached at all.
    let wide: [CGFloat] = [40, 200, 200, 200]
    for offset in [CGFloat(1), 4, 6] {
        let r = grabInside(widths: wide, column: 3, offset: offset, scrollToEnd: true)
        expectTrue(r.reachable, "\(Int(offset))pt inside the last divider is on screen when scrolled right")
        expectEqual("\(r.delta)", "40.0",
                    "the last column resizes from \(Int(offset))pt inside its divider at the right edge")
    }

    // The two locks AppKit itself honours are honoured here too.
    let tableLocked = grabInside(widths: narrow, column: 2, offset: 4) { rig in
        rig.tableView.allowsColumnResizing = false
    }
    expectEqual("\(tableLocked.delta)", "0.0", "a table that forbids column resizing does not resize")
    let columnLocked = grabInside(widths: narrow, column: 2, offset: 4) { rig in
        rig.tableView.tableColumns[2].resizingMask = []
    }
    expectEqual("\(columnLocked.delta)", "0.0", "a column that is not user-resizable does not resize")

    // Clamping, both ends. `NSTableColumn.width` enforces this itself, so these
    // two hold the contract rather than a line of our own: a drag can never put
    // a column outside the width bounds the grid set for it.
    let toMax = grabInside(widths: narrow, column: 2, offset: 2, dx: 5_000)
    expectEqual("\(120 + toMax.delta)", "1000.0", "a drag past the maximum stops at maxWidth")
    let toMin = grabInside(widths: narrow, column: 2, offset: 2, dx: -5_000)
    expectEqual("\(120 + toMin.delta)", "50.0", "a drag past the minimum stops at minWidth")

    // A grab is a grab only near a divider. Mid-header the click still belongs
    // to the sort, so no width may move.
    let midHeader = Rig(widths: narrow)
    let midX = midHeader.header.headerRect(ofColumn: 2).midX
    let widthsBefore = midHeader.tableView.tableColumns.map(\.width)
    midHeader.drag(fromX: midX, dx: 40)
    expectEqual("\(midHeader.tableView.tableColumns.map(\.width))", "\(widthsBefore)",
                "a drag from mid-header resizes nothing")

    // Double-click autofit still reports, and must not drag.
    let autofit = Rig(widths: narrow)
    let autofitBefore = autofit.width(ofColumn: 2)
    autofit.click(atX: autofit.divider(ofColumn: 2) - 2, clicks: 2)
    expectEqual("\(autofit.spy.autofitColumns)", "[2]", "a double-click near the divider reports autofit")
    expectEqual("\(autofit.width(ofColumn: 2))", "\(autofitBefore)", "the autofit double-click does not drag")

    // The funnel icon sits just inside the resize zone and keeps its click.
    let funnel = Rig(widths: narrow)
    let funnelBefore = funnel.width(ofColumn: 2)
    // `filterIconRect` is the 13pt icon inset 6pt from the header's right edge,
    // so its own midpoint is 12.5pt inside the divider.
    funnel.click(atX: funnel.divider(ofColumn: 2) - 12.5)
    expectEqual("\(funnel.spy.filterColumns)", "[\"col_2\"]", "a click on the funnel opens the filter")
    expectEqual("\(funnel.width(ofColumn: 2))", "\(funnelBefore)", "the funnel click does not resize")

    print(failures == 0 ? "\nAll grid column resize tests passed" : "\n\(failures) failure(s)")
    if failures > 0 { exit(1) }
}
