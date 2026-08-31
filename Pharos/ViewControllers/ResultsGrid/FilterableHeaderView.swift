import AppKit

// MARK: - Sort Aware Header Cell

/// Header cell for the two-row (name / type) header. It draws only its own
/// background/bezel — the name and type TEXT are drawn by `FilterableHeaderView`
/// in `draw(_:)`, clipped per column.
///
/// The cell intentionally stores NO Swift properties. `NSTableHeaderView` draws
/// the empty overflow region past the last column using a bitwise `NSCopyObject`
/// copy of a header cell; that copy does not retain Swift-added stored properties
/// (e.g. a `String`), so accessing one on the copy dereferences a dangling
/// pointer → `EXC_BAD_ACCESS`. Keeping the cell property-free makes the copy safe.
class SortAwareHeaderCell: NSTableHeaderCell {
    static let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let typeFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    static let hInset: CGFloat = 6

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Intentionally empty: the two-row text is drawn by FilterableHeaderView
        // so it can be clipped to the column and to avoid the NSCell copy hazard
        // described above. The base class still draws the header background/bezel.
    }
}

// MARK: - Filterable Header View Delegate

protocol FilterableHeaderViewDelegate: AnyObject {
    func headerView(_ headerView: FilterableHeaderView, didClickFilterForColumn column: NSTableColumn, at rect: NSRect)
    func headerView(_ headerView: FilterableHeaderView, didDoubleClickResizeForColumn columnIndex: Int)
}

// MARK: - FilterableHeaderView

/// Custom NSTableHeaderView that draws sort and filter indicators in each column header.
/// - Sort chevron on the LEFT side of the column name (always visible when sort active)
/// - Filter icon on the RIGHT side (shown on hover or when filter active)
/// - Double-click on column right edge triggers auto-fit
class FilterableHeaderView: NSTableHeaderView, HeaderBandClaiming {

    weak var filterDelegate: FilterableHeaderViewDelegate?

    /// Data-type label to draw on row 2, keyed by column identifier. The name on
    /// row 1 comes from each column's `title`. Owned by the view (not the cell) so
    /// the header cells can stay Swift-property-free — see `SortAwareHeaderCell`.
    var columnTypes: [String: String] = [:] {
        didSet { needsDisplay = true }
    }

    /// Column names that currently have active filters.
    var activeFilterColumns: Set<String> = [] {
        didSet { needsDisplay = true }
    }

    /// Sort directions per column identifier, pushed by sort controller.
    var sortDirections: [String: ResultsSortController.SortDirection] = [:] {
        didSet {
            updateSortCellIndicators()
            needsDisplay = true
        }
    }

    /// Column indices to highlight with a grey background (for cell selection).
    var highlightedColumnIndices: IndexSet = IndexSet() {
        didSet { needsDisplay = true }
    }

    private var hoveredColumnIndex: Int = -1
    private var trackingArea: NSTrackingArea?

    private let iconSize: CGFloat = 13
    private let iconPadding: CGFloat = 6

    /// Pre-rendered tinted filter icons. The active/hover variants are the
    /// only two tints we ever draw and they only need to change when the
    /// system appearance flips. Rebuilding the tinted NSImage per-draw used
    /// to dominate redraw cost during cell-drag selection (which re-fires
    /// needsDisplay on this view) and header hover sweeps.
    private var cachedActiveIcon: NSImage?
    private var cachedHoverIcon: NSImage?
    private var cachedIconAppearanceName: NSAppearance.Name?

    private func filterIcon(active: Bool) -> NSImage? {
        let currentName = effectiveAppearance.name
        if cachedIconAppearanceName != currentName {
            cachedActiveIcon = Self.makeFilterIcon(filled: true, tint: .controlAccentColor, size: iconSize)
            cachedHoverIcon = Self.makeFilterIcon(filled: false, tint: .tertiaryLabelColor, size: iconSize)
            cachedIconAppearanceName = currentName
        }
        return active ? cachedActiveIcon : cachedHoverIcon
    }

