import AppKit
import Combine

// MARK: - ResultsGridVC

/// Displays query results in an NSTableView with sorting, find, copy formats, and pagination.
class ResultsGridVC: NSViewController {

    let tableView = ResultsTableView()
    let scrollView = InsetScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Run a query to see results")

    // Helpers
    var dataSource: ResultsDataSource!
    var copyExport: ResultsCopyExport!
    var tagController: ResultsTagController!
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
    var tagButton: NSButton { contentVC?.tagButton ?? NSButton() }
    var pinButton: NSButton { contentVC?.pinButton ?? NSButton() }
    var copyButton: NSButton { contentVC?.copyButton ?? NSButton() }
    var exportButton: NSButton { contentVC?.exportButton ?? NSButton() }

    /// Reference to the owning ContentViewController for toolbar access
    weak var contentVC: ContentViewController?

    // Data
    var columns: [ColumnDef] = []
    var rows: [[AnyCodable]] = []
    /// The result's row identity, or nil when the core could not attribute the
    /// result to a table.
    ///
    /// The block travels with the result rather than being consumed here: it is
    /// cached with a history entry and handed back by the history and workspace
    /// restore, so a reopened grid carries the same block it had. `Load More`
    /// extends it in step with the appended rows.
    ///
    /// The tag path reads `tableDisplay` ONLY, as provenance for a tuple's
    /// origin. It never decides whether a row can be tagged, and the matcher
    /// never reads a row key — matching is on cell values alone.
    var rowIdentity: RowIdentity?
    /// Matching tags by DATA row index, from `TagTupleMatcher`, strongest
    /// first. The grid is the ONLY owner: the data source keeps no copy of it.
    /// `applyTagMap` bakes this map once, through `TagPalette.bake`, into the
    /// four render dictionaries the data source does hold — `segmentsByRow`,
    /// `tooltipByRow`, `tintByRow` and `tagTints`. Anything that needs to paint
    /// reads those; the raw matches here are for the stage closures, the status
    /// text, the Inspector and the removal sheet. Keeping one bake is what
    /// makes band, tooltip and tint appear and disappear in a single repaint.
    var matchesByRow: [Int: [TagRowMatch]] = [:]
    /// The force-show toggle: tagged rows survive the data filters (stages 2
    /// and 3-as-wired). Transient, per grid, by scope decision. The flag
    /// latches while the button is hidden, so a newly-tagged row can bring it
    /// back with force-show still on; the stage gate makes the latch harmless.
    var forceShowTags = false
    /// Fires after EVERY tag-map landing, because every landing goes through
    /// `applyTagMap`: a store change, an async match result, `clear()` wiping
    /// the map on each new query, and the blank placeholder the async path
    /// lands before its real result. The last two carry an empty map, so a
    /// listener that rebuilds shared UI must decide for itself whether a
    /// blank map is worth acting on. ContentViewController uses this to
    /// refresh the Inspector's Tags section in place.
    var onTagMapChanged: (() -> Void)?
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
        // `.automatic` resolves to `.inset` on macOS 11+, which adds leading padding
        // nobody chose — it is what the row-number dot was invented to live beside.
        // `.fullWidth` removes it, so the row's leading edge is the tag bar's home
        // and the gutter is exactly the bar's width.
        tableView.style = .fullWidth
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

        // Tags are global, so every post is for this grid: there is no
        // connection to filter on any more. The observer stays cheap and must
        // not write `AppStateManager` state — `TagStore` is `@MainActor` and
        // posts synchronously, so this can run on a caller's own stack.
        tagStoreObserver = NotificationCenter.default.addObserver(
            forName: TagStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            // `addObserver`'s block is `@Sendable`, so the compiler cannot see that
            // `queue: .main` already guarantees main-actor execution — every
            // `@MainActor` member touched below would otherwise warn, and those
            // warnings become ERRORS in the Swift 6 language mode. Asserting the
            // isolation is correct here and is the pattern `TagStore`'s own hook in
            // `AppStateManager` uses for the same reason.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recomputeTagMap()
                if self.columnFilterController.activeFilters[TagFunnel.columnId] != nil
                    || self.forceShowTags {
                    // A tag change can change which rows are VISIBLE.
                    self.recomputeDisplayRows()
                } else {
                    self.tableView.reloadData()
                    self.updateStatusBarText()
                }
            }
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
        tagController = ResultsTagController(grid: self, copyExport: copyExport)
        tableView.menu = tagController.buildContextMenu()

