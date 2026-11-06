import AppKit

// MARK: - Sort Controller Delegate

protocol ResultsSortControllerDelegate: AnyObject {
    var sortableRows: ResultTable { get }
    var sortableColumnCategories: [PGTypeCategory] { get }
    func sortControllerDidSort(unfilteredDisplayRows: [Int], isSorted: Bool)
    func sortControllerDidReset(unfilteredDisplayRows: [Int])
}

// MARK: - ResultsSortController

/// Sorting compares RAW values, never the escaped display text.
///
/// The grid escapes hostile scalars for DISPLAY only (`ResultCellText.rendered`
/// → `DisplayEscape`). Comparing the escaped form would order by the token
/// spelling — every value with a leading space would collate under `<`, not
/// under the space — so the comparisons below read the raw cell text off the model.
class ResultsSortController: NSObject {

    enum SortDirection {
        case ascending, descending
    }

    private let tableView: NSTableView
    private let resetSortButton: NSButton

    // Sort state
    private(set) var currentSortColumn: String?
    private var currentSortAscending = true
    private var sortClickCount = 0

    /// Sort direction per column identifier, for header view drawing.
    private(set) var sortDirections: [String: SortDirection] = [:]

    weak var delegate: ResultsSortControllerDelegate?

    init(tableView: NSTableView, resetSortButton: NSButton) {
        self.tableView = tableView
        self.resetSortButton = resetSortButton
        super.init()
    }

    // MARK: - Sort Descriptors Changed

    func handleSortDescriptorsChanged(_ oldDescriptors: [NSSortDescriptor]) {
        // `adoptSortState` sets the descriptors itself; the rows it adopts are
        // already in that order.
        guard !isAdoptingSortState else { return }
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else {
            resetSort()
            return
        }

        if key == currentSortColumn {
            sortClickCount += 1
            if sortClickCount >= 3 {
                resetSort()
                return
            }
        } else {
            currentSortColumn = key
            sortClickCount = 1
        }

        currentSortAscending = descriptor.ascending
        applySortAndNotify()
    }

    // MARK: - Apply Sort

    private func applySortAndNotify() {
        guard let delegate = delegate else { return }

        guard let sortKey = currentSortColumn else {
            let displayRows = Array(0..<delegate.sortableRows.rowCount)
            resetSortButton.isHidden = true
            updateSortIndicators()
            delegate.sortControllerDidReset(unfilteredDisplayRows: displayRows)
            return
        }

        guard let unfilteredDisplayRows = sortedOrder(column: sortKey, ascending: currentSortAscending) else { return }

        resetSortButton.isHidden = false
        updateSortIndicators()
        delegate.sortControllerDidSort(unfilteredDisplayRows: unfilteredDisplayRows, isSorted: true)
    }

    /// The delegate's rows in the order of a sort by `column`, or nil when
    /// `column` is not a data column. Changes no state.
    func sortedOrder(column: String, ascending: Bool) -> [Int]? {
        guard let delegate, let sortIdx = colIndex(from: column) else { return nil }
        let categories = delegate.sortableColumnCategories
        let category = sortIdx < categories.count ? categories[sortIdx] : .string
        let kind: ResultsSortKeys.Kind
        switch category {
        case .numeric: kind = .numeric
        case .boolean: kind = .boolean
        default: kind = .text
        }
        return ResultsSortKeys.order(rows: delegate.sortableRows, column: sortIdx, kind: kind, ascending: ascending)
    }

    // MARK: - Adopt a Saved Sort

    private var isAdoptingSortState = false

    /// Take on a sort the caller has already applied to its rows, for a grid
    /// state put back on a card switch: the header, the indicators and the
    /// Reset Sort button show it, and nothing sorts or notifies. The state
    /// matches what a header click on `column` leaves (`sortClickCount` 1).
    func adoptSortState(column: String, ascending: Bool) {
        currentSortColumn = column
        currentSortAscending = ascending
        sortClickCount = 1
        isAdoptingSortState = true
        tableView.sortDescriptors = [NSSortDescriptor(key: column, ascending: ascending)]
        isAdoptingSortState = false
        resetSortButton.isHidden = false
        updateSortIndicators()
    }

    // MARK: - Reset Sort

    @objc func resetSort() {
        guard let delegate = delegate else { return }
        currentSortColumn = nil
        sortClickCount = 0
        tableView.sortDescriptors = []
        let displayRows = Array(0..<delegate.sortableRows.rowCount)
        resetSortButton.isHidden = true
        updateSortIndicators()
        delegate.sortControllerDidReset(unfilteredDisplayRows: displayRows)
    }

    /// Clears sort state without triggering a delegate callback (used during showResult/clear).
    func clearSortState() {
        currentSortColumn = nil
        sortClickCount = 0
        sortDirections.removeAll()
        resetSortButton.isHidden = true
        (tableView.headerView as? FilterableHeaderView)?.sortDirections = [:]
    }

    // MARK: - Re-apply After Data Change

    /// Re-applies the current sort after new rows are appended.
    func reapplySortIfActive() {
        guard currentSortColumn != nil else { return }
        applySortAndNotify()
    }

    // MARK: - Sort Indicators

    private func updateSortIndicators() {
        sortDirections.removeAll()
        if let col = currentSortColumn {
            sortDirections[col] = currentSortAscending ? .ascending : .descending
        }
        // Clear any old indicator images (we now draw manually in the header view)
        for col in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: col)
        }
        // Trigger header view redraw
        (tableView.headerView as? FilterableHeaderView)?.sortDirections = sortDirections
    }
}
