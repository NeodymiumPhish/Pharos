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
}

// MARK: - ColumnFilterPopoverDelegate

extension ResultsGridVC: ColumnFilterPopoverDelegate {
    func columnFilterPopover(_ popover: ColumnFilterPopoverVC, didApplyFilter filter: ColumnFilter) {
        columnFilterController.setFilter(filter, forColumn: filter.columnName)
        refreshColumnFilters()
    }

    func columnFilterPopover(_ popover: ColumnFilterPopoverVC, didClearFilterForColumn column: String) {
        columnFilterController.clearFilter(forColumn: column)
        refreshColumnFilters()
    }
}

// MARK: - FilterableHeaderViewDelegate

extension ResultsGridVC: FilterableHeaderViewDelegate {
    func headerView(_ headerView: FilterableHeaderView, didDoubleClickResizeForColumn columnIndex: Int) {
        autoFitColumn(at: columnIndex)
    }

    func headerView(_ headerView: FilterableHeaderView, didClickFilterForColumn column: NSTableColumn, at rect: NSRect) {
        let colId = column.identifier.rawValue
        if TagFunnel.isTagFilter(columnId: colId) {
            // The labels PRESENT in the result, in palette order.
            let presentIds = Set(tagsByRow.values.map { $0.labelId })
            let present = TagStore.shared.labels.filter { presentIds.contains($0.id) }
            let existing = columnFilterController.filter(forColumn: colId)
                .flatMap { $0.values.map(Set.init) }
            let popoverVC = TagFunnelPopoverVC(labels: present, existing: existing)
            popoverVC.delegate = self
            let popover = NSPopover()
            popover.contentViewController = popoverVC
            popover.behavior = .transient
            popover.show(relativeTo: rect, of: headerView, preferredEdge: .maxY)
            return
        }
        guard let idx = colIndex(from: colId), idx < columns.count else { return }
        let category = columnCategories[idx]
        let rawDataType = columns[idx].dataType
        let existing = columnFilterController.filter(forColumn: colId)

        let distinct = columnFilterController.distinctValues(
            forColumnIndex: idx, excludingColumnId: colId, category: category
        )
        // Reference size for width/height caps = the results pane (the table's
        // enclosing scroll view), falling back to the window, then a default.
        let referenceSize = headerView.enclosingScrollView?.bounds.size
            ?? headerView.window?.frame.size
            ?? CGSize(width: 800, height: 600)

        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks,
            referenceSize: referenceSize,
            counts: distinct.counts,
            loadedRowCount: rows.count,
            hasMore: hasMore
        )
        popoverVC.filterDelegate = self

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popoverVC.hostPopover = popover
        popover.show(relativeTo: rect, of: headerView, preferredEdge: .maxY)
    }
}

// MARK: - TagFunnelPopoverDelegate

extension ResultsGridVC: TagFunnelPopoverDelegate {
    func tagFunnelPopover(_ popover: TagFunnelPopoverVC, didApply values: Set<String>?) {
        // Defense in depth alongside the popover's own `!checked.isEmpty`
        // guard on Apply: a filter with an empty `values` array must never
        // reach `activeFilters` — it would count toward "N filters" while
        // matching nothing (the engine ignores it, but the reset button and
        // filter count would lie about there being an active funnel).
        if let values, !values.isEmpty {
            columnFilterController.setFilter(
                ColumnFilter(columnName: TagFunnel.columnId, op: .isAnyOf, value: "",
                             value2: nil, values: Array(values), dataType: "tag"),
                forColumn: TagFunnel.columnId)
        } else {
            columnFilterController.clearFilter(forColumn: TagFunnel.columnId)
        }
        refreshColumnFilters()
    }
}