        copyButton.target = copyExport
        copyButton.action = #selector(ResultsCopyExport.showCopyMenu)
        exportButton.target = copyExport
        exportButton.action = #selector(ResultsCopyExport.showExportMenu)

        // columnFilterController.delegate is wired in loadView(); this closure is
        // grouped with the rest of setupHelpers()'s post-construction wiring instead.
        columnFilterController.rowTagIds = { [weak self] dataRow in
            self?.matchesByRow[dataRow]?.map { $0.tagId } ?? []
        }

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
        rowIdentity = nil
        // Rows are gone; a stale map would leak into the status text and stage gates.
        applyTagMap([:])
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
        // At 40pt with a 6pt inset each side the text gets 28pt, and "9999" measures
        // 27.97pt in the row-number font, so four digits just fit at the default
        // width. The tag marker is the row view's bar, in the gutter to the left of
        // this column, so it needs no room here.
        rowNumCol.width = 40
        rowNumCol.minWidth = 30
        rowNumCol.maxWidth = 60
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

    /// Apply a stage-2 result and finish the cascade. The ONE copy of this tail —
    /// `recomputeDisplayRows` ends here.
    ///
    /// Find stays push-based: `ResultsFindController` reports through
    /// `findControllerDidUpdateResults` rather than returning a list, so when find is
    /// visible this hands off and that callback finishes the job. Find is therefore
    /// still stage 3, downstream of the column filters, exactly as before.
    func applyColumnFiltered(_ newFiltered: [Int]) {
        columnFilteredDisplayRows = newFiltered
        if findController.isFindVisible {
            findController.findFieldChanged(findField)
        } else {
            displayRows = columnFilteredDisplayRows
            pushDataToHelpers()
            tableView.reloadData()
        }
        updateStatusBarText()
    }

    /// The single place that rebuilds `displayRows` from `unfilteredDisplayRows`.
    ///
    /// The composition lives in `DisplayRowPipeline`, which is tested offline —
    /// the stage ORDER is the part worth pinning, and it cannot be tested through
    /// a view controller. Stage 1 (the tag funnel), stage 2 (the column filters),
    /// and stage 4 (the force-show merge) are all wired here; find remains stage 3,
    /// applied downstream by `applyColumnFiltered`. Stage 4 runs before find in
    /// this wiring — see the inline comment on the `forceShow` closure below for
    /// why (scope decision 2).
    func recomputeDisplayRows() {
        applyColumnFiltered(
            DisplayRowPipeline.run(
                unfiltered: unfilteredDisplayRows,
                stages: .init(
                    tagFilter: { [weak self] rows in
                        guard let self else { return rows }
                        return self.columnFilterController.applyTagFilter(inputDisplayRows: rows)
                    },
                    columnFilters: { [weak self] rows in
                        guard let self else { return rows }
                        return self.columnFilterController.applyFilters(inputDisplayRows: rows)
                    },
                    // Stage 4 runs BEFORE find in this wiring (scope decision 2):
                    // find's match set and navigation are display-indexed against
                    // its own input, so inserting rows after find would break
                    // both. Find therefore sees the merged list.
                    forceShow: (forceShowTags && !matchesByRow.isEmpty)
                        ? DisplayRowPipeline.forceShowAdmitting(taggedRows: Set(matchesByRow.keys))
                        : nil)))
    }

    /// Kept as the name the rest of the class already calls. The composition now
    /// lives in `recomputeDisplayRows()`.
    func recomputeColumnFilteredRows() {
        recomputeDisplayRows()
    }

    // MARK: - Status Bar

    func updateStatusBarText() {
        let timeStr = formatDuration(executionTimeMs)
        let moreStr = hasMore ? " (more available)" : ""
        let filterCount = columnFilterController.activeFilterCount
        let filterSuffix = filterCount > 0
            ? " \u{2022} \(filterCount) filter\(filterCount == 1 ? "" : "s")"
            : ""
        let tagCount = matchesByRow.count
        let tagSuffix = tagCount > 0
            ? " \u{2022} \(formatRowCount(tagCount)) tagged"
            : ""

        let findVisible = findController.isFindVisible
        let findMatchCount = findController.findMatches.count
        if (findVisible || filterCount > 0 || forceShowTags) && displayRows.count < rows.count {
            let visibleCount = formatRowCount(displayRows.count)
            let total = formatRowCount(rows.count)
            statusLabel.stringValue = "\(visibleCount) of \(total) rows in \(timeStr)\(filterSuffix)\(tagSuffix)\(moreStr)"
        } else if findVisible && findMatchCount > 0 {
            let rowStr = formatRowCount(displayRows.count)
            statusLabel.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr) \u{2022} \(findMatchCount) match\(findMatchCount == 1 ? "" : "es")\(filterSuffix)\(tagSuffix)\(moreStr)"
        } else {
            let rowStr = formatRowCount(displayRows.count)
            statusLabel.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr)\(filterSuffix)\(tagSuffix)\(moreStr)"
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

