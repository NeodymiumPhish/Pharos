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
    /// Same inset as the body cell label — see `ResultsGridMetrics`.
    static let hInset: CGFloat = ResultsGridMetrics.cellInset

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
        didSet {
            needsDisplay = true
            // The column SET changed, so the accessibility children did too.
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    /// Column names that currently have active filters.
    var activeFilterColumns: Set<String> = [] {
        didSet {
            needsDisplay = true
            postElementValuesChanged()
        }
    }

    /// Sort directions per column identifier, pushed by sort controller.
    var sortDirections: [String: ResultsSortController.SortDirection] = [:] {
        didSet {
            updateSortCellIndicators()
            needsDisplay = true
            postElementValuesChanged()
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
    private var cachedSortUpIcon: NSImage?
    private var cachedSortDownIcon: NSImage?
    private var cachedIconAppearanceName: NSAppearance.Name?

    /// Point size of the sort chevron. Small, like the system's own header
    /// indicator, and drawn as an SF Symbol rather than the "▲" text glyph
    /// that used to stand in for it.
    private let sortIconSize: CGFloat = 8

    private func refreshIconCacheIfNeeded() {
        let currentName = effectiveAppearance.name
        guard cachedIconAppearanceName != currentName else { return }
        cachedActiveIcon = Self.makeFilterIcon(filled: true, tint: .controlAccentColor, size: iconSize)
        cachedHoverIcon = Self.makeFilterIcon(filled: false, tint: .tertiaryLabelColor, size: iconSize)
        cachedSortUpIcon = Self.makeSymbol("chevron.up", tint: .secondaryLabelColor, size: sortIconSize, weight: .bold)
        cachedSortDownIcon = Self.makeSymbol("chevron.down", tint: .secondaryLabelColor, size: sortIconSize, weight: .bold)
        cachedIconAppearanceName = currentName
    }

    private func filterIcon(active: Bool) -> NSImage? {
        refreshIconCacheIfNeeded()
        return active ? cachedActiveIcon : cachedHoverIcon
    }

    private func sortIcon(ascending: Bool) -> NSImage? {
        refreshIconCacheIfNeeded()
        return ascending ? cachedSortUpIcon : cachedSortDownIcon
    }

    /// Drop the tinted icons so the next draw rebuilds them. The accent
    /// colour can change without the appearance name changing, and the
    /// funnel is accent-tinted.
    func invalidateIconCache() {
        cachedIconAppearanceName = nil
        needsDisplay = true
    }

    private static func makeFilterIcon(filled: Bool, tint: NSColor, size: CGFloat) -> NSImage? {
        let name = filled ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        return makeSymbol(name, tint: tint, size: size, weight: .medium, description: "Filter")
    }

    private static func makeSymbol(_ name: String, tint: NSColor, size: CGFloat,
                                   weight: NSFont.Weight, description: String? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return nil }
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

    // MARK: - Column Visibility Menu

    /// Identifier of the row-number column. It is not a data column: it carries
    /// no name and the grid's selection code relies on it staying at index 0, so
    /// it never appears in the visibility menu.
    private static let rowNumberColumnId = "__rownum__"

    /// The data columns, paired with their index in `tableColumns`. Hidden ones
    /// are included — the menu's whole job is to list them.
    private var dataColumns: [(index: Int, column: NSTableColumn)] {
        guard let tableView = tableView else { return [] }
        return tableView.tableColumns.enumerated()
            .filter { $0.element.identifier.rawValue != Self.rowNumberColumnId }
            .map { (index: $0.offset, column: $0.element) }
    }

    private var visibleDataColumnCount: Int {
        dataColumns.filter { !$0.column.isHidden }.count
    }

    /// Right-click menu: one check-marked item per data column, plus "Show All
    /// Columns", plus "Hide Column" for the column actually clicked on.
    ///
    /// The grid's state snapshot is taken on the way OUT of a result tab
    /// (`ResultsGridVC.captureGridState`), so a toggle here needs no callback to
    /// be persisted — it only has to leave the columns in the state the capture
    /// will read.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard tableView != nil else { return super.menu(for: event) }
        let columns = dataColumns
        guard !columns.isEmpty else { return super.menu(for: event) }

        let point = convert(event.locationInWindow, from: nil)
        let clickedIndex = column(at: point)
        let visible = visibleDataColumnCount

        let menu = NSMenu()
        // Explicit enablement: the items' target is this view, and the "last
        // visible column" rule is not something a validator could infer.
        menu.autoenablesItems = false

        // The clicked column's own Hide, first, because a right-click on a
        // column header is most often aimed at that column.
        if clickedIndex >= 0, let tableView = tableView,
           clickedIndex < tableView.tableColumns.count {
            let clicked = tableView.tableColumns[clickedIndex]
            if clicked.identifier.rawValue != Self.rowNumberColumnId, !clicked.isHidden {
                let item = NSMenuItem(title: String(localized: "Hide Column"),
                                      action: #selector(hideColumnFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clicked.identifier.rawValue
                item.isEnabled = visible > 1
                menu.addItem(item)
                menu.addItem(.separator())
            }
        }

        for (_, column) in columns {
            let item = NSMenuItem(title: column.title,
                                  action: #selector(toggleColumnFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.identifier.rawValue
            item.state = column.isHidden ? .off : .on
            // A grid with no columns at all is not a state the user can get back
            // out of by pointing at a header, so the last visible one is locked.
            item.isEnabled = column.isHidden || visible > 1
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let showAll = NSMenuItem(title: String(localized: "Show All Columns"),
                                 action: #selector(showAllColumnsFromMenu(_:)), keyEquivalent: "")
        showAll.target = self
        showAll.isEnabled = visible < columns.count
        menu.addItem(showAll)
        return menu
    }

    @objc private func toggleColumnFromMenu(_ sender: NSMenuItem) {
        guard let colId = sender.representedObject as? String,
              let index = columnIndex(forId: colId), let tableView = tableView else { return }
        let column = tableView.tableColumns[index]
        setColumn(column, hidden: !column.isHidden)
    }

    @objc private func hideColumnFromMenu(_ sender: NSMenuItem) {
        guard let colId = sender.representedObject as? String,
              let index = columnIndex(forId: colId), let tableView = tableView else { return }
        setColumn(tableView.tableColumns[index], hidden: true)
    }

    @objc private func showAllColumnsFromMenu(_ sender: NSMenuItem) {
        var changed = false
        for (_, column) in dataColumns where column.isHidden {
            column.isHidden = false
            changed = true
        }
        if changed { columnVisibilityDidChange() }
    }

    /// Hide or show one data column. Refuses to take the last visible one away:
    /// the menu disables that item, and this is the same rule stated where the
    /// change actually happens, so no other caller can break the invariant.
    ///
    /// `NSTableColumn.isHidden` re-tiles the table by itself — measured — so
    /// there is no `tile()` here to fall out of step with AppKit's own.
    func setColumn(_ column: NSTableColumn, hidden: Bool) {
        guard column.identifier.rawValue != Self.rowNumberColumnId else { return }
        guard column.isHidden != hidden else { return }
        if hidden && visibleDataColumnCount <= 1 { return }
        column.isHidden = hidden
        columnVisibilityDidChange()
    }

    private func columnVisibilityDidChange() {
        needsDisplay = true
        // The resize handles move with the columns, and their cursor rects are
        // installed per column.
        window?.invalidateCursorRects(for: self)
        // Same notification `columnTypes` posts: the set of columns a screen
        // reader can see has changed.
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Draw column highlights BEFORE super so header cell text renders on top
        if let tableView = tableView, !highlightedColumnIndices.isEmpty {
            for colIndex in highlightedColumnIndices {
                guard colIndex < tableView.tableColumns.count else { continue }
                let colId = tableView.tableColumns[colIndex].identifier.rawValue
                guard colId != "__rownum__", !tableView.tableColumns[colIndex].isHidden else { continue }
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
        let funnelSlot = iconSize + iconPadding * 2 + 8   // width the funnel occupies at the right
        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            // A hidden column keeps its slot in `tableColumns`, and its
            // `headerRect` collapses to a zero-width rect AT x = 0 — not to
            // nothing. Every per-column geometry loop in this view has to skip
            // it or it draws (and grabs) at the header's left edge.
            guard colId != "__rownum__", !column.isHidden else { continue }
            // Reserve the overlay's room so the text truncates BEFORE the
            // funnel and the sort chevron instead of running under them.
            var reserved: CGFloat = 0
            if sortDirections[colId] != nil {
                reserved = funnelSlot + (sortIcon(ascending: true)?.size.width ?? sortIconSize) + 4
            } else if activeFilterColumns.contains(colId) || colIndex == hoveredColumnIndex {
                reserved = funnelSlot
            }
            drawHeaderText(name: column.title, type: columnTypes[colId] ?? "",
                           in: headerRect(ofColumn: colIndex), reservedTrailing: reserved)
        }

        // Filter icons drawn AFTER text (topmost visual element)

        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            // The `#` column gets the funnel icon (its filter is the tag
            // funnel) but still no name, no type row and no sort arrow — the
            // header-text guard (name/type loop above) and the sort-arrow
            // guard (sort arrow loop below) both stay in place.
            guard !column.isHidden else { continue }

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
        // at rest), drawn at the header's midline just left of the funnel slot.
        // Overlay only — reserves no column width.
        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            guard colId != "__rownum__", !column.isHidden,
                  let dir = sortDirections[colId] else { continue }
            let headerRect = self.headerRect(ofColumn: colIndex)
            guard let chevron = sortIcon(ascending: dir == .ascending) else { continue }
            let sz = chevron.size
            let iconRect = filterIconRect(inHeaderRect: headerRect)
            let x = headerRect.maxX - funnelSlot - sz.width - 2
            let y = iconRect.midY - sz.height / 2
            chevron.draw(in: NSRect(x: x, y: y, width: sz.width, height: sz.height))
        }
    }

    /// Draws the column name (row 1) and data type (row 2), block-centred and
    /// clipped to `headerRect`. NSTableHeaderView is FLIPPED (y increases
    /// downward → smaller y = top), so the name draws at the smaller y.
    private func drawHeaderText(name: String, type: String, in headerRect: NSRect, reservedTrailing: CGFloat = 0) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }
        var clip = headerRect.insetBy(dx: SortAwareHeaderCell.hInset, dy: 0)
        clip.size.width = max(0, clip.width - reservedTrailing)
        NSBezierPath(rect: clip).setClip()

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

    // MARK: - Accessibility

    /// One element per column TITLE, keyed by column identifier.
    ///
    /// Cached rather than rebuilt, because an accessibility element's IDENTITY
    /// is what a screen reader keeps its place with; a fresh element per redraw
    /// — and this view redraws on every hover sweep and every drag tick — would
    /// throw the user back to the start of the header each time. Entries for
    /// columns that have gone are dropped in `refreshAccessibilityElements`.
    private var titleElements: [String: AccessibilityProxyElement] = [:]

    /// One element per FUNNEL, keyed the same way.
    private var funnelElements: [String: AccessibilityProxyElement] = [:]

    /// The header's whole contents are drawn, not hosted: `NSTableHeaderView`
    /// publishes one rectangle with no children, so a screen reader could see
    /// neither the column names, nor which column was sorted, nor that a funnel
    /// existed at all. These put each drawn thing back.
    override func accessibilityChildren() -> [Any]? {
        refreshAccessibilityElements()
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let elements = refreshAccessibilityElements()
        for element in elements {
            let screenFrame = element.accessibilityFrame()
            guard screenFrame != .zero else { continue }
            let localFrame = convert(window.convertFromScreen(screenFrame), from: nil)
            if localFrame.contains(local) { return element }
        }
        return self
    }

    /// Build or update the elements for the columns that exist right now, and
    /// forget the ones that do not. Returns them in column order, titles and
    /// funnels interleaved, which is the order the eye reads them in.
    @discardableResult
    private func refreshAccessibilityElements() -> [AccessibilityProxyElement] {
        guard let tableView = tableView else { return [] }
        var ordered: [AccessibilityProxyElement] = []
        var liveIds = Set<String>()

        // A hidden column publishes nothing: it is not drawn, its `headerRect`
        // is a zero-width rect at the header's left edge, and a screen reader
        // offered a name there would be pointed at the wrong column. Its cached
        // elements fall out below with the ones whose columns have gone.
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
            let colId = column.identifier.rawValue
            liveIds.insert(colId)
            let headerRect = self.headerRect(ofColumn: index)

            // The `#` column has no name, no type row and no sort — its only
            // affordance is the tag funnel, so it gets no title element either.
            if colId != "__rownum__" {
                let element = titleElements[colId] ?? AccessibilityProxyElement.button(
                    label: column.title, frame: .zero, parent: self
                ) { [weak self] in self?.pressSort(columnId: colId) ?? false }
                titleElements[colId] = element
                element.setAccessibilityLabel(column.title)
                element.setAccessibilityValue(stateDescription(forColumn: colId))
                element.setAccessibilityFrame(
                    AccessibilityProxyElement.frameInScreen(of: headerRect, in: self))
                ordered.append(element)
            }

            let funnelLabel = colId == "__rownum__" ? "Filter tags" : "Filter \(column.title)"
            let funnel = funnelElements[colId] ?? AccessibilityProxyElement.button(
                label: funnelLabel, frame: .zero, parent: self
            ) { [weak self] in self?.pressFilter(columnId: colId) ?? false }
            funnelElements[colId] = funnel
            funnel.setAccessibilityLabel(funnelLabel)
            funnel.setAccessibilityValue(activeFilterColumns.contains(colId) ? "filtered" : nil)
            funnel.setAccessibilityFrame(
                AccessibilityProxyElement.frameInScreen(
                    of: filterIconRect(inHeaderRect: headerRect), in: self))
            ordered.append(funnel)
        }

        titleElements = titleElements.filter { liveIds.contains($0.key) }
        funnelElements = funnelElements.filter { liveIds.contains($0.key) }
        return ordered
    }

    /// What the column's own drawn state says, in words: the sort chevron and
    /// the filled funnel, which are otherwise a glyph and a tint.
    private func stateDescription(forColumn colId: String) -> String? {
        var parts: [String] = []
        if let direction = sortDirections[colId] {
            parts.append(direction == .ascending ? "sorted ascending" : "sorted descending")
        }
        if activeFilterColumns.contains(colId) { parts.append("filtered") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func postElementValuesChanged() {
        guard !titleElements.isEmpty || !funnelElements.isEmpty else { return }
        refreshAccessibilityElements()
        for element in titleElements.values {
            NSAccessibility.post(element: element, notification: .valueChanged)
        }
    }

    private func columnIndex(forId colId: String) -> Int? {
        tableView?.tableColumns.firstIndex { $0.identifier.rawValue == colId }
    }

    /// The sort a header CLICK performs, without the click.
    ///
    /// A mouse click goes to `super.mouseDown`, which reads the column's
    /// `sortDescriptorPrototype` and writes `tableView.sortDescriptors`; the
    /// table then calls its delegate, and `ResultsSortController` does the
    /// work. This writes the same descriptor, so the third press resets the
    /// sort exactly as the third click does — the click count lives in the
    /// controller, not in the event.
    private func pressSort(columnId: String) -> Bool {
        guard let tableView = tableView,
              let index = columnIndex(forId: columnId),
              let prototype = tableView.tableColumns[index].sortDescriptorPrototype,
              let key = prototype.key else { return false }
        let current = tableView.sortDescriptors.first
        let ascending = current?.key == key ? !(current?.ascending ?? true) : prototype.ascending
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        return true
    }

    /// The funnel CLICK's delegate call, without the click — same delegate,
    /// same rect, so the popover opens where the icon is.
    private func pressFilter(columnId: String) -> Bool {
        guard let tableView = tableView, let index = columnIndex(forId: columnId),
              let delegate = filterDelegate else { return false }
        let column = tableView.tableColumns[index]
        let iconRect = filterIconRect(inHeaderRect: headerRect(ofColumn: index))
        delegate.headerView(self, didClickFilterForColumn: column, at: iconRect)
        return true
    }

    /// Test seam: the elements the header publishes right now. Production reads
    /// them through `accessibilityChildren()`; a harness cannot, because AppKit
    /// only calls that from an accessibility client.
    func accessibilityElementsForTesting() -> [AccessibilityProxyElement] {
        refreshAccessibilityElements()
    }

    // MARK: - Sort Cell Indicators

    private func updateSortCellIndicators() {
        needsDisplay = true
    }

    // MARK: - Geometry

    private func filterIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        // Centred on the header's own midline, not on the type row: the slot
        // is an overlay at the column's trailing edge, and a glyph aligned to
        // the lower text row sat 3.7pt off the bottom edge and read as
        // pressed against it. (The sort chevron takes its y from here too.)
        return NSRect(x: headerRect.maxX - side - 8, y: headerRect.midY - side / 2, width: side, height: side)
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
        // Hidden columns are skipped, and not only because they have no divider
        // to grab: their `headerRect` is a zero-width rect AT x = 0, so a plain
        // `abs(point.x - rect.maxX)` test hands every click within 6pt of the
        // header's left edge to a column the user cannot see.
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
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
            guard !tableView.tableColumns[index].isHidden else { return false }
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
            guard !column.isHidden, column.resizingMask.contains(.userResizingMask) else { continue }
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
