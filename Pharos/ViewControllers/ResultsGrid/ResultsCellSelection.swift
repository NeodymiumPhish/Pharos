import AppKit

// MARK: - Cell Position

struct CellPosition: Hashable, Equatable {
    let row: Int       // display row index
    let column: Int    // column index in tableView.tableColumns
}

// MARK: - Cell Selection State

struct CellSelectionState {
    var anchor: CellPosition?
    var active: CellPosition?
    var isSelecting: Bool = false

    /// Row-mode selection (clicking row numbers).
    var selectedRows: IndexSet = IndexSet()

    /// True when the user has selected whole rows (via row number column).
    var isRowMode: Bool { !selectedRows.isEmpty }

    var selectedRange: (topLeft: CellPosition, bottomRight: CellPosition)? {
        guard let a = anchor, let b = active else { return nil }
        return (
            CellPosition(row: min(a.row, b.row), column: min(a.column, b.column)),
            CellPosition(row: max(a.row, b.row), column: max(a.column, b.column))
        )
    }

    func contains(_ pos: CellPosition) -> Bool {
        guard let range = selectedRange else { return false }
        return pos.row >= range.topLeft.row && pos.row <= range.bottomRight.row
            && pos.column >= range.topLeft.column && pos.column <= range.bottomRight.column
    }

    func selectedRowIndices() -> IndexSet {
        if isRowMode { return selectedRows }
        guard let range = selectedRange else { return IndexSet() }
        return IndexSet(integersIn: range.topLeft.row...range.bottomRight.row)
    }

    /// Column indices covered by the cell selection range (for header highlight).
    var selectedColumnIndices: IndexSet {
        guard let range = selectedRange else { return IndexSet() }
        return IndexSet(integersIn: range.topLeft.column...range.bottomRight.column)
    }
}

// MARK: - Cell Selection Controller

class CellSelectionController {
    weak var tableView: NSTableView?
    var state = CellSelectionState()
    var onChange: ((CellSelectionState) -> Void)?

    var totalRows: Int { tableView?.numberOfRows ?? 0 }
    var totalColumns: Int { tableView?.numberOfColumns ?? 0 }

    /// Returns 1 if column 0 is the __rownum__ column, else 0.
    var firstDataColumn: Int {
        guard let tv = tableView, tv.numberOfColumns > 0 else { return 0 }
        return tv.tableColumns[0].identifier.rawValue == "__rownum__" ? 1 : 0
    }

    /// Anchor row for row-drag selection.
    private var rowAnchor: Int?

    // MARK: - Cell Position from Event

    func cellPosition(from event: NSEvent) -> CellPosition? {
        guard let tv = tableView else { return nil }
        let point = tv.convert(event.locationInWindow, from: nil)
        let row = tv.row(at: point)
        let col = tv.column(at: point)
        guard row >= 0, col >= 0 else { return nil }

        // Skip __rownum__ column
        if col == 0 && tv.tableColumns[0].identifier.rawValue == "__rownum__" {
            return nil
        }

        return CellPosition(row: row, column: col)
    }

    /// Returns the row index if the click is on the __rownum__ column.
    func rowIndex(from event: NSEvent) -> Int? {
        guard let tv = tableView else { return nil }
        let point = tv.convert(event.locationInWindow, from: nil)
        let row = tv.row(at: point)
        let col = tv.column(at: point)
        guard row >= 0, col >= 0 else { return nil }
        guard col == 0, tv.tableColumns[0].identifier.rawValue == "__rownum__" else { return nil }
        return row
    }

    // MARK: - Mouse Handling

    func handleMouseDown(with event: NSEvent) {
        // Check for row number click first
        if let rowIdx = rowIndex(from: event) {
            // Row selection mode
            state.anchor = nil
            state.active = nil
            if event.modifierFlags.contains(.shift), let anchor = rowAnchor {
                // Extend from anchor to clicked row
                let lo = min(anchor, rowIdx)
                let hi = max(anchor, rowIdx)
                state.selectedRows = IndexSet(integersIn: lo...hi)
            } else {
                state.selectedRows = IndexSet(integer: rowIdx)
                rowAnchor = rowIdx
            }
            state.isSelecting = true
            onChange?(state)
            return
        }

        // Data cell click
        if let pos = cellPosition(from: event) {
            state.selectedRows = IndexSet()
            rowAnchor = nil
            if event.modifierFlags.contains(.shift) {
                state.active = pos
            } else {
                state.anchor = pos
                state.active = pos
                state.isSelecting = true
            }
            onChange?(state)
            return
        }

        // Click on empty area
        clear()
    }

