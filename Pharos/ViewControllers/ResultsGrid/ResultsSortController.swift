import AppKit

// MARK: - Sort Controller Delegate

protocol ResultsSortControllerDelegate: AnyObject {
    var sortableRows: [[AnyCodable]] { get }
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
/// under the space — so the comparisons below read `AnyCodable` off the model.
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
            let rows = delegate.sortableRows
            let displayRows = Array(0..<rows.count)
            resetSortButton.isHidden = true
            updateSortIndicators()
            delegate.sortControllerDidReset(unfilteredDisplayRows: displayRows)
            return
        }

        let rows = delegate.sortableRows
        let categories = delegate.sortableColumnCategories
        guard let sortIdx = colIndex(from: sortKey) else { return }
        let category = sortIdx < categories.count ? categories[sortIdx] : .string
        let ascending = currentSortAscending

        // `less` compares two NON-NULL values. Descending order swaps the
        // arguments rather than negating the result: `!less(a, b)` is true for
        // EQUAL keys in both directions, which is not a strict weak ordering,
        // and `sort` then shuffles ties unpredictably between reloads.
        let less: (AnyCodable, AnyCodable) -> Bool
        switch category {
        case .numeric:
            less = { [unowned self] in self.numericValue($0) < self.numericValue($1) }
        case .boolean:
            less = { a, b in
                let sA = (a.value as? Bool).map { $0 ? "t" : "f" } ?? (a.value as? String) ?? ""
                let sB = (b.value as? Bool).map { $0 ? "t" : "f" } ?? (b.value as? String) ?? ""
                return sA < sB // "f" < "t"
            }
        default:
            less = { $0.displayString.localizedStandardCompare($1.displayString) == .orderedAscending }
        }

        // Sort all rows
        var unfilteredDisplayRows = Array(0..<rows.count)
        unfilteredDisplayRows.sort { a, b in
            let valA: AnyCodable? = sortIdx < rows[a].count ? rows[a][sortIdx] : nil
            let valB: AnyCodable? = sortIdx < rows[b].count ? rows[b][sortIdx] : nil

            // NULLs always sort to end, in either direction
            let nullA = valA?.isNull ?? true
            let nullB = valB?.isNull ?? true
            if nullA || nullB { return !nullA && nullB }
            guard let valA, let valB else { return false }

            return ascending ? less(valA, valB) : less(valB, valA)
        }

        resetSortButton.isHidden = false
        updateSortIndicators()
        delegate.sortControllerDidSort(unfilteredDisplayRows: unfilteredDisplayRows, isSorted: true)
    }

    // MARK: - Reset Sort

    @objc func resetSort() {
        guard let delegate = delegate else { return }
        currentSortColumn = nil
        sortClickCount = 0
        tableView.sortDescriptors = []
        let rows = delegate.sortableRows
        let displayRows = Array(0..<rows.count)
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

    // MARK: - Numeric Helpers

    private func numericValue(_ value: AnyCodable?) -> Double {
        guard let v = value?.value else { return 0 }
        if let i = v as? Int64 { return Double(i) }
        if let d = v as? Double { return d }
        if let s = v as? String, let d = Double(s) { return d }
        return 0
    }
}
