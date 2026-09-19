import AppKit

// MARK: - Inline Cell Editing

/// What a committed edit does to the selection afterwards.
enum CellEditMove {
    /// Focus goes back to the table and the selection stays put (a click
    /// elsewhere, a programmatic end).
    case none
    /// Return: down one row, in the same column.
    case nextRow
    /// Tab: one column right, wrapping to the next row.
    case nextColumn
    /// Shift-Tab: one column left.
    case previousColumn
}

extension ResultsGridVC: ResultsCellEditingRouting, NSTextFieldDelegate {

    // MARK: - The rule

    /// Whether this cell may be edited. Every path in — the double-click, the
    /// ⌘Return, the two context-menu items — asks this and nothing else, so
    /// there is one answer rather than three that can drift.
    ///
    /// A plan tab is not checked here because a plan tab never shows this
    /// grid: `ContentViewController` puts the plan view over the same region,
    /// so there is no cell to ask about.
    func canEditCell(at position: CellPosition) -> Bool {
        // Settings ▸ Results ▸ Editing. Off means this grid is read-only, so
        // it is asked FIRST — before the per-cell rules, which are about
        // whether a writable grid could write THIS cell.
        guard gridSettings.allowInlineEditing else { return false }
        guard let dataColumn = dataColumnIndex(forTableColumn: position.column),
              let dataRow = dataRowIndex(forDisplayRow: position.row)
        else { return false }
        return CellEditability.isEditable(
            columns: columns, rowIdentity: rowIdentity,
            columnIndex: dataColumn, dataRow: dataRow)
    }

    /// The result's own column index behind a table column, or nil for the `#`
    /// column and for an index that is out of range. Goes through the table's
    /// live columns, so a user-reordered grid still resolves correctly.
    func dataColumnIndex(forTableColumn column: Int) -> Int? {
        guard column >= 0, column < tableView.numberOfColumns else { return nil }
        return colIndex(from: tableView.tableColumns[column].identifier.rawValue)
    }

    /// The data row behind a display row.
    func dataRowIndex(forDisplayRow row: Int) -> Int? {
        guard row >= 0, row < displayRows.count else { return nil }
        return displayRows[row]
    }

    /// The table column index showing a given data column, or nil when the
    /// column is hidden. The inverse of `dataColumnIndex(forTableColumn:)`.
    func tableColumnIndex(forDataColumn dataColumn: Int) -> Int? {
        tableView.tableColumns.firstIndex { colIndex(from: $0.identifier.rawValue) == dataColumn }
    }

    /// The value as LOADED, or nil for a SQL NULL. The old half of a
    /// `PendingEdit`, and the value the review sheet's `IS NOT DISTINCT FROM`
    /// guard is built from.
    func loadedText(dataRow: Int, columnIndex: Int) -> String? {
        guard dataRow >= 0, dataRow < rows.count, columnIndex < rows[dataRow].count else { return nil }
        return rows[dataRow][columnIndex].stringValue
    }

    // MARK: - Starting and ending an edit

