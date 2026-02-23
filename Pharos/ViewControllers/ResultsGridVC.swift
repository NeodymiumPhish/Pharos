import AppKit

// MARK: - PG Type Classification

private enum PGTypeCategory {
    case numeric
    case boolean
    case temporal
    case array
    case json
    case string

    init(dataType: String) {
        let dt = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        if dt.hasSuffix("[]") || dt.hasPrefix("_") {
            self = .array
            return
        }
        switch dt {
        case "boolean", "bool":
            self = .boolean
        case "smallint", "int2", "integer", "int", "int4", "bigint", "int8",
             "real", "float4", "double precision", "float8",
             "numeric", "decimal", "money",
             "serial", "bigserial", "smallserial", "oid":
            self = .numeric
        case "json", "jsonb":
            self = .json
        case "date", "time", "timetz", "timestamp", "timestamptz",
             "timestamp without time zone", "timestamp with time zone",
             "time without time zone", "time with time zone", "interval":
            self = .temporal
        default:
            if dt.contains("int") || dt.contains("float") || dt.contains("numeric") || dt.contains("decimal") {
                self = .numeric
            } else {
                self = .string
            }
        }
    }
}

// MARK: - NSFont Italic Extension

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Find Match Address

private struct CellAddress: Hashable {
    let row: Int
    let colId: String
}

// MARK: - Copy Data

private struct CopyData {
    let columnNames: [String]
    let rows: [[String]]
}

// MARK: - ResultsGridVC

