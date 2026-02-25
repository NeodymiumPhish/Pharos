import AppKit

// MARK: - Find Controller Delegate

protocol ResultsFindControllerDelegate: AnyObject {
    var findRows: [[String: AnyCodable]] { get }
    var findColumns: [ColumnDef] { get }
    var findUnfilteredDisplayRows: [Int] { get }
    func findControllerDidUpdateResults(
        displayRows: [Int]?,
        matchSet: Set<CellAddress>,
        currentMatchRow: Int,
        currentMatchColId: String?
    )
    func findControllerDidClose(displayRows: [Int])
    func findControllerDidToggleVisibility(visible: Bool)
    func findControllerUpdateStatusBar()
}

// MARK: - ResultsFindController

class ResultsFindController: NSObject, NSSearchFieldDelegate {

    // Find bar UI references (received at init)
    private let tableView: NSTableView
    private let findBar: NSView
    private let findField: NSSearchField
    private let filterToggleButton: NSButton
    private let findClearButton: NSButton
    private let findCountLabel: NSTextField
    private let findPrevButton: NSButton
    private let findNextButton: NSButton
    private let findCloseButton: NSButton

    // Find state
    private(set) var isFindVisible = false
    private var isFilterMode = false
    private(set) var findMatches: [(row: Int, colId: String)] = []
    private(set) var findMatchSet: Set<CellAddress> = Set()
    private(set) var currentMatchIndex: Int = -1

    weak var delegate: ResultsFindControllerDelegate?

