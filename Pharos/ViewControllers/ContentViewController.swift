import AppKit
import Combine
import UniformTypeIdentifiers

/// Main content area: editor panes + results grid.
/// Manages multiple EditorPaneVCs and query execution.
class ContentViewController: NSViewController {

    private let resultsVC = ResultsGridVC()
    private let paneSplitView = NSSplitView()       // Horizontal: side-by-side editor panes
    private let emptyState = NSView()

    // Action bar — independent element between editor panes and results grid
    let actionBar = ResultsToolbarBar()

    // Result tab bar — between action bar and results grid
    private let resultTabBar = ResultTabBar()

    // Container that holds paneSplitView + actionBar + resultTabBar + resultsVC.view with constraints
    private let contentStack = NSView()

    // Layout constraints for the editor/results split
    private var editorHeightConstraint: NSLayoutConstraint!
    private var resultsTopToResultTabBar: NSLayoutConstraint!
    private var resultsBottomToContainer: NSLayoutConstraint!
    private var resultTabBarHeightConstraint: NSLayoutConstraint!

    // Result tab management — scoped per editor tab
    private var resultTabs: [ResultTab] = []
    private var activeResultTabId: String?
    private var resultTabsByEditorTab: [String: [ResultTab]] = [:]
    private var activeResultTabIdByEditorTab: [String: String] = [:]
    private static let resultTabBarHeight: CGFloat = 26

    // Toolbar UI elements (owned here, configured in setupActionBar)
    let statusLabel = NSTextField(labelWithString: "")
    let pinSourceLabel = NSTextField(labelWithString: "")
    let historyContextLabel = NSTextField(labelWithString: "")
    let resetSortButton = NSButton()
    let resetFiltersButton = NSButton()
    let pinButton = NSButton()
    let findToolbarButton = NSButton()
    let copyButton = NSButton()
    let exportButton = NSButton()
    let expandEditorButton = NSButton()
    let expandResultsButton = NSButton()

    private var editorPanes: [EditorPaneVC] = []

    /// The focused editor pane.
    private var focusedPaneVC: EditorPaneVC? {
        editorPanes.first { $0.paneId == stateManager.focusedPaneId }
    }

    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasSetInitialSplit = false
    private static let splitRatioKey = "PharosEditorSplitRatio"

    /// Query IDs that the user has cancelled. Checked in the error handler to
    /// suppress the "Query failed" notification for user-initiated cancellations.
    private var cancelledQueryIds: Set<String> = []

    // Editor/results expand state
    enum ContentExpandState { case normal, editorExpanded, resultsExpanded }
    private(set) var expandState: ContentExpandState = .normal
    private var savedSplitRatio: CGFloat = 0.6

    // Drag-to-resize state
    private var isDragging = false
    private var dragStartY: CGFloat = 0
    private var dragStartEditorHeight: CGFloat = 0
    private static let actionBarHeight: CGFloat = 32

    override func loadView() {
        let container = NSView()
        self.view = container

        // Pane split view: horizontal split for side-by-side editor panes
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.delegate = self

        addChild(resultsVC)

        // Content stack: paneSplitView (top) | actionBar (middle, 28pt) | resultsVC (bottom)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        resultsVC.view.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addSubview(paneSplitView)
        contentStack.addSubview(actionBar)
        contentStack.addSubview(resultTabBar)
        contentStack.addSubview(resultsVC.view)

        // Result tab bar setup
        resultTabBar.translatesAutoresizingMaskIntoConstraints = false
        resultTabBar.isHidden = true  // Hidden until first result
        resultTabBar.onSelectTab = { [weak self] tabId in
            self?.selectResultTab(tabId)
        }
        resultTabBar.onCloseTab = { [weak self] tabId in
            self?.closeResultTab(tabId)
        }
        resultTabBar.onViewDetail = { [weak self] tabId in
            self?.showResultTabDetail(tabId)
        }

        // Action bar setup
        setupActionBar()

        // Wire results VC to use toolbar elements from this VC
        resultsVC.contentVC = self
        resultsVC.setupHelpers()

        // Empty state (no connection)
        setupEmptyState()

        container.addSubview(contentStack)
        container.addSubview(emptyState)

        let safeTop = container.safeAreaLayoutGuide.topAnchor

        // Editor height starts at a default; will be updated in viewDidLayout
        editorHeightConstraint = paneSplitView.heightAnchor.constraint(equalToConstant: 300)
        editorHeightConstraint.priority = .defaultHigh

        resultTabBarHeightConstraint = resultTabBar.heightAnchor.constraint(equalToConstant: 0)
        resultsTopToResultTabBar = resultsVC.view.topAnchor.constraint(equalTo: resultTabBar.bottomAnchor)
        resultsBottomToContainer = resultsVC.view.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: safeTop),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // PaneSplitView: top, full width
            paneSplitView.topAnchor.constraint(equalTo: contentStack.topAnchor),
            paneSplitView.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            paneSplitView.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            editorHeightConstraint,

