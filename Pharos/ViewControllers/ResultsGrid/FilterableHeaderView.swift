import AppKit

// MARK: - Filterable Header View Delegate

protocol FilterableHeaderViewDelegate: AnyObject {
    func headerView(_ headerView: FilterableHeaderView, didClickFilterForColumn column: NSTableColumn, at rect: NSRect)
}

// MARK: - FilterableHeaderView

/// Custom NSTableHeaderView that draws a filter icon in each column header's trailing edge.
/// - Hidden by default
/// - Shown on hover (tertiary color)
/// - Always shown when active filter (accent color, filled icon)
class FilterableHeaderView: NSTableHeaderView {

    weak var filterDelegate: FilterableHeaderViewDelegate?

    /// Column names that currently have active filters.
    var activeFilterColumns: Set<String> = [] {
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

    private func filterIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        return NSRect(
            x: headerRect.maxX - side - 2,
            y: headerRect.midY - side / 2,
            width: side,
            height: side
        )
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
