import AppKit

// MARK: - Find Match Address

struct CellAddress: Hashable {
    let row: Int
    let colId: String
}

// MARK: - Data Source Delegate

protocol ResultsDataSourceDelegate: AnyObject {
    func dataSourceSortDescriptorsDidChange(_ oldDescriptors: [NSSortDescriptor])
    func dataSourceSelectionDidChange()
}

// MARK: - ResultCellView

private class ResultCellView: NSTableCellView {
    var normalTextColor: NSColor = .labelColor

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // In row mode, NSTableView sets .emphasized → use white text on blue.
            // In cell mode we never call selectRowIndexes, so .emphasized is never set.
            textField?.textColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : normalTextColor
        }
    }
}

// MARK: - ResultsDataSource

class ResultsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView: NSTableView

    // Data state (pushed by VC)
    var columns: [ColumnDef] = []
    var rows: [[String: AnyCodable]] = []
    var displayRows: [Int] = []
    var columnCategories: [String: PGTypeCategory] = [:]

    // Find highlight state (pushed by VC after find operations)
    var isFindVisible = false
    var findMatchSet: Set<CellAddress> = Set()
    var currentMatchRow: Int = -1
    var currentMatchColId: String?

    // Cell selection state (pushed by VC)
    var cellSelection: CellSelectionState?

    weak var delegate: ResultsDataSourceDelegate?

    init(tableView: NSTableView) {
        self.tableView = tableView
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row < displayRows.count else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("ResultCell_\(colId.rawValue)")
        let cell: ResultCellView

        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? ResultCellView {
            cell = existing
        } else {
            cell = ResultCellView()
            cell.identifier = cellId
            cell.wantsLayer = true
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let dataRowIdx = displayRows[row]

        if colId.rawValue == "__rownum__" {
            cell.textField?.stringValue = "\(row + 1)"
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.normalTextColor = .tertiaryLabelColor
            cell.textField?.textColor = .tertiaryLabelColor
        } else {
            let rowData = rows[dataRowIdx]
            let category = columnCategories[colId.rawValue] ?? .string
            if let value = rowData[colId.rawValue] {
                styleCell(cell, value: value, category: category)
            } else {
                cell.textField?.stringValue = ""
                cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                cell.normalTextColor = .labelColor
                cell.textField?.textColor = .labelColor
            }
        }

        // Find highlighting
        if isFindVisible && !findMatchSet.isEmpty {
            let addr = CellAddress(row: row, colId: colId.rawValue)
            let isCurrentMatch = currentMatchRow == row && currentMatchColId == colId.rawValue

            if isCurrentMatch {
                cell.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.4).cgColor
            } else if findMatchSet.contains(addr) {
                cell.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
            } else {
                cell.layer?.backgroundColor = nil
            }
        } else {
            cell.layer?.backgroundColor = nil
        }

        // Clear stale borders from recycled cells
        cell.layer?.borderWidth = 0
        cell.layer?.borderColor = nil

        // Cell selection: blue fill + white text (overlay handles intercell gaps + border)
        let colIndex = tableColumn.map { tableView.column(withIdentifier: $0.identifier) } ?? -1
        if let selection = cellSelection, selection.contains(CellPosition(row: row, column: colIndex)) {
            let isFindHighlighted = isFindVisible && !findMatchSet.isEmpty
                && (findMatchSet.contains(CellAddress(row: row, colId: colId.rawValue))
                    || (currentMatchRow == row && currentMatchColId == colId.rawValue))
            if !isFindHighlighted {
                cell.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
                cell.normalTextColor = .white
                cell.textField?.textColor = .white
            }
        }

        return cell
    }

    // MARK: - Cell Selection Fast Path

    /// Iterates visible cells and updates fill + text color for cell selection
    /// without calling reloadData(). Used during drag for smooth updates.
    func updateVisibleCellSelectionAppearance() {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.length > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            for colIdx in 0..<tableView.numberOfColumns {
                guard let cell = tableView.view(atColumn: colIdx, row: row, makeIfNecessary: false) as? ResultCellView else { continue }
                let colId = tableView.tableColumns[colIdx].identifier.rawValue
                let isFindHighlighted = isFindVisible && !findMatchSet.isEmpty
                    && (findMatchSet.contains(CellAddress(row: row, colId: colId))
                        || (currentMatchRow == row && currentMatchColId == colId))

                if let selection = cellSelection, selection.contains(CellPosition(row: row, column: colIdx)) {
                    if !isFindHighlighted {
                        cell.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
                        cell.textField?.textColor = .white
                    }
                } else {
                    if !isFindHighlighted {
                        cell.layer?.backgroundColor = nil
                    }
                    cell.textField?.textColor = cell.normalTextColor
                }
            }
        }

        CATransaction.commit()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        delegate?.dataSourceSortDescriptorsDidChange(oldDescriptors)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.dataSourceSelectionDidChange()
    }

    // MARK: - Cell Styling

    private func styleCell(_ cell: ResultCellView, value: AnyCodable, category: PGTypeCategory) {
        guard let textField = cell.textField else { return }

        if value.isNull {
            textField.stringValue = AppStateManager.shared.settings.nullDisplay.rawValue
            textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
            cell.normalTextColor = .tertiaryLabelColor
            textField.textColor = .tertiaryLabelColor
            return
        }

        textField.stringValue = value.displayString
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        let color: NSColor
        switch category {
        case .numeric:
            color = .systemBlue
        case .boolean:
            let str = value.displayString.lowercased()
            let boolDisplay = AppStateManager.shared.settings.boolDisplay
            if str == "t" || str == "true" {
                textField.stringValue = boolDisplay.trueString
                color = .systemGreen
            } else if str == "f" || str == "false" {
                textField.stringValue = boolDisplay.falseString
                color = .systemRed
            } else {
                color = .labelColor
            }
        case .temporal:
            color = .systemPurple
        case .json:
            color = .systemOrange
        case .array:
            color = .secondaryLabelColor
        case .string:
            color = .labelColor
        }
        cell.normalTextColor = color
        textField.textColor = color
    }
}
