import AppKit

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

    /// Column names that currently have active filters.
    var activeFilterColumns: Set<String> = [] {
        didSet { needsDisplay = true }
    }

    /// Sort directions per column identifier, pushed by sort controller.
    var sortDirections: [String: ResultsSortController.SortDirection] = [:] {
        didSet { needsDisplay = true }
    }

    private var hoveredColumnIndex: Int = -1
    private var trackingArea: NSTrackingArea?

    private let iconSize: CGFloat = 10
    private let iconPadding: CGFloat = 6

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
        if newIndex != hoveredColumnIndex {
            hoveredColumnIndex = newIndex
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredColumnIndex = column(at: point)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredColumnIndex = -1
        needsDisplay = true
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
        super.draw(dirtyRect)

        guard let tableView = tableView else { return }

        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            guard colId != "__rownum__" else { continue }

            let headerRect = self.headerRect(ofColumn: colIndex)

            // Draw sort indicator on LEFT (always visible when sort is active on this column)
            if let sortDir = sortDirections[colId] {
                let symbolName = sortDir == .ascending ? "chevron.up" : "chevron.down"
                let sortRect = sortIconRect(inHeaderRect: headerRect)
                if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Sort")?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                    let tinted = image.tinted(with: .secondaryLabelColor)
                    let imageSize = tinted.size
                    let drawRect = NSRect(
                        x: sortRect.midX - imageSize.width / 2,
                        y: sortRect.midY - imageSize.height / 2,
                        width: imageSize.width,
                        height: imageSize.height
                    )
                    tinted.draw(in: drawRect)
                }
            }

            // Draw filter icon on RIGHT (on hover or when active -- existing logic)
            let isActive = activeFilterColumns.contains(colId)
            let isHovered = colIndex == hoveredColumnIndex
            guard isActive || isHovered else { continue }

            let iconRect = filterIconRect(inHeaderRect: headerRect)
            let symbolName = isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
            let tintColor: NSColor = isActive ? .controlAccentColor : .tertiaryLabelColor

            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Filter")?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = image.tinted(with: tintColor)
                let imageSize = tinted.size
                let drawRect = NSRect(
                    x: iconRect.midX - imageSize.width / 2,
                    y: iconRect.midY - imageSize.height / 2,
                    width: imageSize.width,
                    height: imageSize.height
                )
                tinted.draw(in: drawRect)
            }
        }
    }

    // MARK: - Geometry

    private func sortIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        return NSRect(
            x: headerRect.minX + 2,
            y: headerRect.midY - side / 2,
            width: side,
            height: side
        )
    }

    private func filterIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        return NSRect(
            x: headerRect.maxX - side - 2,
            y: headerRect.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// Returns the column index to auto-fit if the point is near a column's right edge (~4px).
    private func columnIndexForResizeEdge(at point: NSPoint) -> Int? {
        guard let tableView = tableView else { return nil }
        let threshold: CGFloat = 4
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
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
