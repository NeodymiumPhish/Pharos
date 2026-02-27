import AppKit

// MARK: - ResultsGridVC

/// Displays query results in an NSTableView with sorting, find, copy formats, and pagination.
class ResultsGridVC: NSViewController {

    let tableView = ResultsTableView()
    let scrollView = InsetScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Run a query to see results")

    // Helpers
    var dataSource: ResultsDataSource!
    var copyExport: ResultsCopyExport!
    var findController: ResultsFindController!
    var sortController: ResultsSortController!
    var columnFilterController: ResultsColumnFilterController!
    var filterableHeaderView: FilterableHeaderView!
    var cellSelectionController: CellSelectionController!

    // Toolbar
    let toolbarBar = NSView()
    let statusLabel = NSTextField(labelWithString: "")
    let pinSourceLabel = NSTextField(labelWithString: "")
    let historyContextLabel = NSTextField(labelWithString: "")
    let resetSortButton = NSButton()
    let resetFiltersButton = NSButton()
    let pinButton = NSButton()
    let findToolbarButton = NSButton()
    let copyButton = NSButton()
    let exportButton = NSButton()

    // Data
    var columns: [ColumnDef] = []
    var rows: [[String: AnyCodable]] = []
    var hasMore: Bool = false
    var executionTimeMs: UInt64 = 0
    var columnCategories: [String: PGTypeCategory] = [:]

    // Display ordering
    var displayRows: [Int] = []
    var unfilteredDisplayRows: [Int] = []
    var columnFilteredDisplayRows: [Int] = []

    // Find controls (inline in toolbar)
    let findControlsStack = NSStackView()
    let findField = NSSearchField()
    let filterToggleButton = NSButton()
    let findClearButton = NSButton()
    let findCountLabel = NSTextField(labelWithString: "")
    let findPrevButton = NSButton()
    let findNextButton = NSButton()
    let findCloseButton = NSButton()

    // Load more
    let loadMoreBar = NSView()
    let loadMoreButton = NSButton(title: "Load More Rows", target: nil, action: nil)
    let loadMoreSpinner = NSProgressIndicator()
    private var isLoadingMore = false

    // Layout constraints to toggle
    var scrollViewTopToToolbar: NSLayoutConstraint!
    var scrollViewBottomToLoadMore: NSLayoutConstraint!
    var scrollViewBottomToContainer: NSLayoutConstraint!

    // Callbacks
    var onLoadMore: (() -> Void)?
    var onPinToggle: ((Bool) -> Void)?
    var onSelectionChanged: ((IndexSet) -> Void)?

    // Pin state
    private var isPinned = false

    // Formatters
    static let rowCountFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        self.view = container

        setupToolbar()

        // Table view
        dataSource = ResultsDataSource(tableView: tableView)
        dataSource.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        cellSelectionController = CellSelectionController()
        cellSelectionController.tableView = tableView
        cellSelectionController.onChange = { [weak self] state in
            self?.cellSelectionDidChange(state)
        }
        tableView.cellSelectionController = cellSelectionController

        copyExport = ResultsCopyExport(tableView: tableView, copyButton: copyButton, exportButton: exportButton)
        copyExport.delegate = self
        tableView.menu = copyExport.buildContextMenu()

        copyButton.target = copyExport
        copyButton.action = #selector(ResultsCopyExport.showCopyMenu)
        exportButton.target = copyExport
        exportButton.action = #selector(ResultsCopyExport.showExportMenu)

        findController = ResultsFindController(
            tableView: tableView, findBar: findControlsStack, findField: findField,
            filterToggleButton: filterToggleButton, findClearButton: findClearButton,
            findCountLabel: findCountLabel, findPrevButton: findPrevButton,
            findNextButton: findNextButton, findCloseButton: findCloseButton
        )
        findController.delegate = self

        sortController = ResultsSortController(tableView: tableView, resetSortButton: resetSortButton)
        sortController.delegate = self
        resetSortButton.target = sortController
        resetSortButton.action = #selector(ResultsSortController.resetSort)

        columnFilterController = ResultsColumnFilterController()
        columnFilterController.delegate = self

        filterableHeaderView = FilterableHeaderView()
        filterableHeaderView.filterDelegate = self
        tableView.headerView = filterableHeaderView

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center

        setupLoadMoreBar()

        container.addSubview(toolbarBar)
        container.addSubview(scrollView)
        container.addSubview(loadMoreBar)
        container.addSubview(emptyLabel)

