import AppKit

// MARK: - ResultsFindControllerDelegate

extension ResultsGridVC: ResultsFindControllerDelegate {
    var findRows: [[AnyCodable]] { rows }
    var findColumns: [ColumnDef] { columns }
    var findUnfilteredDisplayRows: [Int] { columnFilteredDisplayRows }

    func findControllerDidUpdateResults(
        displayRows newDisplayRows: [Int]?,
        matchSet: Set<CellAddress>,
        currentMatchRow: Int,
        currentMatchColId: String?
    ) {
        if let newDisplayRows {
            displayRows = newDisplayRows
        }
        pushDataToHelpers()
        pushFindStateToDataSource(matchSet: matchSet, currentMatchRow: currentMatchRow, currentMatchColId: currentMatchColId)
        tableView.reloadData()
        updateStatusBarText()
    }

    func findControllerDidClose(displayRows newDisplayRows: [Int]) {
        displayRows = newDisplayRows
        pushDataToHelpers()
        pushFindStateToDataSource(matchSet: Set(), currentMatchRow: -1, currentMatchColId: nil)
        tableView.reloadData()
        updateStatusBarText()
        view.window?.makeFirstResponder(tableView)
    }

    func findControllerDidToggleVisibility(visible: Bool) {
        // Find controls are inline in the toolbar bar, no layout changes needed
    }

    func findControllerUpdateStatusBar() {
        updateStatusBarText()
    }
}

// MARK: - ResultsDataSourceDelegate

extension ResultsGridVC: ResultsDataSourceDelegate {
    func dataSourceSortDescriptorsDidChange(_ oldDescriptors: [NSSortDescriptor]) {
        sortController.handleSortDescriptorsChanged(oldDescriptors)
    }

    func dataSourceSelectionDidChange() {
        let indices = tableView.selectedRowIndexes
        onSelectionChanged?(indices)
    }
}

// MARK: - ResultsSortControllerDelegate

extension ResultsGridVC: ResultsSortControllerDelegate {
    var sortableRows: [[AnyCodable]] { rows }
    var sortableColumnCategories: [PGTypeCategory] { columnCategories }

    func sortControllerDidSort(unfilteredDisplayRows newUnfiltered: [Int], isSorted: Bool) {
        unfilteredDisplayRows = newUnfiltered
        recomputeColumnFilteredRows()
    }

    func sortControllerDidReset(unfilteredDisplayRows newUnfiltered: [Int]) {
        unfilteredDisplayRows = newUnfiltered
        recomputeColumnFilteredRows()
    }
}

// MARK: - ResultsCopyExportDelegate

extension ResultsGridVC: ResultsCopyExportDelegate {
    func copyExportWindow() -> NSWindow? {
        view.window
    }
}

// MARK: - ResultsColumnFilterControllerDelegate

extension ResultsGridVC: ResultsColumnFilterControllerDelegate {
    var filterableRows: [[AnyCodable]] { rows }
    var filterableColumnCategories: [PGTypeCategory] { columnCategories }

    func columnFilterControllerDidUpdate(columnFilteredDisplayRows newFiltered: [Int]) {
        columnFilteredDisplayRows = newFiltered
        if findController.isFindVisible {
            findController.findFieldChanged(findField)
        } else {
            displayRows = columnFilteredDisplayRows
            pushDataToHelpers()
            tableView.reloadData()
        }
        updateStatusBarText()
    }
}

// MARK: - ColumnFilterPopoverDelegate

extension ResultsGridVC: ColumnFilterPopoverDelegate {
    func columnFilterPopover(_ popover: ColumnFilterPopoverVC, didApplyFilter filter: ColumnFilter) {
        columnFilterController.setFilter(filter, forColumn: filter.columnName)
        filterableHeaderView.activeFilterColumns = Set(columnFilterController.activeFilters.keys)
        resetFiltersButton.isHidden = !columnFilterController.hasActiveFilters
        recomputeColumnFilteredRows()
    }

    func columnFilterPopover(_ popover: ColumnFilterPopoverVC, didClearFilterForColumn column: String) {
        columnFilterController.clearFilter(forColumn: column)
        filterableHeaderView.activeFilterColumns = Set(columnFilterController.activeFilters.keys)
        resetFiltersButton.isHidden = !columnFilterController.hasActiveFilters
        recomputeColumnFilteredRows()
    }
}

// MARK: - FilterableHeaderViewDelegate

extension ResultsGridVC: FilterableHeaderViewDelegate {
    func headerView(_ headerView: FilterableHeaderView, didDoubleClickResizeForColumn columnIndex: Int) {
        autoFitColumn(at: columnIndex)
    }

    func headerView(_ headerView: FilterableHeaderView, didClickFilterForColumn column: NSTableColumn, at rect: NSRect) {
        let colId = column.identifier.rawValue
        guard let idx = colIndex(from: colId), idx < columns.count else { return }
        let category = columnCategories[idx]
        let rawDataType = columns[idx].dataType
        let existing = columnFilterController.filter(forColumn: colId)

        let distinct = columnFilterController.distinctValues(
            forColumnIndex: idx, excludingColumnId: colId, category: category
        )
        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks
        )
        popoverVC.filterDelegate = self

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.show(relativeTo: rect, of: headerView, preferredEdge: .maxY)
    }
}
