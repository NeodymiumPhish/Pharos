import AppKit
import Combine

/// Parses the 0-based column index from a "col_N" identifier string.
func colIndex(from identifier: String) -> Int? {
    guard identifier.hasPrefix("col_") else { return nil }
    return Int(identifier.dropFirst(4))
}

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

    // Toolbar elements — owned by ContentViewController, accessed via contentVC
    var statusLabel: NSTextField { contentVC?.statusLabel ?? NSTextField(labelWithString: "") }
    var pinSourceLabel: NSTextField { contentVC?.pinSourceLabel ?? NSTextField(labelWithString: "") }
    var resultBannerLabel: NSTextField { contentVC?.resultBannerLabel ?? NSTextField(labelWithString: "") }
    var resetSortButton: NSButton { contentVC?.resetSortButton ?? NSButton() }
    var resetFiltersButton: NSButton { contentVC?.resetFiltersButton ?? NSButton() }
    var clearSelectionButton: NSButton { contentVC?.clearSelectionButton ?? NSButton() }
    var pinButton: NSButton { contentVC?.pinButton ?? NSButton() }
    var copyButton: NSButton { contentVC?.copyButton ?? NSButton() }
    var exportButton: NSButton { contentVC?.exportButton ?? NSButton() }

    /// Reference to the owning ContentViewController for toolbar access
    weak var contentVC: ContentViewController?

    // Data
    var columns: [ColumnDef] = []
    var rows: [[AnyCodable]] = []
    /// The result's row identity, or nil when the core could not attribute the
    /// result to a table. Read by `recomputeTagMap()`.
    var rowIdentity: RowIdentity?
    var hasMore: Bool = false
    var executionTimeMs: UInt64 = 0
    var columnCategories: [PGTypeCategory] = []

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
    var scrollViewBottomToLoadMore: NSLayoutConstraint!
    var scrollViewBottomToContainer: NSLayoutConstraint!

    // Callbacks
    var onLoadMore: (() -> Void)?
    var onPinToggle: ((Bool) -> Void)?
    var onSelectionChanged: ((IndexSet) -> Void)?


    // Pin state
    private var isPinned = false

    /// Token for the TagStore observer. The BLOCK form of `addObserver` keeps its
    /// closure alive until this is removed — unlike the selector form, it is not
    /// cleaned up when the observer deallocates. There is one `ResultsGridVC` for
    /// the app's life (`ContentViewController` owns it), so today `deinit` never
    /// actually runs and nothing currently leaks. It is kept anyway as insurance:
    /// if a future refactor makes this VC per-tab or per-pane, the removal is
    /// already in place rather than something the next change has to remember.
    private var tagStoreObserver: NSObjectProtocol?

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

        columnFilterController = ResultsColumnFilterController()
        columnFilterController.delegate = self

        filterableHeaderView = FilterableHeaderView()
        filterableHeaderView.filterDelegate = self
        var hf = filterableHeaderView.frame
        hf.size.height = 34
        filterableHeaderView.frame = hf
        tableView.headerView = filterableHeaderView

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center

        setupLoadMoreBar()

        container.addSubview(scrollView)
        container.addSubview(loadMoreBar)
        container.addSubview(emptyLabel)

        scrollViewBottomToContainer = scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        scrollViewBottomToLoadMore = scrollView.bottomAnchor.constraint(equalTo: loadMoreBar.topAnchor)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
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

    override func viewDidLoad() {
        super.viewDidLoad()

        // The store changes when a connection loads its tags, and Phase 3 will add
        // writes. This grid rebuilds its map from the new index — filtered to the
        // affected connection, since `recomputeTagMap()` only ever reflects the
        // GLOBAL active connection (there is exactly one at a time; see
        // `AppStateManager.activeConnectionId`). A notification naming some other,
        // inactive connection changes nothing this grid displays, so skipping it
        // avoids a wasted row walk and table reload whenever an unrelated
        // connection's tags load or a background reload runs. There is only one
        // grid today, so this saves one row walk, not one per tab. A notification
        // with no connection id (a global change, e.g. a future palette edit)
        // still always rebuilds.
        //
        // The filter is safe only because of two facts checked directly against
        // `TagStore` and `AppStateManager`, not assumed:
        //  1. `activeConnectionId`'s `didSet` runs AFTER the new value is stored,
        //     and `loadIfNeeded` (called from inside that `didSet`) posts the
        //     change synchronously from there — so by the time this handler reads
        //     `activeConnectionId`, it already equals the connection the post is
        //     about.
        //  2. `addObserver(forName:object:queue:.main)` delivers the block
        //     SYNCHRONOUSLY when the post itself comes from the main thread, which
        //     every poster in this codebase does — so no `async` hop can land
        //     between the post and this handler.
        //
        // Two changes would break it, and either is a real risk in a future
        // refactor rather than a hypothetical:
        //  - A per-tab or per-pane connection. `recomputeTagMap()` would then need
        //    a GRID-LOCAL connection id, but this filter compares the GLOBAL one —
        //    so a notification for the grid's own connection would be silently
        //    discarded whenever some other connection was globally active.
        //  - Deferred delivery. This filter's correctness depends on the post
        //    arriving while `activeConnectionId` still equals the affected id. A
        //    post from a background thread, or one wrapped in
        //    `DispatchQueue.main.async`, could arrive after `activeConnectionId`
        //    had already moved on — e.g. the clear-on-disconnect post racing a
        //    fast reconnect — and the mismatch would make this handler discard a
        //    notification it needed, leaving stale tag stripes on screen until the
        //    next result.
        tagStoreObserver = NotificationCenter.default.addObserver(
            forName: TagStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let changedId = note.userInfo?[TagStore.connectionIdKey] as? String,
               changedId != AppStateManager.shared.activeConnectionId {
                return
            }
            self.recomputeTagMap()
            self.tableView.reloadData()
        }
    }

    deinit {
        if let tagStoreObserver {
            NotificationCenter.default.removeObserver(tagStoreObserver)
        }
    }

    /// Called by ContentViewController after setting contentVC and toolbar buttons.
    /// Initializes helpers that depend on toolbar elements.
    func setupHelpers() {
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
    }

    // MARK: - Public API

    func showResult(_ result: QueryResult) {
        self.columns = result.columns
        self.rows = result.rows
        self.rowIdentity = result.rowIdentity
        self.hasMore = result.hasMore
        self.executionTimeMs = result.executionTimeMs

        columnCategories = columns.map { PGTypeCategory(dataType: $0.dataType) }

        displayRows = Array(0..<rows.count)
        unfilteredDisplayRows = displayRows
        columnFilteredDisplayRows = displayRows
        columnFilterController.clearAll()
        filterableHeaderView.activeFilterColumns = []
        resetFiltersButton.isHidden = true
        sortController.clearSortState()

        cellSelectionController.clear()

        rebuildColumns()
        recomputeTagMap()
        pushDataToHelpers()
        pushFindStateToDataSource(matchSet: Set(), currentMatchRow: -1, currentMatchColId: nil)
        tableView.reloadData()

        // 0 rows with no column info — show clear empty state
        if rows.isEmpty && columns.isEmpty {
            emptyLabel.stringValue = "Query returned no results"
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.isHidden = false
            scrollView.isHidden = true
        } else {
            emptyLabel.isHidden = true
            scrollView.isHidden = false
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
        rowIdentity = rowIdentity?.appendingPage(result.rowIdentity, pageRowCount: result.rows.count)
            ?? result.rowIdentity
        hasMore = result.hasMore

        let newIndices = Array(oldCount..<rows.count)
        unfilteredDisplayRows.append(contentsOf: newIndices)

        recomputeTagMap()

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
        let timeStr = formatDuration(result.executionTimeMs)
        let count = formatRowCount(Int(result.rowsAffected))
        statusLabel.stringValue = "\(count) row\(result.rowsAffected == 1 ? "" : "s") affected in \(timeStr)"
    }

    func clear() {
        columns = []
        rows = []
        displayRows = []
        unfilteredDisplayRows = []
        columnFilteredDisplayRows = []
        hasMore = false
        executionTimeMs = 0
        columnCategories = []
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
        // The status label lives in the shared action bar (owned by
        // ContentViewController), so it isn't reset by emptying our own
        // datasource — explicitly blank it here so previous-result text
        // ("N rows in Ts") doesn't bleed into tabs that have no results.
        statusLabel.stringValue = ""
        hideResultBanner()

        updateLoadMoreVisibility()

        if findController.isFindVisible {
            findController.closeFind(nil)
        }
    }

    // MARK: - Result Banner

    /// Show the "schema · executed-at" subtitle under the results grid. Shown
    /// for every result (fresh queries use Date(); history replays use the
    /// original execution time), so users can tell at a glance whether they're
    /// looking at recent results or something opened from history.
    func showResultBanner(schema: String?, date: Date) {
        let schemaText = schema ?? "default"
        let timeText = Self.resultBannerDateFormatter.string(from: date)
        resultBannerLabel.stringValue = "\(schemaText) \u{00B7} \(timeText)"
        resultBannerLabel.isHidden = false
    }

    func hideResultBanner() {
        resultBannerLabel.isHidden = true
    }

    /// Parse an ISO8601 history timestamp into a Date, falling back to a
    /// fractional-seconds parser. Returns nil for unparseable input.
    static func parseHistoryTimestamp(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private static let resultBannerDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

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
        // Room for the dot plus the row number. The dot is 6pt at a 5pt inset, so the
        // text starts at 15pt. At the DEFAULT 54pt width that leaves 33pt, which holds
        // a four-digit row number (measured: "9999" is 27.97pt in the row-number font).
        // At the 44pt minimum only three digits fit — acceptable, because the user has
        // to drag the column down to reach it, and the old 30pt minimum was worse.
        rowNumCol.width = 54
        rowNumCol.minWidth = 44
        rowNumCol.maxWidth = 70
        tableView.addTableColumn(rowNumCol)

        var types: [String: String] = [:]
        for (index, colDef) in columns.enumerated() {
            let colId = "col_\(index)"
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colId))
            // Assign the header cell BEFORE the title: replacing headerCell resets
            // its stringValue (title), so setting title first would be discarded.
            col.headerCell = SortAwareHeaderCell()
            col.title = colDef.name
            col.minWidth = 50
            col.maxWidth = 1000
            types[colId] = colDef.dataType.uppercased()
            col.width = measuredColumnWidth(column: col, colId: colId, includeVisibleSample: false)
            col.sortDescriptorPrototype = NSSortDescriptor(key: colId, ascending: true)
            tableView.addTableColumn(col)
        }
        filterableHeaderView.columnTypes = types
    }

    // MARK: - Column Filter Pipeline

    /// Syncs the header highlight + reset-button state to the current active
    /// filters, then recomputes the filtered rows. Shared by the header-filter
    /// popover path and the chart-drill path so both stay in step.
    func refreshColumnFilters() {
        filterableHeaderView.activeFilterColumns = Set(columnFilterController.activeFilters.keys)
        resetFiltersButton.isHidden = !columnFilterController.hasActiveFilters
        recomputeColumnFilteredRows()
    }

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

    // MARK: - Tags

    /// Rebuild the tag map for the loaded result.
    ///
    /// Called when a result arrives, when a page is appended, and when the store
    /// changes. NOT called per row: the matcher walks the rows once and the data
    /// source then answers each row view from a dictionary.
    func recomputeTagMap() {
        guard let connectionId = AppStateManager.shared.activeConnectionId else {
            dataSource.tagsByRow = [:]
            return
        }
        let index = TagStore.shared.index(for: connectionId)
        guard !index.isEmpty else {
            dataSource.tagsByRow = [:]
            return
        }
        // `TagMatcher.needsRowValues` owns this tier decision — see its doc for why
        // a second copy of the rule here would be dangerous. Building the text copy
        // unconditionally would copy the whole result on every store change for the
        // common keyed case. The row COUNT must still be right in both branches,
        // since that is what the strong path reads — `Array(repeating: [],
        // count: rows.count)` keeps it correct while each row's own array of
        // values stays empty.
        let needsText = TagMatcher.needsRowValues(rowIdentity)
        let textRows: [[String?]] = needsText
            ? rows.map { row in row.map { $0.stringValue } }
            : Array(repeating: [], count: rows.count)
        dataSource.tagsByRow = TagMatcher.match(
            identity: rowIdentity,
            columns: columns.map { $0.name },
            rows: textRows,
            tagsByIdentity: index
        )
        dataSource.labelColors = Dictionary(
            uniqueKeysWithValues: TagStore.shared.labels.map {
                ($0.id, TagLabelPalette.color(at: $0.colorIndex))
            }
        )
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
            clearSelectionButton.isHidden = false
        } else if state.selectedRange != nil {
            dataSource.cellSelection = state
            copyExport.cellSelection = state
            tableView.deselectAll(nil)
            dataSource.updateVisibleCellSelectionAppearance()
            onSelectionChanged?(state.selectedRowIndices())
            filterableHeaderView.highlightedColumnIndices = state.selectedColumnIndices
            filterableHeaderView.needsDisplay = true
            clearSelectionButton.isHidden = false
        } else {
            dataSource.cellSelection = nil
            copyExport.cellSelection = nil
            tableView.deselectAll(nil)
            dataSource.updateVisibleCellSelectionAppearance()
            onSelectionChanged?(IndexSet())
            filterableHeaderView.highlightedColumnIndices = IndexSet()
            filterableHeaderView.needsDisplay = true
            clearSelectionButton.isHidden = true
        }
    }

    /// Clears any active cell/row selection. Wired to the accent-tinted
    /// "Clear Selection" toolbar button, which only appears while a selection
    /// is active (toggled in `cellSelectionDidChange`).
    @objc func clearCellSelection() {
        cellSelectionController.clear()
    }

    // MARK: - Auto-Fit Column

    /// Content-aware column width: the max of the header name row, the header type
    /// row, and the rendered cell contents (sampled), clamped to [minWidth, 1000].
    /// No funnel/sort reserve — those overlay row 2 (two-row header). Pass
    /// `includeVisibleSample: true` for on-demand auto-fit (adds on-screen rows);
    /// the initial default passes false (reloadData hasn't run, visible rect stale).
    func measuredColumnWidth(column: NSTableColumn, colId: String, includeVisibleSample: Bool) -> CGFloat {
        guard let idx = colIndex(from: colId) else { return column.width }
        // Padding = the 6/6 text insets (both header text and body cells use them)
        // + the table's intercell gap (eats into a cell's drawable width) + a small
        // rounding safety, so the rendered text never lands a hair short and truncates.
        let pad: CGFloat = SortAwareHeaderCell.hInset * 2 + tableView.intercellSpacing.width + 2
        // Header contributes the wider of the two rows: name (row 1) and type (row 2).
        let nameStr = idx < columns.count ? columns[idx].name : column.title
        let typeStr = (idx < columns.count ? columns[idx].dataType : "").uppercased()
        let nameW = (nameStr as NSString).size(withAttributes: [.font: SortAwareHeaderCell.nameFont]).width
        let typeW = (typeStr as NSString).size(withAttributes: [.font: SortAwareHeaderCell.typeFont]).width
        var maxW = ceil(max(nameW, typeW)) + pad

        var sampleIndices = Set<Int>()
        let total = displayRows.count
        for i in 0..<min(100, total) { sampleIndices.insert(i) }
        for i in max(0, total - 100)..<total { sampleIndices.insert(i) }
        if includeVisibleSample {
            let vr = tableView.rows(in: tableView.visibleRect)
            if vr.length > 0 { for i in vr.location..<(vr.location + vr.length) { sampleIndices.insert(i) } }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        for r in sampleIndices {
            guard r < displayRows.count else { continue }
            let d = displayRows[r]
            guard d < rows.count, idx < rows[d].count else { continue }
            let cat = idx < columnCategories.count ? columnCategories[idx] : .string
            let text = ResultCellText.rendered(value: rows[d][idx], category: cat,
                                               boolTrue: dataSource.boolDisplayTrue,
                                               boolFalse: dataSource.boolDisplayFalse,
                                               nullString: dataSource.nullDisplay)
            maxW = max(maxW, ceil((text as NSString).size(withAttributes: attrs).width) + pad)
        }
        return min(max(maxW, column.minWidth), 1000)
    }

    func autoFitColumn(at columnIndex: Int) {
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return }
        let column = tableView.tableColumns[columnIndex]
        let colId = column.identifier.rawValue
        guard colId != "__rownum__" else { return }
        column.width = measuredColumnWidth(column: column, colId: colId, includeVisibleSample: true)
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

// MARK: - Results Toolbar Bar

/// Custom toolbar bar that draws an Xcode-style debug area action bar:
/// opaque background with a top separator line, optional bottom separator,
/// and drag-to-resize cursor behavior.
class ResultsToolbarBar: NSView {

    /// When true, draws a bottom separator line as well.
    var drawsBottomSeparator = false

    /// The ContentViewController that owns this bar, used for drag-to-resize.
    weak var contentViewController: ContentViewController?

    /// Whether the top separator should pulse in the accent color (query running in focused tab).
    var isPulsing: Bool = false {
        didSet {
            guard oldValue != isPulsing else { return }
            if isPulsing {
                startPulseSubscription()
            } else {
                beginPulseFadeOut()
            }
            needsDisplay = true
        }
    }

    private var pulseSubscription: AnyCancellable?
    private var pulseValue: CGFloat = 1.0
    private var fadeOutUntil: CFTimeInterval?
    private var fadeStartAlpha: CGFloat = 0
    private let fadeOutDuration: CFTimeInterval = 0.25

    private func startPulseSubscription() {
        fadeOutUntil = nil
        guard pulseSubscription == nil else { return }
        let token = PulseClock.shared.observe()
        let sub = PulseClock.shared.value.sink { [weak self] v in
            self?.pulseValue = v
            self?.needsDisplay = true
        }
        pulseSubscription = AnyCancellable {
            sub.cancel()
            token.cancel()
        }
    }

    private func beginPulseFadeOut() {
        // Snapshot current alpha and cancel subscription immediately. The fade-out
        // redraw loop in draw(_:) is the only redraw driver during the fade.
        fadeStartAlpha = 0.55 + 0.45 * pulseValue
        pulseSubscription = nil
        fadeOutUntil = CACurrentMediaTime() + fadeOutDuration
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Background — matches window chrome
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        // Top separator line — blended with accent color when pulsing (or during fade-out).
        let now = CACurrentMediaTime()
        let pulseAlpha: CGFloat = {
            if isPulsing {
                return 0.55 + 0.45 * pulseValue
            }
            if let fadeEnd = fadeOutUntil {
                let remaining = fadeEnd - now
                if remaining > 0 {
                    let progress = CGFloat(1.0 - (remaining / fadeOutDuration))
                    return fadeStartAlpha * (1.0 - progress)
                }
            }
            return 0
        }()

        if pulseAlpha > 0 {
            // Paint the base separator first, then overlay the accent at current alpha.
            NSColor.separatorColor.setStroke()
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
            basePath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
            basePath.stroke()
            NSColor.controlAccentColor.withAlphaComponent(pulseAlpha).setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        let topPath = NSBezierPath()
        topPath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        topPath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        topPath.stroke()

        // Drive fade-out redraws until the fade ends.
        if let fadeEnd = fadeOutUntil {
            if fadeEnd - now <= 0 {
                fadeOutUntil = nil
            } else {
                DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            }
        }

        // Bottom separator line
        if drawsBottomSeparator {
            NSColor.separatorColor.setStroke()
            let bottomPath = NSBezierPath()
            bottomPath.move(to: NSPoint(x: bounds.minX, y: bounds.minY + 0.5))
            bottomPath.line(to: NSPoint(x: bounds.maxX, y: bounds.minY + 0.5))
            bottomPath.stroke()
        }
    }

    /// Returns true if the deepest view at the given point is an interactive control (button, text field).
    private func isInteractiveControl(at windowPoint: NSPoint) -> Bool {
        let loc = convert(windowPoint, from: nil)
        guard let hit = hitTest(loc) else { return false }
        return hit is NSButton || hit is NSTextField || hit is NSSearchField || hit is NSSegmentedControl
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard contentViewController != nil else { return }
        // Default: resize cursor for the whole bar
        addCursorRect(bounds, cursor: .resizeUpDown)
        // Override with arrow cursor for each interactive control
        enumerateInteractiveControls(in: self) { controlRect in
            addCursorRect(controlRect, cursor: .arrow)
        }
    }

    /// Recursively finds interactive controls and calls the closure with their rects in this view's coordinates.
    private func enumerateInteractiveControls(in view: NSView, handler: (NSRect) -> Void) {
        for sub in view.subviews {
            if sub is NSButton || sub is NSSearchField || sub is NSSegmentedControl {
                let rect = convert(sub.bounds, from: sub)
                handler(rect)
            } else if sub is NSStackView {
                enumerateInteractiveControls(in: sub, handler: handler)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let vc = contentViewController else { super.mouseDown(with: event); return }
        if isInteractiveControl(at: event.locationInWindow) {
            super.mouseDown(with: event)
            return
        }
        // Start drag tracking loop for resize
        vc.handleActionBarDrag(event: event)
        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            vc.handleActionBarDrag(event: nextEvent)
            if nextEvent.type == .leftMouseUp { break }
        }
    }
}