        scrollViewTopToToolbar = scrollView.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor, constant: 2)
        scrollViewBottomToContainer = scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        scrollViewBottomToLoadMore = scrollView.bottomAnchor.constraint(equalTo: loadMoreBar.topAnchor)

        NSLayoutConstraint.activate([
            toolbarBar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbarBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarBar.heightAnchor.constraint(equalToConstant: 28),

            scrollViewTopToToolbar,
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

    // MARK: - Public API

    func showResult(_ result: QueryResult) {
        self.columns = result.columns
        self.rows = result.rows
        self.hasMore = result.hasMore
        self.executionTimeMs = result.executionTimeMs

        columnCategories = Dictionary(
            columns.map { ($0.name, PGTypeCategory(dataType: $0.dataType)) },
            uniquingKeysWith: { _, last in last }
        )

        displayRows = Array(0..<rows.count)
        unfilteredDisplayRows = displayRows
        columnFilteredDisplayRows = displayRows
        columnFilterController.clearAll()
        filterableHeaderView.activeFilterColumns = []
        resetFiltersButton.isHidden = true
        sortController.clearSortState()

        cellSelectionController.clear()

        rebuildColumns()
        pushDataToHelpers()
        pushFindStateToDataSource(matchSet: Set(), currentMatchRow: -1, currentMatchColId: nil)
        tableView.reloadData()

        // 0 rows with no column info — show clear empty state
        if rows.isEmpty && columns.isEmpty {
            emptyLabel.stringValue = "Query returned no results"
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            toolbarBar.isHidden = false
        } else {
            emptyLabel.isHidden = true
            scrollView.isHidden = false
            toolbarBar.isHidden = false
        }

        updateLoadMoreVisibility()
        updateStatusBarText()

        if findController.isFindVisible {
            findController.closeFind(nil)
        }
    }

    /// Captures current grid view state (column widths, sort, filters, scroll, selection).
    func captureGridState() -> ResultsGridState? {
        guard !columns.isEmpty else { return nil }

        var widths: [String: CGFloat] = [:]
        for col in tableView.tableColumns where col.identifier.rawValue != "__rownum__" {
            widths[col.identifier.rawValue] = col.width
        }

        let order = tableView.tableColumns.map { $0.identifier.rawValue }

        let sortCol = sortController.currentSortColumn
        let sortAsc = tableView.sortDescriptors.first?.ascending ?? true

        return ResultsGridState(
            columnWidths: widths,
            columnOrder: order,
            sortColumn: sortCol,
            sortAscending: sortAsc,
            columnFilters: columnFilterController.activeFilters,
            scrollPosition: scrollView.contentView.bounds.origin,
            selectedRows: tableView.selectedRowIndexes
        )
    }

    /// Restores previously captured grid view state after `showResult()`.
    func restoreGridState(_ state: ResultsGridState) {
        // 0. Column order
        if let order = state.columnOrder {
            for (targetIndex, colId) in order.enumerated() {
                guard targetIndex < tableView.tableColumns.count else { continue }
                if let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == colId }),
                   currentIndex != targetIndex {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        }

        // 1. Column widths
        for col in tableView.tableColumns {
            if let saved = state.columnWidths[col.identifier.rawValue] {
                col.width = saved
            }
        }

        // 2. Sort — setting sortDescriptors triggers handleSortDescriptorsChanged via delegate
        if let sortCol = state.sortColumn {
            tableView.sortDescriptors = [NSSortDescriptor(key: sortCol, ascending: state.sortAscending)]
        }

        // 3. Column filters
        if !state.columnFilters.isEmpty {
            for (colName, filter) in state.columnFilters {
                columnFilterController.setFilter(filter, forColumn: colName)
            }
            filterableHeaderView.activeFilterColumns = Set(columnFilterController.activeFilters.keys)
            resetFiltersButton.isHidden = !columnFilterController.hasActiveFilters
            recomputeColumnFilteredRows()
        }

        // 4. Scroll position
        scrollView.contentView.setBoundsOrigin(state.scrollPosition)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // 5. Selection
        if !state.selectedRows.isEmpty {
            tableView.selectRowIndexes(state.selectedRows, byExtendingSelection: false)
        }
    }

    func appendRows(from result: QueryResult) {
        let oldCount = rows.count
        rows.append(contentsOf: result.rows)
        hasMore = result.hasMore

        let newIndices = Array(oldCount..<rows.count)
        unfilteredDisplayRows.append(contentsOf: newIndices)

        if sortController.currentSortColumn != nil {
            sortController.reapplySortIfActive()
        } else {
            recomputeColumnFilteredRows()
        }

        updateLoadMoreVisibility()
        updateStatusBarText()
        setLoadingMore(false)
    }

    func showExecuteResult(_ result: ExecuteResult) {
        clear()
        toolbarBar.isHidden = false
        let timeStr = formatDuration(result.executionTimeMs)
        let count = formatRowCount(Int(result.rowsAffected))
        statusLabel.stringValue = "\(count) row\(result.rowsAffected == 1 ? "" : "s") affected in \(timeStr)"
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
        unfilteredDisplayRows = []
        columnFilteredDisplayRows = []
        hasMore = false
        executionTimeMs = 0
        columnCategories = [:]
        columnFilterController.clearAll()
        filterableHeaderView.activeFilterColumns = []
        resetFiltersButton.isHidden = true
        sortController.clearSortState()
        cellSelectionController.clear()

        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }
        pushDataToHelpers()
        pushFindStateToDataSource(matchSet: Set(), currentMatchRow: -1, currentMatchColId: nil)
        tableView.reloadData()
        emptyLabel.stringValue = "Run a query to see results"
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = false
        scrollView.isHidden = true
        toolbarBar.isHidden = true
        hideHistoryContext()

        updateLoadMoreVisibility()

        if findController.isFindVisible {
            findController.closeFind(nil)
        }
    }

    // MARK: - History Context

    func showHistoryContext(schema: String?, timestamp: String) {
        let schemaText = schema ?? "default"
        let timeText = formatAbsoluteDate(timestamp)
        historyContextLabel.stringValue = "\(schemaText) \u{00B7} \(timeText)"
        historyContextLabel.isHidden = false
    }

    func hideHistoryContext() {
        historyContextLabel.isHidden = true
    }

    private func formatAbsoluteDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
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
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        let rowNumCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rownum__"))
        rowNumCol.title = "#"
        rowNumCol.width = 40
        rowNumCol.minWidth = 30
        rowNumCol.maxWidth = 60
        tableView.addTableColumn(rowNumCol)

        for colDef in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colDef.name))
            col.title = colDef.name
            col.width = estimateColumnWidth(colDef)
            col.minWidth = 50
            col.maxWidth = 720

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
            let headerCell = SortAwareHeaderCell()
            headerCell.attributedStringValue = attrStr
            col.headerCell = headerCell
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

    // MARK: - Column Filter Pipeline

    /// Recomputes columnFilteredDisplayRows from unfilteredDisplayRows, then cascades to find.
    func recomputeColumnFilteredRows() {
        columnFilteredDisplayRows = columnFilterController.applyFilters(inputDisplayRows: unfilteredDisplayRows)
        if findController.isFindVisible {
            findController.findFieldChanged(findField)
        } else {
            displayRows = columnFilteredDisplayRows
            pushDataToHelpers()
            tableView.reloadData()
        }
        updateStatusBarText()
    }

    // MARK: - Status Bar

    func updateStatusBarText() {
        let timeStr = formatDuration(executionTimeMs)
        let moreStr = hasMore ? " (more available)" : ""
        let filterCount = columnFilterController.activeFilterCount
        let filterSuffix = filterCount > 0
            ? " \u{2022} \(filterCount) filter\(filterCount == 1 ? "" : "s")"
            : ""

        let findVisible = findController.isFindVisible
        let findMatchCount = findController.findMatches.count
        if (findVisible || filterCount > 0) && displayRows.count < rows.count {
            let visibleCount = formatRowCount(displayRows.count)
            let total = formatRowCount(rows.count)
            statusLabel.stringValue = "\(visibleCount) of \(total) rows in \(timeStr)\(filterSuffix)\(moreStr)"
        } else if findVisible && findMatchCount > 0 {
            let rowStr = formatRowCount(displayRows.count)
            statusLabel.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr) \u{2022} \(findMatchCount) match\(findMatchCount == 1 ? "" : "es")\(filterSuffix)\(moreStr)"
        } else {
            let rowStr = formatRowCount(displayRows.count)
            statusLabel.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr)\(filterSuffix)\(moreStr)"
        }
    }

    // MARK: - Load More

    private func updateLoadMoreVisibility() {
        loadMoreBar.isHidden = !hasMore
        scrollViewBottomToLoadMore.isActive = hasMore
        scrollViewBottomToContainer.isActive = !hasMore
    }

    @objc func loadMoreTapped() {
        onLoadMore?()
    }

    // MARK: - Escape to Deselect

    @objc override func cancelOperation(_ sender: Any?) {
        if findController.isFindVisible {
            findController.closeFind(nil)
        } else {
            cellSelectionController.clear()
        }
    }

    // MARK: - Reset Column Filters

    @objc func resetAllColumnFilters() {
        columnFilterController.clearAll()
        filterableHeaderView.activeFilterColumns = []
        resetFiltersButton.isHidden = true
        recomputeColumnFilteredRows()
    }

    // MARK: - Find (Forwarding)

    @objc func showFind() {
        if findController.isFindVisible {
            findController.closeFind(nil)
        } else {
            findController.showFind()
        }
    }
    @objc func showFilter() { findController.showFilter() }

    // MARK: - Pin Results

    @objc func togglePin() {
        isPinned.toggle()
        updatePinUI()
        onPinToggle?(isPinned)
    }

    func setPinState(pinned: Bool, tabName: String?) {
        isPinned = pinned
        if let name = tabName {
            pinSourceLabel.stringValue = "Pinned: \(name)"
        }
        updatePinUI()
    }

    private func updatePinUI() {
        if isPinned {
            pinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Unpin Results")
            pinButton.contentTintColor = .systemOrange
            pinSourceLabel.isHidden = false
        } else {
            pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin Results")
            pinButton.contentTintColor = .secondaryLabelColor
            pinSourceLabel.isHidden = true
        }
    }

    // MARK: - Copy (Forwarding)

    @objc func copy(_ sender: Any?) {
        copyExport.cellSelection = cellSelectionController?.state
        copyExport.copy(sender)
    }

    // MARK: - Helper Coordination

    func pushDataToHelpers() {
        dataSource.columns = columns
        dataSource.rows = rows
        dataSource.displayRows = displayRows
        dataSource.columnCategories = columnCategories

        copyExport.columns = columns
        copyExport.rows = rows
        copyExport.displayRows = displayRows
        copyExport.columnCategories = columnCategories
        copyExport.cellSelection = cellSelectionController?.state
    }

    func pushFindStateToDataSource(matchSet: Set<CellAddress>, currentMatchRow: Int, currentMatchColId: String?) {
        dataSource.isFindVisible = findController.isFindVisible
        dataSource.findMatchSet = matchSet
        dataSource.currentMatchRow = currentMatchRow
        dataSource.currentMatchColId = currentMatchColId
    }

    // MARK: - Cell Selection

    func cellSelectionDidChange(_ state: CellSelectionState) {
        if state.isRowMode {
            dataSource.cellSelection = nil
            copyExport.cellSelection = nil
            tableView.reloadData()
            tableView.selectRowIndexes(state.selectedRows, byExtendingSelection: false)
            filterableHeaderView.highlightedColumnIndices = IndexSet()
            filterableHeaderView.needsDisplay = true
        } else if state.selectedRange != nil {
            dataSource.cellSelection = state
            copyExport.cellSelection = state
            tableView.deselectAll(nil)
            dataSource.updateVisibleCellSelectionAppearance()
            onSelectionChanged?(state.selectedRowIndices())
            filterableHeaderView.highlightedColumnIndices = state.selectedColumnIndices
            filterableHeaderView.needsDisplay = true
        } else {
            dataSource.cellSelection = nil
            copyExport.cellSelection = nil
            tableView.deselectAll(nil)
            dataSource.updateVisibleCellSelectionAppearance()
            onSelectionChanged?(IndexSet())
            filterableHeaderView.highlightedColumnIndices = IndexSet()
            filterableHeaderView.needsDisplay = true
        }
    }

    // MARK: - Auto-Fit Column

    func autoFitColumn(at columnIndex: Int) {
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return }
        let column = tableView.tableColumns[columnIndex]
        let colId = column.identifier.rawValue
        guard colId != "__rownum__" else { return }

        // Measure header text width
        let headerWidth = column.headerCell.attributedStringValue
            .size().width + 40  // Padding for sort+filter icons + margins

        // Sample visible rows + first/last 100
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        var sampleIndices = Set<Int>()
        if visibleRange.length > 0 {
            for i in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                sampleIndices.insert(i)
            }
        }
        let totalRows = displayRows.count
        for i in 0..<min(100, totalRows) { sampleIndices.insert(i) }
        for i in max(0, totalRows - 100)..<totalRows { sampleIndices.insert(i) }

        var maxWidth: CGFloat = headerWidth
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        for rowIdx in sampleIndices {
            guard rowIdx < displayRows.count else { continue }
            let dataIdx = displayRows[rowIdx]
            guard dataIdx < rows.count else { continue }
            if let value = rows[dataIdx][colId] {
                let text = value.displayString
                let width = (text as NSString).size(withAttributes: attrs).width + 12
                maxWidth = max(maxWidth, width)
            }
        }

        column.width = min(max(maxWidth, column.minWidth), 720)
    }

    // MARK: - Formatting

    func formatDuration(_ ms: UInt64) -> String {
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

    func formatRowCount(_ count: Int) -> String {
        Self.rowCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
