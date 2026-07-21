import AppKit

// MARK: - Sort Aware Header Cell

/// Header cell drawing the column name on row 1 and the data type on row 2.
/// Sort/filter affordances are drawn by FilterableHeaderView as row-2 overlays
/// (Task B2), so this cell reserves no horizontal space for them.
class SortAwareHeaderCell: NSTableHeaderCell {
    var nameString: String = ""
    var typeString: String = ""

    static let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let typeFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    static let hInset: CGFloat = 6

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: Self.nameFont, .foregroundColor: NSColor.labelColor]
        let typeAttrs: [NSAttributedString.Key: Any] = [.font: Self.typeFont, .foregroundColor: NSColor.secondaryLabelColor]
        let nameSize = (nameString as NSString).size(withAttributes: nameAttrs)
        let typeSize = (typeString as NSString).size(withAttributes: typeAttrs)
        let gap: CGFloat = 1
        let totalH = nameSize.height + gap + typeSize.height
        // Header cells are NON-flipped (y increases upward). Center the two-line
        // block; type sits below the name.
        let bottomY = cellFrame.midY - totalH / 2
        let x = cellFrame.minX + Self.hInset
        (typeString as NSString).draw(at: NSPoint(x: x, y: bottomY), withAttributes: typeAttrs)
        (nameString as NSString).draw(at: NSPoint(x: x, y: bottomY + typeSize.height + gap), withAttributes: nameAttrs)
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
class FilterableHeaderView: NSTableHeaderView {

    weak var filterDelegate: FilterableHeaderViewDelegate?

    /// Minimum header height needed to fit the two-row (name / type) header cell.
    /// NSScrollView re-tiles the table and resets the header frame to the default
    /// single-row height; clamping here keeps the two-row layout from clipping.
    static let minHeaderHeight: CGFloat = 34

    override var frame: NSRect {
        get { super.frame }
        set {
            var f = newValue
            f.size.height = max(f.size.height, Self.minHeaderHeight)
            super.frame = f
        }
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
            if let resizeColIndex = columnIndexForResizeEdge(at: point) {
                filterDelegate?.headerView(self, didDoubleClickResizeForColumn: resizeColIndex)
                return
            }
        }

        let colIndex = column(at: point)
        guard colIndex >= 0, let tableView = tableView else {
            super.mouseDown(with: event)
            return
        }

        let column = tableView.tableColumns[colIndex]

        // Skip row-number column
        guard column.identifier.rawValue != "__rownum__" else {
            super.mouseDown(with: event)
            return
        }

        let headerRect = self.headerRect(ofColumn: colIndex)
        // Near column edge -> let super handle resize drag
        if columnIndexForResizeEdge(at: point) != nil {
            super.mouseDown(with: event)
            return
        }

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

        // Filter icons drawn AFTER super (topmost visual element)
        guard let tableView = tableView else { return }

        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            guard colId != "__rownum__" else { continue }

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

    // MARK: - Sort Cell Indicators

    private func updateSortCellIndicators() {
        needsDisplay = true
    }

    // MARK: - Geometry

    private func filterIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        // Row 2 ≈ lower third of the (taller) header. Non-flipped: minY = bottom.
        let row2MidY = headerRect.minY + headerRect.height * 0.30
        return NSRect(x: headerRect.maxX - side - 8, y: row2MidY - side / 2, width: side, height: side)
    }

    /// Returns the column index to auto-fit if the point is near a column's right edge (~4px).
    private func columnIndexForResizeEdge(at point: NSPoint) -> Int? {
        guard let tableView = tableView else { return nil }
        let threshold: CGFloat = 6
        for (index, _) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            if abs(point.x - rect.maxX) <= threshold {
                return index
            }
        }
        return nil
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
