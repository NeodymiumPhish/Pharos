import AppKit

// MARK: - Sort Controller Delegate

protocol ResultsSortControllerDelegate: AnyObject {
    var sortableRows: [[String: AnyCodable]] { get }
    var sortableColumnCategories: [String: PGTypeCategory] { get }
    func sortControllerDidSort(unfilteredDisplayRows: [Int], isSorted: Bool)
    func sortControllerDidReset(unfilteredDisplayRows: [Int])
}

// MARK: - ResultsSortController

class ResultsSortController: NSObject {
    private let tableView: NSTableView
    private let resetSortButton: NSButton

    // Sort state
    private(set) var currentSortColumn: String?
    private var currentSortAscending = true
    private var sortClickCount = 0

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
        let category = categories[sortKey] ?? .string
        let ascending = currentSortAscending

        // Sort all rows
        var unfilteredDisplayRows = Array(0..<rows.count)
        unfilteredDisplayRows.sort { a, b in
            let valA = rows[a][sortKey]
            let valB = rows[b][sortKey]

            // NULLs always sort to end
            if valA?.isNull ?? true {
                if valB?.isNull ?? true { return false }
                return false
            }
            if valB?.isNull ?? true { return true }

            let result: Bool
            switch category {
            case .numeric:
                let dA = numericValue(valA)
                let dB = numericValue(valB)
                result = dA < dB
            case .boolean:
                let sA = (valA?.value as? Bool).map { $0 ? "t" : "f" }
                    ?? (valA?.value as? String) ?? ""
                let sB = (valB?.value as? Bool).map { $0 ? "t" : "f" }
                    ?? (valB?.value as? String) ?? ""
                result = sA < sB // "f" < "t"
            default:
                let sA = valA?.displayString ?? ""
                let sB = valB?.displayString ?? ""
                result = sA.localizedStandardCompare(sB) == .orderedAscending
            }

            return ascending ? result : !result
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
        resetSortButton.isHidden = true
    }

    // MARK: - Re-apply After Data Change

    /// Re-applies the current sort after new rows are appended.
    func reapplySortIfActive() {
        guard currentSortColumn != nil else { return }
        applySortAndNotify()
    }

    // MARK: - Sort Indicators

    private func updateSortIndicators() {
        for col in tableView.tableColumns {
            if col.identifier.rawValue == currentSortColumn {
                let symbolName = currentSortAscending ? "chevron.up" : "chevron.down"
                let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
                tableView.setIndicatorImage(image, in: col)
            } else {
                tableView.setIndicatorImage(nil, in: col)
            }
        }
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
