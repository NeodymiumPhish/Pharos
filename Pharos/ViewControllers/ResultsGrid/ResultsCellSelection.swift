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
        guard let range = selectedRange else { return IndexSet() }
        return IndexSet(integersIn: range.topLeft.row...range.bottomRight.row)
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

    // MARK: - Mouse Handling

    func handleMouseDown(with event: NSEvent) {
        guard let pos = cellPosition(from: event) else {
            clear()
            return
        }

        if event.modifierFlags.contains(.shift) {
            // Shift+click: keep anchor, set active to clicked cell
            state.active = pos
        } else {
            state.anchor = pos
            state.active = pos
            state.isSelecting = true
        }

        onChange?(state)
    }

    func handleMouseDragged(with event: NSEvent) {
        guard state.isSelecting else { return }

        if let pos = cellPosition(from: event) {
            state.active = pos
        }
        // If position returns nil (e.g., over row number column), keep last valid active

        onChange?(state)
    }

    func handleMouseUp(with event: NSEvent) {
        state.isSelecting = false
    }

    // MARK: - Keyboard Handling

    /// Returns true if the event was handled.
    func handleKeyDown(with event: NSEvent) -> Bool {
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
