import AppKit
import UniformTypeIdentifiers

// MARK: - Scroll View with Non-Overlapping Scrollers

/// NSScrollView subclass that positions scrollers outside the content area
/// instead of overlaying them on top of the document view.
private class InsetScrollView: NSScrollView {
    override func tile() {
        super.tile()

        // Only adjust the clip view's SIZE to make room for scrollers.
        // Do NOT change its origin — super.tile() positions it correctly
        // relative to the floating header. Moving it creates a gap.
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let hasVert = hasVerticalScroller && !(verticalScroller?.isHidden ?? true)
        let hasHoriz = hasHorizontalScroller && !(horizontalScroller?.isHidden ?? true)
        let vertW = hasVert ? w : 0
        let horizH = hasHoriz ? w : 0

        var clipFrame = contentView.frame
        clipFrame.size.width = max(0, bounds.width - vertW)
        clipFrame.size.height = max(0, clipFrame.size.height - horizH)
        contentView.frame = clipFrame

        // Vertical scroller: starts below the header, spans data rows only
        let headerH = (documentView as? NSTableView)?.headerView?.frame.height ?? 0
        if hasVert, let vs = verticalScroller {
            vs.frame = NSRect(
                x: bounds.width - vertW,
                y: headerH,
                width: vertW,
                height: max(0, clipFrame.maxY - headerH)
            )
        }

        // Horizontal scroller: right below the clip view
        if hasHoriz, let hs = horizontalScroller {
            hs.frame = NSRect(x: 0, y: clipFrame.maxY, width: clipFrame.width, height: horizH)
        }
    }
}

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
class ResultsGridVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    private let tableView = NSTableView()
    private let scrollView = InsetScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Run a query to see results")

    // Toolbar
    private let toolbarBar = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pinSourceLabel = NSTextField(labelWithString: "")
    private let resetSortButton = NSButton()
    private let pinButton = NSButton()
    private let findToolbarButton = NSButton()
    private let copyButton = NSButton()
    private let exportButton = NSButton()

    // Data
    private var columns: [ColumnDef] = []
    private var rows: [[String: AnyCodable]] = []
    private var rowCount: Int = 0
    private var hasMore: Bool = false
    private var executionTimeMs: UInt64 = 0
    private var columnCategories: [String: PGTypeCategory] = [:]

    // Sort state
    private var displayRows: [Int] = []
    private var unfilteredDisplayRows: [Int] = []
    private var currentSortColumn: String?
    private var currentSortAscending = true
    private var sortClickCount = 0

    // Find state
    private let findBar = NSView()
    private let findField = NSSearchField()
    private let filterToggleButton = NSButton()
    private let findClearButton = NSButton()
    private let findCountLabel = NSTextField(labelWithString: "")
    private let findPrevButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()
    private var isFindVisible = false
    private var isFilterMode = false
    private var findMatches: [(row: Int, colId: String)] = []
    private var findMatchSet: Set<CellAddress> = Set()
    private var currentMatchIndex: Int = -1

    // Load more
    private let loadMoreBar = NSView()
    private let loadMoreButton = NSButton(title: "Load More Rows", target: nil, action: nil)
    private let loadMoreSpinner = NSProgressIndicator()
    private var isLoadingMore = false

    // Layout constraints to toggle
    private var scrollViewTopToToolbar: NSLayoutConstraint!
    private var scrollViewTopToFindBar: NSLayoutConstraint!
    private var scrollViewBottomToLoadMore: NSLayoutConstraint!
    private var scrollViewBottomToContainer: NSLayoutConstraint!

    // Callbacks
    var onLoadMore: (() -> Void)?
    var onPinToggle: ((Bool) -> Void)?

    // Pin state
    private var isPinned = false

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

        // Toolbar at top
        setupToolbar()

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

        container.addSubview(toolbarBar)
        container.addSubview(findBar)
        container.addSubview(scrollView)
        container.addSubview(loadMoreBar)
        container.addSubview(emptyLabel)

        // Toggleable constraints
        scrollViewTopToToolbar = scrollView.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor, constant: 2)
        scrollViewTopToFindBar = scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 2)
        scrollViewBottomToContainer = scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        scrollViewBottomToLoadMore = scrollView.bottomAnchor.constraint(equalTo: loadMoreBar.topAnchor)

        NSLayoutConstraint.activate([
            toolbarBar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbarBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbarBar.heightAnchor.constraint(equalToConstant: 28),

            findBar.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBar.heightAnchor.constraint(equalToConstant: 28),

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

    // MARK: - Toolbar Setup

    private func setupToolbar() {
        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarBar.isHidden = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinSourceLabel.translatesAutoresizingMaskIntoConstraints = false
        pinSourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pinSourceLabel.textColor = .systemOrange
        pinSourceLabel.isHidden = true
        pinSourceLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureToolbarButton(resetSortButton, symbol: "arrow.up.arrow.down.circle.fill",
                               action: #selector(resetSortTapped), tooltip: "Reset Sort")
        resetSortButton.contentTintColor = .controlAccentColor
        resetSortButton.isHidden = true

        configureToolbarButton(pinButton, symbol: "pin",
                               action: #selector(togglePin), tooltip: "Pin Results")
        configureToolbarButton(findToolbarButton, symbol: "magnifyingglass",
                               action: #selector(showFind), tooltip: "Find (Cmd+F)")
        configureToolbarButton(copyButton, symbol: "doc.on.doc",
                               action: #selector(showCopyMenu), tooltip: "Copy")
        configureToolbarButton(exportButton, symbol: "square.and.arrow.up",
                               action: #selector(showExportMenu), tooltip: "Export")

        let buttonStack = NSStackView(views: [resetSortButton, pinButton, findToolbarButton, copyButton, exportButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setHuggingPriority(.required, for: .horizontal)

        toolbarBar.addSubview(statusLabel)
        toolbarBar.addSubview(pinSourceLabel)
        toolbarBar.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: toolbarBar.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),

            pinSourceLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            pinSourceLabel.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
            pinSourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -8),

            buttonStack.trailingAnchor.constraint(equalTo: toolbarBar.trailingAnchor, constant: -8),
            buttonStack.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),
        ])
    }

    private func configureToolbarButton(_ button: NSButton, symbol: String, action: Selector, tooltip: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
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

        filterToggleButton.setButtonType(.pushOnPushOff)
        filterToggleButton.title = "Filter"
        filterToggleButton.bezelStyle = .recessed
        filterToggleButton.font = .systemFont(ofSize: 11)
        filterToggleButton.target = self
        filterToggleButton.action = #selector(filterToggleChanged)
        filterToggleButton.translatesAutoresizingMaskIntoConstraints = false
        filterToggleButton.toolTip = "Filter rows to matches only"

        findClearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        findClearButton.bezelStyle = .recessed
        findClearButton.isBordered = false
        findClearButton.target = self
        findClearButton.action = #selector(clearFindField)
        findClearButton.translatesAutoresizingMaskIntoConstraints = false
        findClearButton.contentTintColor = .tertiaryLabelColor
        findClearButton.isHidden = true

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
        findBar.addSubview(filterToggleButton)
        findBar.addSubview(findClearButton)
        findBar.addSubview(findCountLabel)
        findBar.addSubview(findPrevButton)
        findBar.addSubview(findNextButton)
        findBar.addSubview(findCloseButton)

        NSLayoutConstraint.activate([
            findField.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findField.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            filterToggleButton.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 6),
            filterToggleButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),

            findClearButton.leadingAnchor.constraint(equalTo: filterToggleButton.trailingAnchor, constant: 4),
            findClearButton.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findClearButton.widthAnchor.constraint(equalToConstant: 20),

            findCountLabel.leadingAnchor.constraint(equalTo: findClearButton.trailingAnchor, constant: 8),
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
        unfilteredDisplayRows = displayRows
        currentSortColumn = nil
        sortClickCount = 0
        resetSortButton.isHidden = true

        rebuildColumns()
        tableView.reloadData()
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        toolbarBar.isHidden = false

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

        // Extend with new indices
        let newIndices = Array(oldCount..<rows.count)
        unfilteredDisplayRows.append(contentsOf: newIndices)
        displayRows = unfilteredDisplayRows

        // Re-apply sort if active
        if currentSortColumn != nil {
            applySortAndReload()
        } else if isFilterMode && isFindVisible && !findField.stringValue.isEmpty {
            findFieldChanged(findField)
        } else {
            tableView.reloadData()
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
        rowCount = 0
        hasMore = false
        executionTimeMs = 0
        columnCategories = [:]
        currentSortColumn = nil
        sortClickCount = 0
        resetSortButton.isHidden = true

        // Remove all table columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }
        tableView.reloadData()
        emptyLabel.stringValue = "Run a query to see results"
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = false
        scrollView.isHidden = true
        toolbarBar.isHidden = true

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
        let timeStr = formatDuration(executionTimeMs)
        let moreStr = hasMore ? " (more available)" : ""

        if isFilterMode && isFindVisible && !findField.stringValue.isEmpty {
            let visibleCount = formatRowCount(displayRows.count)
            let total = formatRowCount(rows.count)
            statusLabel.stringValue = "\(visibleCount) of \(total) rows in \(timeStr)\(moreStr)"
        } else if isFindVisible && !findMatches.isEmpty {
            let rowStr = formatRowCount(displayRows.count)
            statusLabel.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr) \u{2022} \(findMatches.count) match\(findMatches.count == 1 ? "" : "es")\(moreStr)"
        } else {
            let rowStr = formatRowCount(displayRows.count)
            statusLabel.stringValue = "\(rowStr) row\(displayRows.count == 1 ? "" : "s") in \(timeStr)\(moreStr)"
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
            unfilteredDisplayRows = Array(0..<rows.count)
            displayRows = unfilteredDisplayRows
            resetSortButton.isHidden = true
            updateSortIndicators()
            if isFilterMode && isFindVisible && !findField.stringValue.isEmpty {
                findFieldChanged(findField)
            } else {
                tableView.reloadData()
            }
            return
        }

        let category = columnCategories[sortKey] ?? .string
        let ascending = currentSortAscending

        // Sort all rows
        unfilteredDisplayRows = Array(0..<rows.count)
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

        displayRows = unfilteredDisplayRows
        resetSortButton.isHidden = false
        updateSortIndicators()

        // Re-apply filter if active
        if isFilterMode && isFindVisible && !findField.stringValue.isEmpty {
            findFieldChanged(findField)
        } else {
            tableView.reloadData()
        }
    }

    private func resetSort() {
        currentSortColumn = nil
        sortClickCount = 0
        tableView.sortDescriptors = []
        unfilteredDisplayRows = Array(0..<rows.count)
        displayRows = unfilteredDisplayRows
        resetSortButton.isHidden = true
        updateSortIndicators()

        if isFilterMode && isFindVisible && !findField.stringValue.isEmpty {
            findFieldChanged(findField)
        } else {
            tableView.reloadData()
        }
    }

    @objc private func resetSortTapped() {
        resetSort()
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
            textField.stringValue = AppStateManager.shared.settings.nullDisplay.rawValue
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

    // MARK: - Escape to Deselect

    @objc override func cancelOperation(_ sender: Any?) {
        if isFindVisible {
            closeFind(nil)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - Find

    @objc func showFind() {
        guard !rows.isEmpty else { return }
        if isFindVisible {
            findField.window?.makeFirstResponder(findField)
            return
        }
        isFindVisible = true
        findBar.isHidden = false
        scrollViewTopToToolbar.isActive = false
        scrollViewTopToFindBar.isActive = true
        findField.window?.makeFirstResponder(findField)
    }

    @objc func showFilter() {
        guard !rows.isEmpty else { return }
        if !isFindVisible {
            isFindVisible = true
            findBar.isHidden = false
            scrollViewTopToToolbar.isActive = false
            scrollViewTopToFindBar.isActive = true
        }
        filterToggleButton.state = .on
        isFilterMode = true
        findField.window?.makeFirstResponder(findField)
        if !findField.stringValue.isEmpty {
            findFieldChanged(findField)
        }
    }

    @objc private func closeFind(_ sender: Any?) {
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
        displayRows = unfilteredDisplayRows

        scrollViewTopToFindBar.isActive = false
        scrollViewTopToToolbar.isActive = true
        tableView.reloadData()
        updateStatusBarText()
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func filterToggleChanged() {
        isFilterMode = filterToggleButton.state == .on
        findFieldChanged(findField)
    }

    @objc private func clearFindField() {
        findField.stringValue = ""
        findFieldChanged(findField)
    }

    @objc private func findFieldChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.lowercased()
        findClearButton.isHidden = query.isEmpty

        // Always start from the unfiltered set
        displayRows = unfilteredDisplayRows

        guard !query.isEmpty else {
            findMatches = []
            findMatchSet = Set()
            currentMatchIndex = -1
            findCountLabel.stringValue = ""
            tableView.reloadData()
            updateStatusBarText()
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
            displayRows = unfilteredDisplayRows.filter { matchingRowIndices.contains($0) }

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

    private var hasSelection: Bool {
        !tableView.selectedRowIndexes.isEmpty
    }

    @objc func copy(_ sender: Any?) {
        copyAsTSV(sender)
    }

    /// Gathers data for copy/export. Uses selected rows if any, otherwise all displayed rows.
    private func gatherData() -> CopyData? {
        let selectedRows = tableView.selectedRowIndexes

        let colIds = tableView.tableColumns.compactMap { col -> String? in
            let id = col.identifier.rawValue
            return id == "__rownum__" ? nil : id
        }
        guard !colIds.isEmpty else { return nil }

        var rowData: [[String]] = []

        if !selectedRows.isEmpty {
            for row in selectedRows {
                guard row < displayRows.count else { continue }
                let data = rows[displayRows[row]]
                let values = colIds.map { data[$0]?.displayString ?? "" }
                rowData.append(values)
            }
        } else {
            for row in 0..<displayRows.count {
                let data = rows[displayRows[row]]
                let values = colIds.map { data[$0]?.displayString ?? "" }
                rowData.append(values)
            }
        }

        guard !rowData.isEmpty else { return nil }
        return CopyData(columnNames: colIds, rows: rowData)
    }

    @objc func copyAsTSV(_ sender: Any?) {
        guard let data = gatherData() else { return }
        let header = data.columnNames.joined(separator: "\t")
        let lines = data.rows.map { $0.joined(separator: "\t") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([header] + lines).joined(separator: "\n"), forType: .string)
    }

    @objc func copyAsCSV(_ sender: Any?) {
        guard let data = gatherData() else { return }
        let header = data.columnNames.map { Self.csvEscape($0) }.joined(separator: ",")
        let rows = data.rows.map { $0.map { Self.csvEscape($0) }.joined(separator: ",") }
        let result = ([header] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @objc func copyAsMarkdown(_ sender: Any?) {
        guard let data = gatherData() else { return }
        let header = "| " + data.columnNames.joined(separator: " | ") + " |"
        let divider = "| " + data.columnNames.map { _ in "---" }.joined(separator: " | ") + " |"
        let rows = data.rows.map { "| " + $0.joined(separator: " | ") + " |" }
        let result = ([header, divider] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @objc func copyAsSQLInsert(_ sender: Any?) {
        guard let data = gatherData() else { return }
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

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Pin Results

    @objc private func togglePin() {
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

    // MARK: - Copy Menu

    @objc private func showCopyMenu() {
        let prefix = hasSelection ? "Copy selection" : "Copy"
        let menu = NSMenu()
        menu.addItem(withTitle: "\(prefix) as TSV", action: #selector(copyAsTSV), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as CSV", action: #selector(copyAsCSV), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as Markdown", action: #selector(copyAsMarkdown), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as SQL INSERT", action: #selector(copyAsSQLInsert), keyEquivalent: "")
        let point = NSPoint(x: 0, y: 0)
        menu.popUp(positioning: nil, at: point, in: copyButton)
    }

    // MARK: - Export

    @objc private func showExportMenu() {
        let prefix = hasSelection ? "Export selection" : "Export"
        let menu = NSMenu()
        menu.addItem(withTitle: "\(prefix) as CSV…", action: #selector(exportAsCSV), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as TSV…", action: #selector(exportAsTSV), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as JSON…", action: #selector(exportAsJSON), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as SQL INSERT…", action: #selector(exportAsSQLInsert), keyEquivalent: "")
        menu.addItem(withTitle: "\(prefix) as Markdown…", action: #selector(exportAsMarkdown), keyEquivalent: "")
        let point = NSPoint(x: 0, y: 0)
        menu.popUp(positioning: nil, at: point, in: exportButton)
    }

    private func exportToFile(filename: String, contentType: UTType, generator: @escaping (CopyData) -> String) {
        guard let data = gatherData(), let window = view.window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [contentType]

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let content = generator(data)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func exportAsCSV(_ sender: Any?) {
        exportToFile(filename: "export.csv", contentType: .commaSeparatedText) { data in
            let header = data.columnNames.map { Self.csvEscape($0) }.joined(separator: ",")
            let rows = data.rows.map { $0.map { Self.csvEscape($0) }.joined(separator: ",") }
            return ([header] + rows).joined(separator: "\n")
        }
    }

    @objc private func exportAsTSV(_ sender: Any?) {
        exportToFile(filename: "export.tsv", contentType: .tabSeparatedText) { data in
            let header = data.columnNames.joined(separator: "\t")
            let rows = data.rows.map { $0.joined(separator: "\t") }
            return ([header] + rows).joined(separator: "\n")
        }
    }

    @objc private func exportAsJSON(_ sender: Any?) {
        guard let data = gatherData(), let window = view.window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.json"
        panel.allowedContentTypes = [.json]

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let jsonArray = data.rows.map { row in
                    Dictionary(uniqueKeysWithValues: zip(data.columnNames, row))
                }
                let jsonData = try JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys])
                try jsonData.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func exportAsSQLInsert(_ sender: Any?) {
        let cats = columnCategories
        exportToFile(filename: "export.sql", contentType: UTType(filenameExtension: "sql") ?? .plainText) { data in
            let colList = data.columnNames.map { "\"\($0)\"" }.joined(separator: ", ")
            let statements = data.rows.map { row in
                let values = zip(data.columnNames, row).map { (col, val) -> String in
                    if val.isEmpty || val == "NULL" { return "NULL" }
                    let category = cats[col] ?? .string
                    switch category {
                    case .numeric, .boolean:
                        return val
                    default:
                        return "'\(val.replacingOccurrences(of: "'", with: "''"))'"
                    }
                }
                return "INSERT INTO table_name (\(colList)) VALUES (\(values.joined(separator: ", ")));"
            }
            return statements.joined(separator: "\n")
        }
    }

    @objc private func exportAsMarkdown(_ sender: Any?) {
        exportToFile(filename: "export.md", contentType: UTType(filenameExtension: "md") ?? .plainText) { data in
            let header = "| " + data.columnNames.joined(separator: " | ") + " |"
            let divider = "| " + data.columnNames.map { _ in "---" }.joined(separator: " | ") + " |"
            let rows = data.rows.map { "| " + $0.joined(separator: " | ") + " |" }
            return ([header, divider] + rows).joined(separator: "\n")
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let tsv = menu.addItem(withTitle: "Copy as TSV", action: #selector(copyAsTSV), keyEquivalent: "")
        tsv.tag = 1
        let csv = menu.addItem(withTitle: "Copy as CSV", action: #selector(copyAsCSV), keyEquivalent: "")
        csv.tag = 2
        let md = menu.addItem(withTitle: "Copy as Markdown", action: #selector(copyAsMarkdown), keyEquivalent: "")
        md.tag = 3
        let sql = menu.addItem(withTitle: "Copy as SQL INSERT", action: #selector(copyAsSQLInsert), keyEquivalent: "")
        sql.tag = 4

        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let prefix = hasSelection ? "Copy selection" : "Copy"
        for item in menu.items {
            switch item.tag {
            case 1: item.title = "\(prefix) as TSV"
            case 2: item.title = "\(prefix) as CSV"
            case 3: item.title = "\(prefix) as Markdown"
            case 4: item.title = "\(prefix) as SQL INSERT"
            default: break
            }
        }
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