            // Action bar: below editor, full width, fixed height
            actionBar.topAnchor.constraint(equalTo: paneSplitView.bottomAnchor),
            actionBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: Self.actionBarHeight),

            // Result tab bar: below action bar, full width
            resultTabBar.topAnchor.constraint(equalTo: actionBar.bottomAnchor),
            resultTabBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            resultTabBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            resultTabBarHeightConstraint,

            // Results: below result tab bar, full width, fills remaining space
            resultsTopToResultTabBar,
            resultsVC.view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            resultsVC.view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            resultsBottomToContainer,

            emptyState.topAnchor.constraint(equalTo: safeTop),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Wire up load more
        resultsVC.onLoadMore = { [weak self] in
            self?.loadMoreRows()
        }

        // Wire up pin toggle
        resultsVC.onPinToggle = { [weak self] pinned in
            self?.handlePinToggle(pinned)
        }

        // Wire up selection changes for inspector
        resultsVC.onSelectionChanged = { [weak self] selectedIndices in
            self?.updateInspector(selectedIndices: selectedIndices)
        }

        // Wire up expand editor / results (handled by action bar buttons directly)

        // Observe state
        stateManager.$activeConnectionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionId in
                self?.updateVisibility()
                if let connectionId, self?.stateManager.status(for: connectionId) == .connected {
                    self?.metadataCache.load(connectionId: connectionId)
                } else {
                    self?.metadataCache.clear()
                }
            }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] statuses in
                self?.updateVisibility()
                // Trigger metadata load when active connection becomes connected
                // (needed because .removeDuplicates on activeConnectionId may suppress
                // the second publish after connection completes)
                if let connId = self?.stateManager.activeConnectionId,
                   self?.stateManager.status(for: connId) == .connected {
                    self?.metadataCache.load(connectionId: connId)
                } else if self?.stateManager.activeConnectionId == nil {
                    self?.metadataCache.clear()
                }

                // Clear cache for connections that disconnected or errored,
                // preserving other connections' caches
                for (connId, status) in statuses {
                    if status == .disconnected || status == .error {
                        self?.metadataCache.clearConnection(connId)
                    }
                }
            }
            .store(in: &cancellables)

        stateManager.$activeSchema
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] schema in
                if let schema {
                    self?.metadataCache.prioritize(schema: schema)
                }
            }
            .store(in: &cancellables)

        // Observe pane changes to sync pane view controllers
        stateManager.$panes
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in
                self?.syncPaneViewControllers(with: panes)
            }
            .store(in: &cancellables)

        // Observe active tab changes to update results grid
        stateManager.$activeTabId
            .receive(on: RunLoop.main)
            .sink { [weak self] tabId in self?.activeTabChanged(tabId) }
            .store(in: &cancellables)

        // Observe pin state changes (e.g. auto-unpin on tab close)
        stateManager.$pinnedTabId
            .receive(on: RunLoop.main)
            .sink { [weak self] pinnedId in
                if pinnedId == nil {
                    self?.resultsVC.setPinState(pinned: false, tabName: nil)
                }
            }
            .store(in: &cancellables)

        // Drive the action-bar pulse from the focused pane's active tab's executing state.
        Publishers.CombineLatest3(
            stateManager.$tabs,
            stateManager.$panes,
            stateManager.$focusedPaneId
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] tabs, panes, focusedPaneId in
            guard let self else { return }
            let focusedPane = panes.first { $0.id == focusedPaneId }
            let activeTabId = focusedPane?.activeTabId
            let activeTab = tabs.first { $0.id == activeTabId }
            self.actionBar.isPulsing = activeTab?.isExecuting == true
        }
        .store(in: &cancellables)

        // Observe "open saved query" from sidebar
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenSavedQuery(_:)),
            name: .openSavedQuery, object: nil
        )

        // Observe "open history entry" from sidebar
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenHistoryEntry(_:)),
            name: .openHistoryEntry, object: nil
        )

        // Observe "run query in new tab" from schema browser context menu
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRunQueryInNewTab(_:)),
            name: .runQueryInNewTab, object: nil
        )

        // Observe "run query in current tab" — execute silently, results in named result tab
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRunQueryInCurrentTab(_:)),
            name: .runQueryInCurrentTab, object: nil
        )

        // Observe "insert text in editor" from schema browser context menu
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInsertTextInEditor(_:)),
            name: .insertTextInEditor, object: nil
        )

        // Observe connection status changes to clear in-flight queries on disconnect
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionStatusChanged(_:)),
            name: AppStateManager.connectionStatusDidChange,
            object: nil
        )

        updateVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Restore saved split ratio once the content area has real height
        if !hasSetInitialSplit, contentStack.bounds.height > 0 {
            hasSetInitialSplit = true
            let saved = UserDefaults.standard.double(forKey: Self.splitRatioKey)
            savedSplitRatio = saved > 0 ? saved : 0.6
            applyExpandState()
        }
    }

    // MARK: - Pane Sync

    /// Add/remove EditorPaneVC instances to match the state manager's panes.
    private func syncPaneViewControllers(with panes: [EditorPane]) {
        let currentPaneIds = Set(editorPanes.map(\.paneId))
        let targetPaneIds = Set(panes.map(\.id))

        // Remove panes that no longer exist
        for paneVC in editorPanes where !targetPaneIds.contains(paneVC.paneId) {
            paneVC.view.removeFromSuperview()
            paneVC.removeFromParent()
        }
        editorPanes.removeAll { !targetPaneIds.contains($0.paneId) }

        // Add new panes (don't add to split view yet — we rebuild below)
        for pane in panes where !currentPaneIds.contains(pane.id) {
            let paneVC = EditorPaneVC(paneId: pane.id)
            paneVC.delegate = self
            addChild(paneVC)
            editorPanes.append(paneVC)
        }

        // Reorder to match state manager order
        let ordered = panes.compactMap { pane in
            editorPanes.first { $0.paneId == pane.id }
        }
        editorPanes = ordered

        // Determine which pane views should be arranged in the split view
        let expandedPane = panes.first(where: { $0.isExpanded })
        let visiblePaneVCs: [EditorPaneVC]
        if let expanded = expandedPane {
            // Only show the expanded pane
            visiblePaneVCs = editorPanes.filter { $0.paneId == expanded.id }
        } else {
            visiblePaneVCs = editorPanes
        }

        // Rebuild paneSplitView's arranged subviews to match visiblePaneVCs.
        // Remove subviews that shouldn't be visible, add those that should be.
        let currentArranged = paneSplitView.arrangedSubviews
        let targetViews = visiblePaneVCs.map(\.view)

        // Remove views that are no longer visible
        for view in currentArranged where !targetViews.contains(view) {
            paneSplitView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Add views that are missing, in the correct order
        for (index, paneVC) in visiblePaneVCs.enumerated() {
            let view = paneVC.view
            view.isHidden = false
            if !paneSplitView.arrangedSubviews.contains(view) {
                if index < paneSplitView.arrangedSubviews.count {
                    // Insert at correct position
                    paneSplitView.insertArrangedSubview(view, at: index)
                } else {
                    paneSplitView.addArrangedSubview(view)
                }
            }
        }

        // Ensure correct ordering of arranged subviews
        let arranged = paneSplitView.arrangedSubviews
        for (index, paneVC) in visiblePaneVCs.enumerated() {
            let view = paneVC.view
            if index < arranged.count && arranged[index] !== view {
                // Wrong order — remove and re-insert
                paneSplitView.removeArrangedSubview(view)
                view.removeFromSuperview()
                paneSplitView.insertArrangedSubview(view, at: index)
            }
        }

        paneSplitView.adjustSubviews()

        // Split evenly when we have multiple visible panes
        if visiblePaneVCs.count > 1 {
            DispatchQueue.main.async {
                let totalWidth = self.paneSplitView.bounds.width
                let dividerThickness = self.paneSplitView.dividerThickness
                let count = CGFloat(visiblePaneVCs.count)
                let totalDividers = dividerThickness * (count - 1)
                let paneWidth = (totalWidth - totalDividers) / count
                for i in 0..<(visiblePaneVCs.count - 1) {
                    let position = paneWidth * CGFloat(i + 1) + dividerThickness * CGFloat(i)
                    self.paneSplitView.setPosition(position, ofDividerAt: i)
                }
            }
        }

        updateSplitViewVisibility()
    }

    // MARK: - Active Tab Changed (results grid update)

    private var lastActiveTabId: String?

    private func activeTabChanged(_ tabId: String?) {
        // Save grid state and result tabs of the tab we're leaving
        if let previousTabId = lastActiveTabId {
            let gridState = resultsVC.captureGridState()
            stateManager.updateTab(id: previousTabId) { tab in
                tab.gridState = gridState
            }
            // Also save grid state to the active result tab
            if let activeRTId = activeResultTabId,
               let rtIdx = resultTabs.firstIndex(where: { $0.id == activeRTId }) {
                resultTabs[rtIdx].gridState = gridState
            }
            // Persist result tabs for the previous editor tab
            resultTabsByEditorTab[previousTabId] = resultTabs
            if let activeRTId = activeResultTabId {
                activeResultTabIdByEditorTab[previousTabId] = activeRTId
            } else {
                activeResultTabIdByEditorTab.removeValue(forKey: previousTabId)
            }
        }
        lastActiveTabId = tabId

        guard let tabId, let tab = stateManager.tabs.first(where: { $0.id == tabId }) else {
            resultsVC.clear()
            resultTabs = []
            activeResultTabId = nil
            updateResultTabBarVisibility()
            updateSplitViewVisibility()
            return
        }

        updateSplitViewVisibility()

        // Restore result tabs for the new editor tab
        resultTabs = resultTabsByEditorTab[tabId] ?? []
        activeResultTabId = activeResultTabIdByEditorTab[tabId]
        updateResultTabBarVisibility()

        // Pin override: while pinned, the grid stays on the pinned result no
        // matter which editor tab is active. Result tab bar still reflects the
        // destination tab — clicking a result tab in it explicitly unpins.
        if let pinnedResult = stateManager.pinnedResult {
            resultsVC.showResult(pinnedResult)
            resultsVC.setPinState(pinned: true, tabName: stateManager.pinnedTabName)
        } else if let activeRTId = activeResultTabId,
                  let activeRT = resultTabs.first(where: { $0.id == activeRTId }) {
            if let result = activeRT.queryResult {
                resultsVC.showResult(result)
            } else if let execResult = activeRT.executeResult {
                resultsVC.showExecuteResult(execResult)
            }
            if let gridState = activeRT.gridState {
                resultsVC.restoreGridState(gridState)
            }
        } else if let result = tab.result {
            resultsVC.showResult(result)
            if let gridState = tab.gridState {
                resultsVC.restoreGridState(gridState)
            }
        } else if let execResult = tab.executeResult {
            resultsVC.showExecuteResult(execResult)
        } else if let error = tab.error {
            resultsVC.showError(error)
        } else {
            resultsVC.clear()
        }

        // Re-resolve and restore segment colors in the gutter.
        reResolveAllResultTabs(immediate: true)

        // Show/hide history context for this tab. Suppress while pinned —
        // the grid is showing the pinned tab's data, not this tab's history.
        if stateManager.pinnedResult == nil, let historyTimestamp = tab.historyTimestamp {
            resultsVC.showHistoryContext(schema: tab.historySchema, timestamp: historyTimestamp)
        } else {
            resultsVC.hideHistoryContext()
        }
    }

    // MARK: - Inspector

    private func updateInspector(selectedIndices: IndexSet) {
        guard let splitVC = parent as? PharosSplitViewController else { return }

        if selectedIndices.isEmpty {
            splitVC.inspectorVC.showNoSelection()
            return
        }

        if selectedIndices.count == 1 {
            let displayIndex = selectedIndices.first!
            guard displayIndex < resultsVC.displayRows.count else { return }
            let dataIndex = resultsVC.displayRows[displayIndex]
            guard dataIndex < resultsVC.rows.count else { return }
            let rowData = resultsVC.rows[dataIndex]
            splitVC.inspectorVC.showRowDetail(
                columns: resultsVC.columns,
                row: rowData,
                rowNumber: displayIndex + 1,
                totalRows: resultsVC.displayRows.count,
                columnCategories: resultsVC.columnCategories
            )
        } else {
            let dataIndices = selectedIndices.compactMap { idx -> Int? in
                guard idx < resultsVC.displayRows.count else { return nil }
                return resultsVC.displayRows[idx]
            }
            let selectedRows = dataIndices.compactMap { idx -> [AnyCodable]? in
                guard idx < resultsVC.rows.count else { return nil }
                return resultsVC.rows[idx]
            }
            splitVC.inspectorVC.showAggregation(
                columns: resultsVC.columns,
                rows: selectedRows,
                selectionCount: selectedIndices.count,
                columnCategories: resultsVC.columnCategories
            )
        }
    }

    // MARK: - Action Bar Setup

    private func setupActionBar() {
        // Draw separator lines on top and bottom of action bar
        actionBar.drawsBottomSeparator = true
        actionBar.contentViewController = self

        // -- Status Labels (right-justified, order: pinned | history | row/time) --

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        pinSourceLabel.translatesAutoresizingMaskIntoConstraints = false
        pinSourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pinSourceLabel.textColor = .systemOrange
        pinSourceLabel.isHidden = true
        pinSourceLabel.setContentHuggingPriority(.required, for: .horizontal)

        historyContextLabel.translatesAutoresizingMaskIntoConstraints = false
        historyContextLabel.font = .systemFont(ofSize: 11, weight: .medium)
        historyContextLabel.textColor = .systemIndigo
        historyContextLabel.isHidden = true
        historyContextLabel.lineBreakMode = .byTruncatingTail
        historyContextLabel.setContentHuggingPriority(.required, for: .horizontal)
        historyContextLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let labelStack = NSStackView(views: [pinSourceLabel, historyContextLabel, statusLabel])
        labelStack.orientation = .horizontal
        labelStack.spacing = 8
        labelStack.setHuggingPriority(.required, for: .horizontal)
        labelStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // -- Find Controls (inline, hidden by default) --

        resultsVC.findControlsStack.orientation = .horizontal
        resultsVC.findControlsStack.spacing = 4
        resultsVC.findControlsStack.isHidden = true
        resultsVC.findControlsStack.setContentHuggingPriority(.required, for: .horizontal)
        resultsVC.findControlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        resultsVC.findField.translatesAutoresizingMaskIntoConstraints = false
        resultsVC.findField.placeholderString = "Find in results..."
        resultsVC.findField.sendsSearchStringImmediately = true
        resultsVC.findField.font = .systemFont(ofSize: 12)

        resultsVC.filterToggleButton.setButtonType(.pushOnPushOff)
        resultsVC.filterToggleButton.title = "Filter"
        resultsVC.filterToggleButton.bezelStyle = .recessed
        resultsVC.filterToggleButton.font = .systemFont(ofSize: 11)
        resultsVC.filterToggleButton.translatesAutoresizingMaskIntoConstraints = false
        resultsVC.filterToggleButton.toolTip = "Filter rows to matches only"

        resultsVC.findClearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
        resultsVC.findClearButton.bezelStyle = .recessed
        resultsVC.findClearButton.isBordered = false
        resultsVC.findClearButton.translatesAutoresizingMaskIntoConstraints = false
        resultsVC.findClearButton.contentTintColor = .tertiaryLabelColor
        resultsVC.findClearButton.isHidden = true

        resultsVC.findCountLabel.translatesAutoresizingMaskIntoConstraints = false
        resultsVC.findCountLabel.font = .systemFont(ofSize: 11)
        resultsVC.findCountLabel.textColor = .secondaryLabelColor
        resultsVC.findCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        resultsVC.findPrevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        resultsVC.findPrevButton.bezelStyle = .recessed
        resultsVC.findPrevButton.isBordered = false
        resultsVC.findPrevButton.translatesAutoresizingMaskIntoConstraints = false

        resultsVC.findNextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        resultsVC.findNextButton.bezelStyle = .recessed
        resultsVC.findNextButton.isBordered = false
        resultsVC.findNextButton.translatesAutoresizingMaskIntoConstraints = false

        resultsVC.findCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        resultsVC.findCloseButton.bezelStyle = .recessed
        resultsVC.findCloseButton.isBordered = false
        resultsVC.findCloseButton.translatesAutoresizingMaskIntoConstraints = false

        resultsVC.findControlsStack.addArrangedSubview(resultsVC.findField)
        resultsVC.findControlsStack.addArrangedSubview(resultsVC.filterToggleButton)
        resultsVC.findControlsStack.addArrangedSubview(resultsVC.findClearButton)
        resultsVC.findControlsStack.addArrangedSubview(resultsVC.findCountLabel)
        resultsVC.findControlsStack.addArrangedSubview(resultsVC.findPrevButton)
        resultsVC.findControlsStack.addArrangedSubview(resultsVC.findNextButton)
        resultsVC.findControlsStack.addArrangedSubview(resultsVC.findCloseButton)

        NSLayoutConstraint.activate([
            resultsVC.findClearButton.widthAnchor.constraint(equalToConstant: 24),
            resultsVC.findPrevButton.widthAnchor.constraint(equalToConstant: 24),
            resultsVC.findNextButton.widthAnchor.constraint(equalToConstant: 24),
            resultsVC.findCloseButton.widthAnchor.constraint(equalToConstant: 24),
        ])

        // -- Action Buttons (left side) --

        configureToolbarButton(pinButton, symbol: "pin",
                               target: resultsVC, action: #selector(ResultsGridVC.togglePin), tooltip: "Pin Results")
        configureToolbarButtonAppearance(exportButton, symbol: "square.and.arrow.up", tooltip: "Export")
        configureToolbarButtonAppearance(copyButton, symbol: "doc.on.doc", tooltip: "Copy")
        configureToolbarButton(findToolbarButton, symbol: "magnifyingglass",
                               target: resultsVC, action: #selector(ResultsGridVC.showFind), tooltip: "Find (Cmd+F)")

        configureToolbarButtonAppearance(resetSortButton, symbol: "arrow.up.arrow.down.circle.fill", tooltip: "Reset Sort")
        resetSortButton.contentTintColor = .controlAccentColor
        resetSortButton.isHidden = true

        configureToolbarButtonAppearance(resetFiltersButton, symbol: "line.3.horizontal.decrease.circle.fill", tooltip: "Reset Column Filters")
        resetFiltersButton.contentTintColor = .controlAccentColor
        resetFiltersButton.isHidden = true
        resetFiltersButton.target = resultsVC
        resetFiltersButton.action = #selector(ResultsGridVC.resetAllColumnFilters)

        let actionStack = NSStackView(views: [pinButton, exportButton, copyButton, findToolbarButton, resetSortButton, resetFiltersButton])
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.setHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // -- Expand Buttons (right side) --

        configureToolbarButton(expandEditorButton, symbol: "rectangle.tophalf.inset.filled",
                               target: self, action: #selector(expandEditorTapped), tooltip: "Expand Editor")
        configureToolbarButton(expandResultsButton, symbol: "rectangle.bottomhalf.inset.filled",
                               target: self, action: #selector(expandResultsTapped), tooltip: "Expand Results")

        let expandStack = NSStackView(views: [expandEditorButton, expandResultsButton])
        expandStack.orientation = .horizontal
        expandStack.spacing = 2
        expandStack.setHuggingPriority(.required, for: .horizontal)
        expandStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // -- Root Layout: actionStack | findControlsStack | <spacer> | labelStack | expandStack --

        // Spacer view absorbs all extra space, pushing labels + expand flush right
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let rootStack = NSStackView(views: [actionStack, resultsVC.findControlsStack, spacer, labelStack, expandStack])
        rootStack.orientation = .horizontal
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        actionBar.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -8),
            rootStack.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),

            // Find field: 25% of action bar width
            resultsVC.findField.widthAnchor.constraint(equalTo: actionBar.widthAnchor, multiplier: 0.25),
        ])
    }

    @objc private func expandEditorTapped() { toggleExpandEditor() }
    @objc private func expandResultsTapped() { toggleExpandResults() }

    private func configureToolbarButton(_ button: NSButton, symbol: String, target: AnyObject, action: Selector, tooltip: String) {
        configureToolbarButtonAppearance(button, symbol: symbol, tooltip: tooltip)
        button.target = target
        button.action = action
    }

    private func configureToolbarButtonAppearance(_ button: NSButton, symbol: String, tooltip: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Empty State

    private func setupEmptyState() {
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "text.page.badge.magnifyingglass", accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Connect to a database to get started")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        emptyState.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
        ])
    }

    // MARK: - Visibility

    private func updateVisibility() {
        // Always show the editor — users can select a connection from the editor toolbar.
        // Empty state is hidden; content stack always visible.
        emptyState.isHidden = true

        let hasConnection: Bool
        if let activeId = stateManager.activeConnectionId {
            let status = stateManager.status(for: activeId)
            hasConnection = (status == .connected)
        } else {
            hasConnection = false
        }

        if hasConnection {
            stateManager.ensureTab()
        }

        // Always ensure at least one tab so the editor is usable
        stateManager.ensureTab()

        updateSplitViewVisibility()
    }

    private func updateSplitViewVisibility() {
        // Content stack is always visible — editor is usable without a connection.
        contentStack.isHidden = false
    }

    // MARK: - Expand Editor / Results

    func toggleExpandEditor() {
        if expandState == .editorExpanded {
            expandState = .normal
        } else {
            if expandState == .normal {
                let totalHeight = contentStack.bounds.height - Self.actionBarHeight
                if totalHeight > 0 {
                    savedSplitRatio = paneSplitView.frame.height / totalHeight
                }
            }
            expandState = .editorExpanded
        }
        applyExpandState()
    }

    func toggleExpandResults() {
        if expandState == .resultsExpanded {
            expandState = .normal
        } else {
            if expandState == .normal {
                let totalHeight = contentStack.bounds.height - Self.actionBarHeight
                if totalHeight > 0 {
                    savedSplitRatio = paneSplitView.frame.height / totalHeight
                }
            }
            expandState = .resultsExpanded
        }
        applyExpandState()
    }

    private func applyExpandState() {
        let rtBarH = resultTabs.isEmpty ? 0 : Self.resultTabBarHeight
        let totalHeight = contentStack.bounds.height - Self.actionBarHeight - rtBarH
        guard totalHeight > 0 else { return }

        switch expandState {
        case .normal:
            paneSplitView.isHidden = false
            resultsVC.view.isHidden = false
            let editorHeight = totalHeight * savedSplitRatio
            editorHeightConstraint.constant = max(100, editorHeight)

        case .editorExpanded:
            // Hide results grid, editor fills all available space
            paneSplitView.isHidden = false
            resultsVC.view.isHidden = true
            editorHeightConstraint.constant = totalHeight

        case .resultsExpanded:
            // Hide editor panes, results fill all available space
            paneSplitView.isHidden = true
            resultsVC.view.isHidden = false
            editorHeightConstraint.constant = 0
        }

        updateExpandButtonUI()
        persistSplitRatio()
        contentStack.layoutSubtreeIfNeeded()
    }

    private func updateExpandButtonUI() {
        expandEditorButton.contentTintColor = expandState == .editorExpanded ? .controlAccentColor : .secondaryLabelColor
        expandResultsButton.contentTintColor = expandState == .resultsExpanded ? .controlAccentColor : .secondaryLabelColor
    }

    private func persistSplitRatio() {
        guard expandState == .normal else { return }
        UserDefaults.standard.set(Double(savedSplitRatio), forKey: Self.splitRatioKey)
    }

    // MARK: - Rename Tab

    private func renameTab(id: String) {
        guard let tab = stateManager.tabs.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = tab.name
        alert.accessoryView = textField

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
                if !newName.isEmpty {
                    self?.stateManager.updateTab(id: id) { $0.name = newName }
                }
            }
        }
    }

    // MARK: - Query Execution

    func executeQuery(_ sql: String? = nil) {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else { return }

        if let sql {
            // Explicit SQL passed (e.g., from context menu, saved query) — use direct execution
            executeDirectSQL(sql)
        } else {
            // Cmd+Return — execute the segment at the cursor
            if let segment = focusedPaneVC?.editorVC.getSegmentSQLAtCursor() {
                executeSegment(segment)
            } else {
                // Fallback: no segments parsed, execute full editor text
                let fullSQL = focusedPaneVC?.getSQL() ?? ""
                executeDirectSQL(fullSQL)
            }
        }
    }

    /// Execute a specific SQL segment, creating a result tab on success.
    func executeSegment(_ segment: SQLSegment) {
        performQuery(
            segment.sql,
            segmentIndex: segment.index,
            lineRange: segment.startLine...segment.endLine,
            customLabel: nil,
            createResultTab: true
        )
    }

    /// Execute SQL directly without creating a result tab (fallback when no segments parsed).
    private func executeDirectSQL(_ querySQL: String) {
        performQuery(querySQL, segmentIndex: -1, lineRange: 0...0, customLabel: nil, createResultTab: false)
    }

    /// Unified query execution.
    /// - `createResultTab`: if true, results go into a new result tab; if false, shown inline.
    private func performQuery(
        _ querySQL: String,
        segmentIndex: Int,
        lineRange: ClosedRange<Int>,
        customLabel: String?,
        createResultTab: Bool
    ) {
        guard let activeTab = stateManager.activeTab,
              let connectionId = activeTab.connectionId,
              stateManager.status(for: connectionId) == .connected else { return }
        let tabId = activeTab.id
        let tabSchema = activeTab.schemaName

        let sql = querySQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        let normalized = Self.normalizeSQL(sql)

        // Dedup: re-running the same SQL while it's in flight is a no-op (with toast).
        if let existing = activeTab.runningQueries.first(where: { $0.normalizedSQL == normalized }) {
            let elapsed = Self.formatElapsed(CACurrentMediaTime() - existing.startTime)
            Toast.show(
                in: self.view,
                message: "Already running — lines \(existing.lineRange.lowerBound)–\(existing.lineRange.upperBound) (\(elapsed))",
                style: .info,
                duration: 2.0
            )
            return
        }

        // Direct-SQL inline-result protection: if another direct-SQL run is already
        // in flight, route this one to a result tab so the two completions don't
        // race to overwrite tab.result.
        var effectiveCreateResultTab = createResultTab
        if segmentIndex == -1,
           activeTab.runningQueries.contains(where: { $0.segmentIndex == -1 }) {
            effectiveCreateResultTab = true
        }

        let queryId = UUID().uuidString
        let color = effectiveCreateResultTab ? ResultTab.nextColor() : .clear
        let startTime = CACurrentMediaTime()

        let runningQuery = RunningQuery(
            id: queryId,
            normalizedSQL: normalized,
            segmentIndex: segmentIndex,
            lineRange: lineRange,
            startTime: startTime
        )

        stateManager.updateTab(id: tabId) { tab in
            tab.runningQueries.append(runningQuery)
            if !effectiveCreateResultTab {
                tab.error = nil
                tab.result = nil
                tab.executeResult = nil
            }
        }
        if !effectiveCreateResultTab { resultsVC.clear() }
        focusedPaneVC?.clearErrorMarkers()

        let limit = Int32(stateManager.settings.query.defaultLimit)
        let isSelectLike = Self.isSelectLikeSQL(sql)

        Task {
            do {
                if isSelectLike {
                    let result = try await PharosCore.executeQuery(
                        connectionId: connectionId, sql: sql, queryId: queryId,
                        limit: limit, schema: tabSchema
                    )
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.runningQueries.removeAll { $0.id == queryId }
                            if !effectiveCreateResultTab {
                                tab.result = result
                            }
                        }
                        if effectiveCreateResultTab {
                            var rt = ResultTab(
                                id: UUID().uuidString, segmentIndex: segmentIndex,
                                sql: sql, lineRange: lineRange, color: color, timestamp: Date()
                            )
                            rt.customLabel = customLabel
                            rt.queryResult = result
                            rt.executionTimeMs = result.executionTimeMs
                            self.addResultTab(rt)
                        } else if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showResult(result)
                        }
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
                        self.cancelledQueryIds.remove(queryId)
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .select(rowCount: result.rowCount),
                            durationMs: result.executionTimeMs
                        )
                    }
                } else {
                    let result = try await PharosCore.executeStatement(
                        connectionId: connectionId, sql: sql, schema: tabSchema
                    )
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.runningQueries.removeAll { $0.id == queryId }
                            if !effectiveCreateResultTab {
                                tab.executeResult = result
                            }
                        }
                        if effectiveCreateResultTab {
                            var rt = ResultTab(
                                id: UUID().uuidString, segmentIndex: segmentIndex,
                                sql: sql, lineRange: lineRange, color: color, timestamp: Date()
                            )
                            rt.customLabel = customLabel
                            rt.executeResult = result
                            rt.executionTimeMs = result.executionTimeMs
                            self.addResultTab(rt)
                        } else if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showExecuteResult(result)
                        }
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
                        self.cancelledQueryIds.remove(queryId)
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .statement(rowsAffected: Int(result.rowsAffected)),
                            durationMs: result.executionTimeMs
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    self.stateManager.updateTab(id: tabId) { tab in
                        tab.runningQueries.removeAll { $0.id == queryId }
                        if !effectiveCreateResultTab {
                            tab.error = message
                        }
                    }
                    if self.stateManager.activeTabId == tabId {
                        self.resultsVC.showError(message)
                        self.markEditorError(message: message, sql: sql)
                    }

                    // Suppress notification for user-initiated cancellations.
                    let wasCancelled = self.cancelledQueryIds.remove(queryId) != nil
                    if !wasCancelled {
                        // Server-side duration unavailable on error; use Swift-side wall clock.
                        let elapsedMs = UInt64((CACurrentMediaTime() - startTime) * 1000)
                        self.fireCompletionNotification(
                            tabId: tabId,
                            connectionId: connectionId,
                            outcome: .error(message: message),
                            durationMs: elapsedMs
                        )
                    }
                }
            }
        }
    }

    /// Assemble metadata and invoke QueryNotifier. Single entry point from the
    /// three completion paths so the argument-assembly logic lives in one place.
    private func fireCompletionNotification(
        tabId: String,
        connectionId: String,
        outcome: QueryNotifier.Outcome,
        durationMs: UInt64
    ) {
        let tabName = stateManager.tabs.first { $0.id == tabId }?.name ?? "Query"
        let connectionName = stateManager.connections.first { $0.id == connectionId }?.name
        QueryNotifier.shared.notifyQueryCompleted(
            tabId: tabId,
            tabName: tabName,
            connectionName: connectionName,
            outcome: outcome,
            durationMs: durationMs
        )
    }

    private static func isSelectLikeSQL(_ sql: String) -> Bool {
        let stripped = stripLeadingComments(sql)
        let upper = stripped.uppercased()
        return upper.hasPrefix("SELECT")
            || upper.hasPrefix("WITH")
            || upper.hasPrefix("EXPLAIN")
            || upper.hasPrefix("SHOW")
            || upper.hasPrefix("TABLE")
            || upper.hasPrefix("VALUES")
    }

    /// Strips leading SQL comments (block and line) and whitespace.
    private static func stripLeadingComments(_ sql: String) -> String {
        var s = sql[sql.startIndex...]
        while !s.isEmpty {
            if s.first?.isWhitespace == true {
                s = s.drop(while: { $0.isWhitespace })
                continue
            }
            if s.hasPrefix("--") {
                if let newline = s.firstIndex(of: "\n") {
                    s = s[s.index(after: newline)...]
                } else {
                    return ""
                }
                continue
            }
            if s.hasPrefix("/*") {
                var depth = 1
                var i = s.index(s.startIndex, offsetBy: 2)
                while i < s.endIndex && depth > 0 {
                    if s[i] == "/" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "*" {
                        depth += 1
                        i = s.index(i, offsetBy: 2)
                    } else if s[i] == "*" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "/" {
                        depth -= 1
                        i = s.index(i, offsetBy: 2)
                    } else {
                        i = s.index(after: i)
                    }
                }
                s = s[i...]
                continue
            }
            break
        }
        return String(s)
    }

    /// Trim leading/trailing whitespace and collapse internal whitespace runs to
    /// a single space. Comments and string-literal contents are NOT stripped —
    /// they participate in the equality check so `SELECT 1 -- v2` does not match
    /// `SELECT 1`.
    static func normalizeSQL(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        result.reserveCapacity(trimmed.count)
        var lastWasWhitespace = false
        for ch in trimmed {
            if ch.isWhitespace {
                if !lastWasWhitespace {
                    result.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                result.append(ch)
                lastWasWhitespace = false
            }
        }
        return result
    }

    /// Format an elapsed-time interval as `M:SS` (e.g. "0:08", "1:23", "12:34").
    static func formatElapsed(_ seconds: CFTimeInterval) -> String {
        let total = max(0, Int(seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Result Tab Management

    private func addResultTab(_ tab: ResultTab) {
        resultTabs.append(tab)
        activeResultTabId = tab.id
        updateResultTabBarVisibility()

        // Set segment color in gutter
        focusedPaneVC?.setSegmentColor(tab.color, forSegmentIndex: tab.segmentIndex)

        // Show this result in the grid
        if let result = tab.queryResult {
            resultsVC.showResult(result)
        } else if let execResult = tab.executeResult {
            resultsVC.showExecuteResult(execResult)
        }
    }

    private func selectResultTab(_ tabId: String) {
        // Clicking a result tab is an explicit request to view that result —
        // unpin so the grid follows the selection.
        if stateManager.pinnedResult != nil {
            stateManager.unpinResults()
            resultsVC.setPinState(pinned: false, tabName: nil)
        }

        reResolveAllResultTabs(immediate: true)

        // Capture outgoing result tab's grid state
        if let outgoingId = activeResultTabId,
           let outgoingIdx = resultTabs.firstIndex(where: { $0.id == outgoingId }) {
            resultTabs[outgoingIdx].gridState = resultsVC.captureGridState()
        }

        activeResultTabId = tabId
        resultTabBar.update(tabs: resultTabs, activeTabId: activeResultTabId)

        guard let tab = resultTabs.first(where: { $0.id == tabId }) else { return }

        // Show the result in the grid
        if let result = tab.queryResult {
            resultsVC.showResult(result)
        } else if let execResult = tab.executeResult {
            resultsVC.showExecuteResult(execResult)
        }

        // Restore saved grid state (column widths, scroll position, etc.)
        if let gridState = tab.gridState {
            resultsVC.restoreGridState(gridState)
        }

        // Highlight source lines in the editor (skip if stale — line numbers may have shifted)
        if !tab.isStale {
            focusedPaneVC?.highlightLines(tab.lineRange)
        }
    }

    private func closeResultTab(_ tabId: String) {
        guard let idx = resultTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closedTab = resultTabs.remove(at: idx)

        // Clear the segment color
        focusedPaneVC?.setSegmentColor(nil, forSegmentIndex: closedTab.segmentIndex)

        if resultTabs.isEmpty {
            activeResultTabId = nil
            updateResultTabBarVisibility()
            resultsVC.clear()
        } else if activeResultTabId == tabId {
            let newIdx = min(idx, resultTabs.count - 1)
            selectResultTab(resultTabs[newIdx].id)
        } else {
            resultTabBar.update(tabs: resultTabs, activeTabId: activeResultTabId)
        }
    }

    private func showResultTabDetail(_ tabId: String) {
        guard let tab = resultTabs.first(where: { $0.id == tabId }) else { return }

        let sheet = QueryDetailSheet(resultTab: tab) { [weak self] sql in
            guard let self else { return }
            let saveSheet = SaveQuerySheet(tabName: "Query", sql: sql) { _ in
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            }
            // Delay briefly so the detail sheet dismiss animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.presentAsSheet(saveSheet)
            }
        }
        presentAsSheet(sheet)
    }

    private func updateResultTabBarVisibility() {
        let hasResultTabs = !resultTabs.isEmpty
        resultTabBar.isHidden = !hasResultTabs
        resultTabBarHeightConstraint.constant = hasResultTabs ? Self.resultTabBarHeight : 0
        resultTabBar.update(tabs: resultTabs, activeTabId: activeResultTabId)
    }

    /// Pending debounced re-resolve work item, cancellable when a new edit
    /// arrives or when a caller wants an immediate flush.
    private var pendingReResolveWorkItem: DispatchWorkItem?

    /// Re-resolve every result tab's source segment against the current
    /// parsed editor segments. Updates each tab's `segmentIndex`, `lineRange`,
    /// and `isStale`, then repaints gutter colors and the result-tab bar.
    ///
    /// - Parameter immediate: when `true`, runs synchronously and cancels any
    ///   pending debounce; when `false`, schedules a 250 ms debounced run.
    private func reResolveAllResultTabs(immediate: Bool = false) {
        pendingReResolveWorkItem?.cancel()
        pendingReResolveWorkItem = nil

        let body: () -> Void = { [weak self] in
            guard let self else { return }
            let text = self.focusedPaneVC?.getSQL() ?? ""
            let segments = SQLSegmentParser.parse(text)

            for i in self.resultTabs.indices {
                let tab = self.resultTabs[i]
                if let outcome = ResultTabResolver.resolve(
                    sql: tab.sql,
                    previousLineRange: tab.lineRange,
                    in: segments
                ) {
                    self.resultTabs[i].segmentIndex = outcome.segmentIndex
                    self.resultTabs[i].lineRange = outcome.lineRange
                    self.resultTabs[i].isStale = false
                } else {
                    self.resultTabs[i].isStale = true
                }
            }

            self.focusedPaneVC?.clearSegmentColors()
            for tab in self.resultTabs where !tab.isStale {
                self.focusedPaneVC?.setSegmentColor(tab.color, forSegmentIndex: tab.segmentIndex)
            }

            self.resultTabBar.update(tabs: self.resultTabs, activeTabId: self.activeResultTabId)
        }

        if immediate {
            body()
        } else {
            let item = DispatchWorkItem(block: body)
            pendingReResolveWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
    }

    /// Load more rows for pagination.
    private func loadMoreRows() {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let existingResult = tab.result,
              existingResult.hasMore else { return }

        let sql = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = Int64(existingResult.rows.count)
        let limit = Int64(stateManager.settings.query.defaultLimit)
        let tabSchema = tab.schemaName

        resultsVC.setLoadingMore(true)

        Task {
            do {
                let moreResult = try await PharosCore.fetchMoreRows(
                    connectionId: connectionId,
                    sql: sql,
                    limit: limit,
                    offset: offset,
                    schema: tabSchema
                )
                await MainActor.run {
                    let merged = QueryResult(
                        columns: existingResult.columns,
                        rows: existingResult.rows + moreResult.rows,
                        rowCount: existingResult.rows.count + moreResult.rows.count,
                        executionTimeMs: existingResult.executionTimeMs,
                        hasMore: moreResult.hasMore,
                        historyEntryId: existingResult.historyEntryId
                    )
                    self.stateManager.updateTab(id: tab.id) { $0.result = merged }
                    self.resultsVC.appendRows(from: moreResult)
                }
            } catch {
                await MainActor.run {
                    self.resultsVC.setLoadingMore(false)
                    NSLog("Failed to load more rows: \(error)")
                }
            }
        }
    }

    // MARK: - Pin Results

    private func handlePinToggle(_ pinned: Bool) {
        if pinned {
            guard let tab = stateManager.activeTab, let result = tab.result else { return }
            stateManager.pinnedResult = result
            stateManager.pinnedTabId = tab.id
            stateManager.pinnedTabName = tab.name
            resultsVC.setPinState(pinned: true, tabName: tab.name)
        } else {
            stateManager.unpinResults()
            resultsVC.setPinState(pinned: false, tabName: nil)
            if let tab = stateManager.activeTab {
                if let result = tab.result {
                    resultsVC.showResult(result)
                } else if let execResult = tab.executeResult {
                    resultsVC.showExecuteResult(execResult)
                } else if let error = tab.error {
                    resultsVC.showError(error)
                } else {
                    resultsVC.clear()
                }
            }
        }
    }

    /// Menubar/keyboard Cancel: cancels the most recently started query in the
    /// active tab. For targeted cancellation by id (used by the popover), use
    /// `cancelQuery(id:)`.
    func cancelQuery() {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              let queryId = tab.runningQueries.last?.id else { return }

        // Mark this queryId as user-cancelled so the error path can suppress
        // the completion notification.
        cancelledQueryIds.insert(queryId)

        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: queryId)
        }
    }

    /// Cancel a specific in-flight query in the active tab by `id`.
    func cancelQuery(id: String) {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              tab.runningQueries.contains(where: { $0.id == id }) else { return }
        cancelledQueryIds.insert(id)
        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: id)
        }
    }

    /// Centralized tab-close handler. Cancels in-flight queries for the tab
    /// (suppressing their completion notifications via `cancelledQueryIds`),
    /// then removes the tab via the state manager.
    func closeTab(id: String) {
        if let tab = stateManager.tabs.first(where: { $0.id == id }),
           let connectionId = tab.connectionId {
            for q in tab.runningQueries {
                cancelledQueryIds.insert(q.id)
                Task {
                    _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: q.id)
                }
            }
        }
        stateManager.closeTab(id: id)
    }

    // MARK: - Error Position Parsing

    private func markEditorError(message: String, sql: String) {
        guard let range = message.range(of: #"at character (\d+)"#, options: .regularExpression),
              let digitRange = message.range(of: #"\d+"#, options: .regularExpression, range: range),
              let charPos = Int(message[digitRange]) else { return }

        let tokenLength = QueryEditorVC.parseTokenLength(from: message)
        focusedPaneVC?.markError(charPosition: charPos, tokenLength: tokenLength)
    }
}

// MARK: - EditorPaneDelegate

extension ContentViewController: EditorPaneDelegate {

    func editorPane(_ pane: EditorPaneVC, didRequestClosePane paneId: String) {
        stateManager.closePane(id: paneId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestExpandPane paneId: String) {
        stateManager.togglePaneExpansion(id: paneId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestAddPane paneId: String) {
        stateManager.addPane()
    }

    func editorPane(_ pane: EditorPaneVC, didFocus paneId: String) {
        // Pane focus is handled by state manager; results update via activeTabId
    }

    func editorPane(_ pane: EditorPaneVC, didChangeActiveTab tabId: String?) {
        // activeTabId publisher handles results grid update
    }

    func editorPane(_ pane: EditorPaneVC, didRequestRenameTab tabId: String) {
        renameTab(id: tabId)
    }

    func editorPaneDidRequestRunQuery(_ pane: EditorPaneVC) {
        stateManager.focusPane(id: pane.paneId)
        executeQuery()
    }

    func editorPane(_ pane: EditorPaneVC, didRequestCancelQueryId queryId: String) {
        cancelQuery(id: queryId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestCloseTab tabId: String) {
        closeTab(id: tabId)
    }

    func editorPaneDidRequestSave(_ pane: EditorPaneVC) {
        menuSaveQuery(nil)
    }

    func editorPaneDidRequestSaveAs(_ pane: EditorPaneVC) {
        menuSaveQueryAs(nil)
    }

    func editorPaneDidRequestExportAsSQL(_ pane: EditorPaneVC) {
        menuExportEditorAsSQL(nil)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestRunSegment segment: SQLSegment) {
        stateManager.focusPane(id: pane.paneId)
        executeSegment(segment)
    }

    func editorPane(_ pane: EditorPaneVC, didEditText paneId: String) {
        reResolveAllResultTabs()
    }
}

// MARK: - Open Saved Query

extension ContentViewController {

    @objc private func handleOpenSavedQuery(_ notification: Notification) {
        guard let query = notification.userInfo?["query"] as? SavedQuery else { return }
        if let existingTab = stateManager.tabs.first(where: { $0.savedQueryId == query.id }) {
            stateManager.selectTab(id: existingTab.id)
            return
        }
        let tab = stateManager.createTab(sql: query.sql, name: query.name)
        stateManager.updateTab(id: tab.id) { $0.savedQueryId = query.id }
    }

    @objc private func handleOpenHistoryEntry(_ notification: Notification) {
        guard let entry = notification.userInfo?["entry"] as? QueryHistoryEntry else { return }

        let tabName = entry.tableNames ?? "History"
        let tab = stateManager.createTab(sql: entry.sql, name: tabName)

        stateManager.updateTab(id: tab.id) { t in
            t.historySchema = entry.schema
            t.historyTimestamp = entry.executedAt
        }

        do {
            if let resultData = try PharosCore.getQueryHistoryResult(id: entry.id) {
                let result = QueryResult(
                    columns: resultData.columns,
                    rows: resultData.rows,
                    rowCount: resultData.rows.count,
                    executionTimeMs: UInt64(entry.executionTimeMs),
                    hasMore: false,
                    historyEntryId: entry.id
                )
                stateManager.updateTab(id: tab.id) { t in
                    t.result = result
                }
                if stateManager.activeTabId == tab.id {
                    resultsVC.showResult(result)
                    resultsVC.showHistoryContext(schema: entry.schema, timestamp: entry.executedAt)
                }
            }
        } catch {
            NSLog("Failed to load history results: \(error)")
        }
    }
}

// MARK: - Run Query / Insert Text (from schema browser context menu)

extension ContentViewController {

    @objc private func handleRunQueryInNewTab(_ notification: Notification) {
        guard let sql = notification.userInfo?["sql"] as? String else { return }
        let tab = stateManager.createTab(sql: sql, name: "Query")
        DispatchQueue.main.async {
            if self.stateManager.activeTabId == tab.id {
                self.executeQuery(sql)
            }
        }
    }

    @objc private func handleRunQueryInCurrentTab(_ notification: Notification) {
        guard let sql = notification.userInfo?["sql"] as? String,
              let resultName = notification.userInfo?["resultName"] as? String else { return }
        performQuery(sql, segmentIndex: -1, lineRange: 0...0, customLabel: resultName, createResultTab: true)
    }

    @objc private func handleInsertTextInEditor(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        guard stateManager.activeTab != nil else { return }
        focusedPaneVC?.insertText(text)
        focusedPaneVC?.focus()
    }

    @objc private func handleConnectionStatusChanged(_ note: Notification) {
        guard let connectionId = note.userInfo?["connectionId"] as? String else { return }
        guard stateManager.status(for: connectionId) != .connected else { return }
        // Connection dropped — clear runningQueries for every tab on this connection
        // so the UI returns to idle without waiting for each in-flight error.
        let affectedTabIds = stateManager.tabs.compactMap { $0.connectionId == connectionId ? $0.id : nil }
        for tabId in affectedTabIds {
            stateManager.updateTab(id: tabId) { tab in
                for q in tab.runningQueries {
                    self.cancelledQueryIds.insert(q.id)
                }
                tab.runningQueries.removeAll()
            }
        }
    }
}

// MARK: - Save Query (Cmd+S)

extension ContentViewController {

    @objc func menuSaveQuery(_: Any?) {
        guard let tab = stateManager.activeTab else { return }

        // File-backed tab: write back to the source URL.
        if let url = tab.sourceURL {
            let currentSQL = focusedPaneVC?.getSQL() ?? ""
            do {
                try SQLFileWriter.write(currentSQL, to: url)
                stateManager.updateTab(id: tab.id) {
                    $0.sql = currentSQL
                    $0.isDirty = false
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        // Saved-query-backed tab: update the saved query in place.
        if let savedId = tab.savedQueryId {
            let currentSQL = focusedPaneVC?.getSQL() ?? ""
            do {
                let update = UpdateSavedQuery(id: savedId, name: nil, folder: nil, sql: currentSQL)
                _ = try PharosCore.updateSavedQuery(update)
                stateManager.updateTab(id: tab.id) { $0.sql = currentSQL }
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            } catch {
                NSLog("Failed to update saved query: \(error)")
            }
            return
        }

        // New tab: prompt to save into the saved-queries store.
        presentSaveQuerySheet(tab: tab)
    }

    @objc func menuSaveQueryAs(_: Any?) {
        guard let tab = stateManager.activeTab else { return }
        presentSaveQuerySheet(tab: tab)
    }

    @objc func menuExportEditorAsSQL(_: Any?) {
        guard let tab = stateManager.activeTab else { return }
        let text = focusedPaneVC?.getSQL() ?? ""

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("public.sql") ?? .plainText]
        panel.nameFieldStringValue = "\(SavedQueryFilename.sanitize(tab.name)).sql"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: view.window!) { response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "sql" {
                url = url.appendingPathExtension("sql")
            }
            do {
                try SQLFileWriter.write(text, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func presentSaveQuerySheet(tab: QueryTab) {
        let sheet = SaveQuerySheet(
            tabName: tab.name,
            sql: focusedPaneVC?.getSQL() ?? ""
        ) { [weak self] action in
            guard let self else { return }
            let savedQuery: SavedQuery
            switch action {
            case .created(let q): savedQuery = q
            case .replaced(let q): savedQuery = q
            }
            self.stateManager.updateTab(id: tab.id) { $0.savedQueryId = savedQuery.id }
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        }
        presentAsSheet(sheet)
    }
}

// MARK: - Menu Actions (Responder Chain)

extension ContentViewController {

    @objc func menuRunQuery(_: Any?) {
        executeQuery()
    }

    @objc func menuCancelQuery(_: Any?) {
        cancelQuery()
    }

    @objc func menuNewTab(_: Any?) {
        stateManager.createTab()
    }

    @objc func menuCloseTab(_: Any?) {
        guard let tabId = stateManager.activeTabId else { return }
        closeTab(id: tabId)
    }

    @objc func menuReopenTab(_: Any?) {
        stateManager.reopenLastClosedTab()
    }

    @objc func menuSelectTab(_ sender: NSMenuItem) {
        let index = sender.tag
        stateManager.selectTabByIndex(index)
    }

    @objc func showFind() {
        resultsVC.showFind()
    }

    @objc func showFilter() {
        resultsVC.showFilter()
    }

    @objc func menuFormatSQL(_: Any?) {
        focusedPaneVC?.formatSQL()
    }
}

// MARK: - NSSplitViewDelegate

extension ContentViewController: NSSplitViewDelegate {

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 100 // Minimum editor pane width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.bounds.width - 100 // Minimum right editor pane width
    }
}

// MARK: - Action Bar Drag-to-Resize

extension ContentViewController {

    func handleActionBarDrag(event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // If in an expanded state, restore normal before dragging
            if expandState != .normal {
                expandState = .normal
                paneSplitView.isHidden = false
                resultsVC.view.isHidden = false
                updateExpandButtonUI()
            }
            isDragging = true
            dragStartY = event.locationInWindow.y
            dragStartEditorHeight = editorHeightConstraint.constant

        case .leftMouseDragged:
            guard isDragging else { return }
            // Window coordinates: y increases upward. Dragging down = negative delta = editor grows.
            let deltaY = dragStartY - event.locationInWindow.y
            let rtBarH = resultTabs.isEmpty ? CGFloat(0) : Self.resultTabBarHeight
            let totalAvailable = contentStack.bounds.height - Self.actionBarHeight - rtBarH
            let newHeight = max(100, min(totalAvailable - 60, dragStartEditorHeight + deltaY))
            editorHeightConstraint.constant = newHeight
            savedSplitRatio = newHeight / totalAvailable
            persistSplitRatio()

        case .leftMouseUp:
            isDragging = false

        default:
            break
        }
    }
}

// MARK: - Open Text File

extension ContentViewController {

    /// Maximum file size we'll open without prompting (50 MB).
    private static let openFileSizeLimit: Int64 = 50 * 1024 * 1024

    /// Open a plain-text or `.sql` file as a new editor tab.
    ///
    /// Reads `url` synchronously (called from the main thread), shows a
    /// confirmation if the file is unusually large, alerts on read or
    /// decode failure, and on success creates a new tab in the focused
    /// pane with the file's contents and the URL recorded as `sourceURL`.
    @objc func openTextFile(at url: URL) {
        let fm = FileManager.default

        // Size guard.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > Self.openFileSizeLimit {
            let mb = Double(size.int64Value) / (1024 * 1024)
            let alert = NSAlert()
            alert.messageText = "Open large file?"
            alert.informativeText = String(format: "%@ is %.1f MB and may slow the editor.", url.lastPathComponent, mb)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open Anyway")
            // First button (Cancel) is the default.
            if alert.runModal() != .alertSecondButtonReturn { return }
        }

        // Read and decode.
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Tab title: drop `.sql` for cleanliness; keep other extensions visible.
        let name: String
        if url.pathExtension.lowercased() == "sql" {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = url.lastPathComponent
        }

        let tab = stateManager.createTab(sql: text, name: name)
        stateManager.updateTab(id: tab.id) { $0.sourceURL = url }
    }
}
