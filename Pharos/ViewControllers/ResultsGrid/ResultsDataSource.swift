import AppKit
import Combine

// MARK: - Newline Flattening

private extension String {
    /// Replaces newlines with a visible ↵ indicator so multi-line data
    /// displays as a single line in the results grid.
    var flattenedForCell: String {
        guard contains(where: \.isNewline) else { return self }
        return replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
    }
}

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
    /// Type-appropriate unselected text color (purple for temporal, tertiary
    /// for NULL, blue for numeric, etc.). Setter keeps `textField.textColor` in
    /// sync when not selected — callers no longer assign textField directly.
    var normalTextColor: NSColor = .labelColor {
        didSet { updateTextColor() }
    }

    /// True when this cell is part of the active cell-mode selection. Setter
    /// flips text color between white (selected) and `normalTextColor`. The
    /// background fill is managed externally by the data source so it can
    /// coordinate precedence with find-match highlighting.
    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateTextColor()
        }
    }

    private func updateTextColor() {
        // Row-emphasis (.emphasized) wins when NSTableView sets it via
        // selectRowIndexes (row-number-column selection). Cell-mode selection
        // never sets .emphasized, so isSelected drives the color.
        if backgroundStyle == .emphasized {
            textField?.textColor = .alternateSelectedControlTextColor
        } else {
            textField?.textColor = isSelected ? .white : normalTextColor
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }
}

// MARK: - ResultsDataSource