    init(tableView: NSTableView,
         findBar: NSView, findField: NSSearchField,
         filterToggleButton: NSButton, findClearButton: NSButton,
         findCountLabel: NSTextField, findPrevButton: NSButton,
         findNextButton: NSButton, findCloseButton: NSButton) {
        self.tableView = tableView
        self.findBar = findBar
        self.findField = findField
        self.filterToggleButton = filterToggleButton
        self.findClearButton = findClearButton
        self.findCountLabel = findCountLabel
        self.findPrevButton = findPrevButton
        self.findNextButton = findNextButton
        self.findCloseButton = findCloseButton
        super.init()

        // Wire button targets to self
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldChanged(_:))
        filterToggleButton.target = self
        filterToggleButton.action = #selector(filterToggleChanged)
        findClearButton.target = self
        findClearButton.action = #selector(clearFindField)
        findPrevButton.target = self
        findPrevButton.action = #selector(findPrevious(_:))
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findCloseButton.target = self
        findCloseButton.action = #selector(closeFind(_:))
    }

    // MARK: - Show / Hide

    @objc func showFind() {
        guard delegate != nil, !(delegate?.findRows.isEmpty ?? true) else { return }
        if isFindVisible {
            findField.window?.makeFirstResponder(findField)
            return
        }
        isFindVisible = true
        findBar.isHidden = false
        delegate?.findControllerDidToggleVisibility(visible: true)
        findField.window?.makeFirstResponder(findField)
    }

    @objc func showFilter() {
        guard delegate != nil, !(delegate?.findRows.isEmpty ?? true) else { return }
        if !isFindVisible {
            isFindVisible = true
            findBar.isHidden = false
            delegate?.findControllerDidToggleVisibility(visible: true)
        }
        filterToggleButton.state = .on
        isFilterMode = true
        findField.window?.makeFirstResponder(findField)
        if !findField.stringValue.isEmpty {
            findFieldChanged(findField)
        }
    }

    @objc func closeFind(_: Any?) {
        isFindVisible = false
        isFilterMode = false
        filterToggleButton.state = .off
        findBar.isHidden = true
        findField.stringValue = ""
        findMatches = []
        findMatchSet = Set()
        currentMatchIndex = -1
        findCountLabel.stringValue = ""
        findClearButton.isHidden = true

        // Restore unfiltered display
        let displayRows = delegate?.findUnfilteredDisplayRows ?? []
        delegate?.findControllerDidClose(displayRows: displayRows)
        delegate?.findControllerDidToggleVisibility(visible: false)
    }

    // MARK: - Filter Toggle & Clear

    @objc private func filterToggleChanged() {
        isFilterMode = filterToggleButton.state == .on
        findFieldChanged(findField)
    }

    @objc private func clearFindField() {
        findField.stringValue = ""
        findFieldChanged(findField)
    }

    // MARK: - Search Execution

    @objc func findFieldChanged(_ sender: NSSearchField) {
        guard let delegate = delegate else { return }
        let query = sender.stringValue.lowercased()
        findClearButton.isHidden = query.isEmpty

        let rows = delegate.findRows
        let columns = delegate.findColumns
        var displayRows = delegate.findUnfilteredDisplayRows

        guard !query.isEmpty else {
            findMatches = []
            findMatchSet = Set()
            currentMatchIndex = -1
            findCountLabel.stringValue = ""
            delegate.findControllerDidUpdateResults(
                displayRows: displayRows,
                matchSet: Set(),
                currentMatchRow: -1,
                currentMatchColId: nil
            )
            return
        }

        // Find all matching cells and track which rows have matches
        let colIds = columns.map(\.name)
        var matchingRowIndices = Set<Int>()

        findMatches = []
        findMatchSet = Set()

        for (displayIdx, rowIdx) in displayRows.enumerated() {
            let rowData = rows[rowIdx]
            for colId in colIds {
                if let value = rowData[colId], !value.isNull,
                   value.displayString.lowercased().contains(query) {
                    findMatches.append((row: displayIdx, colId: colId))
                    findMatchSet.insert(CellAddress(row: displayIdx, colId: colId))
                    matchingRowIndices.insert(rowIdx)
                }
            }
        }

        // If filter mode, narrow displayRows and rebuild match indices
        if isFilterMode {
            displayRows = delegate.findUnfilteredDisplayRows.filter { matchingRowIndices.contains($0) }

            findMatches = []
            findMatchSet = Set()
            for (displayIdx, rowIdx) in displayRows.enumerated() {
                let rowData = rows[rowIdx]
                for colId in colIds {
                    if let value = rowData[colId], !value.isNull,
                       value.displayString.lowercased().contains(query) {
                        findMatches.append((row: displayIdx, colId: colId))
                        findMatchSet.insert(CellAddress(row: displayIdx, colId: colId))
                    }
                }
            }
        }

        if findMatches.isEmpty {
            currentMatchIndex = -1
            findCountLabel.stringValue = "No matches"
        } else {
            currentMatchIndex = 0
            findCountLabel.stringValue = "1 of \(findMatches.count)"
            scrollToMatch(at: 0)
        }

        let (matchRow, matchColId) = currentMatchAddress
        delegate.findControllerDidUpdateResults(
            displayRows: displayRows,
            matchSet: findMatchSet,
            currentMatchRow: matchRow,
            currentMatchColId: matchColId
        )
    }

    // MARK: - Navigation

    @objc func findNext(_: Any?) {
        guard !findMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % findMatches.count
        findCountLabel.stringValue = "\(currentMatchIndex + 1) of \(findMatches.count)"
        scrollToMatch(at: currentMatchIndex)

        let (matchRow, matchColId) = currentMatchAddress
        delegate?.findControllerDidUpdateResults(
            displayRows: nil,
            matchSet: findMatchSet,
            currentMatchRow: matchRow,
            currentMatchColId: matchColId
        )
    }

    @objc func findPrevious(_: Any?) {
        guard !findMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + findMatches.count) % findMatches.count
        findCountLabel.stringValue = "\(currentMatchIndex + 1) of \(findMatches.count)"
        scrollToMatch(at: currentMatchIndex)

        let (matchRow, matchColId) = currentMatchAddress
        delegate?.findControllerDidUpdateResults(
            displayRows: nil,
            matchSet: findMatchSet,
            currentMatchRow: matchRow,
            currentMatchColId: matchColId
        )
    }

    private func scrollToMatch(at index: Int) {
        guard index >= 0, index < findMatches.count else { return }
        let match = findMatches[index]
        tableView.scrollRowToVisible(match.row)
        if let colIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == match.colId }) {
            tableView.scrollColumnToVisible(colIndex)
        }
    }

    private var currentMatchAddress: (row: Int, colId: String?) {
        if currentMatchIndex >= 0, currentMatchIndex < findMatches.count {
            return (findMatches[currentMatchIndex].row, findMatches[currentMatchIndex].colId)
        }
        return (-1, nil)
    }

    // MARK: - NSSearchFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control == findField else { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false {
                findPrevious(nil)
            } else {
                findNext(nil)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeFind(nil)
            return true
        }
        return false
    }
}
