import AppKit

// MARK: - ResultsFindControllerDelegate

extension ResultsGridVC: ResultsFindControllerDelegate {
    var findRows: [[String: AnyCodable]] { rows }
    var findColumns: [ColumnDef] { columns }
    var findUnfilteredDisplayRows: [Int] { unfilteredDisplayRows }

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
        scrollViewTopToFindBar.isActive = visible
        scrollViewTopToToolbar.isActive = !visible
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
    var sortableRows: [[String: AnyCodable]] { rows }
    var sortableColumnCategories: [String: PGTypeCategory] { columnCategories }

    func sortControllerDidSort(unfilteredDisplayRows newUnfiltered: [Int], isSorted: Bool) {
        unfilteredDisplayRows = newUnfiltered
        // Re-apply find filter on new sort order if active
        if findController.isFindVisible {
            findController.findFieldChanged(findField)
        } else {
            displayRows = newUnfiltered
            pushDataToHelpers()
            tableView.reloadData()
        }
        updateStatusBarText()
    }

    func sortControllerDidReset(unfilteredDisplayRows newUnfiltered: [Int]) {
        unfilteredDisplayRows = newUnfiltered
        if findController.isFindVisible {
            findController.findFieldChanged(findField)
        } else {
            displayRows = newUnfiltered
            pushDataToHelpers()
            tableView.reloadData()
        }
        updateStatusBarText()
    }
}

// MARK: - ResultsCopyExportDelegate

extension ResultsGridVC: ResultsCopyExportDelegate {
    func copyExportWindow() -> NSWindow? {
        view.window
    }
}