    func beginEditingCell(at position: CellPosition) {
        guard canEditCell(at: position) else { return }
        // Never two editors at once: whatever was open commits first, exactly
        // as clicking away from it would.
        if editingPosition != nil, editingPosition != position {
            finishEditing(commitText: currentEditorText(), move: .none)
        }
        guard let dataColumn = dataColumnIndex(forTableColumn: position.column),
              let dataRow = dataRowIndex(forDisplayRow: position.row) else { return }

        editingPosition = position
        dataSource.editingCell = position
        dataSource.cellEditorDelegate = self

        // The field opens on the value that would be WRITTEN — the pending one
        // where there is one, so a second edit of the same cell continues from
        // where the first left off rather than snapping back to the loaded
        // text. A pending NULL opens empty, because there is nothing to show.
        let seed: String
        if let pending = pendingEdits.edit(at: dataRow, columnIndex: dataColumn) {
            seed = pending.newText ?? ""
        } else {
            seed = loadedText(dataRow: dataRow, columnIndex: dataColumn) ?? ""
        }

        tableView.scrollRowToVisible(position.row)
        tableView.scrollColumnToVisible(position.column)
        guard let cell = tableView.view(atColumn: position.column, row: position.row,
                                        makeIfNecessary: true) as? ResultCellView else {
            editingPosition = nil
            dataSource.editingCell = nil
            return
        }
        cell.beginEditing(text: seed, font: dataSource.gridStyle.cellFont, delegate: self)
        if let field = cell.editorField {
            view.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        Log.ui.debug("Editing cell row \(dataRow, privacy: .public) column \(dataColumn, privacy: .public)")
    }

    /// The text in the open editor, or nil when nothing is open.
    func currentEditorText() -> String? {
        guard let position = editingPosition,
              let cell = tableView.view(atColumn: position.column, row: position.row,
                                        makeIfNecessary: false) as? ResultCellView,
              let field = cell.editorField, !field.isHidden
        else { return nil }
        return field.stringValue
    }

    /// Close the editor without recording anything. Escape, and every path
    /// that replaces the result underneath an open editor.
    func abandonEditing() {
        guard editingPosition != nil else { return }
        isAbandoningEdit = true
        finishEditing(commitText: nil, move: .none)
        isAbandoningEdit = false
    }

    /// Close the editor, optionally recording `commitText`, then move on.
    ///
    /// `commitText` of nil means abandon. An empty string is a real value —
    /// the empty string — and is recorded; "Set NULL" is the only way to a
    /// NULL, which is what keeps the two distinguishable.
    func finishEditing(commitText: String?, move: CellEditMove) {
        guard let position = editingPosition else { return }
        editingPosition = nil
        dataSource.editingCell = nil

        if let text = commitText,
           let dataColumn = dataColumnIndex(forTableColumn: position.column),
           let dataRow = dataRowIndex(forDisplayRow: position.row) {
            pendingEdits.set(PendingEdit(
                dataRow: dataRow, columnIndex: dataColumn,
                oldText: loadedText(dataRow: dataRow, columnIndex: dataColumn),
                newText: text))
            notifyPendingEditsChanged()
        }

        // The field is inside the cell, so the table has to take the keyboard
        // back before the cell is reloaded out from under it.
        if let cell = tableView.view(atColumn: position.column, row: position.row,
                                     makeIfNecessary: false) as? ResultCellView {
            cell.endEditing()
        }
        view.window?.makeFirstResponder(tableView)
        reloadDisplayRow(position.row)
        applyMove(move, from: position)
    }

    /// Repaint one display row across every column, so a committed edit's
    /// marker appears without a full `reloadData` of a large result.
    private func reloadDisplayRow(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    private func applyMove(_ move: CellEditMove, from position: CellPosition) {
        let firstDataColumn = cellSelectionController?.firstDataColumn ?? 1
        var next = position
        switch move {
        case .none:
            return
        case .nextRow:
            guard position.row + 1 < tableView.numberOfRows else { return }
            next = CellPosition(row: position.row + 1, column: position.column)
        case .nextColumn:
            if position.column + 1 < tableView.numberOfColumns {
                next = CellPosition(row: position.row, column: position.column + 1)
            } else if position.row + 1 < tableView.numberOfRows {
                next = CellPosition(row: position.row + 1, column: firstDataColumn)
            } else {
                return
            }
        case .previousColumn:
            guard position.column - 1 >= firstDataColumn else { return }
            next = CellPosition(row: position.row, column: position.column - 1)
        }
        cellSelectionController?.state.anchor = next
        cellSelectionController?.state.active = next
        cellSelectionController?.onChange?(cellSelectionController?.state ?? CellSelectionState())
        cellSelectionController?.scrollToActive()
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard editingPosition != nil else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commitText: control.stringValue, move: .nextRow)
            return true
        case #selector(NSResponder.insertTab(_:)):
            finishEditing(commitText: control.stringValue, move: .nextColumn)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            finishEditing(commitText: control.stringValue, move: .previousColumn)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            abandonEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // AppKit fires this as focus leaves, which is AFTER `doCommandBy` has
        // already finished the edit — `editingPosition` is nil by then, and
        // `finishEditing` returns at its guard. What this catches is the case
        // `doCommandBy` cannot: the user clicking somewhere else. That commits,
        // the way every macOS inline field does.
        guard !isAbandoningEdit, editingPosition != nil,
              let field = obj.object as? NSTextField else { return }
        finishEditing(commitText: field.stringValue, move: .none)
    }

    // MARK: - Context-menu edits

    /// "Set NULL": record a pending NULL for the clicked cell.
    ///
    /// The one way to a SQL NULL. An empty field is the empty string, and the
    /// two must stay distinguishable — in a `text` column they are different
    /// values, and conflating them would silently change data.
    func setPendingNull(dataRow: Int, columnIndex: Int) {
        pendingEdits.set(PendingEdit(
            dataRow: dataRow, columnIndex: columnIndex,
            oldText: loadedText(dataRow: dataRow, columnIndex: columnIndex),
            newText: nil))
        notifyPendingEditsChanged()
        reloadDataRow(dataRow)
    }

    /// "Revert Edit": drop one cell's pending change.
    func revertPendingEdit(dataRow: Int, columnIndex: Int) {
        guard pendingEdits.edit(at: dataRow, columnIndex: columnIndex) != nil else { return }
        pendingEdits.remove(dataRow: dataRow, columnIndex: columnIndex)
        notifyPendingEditsChanged()
        reloadDataRow(dataRow)
    }

    /// Throw every pending change away. The caller asks the user first.
    func discardPendingEdits() {
        guard !pendingEdits.isEmpty else { return }
        abandonEditing()
        pendingEdits.removeAll()
        notifyPendingEditsChanged()
        tableView.reloadData()
    }

    /// Repaint the DISPLAY row showing a given data row, if it is on screen at
    /// all — a column filter or a find filter can have hidden it.
    private func reloadDataRow(_ dataRow: Int) {
        guard let displayRow = displayRows.firstIndex(of: dataRow) else { return }
        reloadDisplayRow(displayRow)
    }

    // MARK: - Pushing the set outward

    /// The one place the pending set is handed on: to the data source, which
    /// renders it, and to the owner, which draws the bar. Every mutation above
    /// ends here.
    func notifyPendingEditsChanged() {
        dataSource.pendingEdits = pendingEdits
        onPendingEditsChanged?()
    }

    /// The request the review sheet shows and the core applies, or nil when
    /// the pending set cannot safely become one (see `makeRequest`).
    func makeRowUpdateRequest() -> RowUpdateRequest? {
        RowUpdateSQLBuilder.makeRequest(
            pending: pendingEdits, columns: columns, rows: rows, rowIdentity: rowIdentity)
    }

    /// The table the pending edits belong to, for the bar's text. Empty when
    /// the result has no identity, in which case nothing is editable anyway.
    var pendingEditsTableDisplay: String { rowIdentity?.tableDisplay ?? "" }

    // MARK: - Context-menu targets

    /// The cell the context menu was opened on, as DATA indices, or nil when
    /// the click was not on a data cell.
    ///
    /// `clickedRow`/`clickedColumn` and not the selection: the menu acts on
    /// what was right-clicked, which is how every other item in this menu
    /// behaves. (`tagTargetDataRows` documents why `clickedRow` alone cannot be
    /// trusted for anything BUT a context menu.)
    func contextMenuCell() -> (dataRow: Int, columnIndex: Int)? {
        let row = tableView.clickedRow
        let column = tableView.clickedColumn
        guard row >= 0, column >= 0,
              let dataRow = dataRowIndex(forDisplayRow: row),
              let dataColumn = dataColumnIndex(forTableColumn: column)
        else { return nil }
        return (dataRow, dataColumn)
    }

    /// Whether "Set NULL" applies to the clicked cell.
    ///
    /// Editability only. The grid does not know whether the column is
    /// NULLABLE — `ColumnDef` carries a type and a provenance, not
    /// `attnotnull` — so a NULL into a NOT NULL column is refused by the
    /// server, which rolls the whole transaction back and reports the
    /// constraint by name. Refusing it here would need a metadata round trip
    /// per result and would still be a guess on a stale cache.
    func canSetNullAtClickedCell() -> Bool {
        guard let cell = contextMenuCell(),
              let displayRow = displayRows.firstIndex(of: cell.dataRow),
              let tableColumn = tableColumnIndex(forDataColumn: cell.columnIndex)
        else { return false }
        return canEditCell(at: CellPosition(row: displayRow, column: tableColumn))
    }

    /// Whether "Revert Edit" applies to the clicked cell.
    func canRevertClickedCell() -> Bool {
        guard let cell = contextMenuCell() else { return false }
        return pendingEdits.edit(at: cell.dataRow, columnIndex: cell.columnIndex) != nil
    }

    @objc func setNullAtClickedCell(_ sender: Any?) {
        guard let cell = contextMenuCell(), canSetNullAtClickedCell() else { return }
        setPendingNull(dataRow: cell.dataRow, columnIndex: cell.columnIndex)
    }

    @objc func revertEditAtClickedCell(_ sender: Any?) {
        guard let cell = contextMenuCell() else { return }
        revertPendingEdit(dataRow: cell.dataRow, columnIndex: cell.columnIndex)
    }
}