    private static func makeFilterIcon(filled: Bool, tint: NSColor, size: CGFloat) -> NSImage? {
        let name = filled ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Filter")?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) else { return nil }
        return base.tinted(with: tint)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cachedIconAppearanceName = nil  // force regeneration on next draw
        needsDisplay = true
    }

    // MARK: - Tracking Areas

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Mouse Tracking

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = column(at: point)
        guard newIndex != hoveredColumnIndex else { return }
        // Targeted invalidation: only the two affected header cells (the one
        // we left and the one we entered) need to redraw, not the whole bar.
        let oldIndex = hoveredColumnIndex
        hoveredColumnIndex = newIndex
        if oldIndex >= 0 { setNeedsDisplay(headerRect(ofColumn: oldIndex)) }
        if newIndex >= 0 { setNeedsDisplay(headerRect(ofColumn: newIndex)) }
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newIndex = column(at: point)
        guard newIndex != hoveredColumnIndex else { return }
        hoveredColumnIndex = newIndex
        if newIndex >= 0 { setNeedsDisplay(headerRect(ofColumn: newIndex)) }
    }

    override func mouseExited(with event: NSEvent) {
        let oldIndex = hoveredColumnIndex
        hoveredColumnIndex = -1
        if oldIndex >= 0 { setNeedsDisplay(headerRect(ofColumn: oldIndex)) }
    }

    // MARK: - Click Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Detect double-click near column right edge for auto-fit
        if event.clickCount == 2 {
            if let grab = columnEdgeGrab(at: point) {
                filterDelegate?.headerView(self, didDoubleClickResizeForColumn: grab.columnIndex)
                return
            }
        }

        // A grab on a column's right edge is decided BEFORE anything else, and is
        // run here rather than handed to super — see `trackResize(_:from:)`. It
        // also has to come before `column(at:)`, which reports -1 both for the
        // empty header region past the last column and for a point beyond the
        // last column's own edge; grabs live in both places.
        if let grab = columnEdgeGrab(at: point) {
            trackResize(grab, from: event)
            return
        }

        let colIndex = column(at: point)
        guard colIndex >= 0, let tableView = tableView else {
            super.mouseDown(with: event)
            return
        }

        let column = tableView.tableColumns[colIndex]

        // The `#` column's ONLY affordance is the funnel icon; clicks
        // elsewhere in its header keep today's pass-to-super (no sort, no
        // resize-drag distinction needed — the funnel intercepts first).
        guard column.identifier.rawValue != "__rownum__" else {
            let headerRect = self.headerRect(ofColumn: colIndex)
            let iconRect = filterIconRect(inHeaderRect: headerRect)
            if iconRect.contains(point) {
                filterDelegate?.headerView(self, didClickFilterForColumn: column, at: iconRect)
                return
            }
            super.mouseDown(with: event)
            return
        }

        let headerRect = self.headerRect(ofColumn: colIndex)
        let iconRect = filterIconRect(inHeaderRect: headerRect)

        if iconRect.contains(point) {
            filterDelegate?.headerView(self, didClickFilterForColumn: column, at: iconRect)
        } else {
            // Header text/sort icon click -> triggers sort via super (sortDescriptorPrototype)
            super.mouseDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Draw column highlights BEFORE super so header cell text renders on top
        if let tableView = tableView, !highlightedColumnIndices.isEmpty {
            for colIndex in highlightedColumnIndices {
                guard colIndex < tableView.tableColumns.count else { continue }
                let colId = tableView.tableColumns[colIndex].identifier.rawValue
                guard colId != "__rownum__" else { continue }
                let headerRect = self.headerRect(ofColumn: colIndex)
                NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
                headerRect.fill()
            }
        }

        super.draw(dirtyRect)

        guard let tableView = tableView else { return }

        // Two-row text (name / type) drawn by the view, clipped per column, so the
        // header cells stay Swift-property-free (see SortAwareHeaderCell) and names
        // can't bleed into neighbouring columns.
        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            guard colId != "__rownum__" else { continue }
            drawHeaderText(name: column.title, type: columnTypes[colId] ?? "",
                           in: headerRect(ofColumn: colIndex))
        }

        // Filter icons drawn AFTER text (topmost visual element)

        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            // The `#` column gets the funnel icon (its filter is the tag
            // funnel) but still no name, no type row and no sort arrow — the
            // header-text guard (name/type loop above) and the sort-arrow
            // guard (sort arrow loop below) both stay in place.

            let headerRect = self.headerRect(ofColumn: colIndex)

            let isActive = activeFilterColumns.contains(colId)
            let isHovered = colIndex == hoveredColumnIndex
            guard isActive || isHovered else { continue }

            let iconRect = filterIconRect(inHeaderRect: headerRect)
            guard let tinted = filterIcon(active: isActive) else { continue }
            let imageSize = tinted.size
            let drawRect = NSRect(
                x: iconRect.midX - imageSize.width / 2,
                y: iconRect.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            tinted.draw(in: drawRect)
        }

        // Sort arrow: persistent when a column is sorted (so sort state is visible
        // at rest), drawn on row-2 right just left of the funnel slot. Overlay only —
        // reserves no column width.
        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            guard colId != "__rownum__", let dir = sortDirections[colId] else { continue }
            let headerRect = self.headerRect(ofColumn: colIndex)
            let arrow = (dir == .ascending) ? "▲" : "▼"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let sz = (arrow as NSString).size(withAttributes: attrs)
            let funnelSlot = iconSize + iconPadding * 2 + 8   // width the funnel occupies at the right
            let iconRect = filterIconRect(inHeaderRect: headerRect)
            let x = headerRect.maxX - funnelSlot - sz.width - 2
            let y = iconRect.midY - sz.height / 2
            (arrow as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }

    /// Draws the column name (row 1) and data type (row 2), block-centred and
    /// clipped to `headerRect`. NSTableHeaderView is FLIPPED (y increases
    /// downward → smaller y = top), so the name draws at the smaller y.
    private func drawHeaderText(name: String, type: String, in headerRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }
        NSBezierPath(rect: headerRect.insetBy(dx: SortAwareHeaderCell.hInset, dy: 0)).setClip()

        let nameAttrs: [NSAttributedString.Key: Any] =
            [.font: SortAwareHeaderCell.nameFont, .foregroundColor: NSColor.labelColor]
        let typeAttrs: [NSAttributedString.Key: Any] =
            [.font: SortAwareHeaderCell.typeFont, .foregroundColor: NSColor.secondaryLabelColor]
        let nameSize = (name as NSString).size(withAttributes: nameAttrs)
        let typeSize = (type as NSString).size(withAttributes: typeAttrs)
        let gap: CGFloat = 1
        let totalH = nameSize.height + gap + typeSize.height
        let topY = headerRect.midY - totalH / 2
        let x = headerRect.minX + SortAwareHeaderCell.hInset
        (name as NSString).draw(at: NSPoint(x: x, y: topY), withAttributes: nameAttrs)
        (type as NSString).draw(at: NSPoint(x: x, y: topY + nameSize.height + gap), withAttributes: typeAttrs)
    }

    // MARK: - Sort Cell Indicators

    private func updateSortCellIndicators() {
        needsDisplay = true
    }

    // MARK: - Geometry

    private func filterIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        // Row 2 (the type row) is the LOWER band. NSTableHeaderView is flipped
        // (y increases downward), so the lower band is near maxY, not minY.
        let row2MidY = headerRect.maxY - headerRect.height * 0.30
        return NSRect(x: headerRect.maxX - side - 8, y: row2MidY - side / 2, width: side, height: side)
    }

    /// How far either side of a column's right edge counts as grabbing that
    /// edge — for the resize drag, for the auto-fit double-click, and for the
    /// resize cursor. One constant so the three cannot drift apart: a zone the
    /// cursor advertises and the click does not honour is what this view used to
    /// have.
    private static let resizeEdgeThreshold: CGFloat = 6

    /// First claim on the header band, consulted by `InsetScrollView.hitTest`.
    /// The scroll view's macOS 26 glass furniture — the scroll pocket, its
    /// backdrops, the corner cap — otherwise takes the click before it can
    /// reach this view, exactly over the strip where the last column's resize
    /// handle lives.
    ///
    /// Claimed narrowly — the resize handles only, not the whole band. Today's
    /// chrome does nothing with a header-band click, so a greedy claim would be
    /// invisible in behaviour; it stays narrow so a future piece of chrome that
    /// IS interactive loses only the handles to us.
    func claimsHeaderBandPoint(_ point: NSPoint) -> Bool {
        columnEdgeGrab(at: point) != nil
    }

    /// A grab on a column's right edge: which column, and the x the drag is
    /// measured from, in WINDOW coordinates.
    private struct ColumnEdgeGrab {
        let columnIndex: Int
        let anchorX: CGFloat
    }

    /// The column whose right edge `point` grabs, or nil for a point that grabs
    /// no edge.
    ///
    /// There are two ways to grab one. The plain one is within
    /// `resizeEdgeThreshold` of the divider itself; the drag then measures from
    /// the pointer, so the edge does not jump out from under it.
    ///
    /// The other is the grid's OWN visible right edge, and only when a column is
    /// cut off there. That column's divider is off screen — behind the vertical
    /// scroller and the grey corner above it — and no amount of scrolling brings
    /// it inboard, because scrolling stops when the document's right edge meets
    /// the clip's. So the visible edge is the only place a pointer can reach that
    /// column's handle, and it is where the eye reads the column as ending. This
    /// grab measures from the divider instead of the pointer, so the first drag
    /// brings the edge TO the pointer rather than moving it further out of sight.
    private func columnEdgeGrab(at point: NSPoint) -> ColumnEdgeGrab? {
        guard let tableView = tableView else { return nil }
        for (index, _) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            if abs(point.x - rect.maxX) <= Self.resizeEdgeThreshold {
                return ColumnEdgeGrab(columnIndex: index, anchorX: windowX(point.x))
            }
        }

        guard let edge = visibleRightEdgeX,
              abs(point.x - edge) <= Self.resizeEdgeThreshold,
              let index = columnCutOff(at: edge) else { return nil }
        return ColumnEdgeGrab(columnIndex: index,
                              anchorX: windowX(headerRect(ofColumn: index).maxX))
    }

    /// Where the grid stops being visible, in this view's coordinates: the right
    /// edge of the scroll view's clip. The rows' clip, not this view's own —
    /// under overlay scrollers the two are not the same width, and the rows are
    /// what the user sees ending.
    ///
    /// Asked of the TABLE, not of self: a header view sits in the scroll view's
    /// separate header clip, so its own `enclosingScrollView` is nil. The table
    /// is the document view, so its answer is the real one.
    private var visibleRightEdgeX: CGFloat? {
        guard let clipView = tableView?.enclosingScrollView?.contentView else { return nil }
        return convert(NSPoint(x: clipView.bounds.maxX, y: 0), from: clipView).x
    }

    /// The column that `x` cuts through — the one whose body starts before `x`
    /// and ends after it. nil when `x` falls on a divider or past the last
    /// column, which is the case whenever nothing is actually cut off.
    private func columnCutOff(at x: CGFloat) -> Int? {
        guard let tableView = tableView else { return nil }
        return tableView.tableColumns.indices.first { index in
            let rect = headerRect(ofColumn: index)
            return rect.minX < x && rect.maxX > x
        }
    }

    private func windowX(_ x: CGFloat) -> CGFloat {
        convert(NSPoint(x: x, y: 0), to: nil).x
    }

    // MARK: - Resize Drag

    /// Resize the grabbed column from the pointer until the button comes up.
    ///
    /// The drag is run here instead of being handed to `super.mouseDown` because
    /// `NSTableHeaderView` starts a resize only within about 2pt of a divider,
    /// while the grab zone above promises 6. The points in between did nothing
    /// at all — the click was swallowed, not passed on — and on the LAST column
    /// they are the only points a pointer can reach: that divider sits at the
    /// table's right edge, so once the grid is scrolled fully right, the divider
    /// itself and everything outside it are behind the vertical scroller. That
    /// left a 2pt target against the scroll bar, which reads as a column that
    /// cannot be resized at all.
    ///
    /// The grab's anchor and the pointer are both in WINDOW coordinates. This
    /// view's own coordinates move with the horizontal scroll, which a resize can
    /// itself provoke by changing the document width.
    ///
    /// The gate is AppKit's own: the table must allow column resizing and the
    /// column must be user-resizable. Anything refused here falls through to
    /// super, so a locked column keeps whatever super makes of the click.
    private func trackResize(_ grab: ColumnEdgeGrab, from startEvent: NSEvent) {
        guard let tableView = tableView,
              grab.columnIndex < tableView.tableColumns.count,
              tableView.allowsColumnResizing,
              tableView.tableColumns[grab.columnIndex].resizingMask.contains(.userResizingMask) else {
            super.mouseDown(with: startEvent)
            return
        }

        let column = tableView.tableColumns[grab.columnIndex]
        let startWidth = column.width

        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            // No clamping here: `NSTableColumn.width` holds the width inside
            // [minWidth, maxWidth] itself, so a second clamp would only be a
            // copy of that rule waiting to fall out of step with it.
            column.width = startWidth + (event.locationInWindow.x - grab.anchorX)
            keepDraggedEdgeVisible(columnIndex: grab.columnIndex)
        }
    }

    /// Scroll so the divider being dragged stays in view — the Finder behaviour.
    ///
    /// Widening tracks the pointer, and the pointer is free to travel past the
    /// grid's right edge into whatever sits beyond it. Without this, the width
    /// keeps growing but the dragged edge slides out of sight behind the
    /// scroller, so the user is resizing something they can no longer see. The
    /// grid scrolls under the pointer instead, keeping the edge pinned at the
    /// viewport edge for as long as the drag continues, in either direction.
    ///
    /// Scrolled through the TABLE, not the clip: a direct clip-origin move does
    /// not carry the header clip with it, and this view would then be drawing
    /// at a stale offset while the rows moved.
    private func keepDraggedEdgeVisible(columnIndex: Int) {
        guard let tableView = tableView else { return }
        let visible = tableView.visibleRect
        guard !visible.isEmpty else { return }
        let divider = headerRect(ofColumn: columnIndex).maxX
        // A sliver either side of the divider, VERTICALLY CENTRED in what is
        // already on screen so the reveal can only ever scroll sideways. The
        // top edge is not safe for this: macOS 26 treats the band under the
        // glass header pocket as obscured, so a rect at the very top is
        // "revealed" by scrolling up one header-height — per drag event, which
        // walked the grid to the top of the table while a column was resized.
        tableView.scrollToVisible(NSRect(
            x: divider - 1, y: visible.midY, width: 2, height: 1))
    }

    /// The resize cursor covers the same zone the click does. `super` installs
    /// it over its own ~2pt only, which is why the last column's edge — the one
    /// standing against the scroller — did not look grabbable.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView = tableView, tableView.allowsColumnResizing else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            guard column.resizingMask.contains(.userResizingMask) else { continue }
            addResizeCursor(centredOn: headerRect(ofColumn: index).maxX)
        }
        // The grid's visible right edge, when a column is cut off there — the
        // other way `columnEdgeGrab` lets a handle be grabbed.
        if let edge = visibleRightEdgeX, let index = columnCutOff(at: edge),
           tableView.tableColumns[index].resizingMask.contains(.userResizingMask) {
            addResizeCursor(centredOn: edge)
        }
    }

    private func addResizeCursor(centredOn x: CGFloat) {
        addCursorRect(
            NSRect(x: x - Self.resizeEdgeThreshold, y: bounds.minY,
                   width: Self.resizeEdgeThreshold * 2, height: bounds.height),
            cursor: .resizeLeftRight)
    }
}

// MARK: - NSImage Tint Extension

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