    func handleMouseDragged(with event: NSEvent) {
        guard state.isSelecting else { return }

        if state.isRowMode, let anchor = rowAnchor {
            // Row drag: extend selection from anchor to current row
            guard let tv = tableView else { return }
            let point = tv.convert(event.locationInWindow, from: nil)
            let dragRow = tv.row(at: point)
            guard dragRow >= 0 else { return }
            let lo = min(anchor, dragRow)
            let hi = max(anchor, dragRow)
            state.selectedRows = IndexSet(integersIn: lo...hi)
            onChange?(state)
            return
        }

        // Cell drag
        if let pos = cellPosition(from: event) {
            state.active = pos
        }
        onChange?(state)
    }

    func handleMouseUp(with event: NSEvent) {
        state.isSelecting = false
    }

    // MARK: - Keyboard Handling

    /// Returns true if the event was handled.
    func handleKeyDown(with event: NSEvent) -> Bool {
        // Row mode: only handle Escape
        if state.isRowMode {
            if event.keyCode == 53 { // Escape
                clear()
                return true
            }
            return false
        }
        guard let current = state.active else { return false }

        let shift = event.modifierFlags.contains(.shift)
        let fdc = firstDataColumn

        switch event.keyCode {
        case 123: // Left arrow
            let newCol = max(fdc, current.column - 1)
            let newPos = CellPosition(row: current.row, column: newCol)
            if shift {
                state.active = newPos
            } else {
                state.anchor = newPos
                state.active = newPos
            }
            onChange?(state)
            return true

        case 124: // Right arrow
            let newCol = min(totalColumns - 1, current.column + 1)
            let newPos = CellPosition(row: current.row, column: newCol)
            if shift {
                state.active = newPos
            } else {
                state.anchor = newPos
                state.active = newPos
            }
            onChange?(state)
            return true

        case 125: // Down arrow
            let newRow = min(totalRows - 1, current.row + 1)
            let newPos = CellPosition(row: newRow, column: current.column)
            if shift {
                state.active = newPos
            } else {
                state.anchor = newPos
                state.active = newPos
            }
            onChange?(state)
            return true

        case 126: // Up arrow
            let newRow = max(0, current.row - 1)
            let newPos = CellPosition(row: newRow, column: current.column)
            if shift {
                state.active = newPos
            } else {
                state.anchor = newPos
                state.active = newPos
            }
            onChange?(state)
            return true

        case 48: // Tab
            var newCol = current.column + 1
            var newRow = current.row
            if newCol >= totalColumns {
                // Wrap to first data column of next row
                newCol = fdc
                newRow += 1
            }
            if newRow >= totalRows {
                // At last row + last column: stop
                return true
            }
            let newPos = CellPosition(row: newRow, column: newCol)
            state.anchor = newPos
            state.active = newPos
            onChange?(state)
            return true

        case 36, 76: // Enter / Return (keypad)
            let newRow = current.row + 1
            if newRow >= totalRows {
                // At last row: stop
                return true
            }
            let newPos = CellPosition(row: newRow, column: current.column)
            state.anchor = newPos
            state.active = newPos
            onChange?(state)
            return true

        case 53: // Escape
            clear()
            return true

        default:
            return false
        }
    }

    // MARK: - Clear

    func clear() {
        state = CellSelectionState()
        rowAnchor = nil
        onChange?(state)
    }
}

// MARK: - ResultsTableView

class ResultsTableView: NSTableView {
    var cellSelectionController: CellSelectionController?

    override func mouseDown(with event: NSEvent) {
        cellSelectionController?.handleMouseDown(with: event)
        // Do NOT call super.mouseDown -- we replace row selection with cell selection.
        // Ensure the table becomes first responder.
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        cellSelectionController?.handleMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        cellSelectionController?.handleMouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if cellSelectionController?.handleKeyDown(with: event) == true {
            return
        }
        super.keyDown(with: event)
    }
}