@MainActor
class ResultsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView: NSTableView

    // Data state (pushed by VC)
    var columns: [ColumnDef] = [] {
        didSet { rebuildColumnIndex() }
    }
    var rows: [[AnyCodable]] = []
    var displayRows: [Int] = []
    var columnCategories: [PGTypeCategory] = []

    // MARK: - Hot-path Caches

    /// Map of column identifier (raw) → tableColumn index. Rebuilt when
    /// `columns` changes. Replaces a per-cell O(N) scan via
    /// `tableView.column(withIdentifier:)` in viewFor.
    private var columnIdToIndex: [String: Int] = [:]

    /// Cached display strings + fonts so the per-cell render path doesn't
    /// re-read `AppStateManager.shared.settings` and rebuild fonts on every
    /// cell realization. Refreshed via a single Combine sink on the settings
    /// publisher.
    private var nullDisplayString: String = NullDisplay.uppercase.rawValue
    private var boolTrueString: String = BoolDisplay.trueFalse.trueString
    private var boolFalseString: String = BoolDisplay.trueFalse.falseString
    private var regularFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var italicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
    private var rownumFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private var settingsCancellable: AnyCancellable?

    private func rebuildColumnIndex() {
        // Note: this is keyed by column NAME, but viewFor receives the
        // tableColumn whose identifier is also the column name. The dict's
        // values are the index into tableView.tableColumns — which always
        // includes the leading __rownum__ column. We build by reading the
        // live tableColumns rather than `columns` so the indexing matches
        // what viewFor needs.
        var map: [String: Int] = [:]
        for (i, col) in tableView.tableColumns.enumerated() {
            map[col.identifier.rawValue] = i
        }
        columnIdToIndex = map
    }

    private func applySettingsSnapshot(_ settings: AppSettings) {
        nullDisplayString = settings.nullDisplay.rawValue
        boolTrueString = settings.boolDisplay.trueString
        boolFalseString = settings.boolDisplay.falseString
    }

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

        // Prime the display-string caches from current settings and subscribe
        // to future changes (deduped at the publisher so unrelated settings
        // mutations don't refire). Single sink, single source of truth.
        applySettingsSnapshot(AppStateManager.shared.settings)
        settingsCancellable = AppStateManager.shared.$settings
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.applySettingsSnapshot(settings)
                self?.tableView.reloadData()
            }

        // User-driven column reorder doesn't go through pushDataToHelpers, so
        // refresh the colId → index dict on the notification too.
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification, object: tableView
        )
    }

    @objc private func columnDidMove(_ notification: Notification) {
        rebuildColumnIndex()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row < displayRows.count else { return nil }
        let colIdRaw = colId.rawValue

        let cellId = NSUserInterfaceItemIdentifier("ResultCell_\(colIdRaw)")
        let cell: ResultCellView

        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? ResultCellView {
            cell = existing
        } else {
            cell = ResultCellView()
            cell.identifier = cellId
            cell.wantsLayer = true
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.cell?.wraps = false
            textField.cell?.isScrollable = false
            textField.font = regularFont
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

        if colIdRaw == "__rownum__" {
            cell.textField?.stringValue = "\(row + 1)"
            cell.textField?.font = rownumFont
            cell.normalTextColor = .tertiaryLabelColor
        } else {
            let rowData = rows[dataRowIdx]
            if let idx = colIndex(from: colIdRaw), idx < rowData.count {
                let category = idx < columnCategories.count ? columnCategories[idx] : .string
                let value = rowData[idx]
                styleCell(cell, value: value, category: category)
            } else {
                cell.textField?.stringValue = ""
                cell.textField?.font = regularFont
                cell.normalTextColor = .labelColor
            }
        }

        // Find + selection state. Compute once, share both branches — the old
        // path recomputed isFindHighlighted (and the contains-checks behind it)
        // in two places per cell render.
        let cellColumnIndex = columnIdToIndex[colIdRaw] ?? -1
        let isCurrentMatch = isFindVisible && currentMatchRow == row && currentMatchColId == colIdRaw
        let isOtherMatch: Bool
        if isFindVisible && !findMatchSet.isEmpty && !isCurrentMatch {
            isOtherMatch = findMatchSet.contains(CellAddress(row: row, colId: colIdRaw))
        } else {
            isOtherMatch = false
        }
        let isFindHighlighted = isCurrentMatch || isOtherMatch
        let isInSelection = cellSelection?.contains(CellPosition(row: row, column: cellColumnIndex)) ?? false

        // Background precedence: current find match > other find match >
        // selection > clear. Assigned exactly once.
        if isCurrentMatch {
            cell.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.4).cgColor
        } else if isOtherMatch {
            cell.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        } else if isInSelection {
            cell.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        } else {
            cell.layer?.backgroundColor = nil
        }

        // Clear stale borders from recycled cells
        cell.layer?.borderWidth = 0
        cell.layer?.borderColor = nil

        // Always assign so a recycled cell can't carry stale selected-state
        // into a non-selected slot. Find-match cells suppress the white text
        // override even when within the selection rectangle.
        cell.isSelected = isInSelection && !isFindHighlighted

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

                let isInSelection = cellSelection?.contains(CellPosition(row: row, column: colIdx)) ?? false
                if !isFindHighlighted {
                    cell.layer?.backgroundColor = isInSelection
                        ? NSColor.selectedContentBackgroundColor.cgColor
                        : nil
                }
                cell.isSelected = isInSelection && !isFindHighlighted
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
            textField.stringValue = nullDisplayString
            textField.font = italicFont
            cell.normalTextColor = .tertiaryLabelColor
            return
        }

        textField.font = regularFont

        // Newline flattening allocates and scans the string. Only strings,
        // JSON, and arrays can plausibly contain newlines; numeric/boolean/
        // temporal columns skip the scan entirely.
        let raw = value.displayString
        textField.stringValue = (category == .string || category == .json || category == .array)
            ? raw.flattenedForCell
            : raw

        let color: NSColor
        switch category {
        case .numeric:
            color = .systemBlue
        case .boolean:
            let str = textField.stringValue.lowercased()
            if str == "t" || str == "true" {
                textField.stringValue = boolTrueString
                color = .systemGreen
            } else if str == "f" || str == "false" {
                textField.stringValue = boolFalseString
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
    }
}