/// Displays query results in an NSTableView with sorting, find, copy formats, and pagination.
class ResultsGridVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Run a query to see results")

    // Data
    private var columns: [ColumnDef] = []
    private var rows: [[String: AnyCodable]] = []
    private var rowCount: Int = 0
    private var hasMore: Bool = false
    private var executionTimeMs: UInt64 = 0
    private var columnCategories: [String: PGTypeCategory] = [:]

    // Sort state
    private var displayRows: [Int] = []
    private var currentSortColumn: String?
    private var currentSortAscending = true
    private var sortClickCount = 0

    // Find state
    private let findBar = NSView()
    private let findField = NSSearchField()
    private let findCountLabel = NSTextField(labelWithString: "")
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private var isFindVisible = false
    private var findMatches: [(row: Int, colId: String)] = []
    private var findMatchSet: Set<CellAddress> = Set()
    private var currentMatchIndex: Int = -1

    // Load more
    private let loadMoreBar = NSView()
    private let loadMoreButton = NSButton(title: "Load More Rows", target: nil, action: nil)
    private let loadMoreSpinner = NSProgressIndicator()
    private var isLoadingMore = false

    // Layout constraints to toggle
    private var scrollViewTopToStatusBar: NSLayoutConstraint!
    private var scrollViewTopToFindBar: NSLayoutConstraint!
    private var scrollViewBottomToLoadMore: NSLayoutConstraint!
    private var scrollViewBottomToContainer: NSLayoutConstraint!

    // Pagination callback
    var onLoadMore: (() -> Void)?

    // Formatters
    private static let rowCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        self.view = container

        // Status bar at top
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.font = .systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        statusBar.isHidden = true

        // Find bar (hidden initially)
        setupFindBar()

        // Table view
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.menu = buildContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder

        // Empty state
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center

        // Load more bar
        setupLoadMoreBar()

        container.addSubview(statusBar)
        container.addSubview(findBar)
        container.addSubview(scrollView)
        container.addSubview(loadMoreBar)
        container.addSubview(emptyLabel)

        // Toggleable constraints
        scrollViewTopToStatusBar = scrollView.topAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: 4)
        scrollViewTopToFindBar = scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 2)
        scrollViewBottomToContainer = scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        scrollViewBottomToLoadMore = scrollView.bottomAnchor.constraint(equalTo: loadMoreBar.topAnchor)

        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            findBar.topAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: 2),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBar.heightAnchor.constraint(equalToConstant: 28),

            scrollViewTopToStatusBar,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollViewBottomToContainer,

            loadMoreBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            loadMoreBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            loadMoreBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            loadMoreBar.heightAnchor.constraint(equalToConstant: 32),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    // MARK: - Find Bar Setup

    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true

        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find in results…"
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findFieldChanged(_:))
        findField.font = .systemFont(ofSize: 12)
        findField.delegate = self

        findCountLabel.translatesAutoresizingMaskIntoConstraints = false
        findCountLabel.font = .systemFont(ofSize: 11)
        findCountLabel.textColor = .secondaryLabelColor
        findCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        findPrevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        findPrevButton.bezelStyle = .recessed
        findPrevButton.isBordered = false
        findPrevButton.target = self
        findPrevButton.action = #selector(findPrevious(_:))
        findPrevButton.translatesAutoresizingMaskIntoConstraints = false

        findNextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        findNextButton.bezelStyle = .recessed
        findNextButton.isBordered = false
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findNextButton.translatesAutoresizingMaskIntoConstraints = false

        findCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        findCloseButton.bezelStyle = .recessed
        findCloseButton.isBordered = false
        findCloseButton.target = self
        findCloseButton.action = #selector(closeFind(_:))
        findCloseButton.translatesAutoresizingMaskIntoConstraints = false

        findBar.addSubview(findField)
        findBar.addSubview(findCountLabel)
        findBar.addSubview(findPrevButton)
        findBar.addSubview(findNextButton)
        findBar.addSubview(findCloseButton)

        NSLayoutConstraint.activate([
            findField.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findField.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            findCountLabel.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 8),
            findCountLabel.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),

            findPrevButton.leadingAnchor.constraint(equalTo: findCountLabel.trailingAnchor, constant: 4),
            findPrevButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findPrevButton.widthAnchor.constraint(equalToConstant: 20),

            findNextButton.leadingAnchor.constraint(equalTo: findPrevButton.trailingAnchor, constant: 2),
            findNextButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findNextButton.widthAnchor.constraint(equalToConstant: 20),

            findCloseButton.leadingAnchor.constraint(greaterThanOrEqualTo: findNextButton.trailingAnchor, constant: 8),
            findCloseButton.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            findCloseButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findCloseButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Load More Bar Setup

    private func setupLoadMoreBar() {
        loadMoreBar.translatesAutoresizingMaskIntoConstraints = false
        loadMoreBar.isHidden = true

        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreTapped)
        loadMoreButton.translatesAutoresizingMaskIntoConstraints = false

        loadMoreSpinner.style = .spinning
        loadMoreSpinner.controlSize = .small
        loadMoreSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadMoreSpinner.isHidden = true

        loadMoreBar.addSubview(loadMoreButton)
        loadMoreBar.addSubview(loadMoreSpinner)

        NSLayoutConstraint.activate([
            loadMoreButton.centerXAnchor.constraint(equalTo: loadMoreBar.centerXAnchor),
            loadMoreButton.centerYAnchor.constraint(equalTo: loadMoreBar.centerYAnchor),

            loadMoreSpinner.leadingAnchor.constraint(equalTo: loadMoreButton.trailingAnchor, constant: 8),
            loadMoreSpinner.centerYAnchor.constraint(equalTo: loadMoreBar.centerYAnchor),
        ])
    }

    // MARK: - Public API

    func showResult(_ result: QueryResult) {
        self.columns = result.columns
        self.rows = result.rows
        self.rowCount = result.rowCount
        self.hasMore = result.hasMore
        self.executionTimeMs = result.executionTimeMs

        // Precompute type categories
        columnCategories = Dictionary(uniqueKeysWithValues: columns.map {
            ($0.name, PGTypeCategory(dataType: $0.dataType))
        })

        // Initialize display order
        displayRows = Array(0..<rows.count)
        currentSortColumn = nil
        sortClickCount = 0

        rebuildColumns()
        tableView.reloadData()
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        statusBar.isHidden = false

        updateLoadMoreVisibility()
        updateStatusBarText()

        // Close find if open
        if isFindVisible {
            closeFind(nil)
        }
    }

    func appendRows(from result: QueryResult) {
        let oldCount = rows.count
        rows.append(contentsOf: result.rows)
        rowCount = rows.count
        hasMore = result.hasMore

        // Extend displayRows with new indices
        let newIndices = Array(oldCount..<rows.count)
        displayRows.append(contentsOf: newIndices)

        // Re-apply sort if active
        if currentSortColumn != nil {
            applySortAndReload()
        } else {
            tableView.reloadData()
        }

        updateLoadMoreVisibility()
        updateStatusBarText()
        setLoadingMore(false)
    }

    func showExecuteResult(_ result: ExecuteResult) {
        clear()
        statusBar.isHidden = false
        let timeStr = formatDuration(result.executionTimeMs)
        let count = formatRowCount(Int(result.rowsAffected))
        statusBar.stringValue = "\(count) row\(result.rowsAffected == 1 ? "" : "s") affected in \(timeStr)"
    }

    func showError(_ message: String) {
        clear()
        emptyLabel.stringValue = message
        emptyLabel.textColor = .systemRed
        emptyLabel.isHidden = false
    }

    func clear() {
        columns = []
        rows = []
        displayRows = []
        rowCount = 0
        hasMore = false
        executionTimeMs = 0
        columnCategories = [:]
        currentSortColumn = nil
        sortClickCount = 0

        // Remove all table columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }
        tableView.reloadData()
        emptyLabel.stringValue = "Run a query to see results"
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = false
        scrollView.isHidden = true
        statusBar.isHidden = true

        updateLoadMoreVisibility()

        if isFindVisible {
            closeFind(nil)
        }
    }

    func setLoadingMore(_ loading: Bool) {
        isLoadingMore = loading
        loadMoreButton.isEnabled = !loading
        loadMoreSpinner.isHidden = !loading
        if loading {
            loadMoreSpinner.startAnimation(nil)
        } else {
            loadMoreSpinner.stopAnimation(nil)
        }
    }

    // MARK: - Column Setup

    private func rebuildColumns() {
        // Remove existing columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        // Row number column
        let rowNumCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rownum__"))
        rowNumCol.title = "#"
        rowNumCol.width = 40
        rowNumCol.minWidth = 30
        rowNumCol.maxWidth = 60
        tableView.addTableColumn(rowNumCol)

        // Data columns
        for colDef in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colDef.name))
            col.title = colDef.name
            col.width = estimateColumnWidth(colDef)
            col.minWidth = 50
            col.maxWidth = 600

            // Header: "name  type" with type styled lighter
            let attrStr = NSMutableAttributedString(
                string: colDef.name,
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]
            )
            attrStr.append(NSAttributedString(
                string: "  \(colDef.dataType)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            col.headerCell.attributedStringValue = attrStr

            // Sort descriptor for click-to-sort
            col.sortDescriptorPrototype = NSSortDescriptor(key: colDef.name, ascending: true)

            tableView.addTableColumn(col)
        }
    }

    private func estimateColumnWidth(_ col: ColumnDef) -> CGFloat {
        let nameWidth = CGFloat(col.name.count) * 8 + 20
        let typeWidth: CGFloat
        switch col.dataType.lowercased() {
        case "boolean", "bool": typeWidth = 60
        case "integer", "int", "int4", "smallint", "int2": typeWidth = 80
        case "bigint", "int8": typeWidth = 100
        case "uuid": typeWidth = 260
        case "timestamp", "timestamptz",
             "timestamp without time zone", "timestamp with time zone": typeWidth = 180
        case "date": typeWidth = 100
        default: typeWidth = 150
        }
        return max(nameWidth, typeWidth)
    }

    // MARK: - Status Bar

    private func updateStatusBarText() {
        let rowStr = formatRowCount(displayRows.count)
        let timeStr = formatDuration(executionTimeMs)
        let moreStr = hasMore ? " (more available)" : ""

        if isFindVisible && !findMatches.isEmpty {
            statusBar.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr) \u{2022} \(findMatches.count) match\(findMatches.count == 1 ? "" : "es")\(moreStr)"
        } else {
            statusBar.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr)\(moreStr)"
        }
    }

    // MARK: - Load More

    private func updateLoadMoreVisibility() {
        loadMoreBar.isHidden = !hasMore
        scrollViewBottomToLoadMore.isActive = hasMore
        scrollViewBottomToContainer.isActive = !hasMore
    }

    @objc private func loadMoreTapped() {
        onLoadMore?()
    }

    // MARK: - Sorting

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
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
        applySortAndReload()
    }

    private func applySortAndReload() {
        guard let sortKey = currentSortColumn else {
            displayRows = Array(0..<rows.count)
            tableView.reloadData()
            return
        }

        let category = columnCategories[sortKey] ?? .string
        let ascending = currentSortAscending

        displayRows.sort { a, b in
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
                let bA = (valA?.value as? Bool) ?? false
                let bB = (valB?.value as? Bool) ?? false
                result = !bA && bB // false < true
            default:
                let sA = valA?.displayString ?? ""
                let sB = valB?.displayString ?? ""
                result = sA.localizedStandardCompare(sB) == .orderedAscending
            }

            return ascending ? result : !result
        }

        updateSortIndicators()
        tableView.reloadData()
    }

    private func resetSort() {
        currentSortColumn = nil
        sortClickCount = 0
        tableView.sortDescriptors = []
        displayRows = Array(0..<rows.count)
        updateSortIndicators()
        tableView.reloadData()
    }

    private func numericValue(_ value: AnyCodable?) -> Double {
        guard let v = value?.value else { return 0 }
        if let i = v as? Int64 { return Double(i) }
        if let d = v as? Double { return d }
        if let s = v as? String, let d = Double(s) { return d }
        return 0
    }

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

    // MARK: - Cell Styling

    private func styleCell(_ textField: NSTextField, value: AnyCodable, category: PGTypeCategory) {
        if value.isNull {
            textField.stringValue = "NULL"
            textField.textColor = .tertiaryLabelColor
            textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).withTraits(.italic)
            return
        }

        textField.stringValue = value.displayString
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        switch category {
        case .numeric:
            textField.textColor = .systemBlue
        case .boolean:
            if let boolVal = value.value as? Bool {
                textField.textColor = boolVal ? .systemGreen : .systemRed
            } else {
                textField.textColor = .labelColor
            }
        case .array:
            textField.textColor = .secondaryLabelColor
        default:
            textField.textColor = .labelColor
        }
    }

    // MARK: - Find

    @objc func showFind() {
        guard !rows.isEmpty else { return }
        isFindVisible = true
        findBar.isHidden = false
        scrollViewTopToStatusBar.isActive = false
        scrollViewTopToFindBar.isActive = true
        findField.window?.makeFirstResponder(findField)
    }

    @objc private func closeFind(_ sender: Any?) {
        isFindVisible = false
        findBar.isHidden = true
        findField.stringValue = ""
        findMatches = []
        findMatchSet = Set()
        currentMatchIndex = -1
        findCountLabel.stringValue = ""
        scrollViewTopToFindBar.isActive = false
        scrollViewTopToStatusBar.isActive = true
        tableView.reloadData()
        updateStatusBarText()
    }

    @objc private func findFieldChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.lowercased()
        guard !query.isEmpty else {
            findMatches = []
            findMatchSet = Set()
            currentMatchIndex = -1
            findCountLabel.stringValue = ""
            tableView.reloadData()
            updateStatusBarText()
            return
        }

        findMatches = []
        findMatchSet = Set()
        let colIds = columns.map(\.name)

        for (displayIdx, rowIdx) in displayRows.enumerated() {
            let rowData = rows[rowIdx]
            for colId in colIds {
                if let value = rowData[colId], !value.isNull {
                    if value.displayString.lowercased().contains(query) {
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

        tableView.reloadData()
        updateStatusBarText()
    }

    @objc private func findNext(_ sender: Any?) {
        guard !findMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % findMatches.count
        findCountLabel.stringValue = "\(currentMatchIndex + 1) of \(findMatches.count)"
        scrollToMatch(at: currentMatchIndex)
        tableView.reloadData()
    }

    @objc private func findPrevious(_ sender: Any?) {
        guard !findMatches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + findMatches.count) % findMatches.count
        findCountLabel.stringValue = "\(currentMatchIndex + 1) of \(findMatches.count)"
        scrollToMatch(at: currentMatchIndex)
        tableView.reloadData()
    }

    private func scrollToMatch(at index: Int) {
        guard index >= 0, index < findMatches.count else { return }
        let match = findMatches[index]
        tableView.scrollRowToVisible(match.row)
        if let colIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == match.colId }) {
            tableView.scrollColumnToVisible(colIndex)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row < displayRows.count else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("ResultCell_\(colId.rawValue)")
        let cell: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            cell.wantsLayer = true
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let dataRowIdx = displayRows[row]

        if colId.rawValue == "__rownum__" {
            cell.textField?.stringValue = "\(row + 1)"
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else {
            let rowData = rows[dataRowIdx]
            let category = columnCategories[colId.rawValue] ?? .string
            if let value = rowData[colId.rawValue] {
                styleCell(cell.textField!, value: value, category: category)
            } else {
                cell.textField?.stringValue = ""
                cell.textField?.textColor = .labelColor
                cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            }
        }

        // Find highlighting
        if isFindVisible && !findMatchSet.isEmpty {
            let addr = CellAddress(row: row, colId: colId.rawValue)
            let isCurrentMatch = currentMatchIndex >= 0
                && currentMatchIndex < findMatches.count
                && findMatches[currentMatchIndex].row == row
                && findMatches[currentMatchIndex].colId == colId.rawValue

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

        return cell
    }

    // MARK: - Copy Support

    @objc func copy(_ sender: Any?) {
        copyAsTSV(sender)
    }

    private func gatherCopyData() -> CopyData? {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return nil }

        let colIds = tableView.tableColumns.compactMap { col -> String? in
            let id = col.identifier.rawValue
            return id == "__rownum__" ? nil : id
        }

        var rowData: [[String]] = []
        for row in selectedRows {
            guard row < displayRows.count else { continue }
            let data = rows[displayRows[row]]
            let values = colIds.map { data[$0]?.displayString ?? "" }
            rowData.append(values)
        }

        return CopyData(columnNames: colIds, rows: rowData)
    }

    @objc private func copyAsTSV(_ sender: Any?) {
        guard let data = gatherCopyData() else { return }
        let lines = data.rows.map { $0.joined(separator: "\t") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc private func copyAsCSV(_ sender: Any?) {
        guard let data = gatherCopyData() else { return }
        let header = data.columnNames.map { csvEscape($0) }.joined(separator: ",")
        let rows = data.rows.map { $0.map { csvEscape($0) }.joined(separator: ",") }
        let result = ([header] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @objc private func copyAsMarkdown(_ sender: Any?) {
        guard let data = gatherCopyData() else { return }
        let header = "| " + data.columnNames.joined(separator: " | ") + " |"
        let divider = "| " + data.columnNames.map { _ in "---" }.joined(separator: " | ") + " |"
        let rows = data.rows.map { "| " + $0.joined(separator: " | ") + " |" }
        let result = ([header, divider] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @objc private func copyAsSQLInsert(_ sender: Any?) {
        guard let data = gatherCopyData() else { return }
        let colList = data.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let statements = data.rows.map { row in
            let values = zip(data.columnNames, row).map { (col, val) -> String in
                if val.isEmpty || val == "NULL" { return "NULL" }
                let category = columnCategories[col] ?? .string
                switch category {
                case .numeric:
                    return val
                case .boolean:
                    return val
                default:
                    return "'\(val.replacingOccurrences(of: "'", with: "''"))'"
                }
            }
            return "INSERT INTO table_name (\(colList)) VALUES (\(values.joined(separator: ", ")));"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statements.joined(separator: "\n"), forType: .string)
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy as TSV", action: #selector(copyAsTSV), keyEquivalent: "")
        menu.addItem(withTitle: "Copy as CSV", action: #selector(copyAsCSV), keyEquivalent: "")
        menu.addItem(withTitle: "Copy as Markdown", action: #selector(copyAsMarkdown), keyEquivalent: "")
        menu.addItem(withTitle: "Copy as SQL INSERT", action: #selector(copyAsSQLInsert), keyEquivalent: "")
        return menu
    }

    // MARK: - Formatting

    private func formatDuration(_ ms: UInt64) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        }
        if ms < 10_000 {
            return String(format: "%.2fs", Double(ms) / 1000)
        }
        if ms < 60_000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        let totalSeconds = Double(ms) / 1000
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        if ms < 3_600_000 {
            return seconds >= 0.5
                ? "\(minutes)m \(String(format: "%.0f", seconds))s"
                : "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
    }

    private func formatRowCount(_ count: Int) -> String {
        Self.rowCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

// MARK: - NSSearchFieldDelegate (Find navigation)

extension ResultsGridVC: NSSearchFieldDelegate {
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