    /// Rows above which matching leaves the main thread. The tuple matcher
    /// always reads the row VALUES — there is no key-only path any more — so
    /// this now gates every result, not just an unkeyed one.
    static let matchAsyncThreshold = 5_000

    /// Monotonic stamp for async tag-map results. Bumped by EVERY recompute,
    /// so a stale background result can never overwrite a newer map.
    private var tagMapGeneration = 0

    /// Rebuild the tag map for the loaded result.
    ///
    /// Called when a result arrives, when a page is appended, and when the store
    /// changes. NOT called per row: the matcher walks the rows once and the data
    /// source then answers each row view from a dictionary.
    func recomputeTagMap() {
        tagMapGeneration += 1
        let index = TagStore.shared.tagIndex
        guard !index.isEmpty else {
            applyTagMap([:])
            return
        }
        // Every value crosses the FFI as text, so the matcher takes a text copy
        // of the result. It is built on the main thread — `rows` is main-actor
        // state — and only the matching itself leaves.
        let columnDefs = columns
        let textRows: [[String?]] = rows.map { row in row.map { $0.stringValue } }

        guard rows.count > Self.matchAsyncThreshold else {
            applyTagMap(TagTupleMatcher.match(columns: columnDefs, rows: textRows, index: index))
            return
        }

        // The previous result's map is keyed by its own row indices; showing it
        // on new rows draws stripes on the wrong rows. Blank is honest during
        // the match. Superseded matches run to completion on the concurrent
        // global queue — bounded at current page sizes; a serial queue or a
        // cancellable Task is the upgrade path if result sizes grow.
        applyTagMap([:])
        let generation = tagMapGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let map = TagTupleMatcher.match(columns: columnDefs, rows: textRows, index: index)
            DispatchQueue.main.async {
                // `DispatchQueue.main.async`'s closure is `@Sendable`, so the
                // compiler cannot see that main-queue dispatch already
                // guarantees main-actor execution — same reasoning as the
                // `TagStore.didChange` observer above.
                MainActor.assumeIsolated {
                    guard let self, self.tagMapGeneration == generation else { return }
                    self.applyTagMap(map)
                    if self.columnFilterController.activeFilters[TagFunnel.columnId] != nil
                        || self.forceShowTags {
                        // Tags decide visibility here; the map just changed.
                        self.recomputeDisplayRows()
                    } else {
                        self.tableView.reloadData()
                        self.updateStatusBarText()
                    }
                }
            }
        }
    }

    /// The single landing point for a computed tag map, sync or async.
    func applyTagMap(_ map: [Int: [TagRowMatch]]) {
        // Any landed map supersedes an in-flight match: a stale async result
        // must fail its generation check even when the landing came from
        // clear() or a sync path.
        tagMapGeneration += 1
        matchesByRow = map
        // Bands, tooltips and tints are baked HERE, once, and the data source
        // only looks them up. One bake also means one survivor rule: a deleted
        // tag leaves all three together.
        let state = TagPalette.bake(tags: TagStore.shared.tags, matchesByRow: map)
        dataSource.segmentsByRow = state.segmentsByRow
        dataSource.tooltipByRow = state.tooltipByRow
        dataSource.tintByRow = state.tintByRow
        dataSource.tagTints = state.tints
        copyExport.taggedRows = Set(map.keys)
        syncTagButton()
        onTagMapChanged?()
    }

    // MARK: - Tagging

    /// The current selection as DATA row indices. Selection APIs speak display
    /// indices; the tag map speaks data indices.
    func selectedDataRows() -> [Int] {
        guard let state = cellSelectionController?.state else { return [] }
        return state.selectedRowIndices().compactMap {
            $0 < displayRows.count ? displayRows[$0] : nil
        }
    }

    /// The rows a tag action applies to: the clicked row when the click landed
    /// outside the selection, else the selection. (The SavedQueries menu rule.)
    ///
    /// Only safe to call synchronously from inside the right-click that just
    /// set `tableView.clickedRow` (i.e. `ResultsTagController`'s context menu,
    /// which reads it from `menuNeedsUpdate` during that same click). It is
    /// NOT safe for anything that can run later, such as a keyboard shortcut:
    /// `ResultsTableView.mouseDown` never calls `super.mouseDown` (it replaces
    /// row selection with cell selection), and `super.mouseDown` is the one
    /// path that resets `clickedRow` to -1 after a plain left-click. Verified
    /// empirically — a synthetic right-click followed by a synthetic
    /// selection-only left-click left `clickedRow` pinned at the old value,
    /// while a stock `NSTableView` reset it to -1 on the same sequence. So a
    /// stale `clickedRow` from an old right-click can silently outlive a later
    /// selection change. Use `selectedDataRows()` for anything that isn't the
    /// context menu itself.
    func tagTargetDataRows() -> [Int] {
        let selection = selectedDataRows()
        let clicked = tableView.clickedRow
        if clicked >= 0, clicked < displayRows.count {
            let selectedDisplay = cellSelectionController?.state.selectedRowIndices() ?? IndexSet()
            if !selectedDisplay.contains(clicked) { return [displayRows[clicked]] }
        }
        return selection
    }

    /// ⌘L and the context menu's "Add Tag…": open the modal on the target rows.
    ///
    /// Deliberately `selectedDataRows()`, not `tagTargetDataRows()` — see that
    /// method's doc comment. This can fire from the main menu long after the
    /// last click, and `clickedRow` is not reset by this table's `mouseDown`.
    ///
    /// There is no quick-tag path any more: breadth needs the live count in
    /// front of the analyst, which is the whole reason the modal exists.
    @objc func presentTagSheet(_ sender: Any?) {
        presentTagSheet(on: selectedDataRows())
    }

    func presentTagSheet(on targets: [Int]) {
        // A sheet needs a window to hang from; a grid off screen just beeps.
        guard !targets.isEmpty, view.window != nil else { NSSound.beep(); return }
        let sheet = TagSheet(context: TagSheet.Context(
            columns: columns,
            selectedRows: targets.compactMap { row in
                row < rows.count ? rows[row].map { $0.stringValue } : nil
            },
            loadedRows: rows.map { row in row.map { $0.stringValue } },
            originConnection: AppStateManager.shared.activeConnectionId ?? "",
            // Provenance only. A result with no source table is still taggable —
            // the "no source table" refusal retired with row identity.
            originTable: rowIdentity?.tableDisplay ?? "",
            existingTags: TagStore.shared.tags))
        presentAsSheet(sheet)
    }

    /// "Manage Tags…": rename, recolour, note, delete. `preselect` lands the
    /// sheet on a specific tag (the Inspector's per-tag Edit button).
    func presentTagManageSheet(preselect: String?) {
        guard view.window != nil, !TagStore.shared.tags.isEmpty else {
            NSSound.beep()
            return
        }
        presentAsSheet(TagManageSheet(preselect: preselect))
    }

    /// "Remove From Tag…": open the removal confirmation sheet on the tuples
    /// the target rows complete. The sheet — not this method — deletes;
    /// see `TagRemovalSheet` for the disclosure rules.
    func presentTagRemovalSheet(on targets: [Int]) {
        guard view.window != nil else { NSSound.beep(); return }
        let groups = TagRemovalModel.groups(
            targetRows: targets,
            matchesByRow: matchesByRow,
            tags: TagStore.shared.tags)
        // An empty result means every target row is dashed-only, or the tuples
        // went while the menu was open: there is nothing to disclose and the
        // footer would read "Removes 0 tuples from 0 tags."
        guard !groups.isEmpty else { NSSound.beep(); return }
        presentAsSheet(TagRemovalSheet(groups: groups, remover: TagStore.shared))
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
        copyExport.taggedRows = Set(matchesByRow.keys)
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

    // MARK: - Force-Show Tagged Rows

    @objc func toggleForceShowTags() {
        forceShowTags.toggle()
        syncTagButton()
        recomputeDisplayRows()
    }

    /// Visibility and polarity. Hidden while nothing is tagged; filled + tinted
    /// while the toggle is on. Reapplies `configureToolbarButtonAppearance`'s
    /// point-size-13/medium symbol configuration on every swap so the glyph
    /// stays the same size as its toolbar siblings instead of falling back to
    /// the system default.
    func syncTagButton() {
        tagButton.isHidden = matchesByRow.isEmpty
        let symbol = forceShowTags ? "tag.fill" : "tag"
        let config = ContentViewController.toolbarSymbolConfiguration
        tagButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Force-show tagged rows")?.withSymbolConfiguration(config)
        tagButton.contentTintColor = forceShowTags ? .controlAccentColor : .secondaryLabelColor
        tagButton.setAccessibilityValue(forceShowTags ? "on" : "off")
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
