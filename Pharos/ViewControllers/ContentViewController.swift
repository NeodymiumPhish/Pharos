import AppKit
import Combine
import UniformTypeIdentifiers

/// Snapshot of the active connection's id + status used to drive the metadata
/// cache. Combining the two into one Equatable value lets us deduplicate the
/// downstream sink without paying for tuple-equality type-inference.
private struct ActiveConnectionStatus: Equatable {
    let id: String?
    let status: ConnectionStatus?
}

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

    // Grid/Chart toggle (front of the action bar) + the SwiftUI chart host that
    // overlays the same region as the results grid, shown only in chart mode.
    private let chartToggle = NSSegmentedControl(labels: ["Grid", "Chart"], trackingMode: .selectOne, target: nil, action: nil)
    private let chartHost = ChartHostingController()
    /// The chart's current staged selection (Task C commits it on button press).
    private var stagedChartKeys: [DrillKey] = []
    private var committedChartKeys: [DrillKey] = []

    /// Debounce timers coalescing rapid chart-config edits into one FFI persist
    /// each, keyed by result-tab id so concurrent edits to different tabs don't
    /// cancel each other's pending write.
    private var chartPersistWorkItems: [String: DispatchWorkItem] = [:]

    /// The in-flight server-aggregation (push-down) query id — tracked so a
    /// superseded run can be cancelled server-side (`pg_cancel_backend`) and its
    /// result ignored (last-write-wins).
    private var chartServerQueryId: String?
    /// The connection the in-flight push-down run was LAUNCHED against. Captured
    /// at launch so a cancel targets the right pool even after the active tab has
    /// switched/closed (`activeTab` would resolve the wrong connection by then).
    private var chartServerConnectionId: String?
    /// Debounce coalescing rapid rail edits into one push-down execution.
    private var chartServerAggWorkItem: DispatchWorkItem?

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
    /// Monotonic result-ordering counter per editor tab, used as `result_order`
    /// when associating executed results with a workspace. Seeded to the restored
    /// count when a workspace is reopened (see handleOpenWorkspace).
    private var resultOrderByEditorTab: [String: Int] = [:]
    private static let resultTabBarHeight: CGFloat = 26

    // Toolbar UI elements (owned here, configured in setupActionBar)
    let statusLabel = NSTextField(labelWithString: "")
    let pinSourceLabel = NSTextField(labelWithString: "")
    let resultBannerLabel = NSTextField(labelWithString: "")
    let resetSortButton = NSButton()
    let resetFiltersButton = NSButton()
    let clearSelectionButton = NSButton()
    let pinButton = NSButton()
    let findToolbarButton = NSButton()
    let copyButton = NSButton()
    let exportButton = NSButton()
    let expandEditorButton = NSButton()
    let expandResultsButton = NSButton()
    /// Clearable "Filtered by chart" chip shown while a chart drill is applied.
    let drillChip = NSButton()
    /// Commits the current chart selection (client → grid filters, server → detail query).
    let chartFilterButton = NSButton()

    // Chart drill-down state (active result tab). `drillColumns` are the col_N
    // ids the drill currently owns; `displacedFilters` snapshots any manual
    // filter a drill overwrote, so clearing the drill restores it.
    private var drillColumns: [String] = []
    private var displacedFilters: [String: ColumnFilter] = [:]

    private var editorPanes: [EditorPaneVC] = []

    /// The focused editor pane.
    private var focusedPaneVC: EditorPaneVC? {
        editorPanes.first { $0.paneId == stateManager.focusedPaneId }
    }

    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()
    /// Local key monitor so Esc clears an in-progress chart selection. A monitor is
    /// more reliable than the responder chain for a SwiftUI-hosted chart; the guards
    /// ensure it only consumes Esc while a selection is actually staged.
    private var escKeyMonitor: Any?
    private var hasSetInitialSplit = false
    private static let splitRatioKey = "PharosEditorSplitRatio"

    /// Query IDs that the user has cancelled. Checked in the error handler to
    /// suppress the "Query failed" notification for user-initiated cancellations.
    private var cancelledQueryIds: Set<String> = []

    /// "Run All Queries" queue: segments still to be launched. Pop from the front
    /// when a slot opens up. Cleared on abort (tab close / disconnect / completion).
    private var runAllPending: [SQLSegment] = []
    /// The tab the current Run-All batch belongs to. Different active tabs do NOT
    /// inherit the batch.
    private var runAllTabId: String?
    /// Subscription that watches the tab's runningQueries count to refill slots.
    private var runAllSubscription: AnyCancellable?
    /// Max concurrent queries launched by the Run-All batch.
    private let runAllMaxConcurrent = 3

    // Editor/results expand state
    enum ContentExpandState { case normal, editorExpanded, resultsExpanded }
    private(set) var expandState: ContentExpandState = .normal
    private var savedSplitRatio: CGFloat = 0.6

    // Drag-to-resize state
    private var isDragging = false
    private var dragStartY: CGFloat = 0
    private var dragStartEditorHeight: CGFloat = 0
    private static let actionBarHeight: CGFloat = 32

    deinit {
        if let m = escKeyMonitor { NSEvent.removeMonitor(m) }
    }

    /// Esc clears a staged chart selection (works everywhere, incl. heatmaps whose
    /// plot is fully tiled with cells so there's no empty area to click). Only
    /// consumes Esc while a selection is staged and our window is key with no sheet.
    private func installEscKeyMonitor() {
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, !self.stagedChartKeys.isEmpty,
                  let win = self.view.window, win.isKeyWindow, win.attachedSheet == nil else { return event }
            self.clearStagedChartSelection()
            return nil
        }
    }

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

        // Chart host: sibling of the results grid, pinned to the same region,
        // hidden until the user switches a result tab to Chart mode.
        addChild(chartHost)
        chartHost.view.translatesAutoresizingMaskIntoConstraints = false
        chartHost.view.isHidden = true
        contentStack.addSubview(chartHost.view)

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
        installEscKeyMonitor()

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

            // Chart host occupies the same region as the results grid.
            chartHost.view.topAnchor.constraint(equalTo: resultTabBar.bottomAnchor),
            chartHost.view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            chartHost.view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            chartHost.view.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),

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

        // Wire up selection changes for inspector. Drag-select fires this for
        // every cell the cursor crosses; the inspector rebuild only matters
        // for the settled selection, so debounce ~50ms to coalesce drag ticks
        // into a single update at rest.
        resultsVC.onSelectionChanged = { [weak self] selectedIndices in
            self?.scheduleInspectorUpdate(selectedIndices: selectedIndices)
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

        // Dedup the whole dict first — many publishes don't actually change
        // state. updateVisibility + the disconnect/error sweep only need to run
        // when something in the dict actually flipped.
        stateManager.$connectionStatuses
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] statuses in
                self?.updateVisibility()
                for (connId, status) in statuses where status == .disconnected || status == .error {
                    self?.metadataCache.clearConnection(connId)
                }
            }
            .store(in: &cancellables)

        // Metadata load reacts to the *active* connection's status only.
        // Combining activeConnectionId with the statuses dict and mapping down
        // to the active's status avoids the original problem (a removeDuplicates
        // on activeConnectionId alone would suppress the connected→ready
        // transition) while still firing only on real status changes.
        Publishers.CombineLatest(stateManager.$activeConnectionId, stateManager.$connectionStatuses)
            .map { activeId, statuses in
                ActiveConnectionStatus(id: activeId, status: activeId.flatMap { statuses[$0] })
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                if let id = snapshot.id, snapshot.status == .connected {
                    self.metadataCache.load(connectionId: id)
                } else if snapshot.id == nil {
                    self.metadataCache.clear()
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

        // Drive the action-bar pulse from the focused pane's active tab's
        // executing state. We map down to the single Bool we actually care
        // about and removeDuplicates so unrelated mutations (any keystroke
        // republishes $tabs) don't reassign isPulsing every time.
        Publishers.CombineLatest3(
            stateManager.$tabs,
            stateManager.$panes,
            stateManager.$focusedPaneId
        )
        .map { tabs, panes, focusedPaneId -> Bool in
            let focusedPane = panes.first { $0.id == focusedPaneId }
            let activeTabId = focusedPane?.activeTabId
            return tabs.first { $0.id == activeTabId }?.isExecuting == true
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] isExecuting in
            self?.actionBar.isPulsing = isExecuting
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

        // Observe "open workspace" (reopen into a live editor tab) from sidebar
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenWorkspace(_:)),
            name: .openWorkspace, object: nil
        )

        // Observe "show SQL in inspector" from a workspace-history preview row
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowSQLInInspector(_:)),
            name: .showSQLInInspector, object: nil
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

        // Observe bulk-close cancellations so completion notifications are suppressed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleQueriesWillBeCancelled(_:)),
            name: AppStateManager.queriesWillBeCancelled,
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
            // Tear down any active drill BEFORE capturing grid state (see
            // addResultTab / selectResultTab): switching editor tabs is another
            // outgoing path where the transient drill filter would otherwise leak
            // into the saved gridState and lose the manual filter it displaced.
            tearDownDrill(restoreManual: true)
            let gridState = resultsVC.captureGridState()
            stateManager.updateTab(id: previousTabId) { tab in
                tab.gridState = gridState
            }
            // Also save grid state (and any live chart config) to the active result tab
            if let activeRTId = activeResultTabId,
               let rtIdx = resultTabs.firstIndex(where: { $0.id == activeRTId }) {
                resultTabs[rtIdx].gridState = gridState
                captureChartConfig(intoTabAt: rtIdx)
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
            syncChartToggleToActiveTab()
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

        // Update the result banner ("schema · executed-at"). When a ResultTab
        // is active, its own timestamp / history fields drive the banner.
        // Otherwise the legacy inline-result path falls back to the editor
        // tab's stored execution time and schema. Suppressed while pinned
        // (the grid is showing the pinned tab's data, not the active tab's).
        let activeRT = activeResultTabId.flatMap { id in resultTabs.first { $0.id == id } }
        if activeRT != nil {
            applyResultBanner(from: activeRT)
        } else if tab.result != nil || tab.executeResult != nil {
            applyResultBanner(schema: tab.schemaName, date: tab.resultExecutedAt)
        } else {
            applyResultBanner(from: nil)
        }

        // Restore grid vs. chart view mode for the newly-active result tab.
        syncChartToggleToActiveTab()
    }

    /// Update the results grid banner from the currently displayed result tab.
    /// Shown for every result — fresh queries display when the query completed,
    /// history replays display the original execution time — so the user can
    /// always see at a glance how recent the visible result is.
    private func applyResultBanner(from resultTab: ResultTab?) {
        guard stateManager.pinnedResult == nil, let resultTab else {
            resultsVC.hideResultBanner()
            return
        }
        // History replays carry the original execution time as an ISO string;
        // fresh queries use the ResultTab's own creation timestamp.
        let date: Date?
        if let historyIso = resultTab.historyTimestamp {
            date = ResultsGridVC.parseHistoryTimestamp(historyIso)
        } else {
            date = resultTab.timestamp
        }
        guard let date else {
            resultsVC.hideResultBanner()
            return
        }
        let schema = resultTab.historySchema ?? stateManager.activeTab?.schemaName
        resultsVC.showResultBanner(schema: schema, date: date)
    }

    /// Banner variant for the legacy inline-result path (no ResultTab, result
    /// stored directly on the editor tab).
    private func applyResultBanner(schema: String?, date: Date?) {
        guard stateManager.pinnedResult == nil, let date else {
            resultsVC.hideResultBanner()
            return
        }
        resultsVC.showResultBanner(schema: schema, date: date)
    }

    // MARK: - Inspector

    /// Pending debounced inspector update; cancelled on each new selection
    /// tick so a fast cell-drag results in a single inspector rebuild at rest.
    private var pendingInspectorWorkItem: DispatchWorkItem?

    private func scheduleInspectorUpdate(selectedIndices: IndexSet) {
        pendingInspectorWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateInspector(selectedIndices: selectedIndices)
        }
        pendingInspectorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

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

        // The banner ("schema · executed-at") sits next to the status label
        // for every result, so secondaryLabelColor keeps it as quiet metadata
        // rather than the previous indigo "this is history" highlight.
        resultBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        resultBannerLabel.font = .systemFont(ofSize: 11, weight: .regular)
        resultBannerLabel.textColor = .secondaryLabelColor
        resultBannerLabel.isHidden = true
        resultBannerLabel.lineBreakMode = .byTruncatingTail
        resultBannerLabel.setContentHuggingPriority(.required, for: .horizontal)
        resultBannerLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let labelStack = NSStackView(views: [pinSourceLabel, resultBannerLabel, statusLabel])
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
        resetFiltersButton.target = self
        resetFiltersButton.action = #selector(resetAllFiltersAndDrill)

        configureToolbarButtonAppearance(clearSelectionButton, symbol: "eraser", tooltip: "Clear Selection")
        clearSelectionButton.contentTintColor = .controlAccentColor
        clearSelectionButton.isHidden = true
        clearSelectionButton.target = resultsVC
        clearSelectionButton.action = #selector(ResultsGridVC.clearCellSelection)

        // -- Grid/Chart toggle (front of the action bar) --

        chartToggle.selectedSegment = 0
        chartToggle.segmentStyle = .texturedRounded
        chartToggle.target = self
        chartToggle.action = #selector(chartToggleChanged)
        chartToggle.setContentHuggingPriority(.required, for: .horizontal)
        chartToggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        // -- Drill chip (next to the Grid/Chart toggle) --

        let drillConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        drillChip.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle.fill", accessibilityDescription: "Filtered by chart")?
            .withSymbolConfiguration(drillConfig)
        drillChip.imagePosition = .imageLeading
        drillChip.title = "Filtered by chart"
        drillChip.font = .systemFont(ofSize: 11)
        drillChip.bezelStyle = .recessed
        drillChip.contentTintColor = .controlAccentColor
        drillChip.toolTip = "Clear the filter applied by clicking the chart"
        drillChip.target = self
        drillChip.action = #selector(clearDrill)
        drillChip.isHidden = true
        drillChip.setContentHuggingPriority(.required, for: .horizontal)
        drillChip.setContentCompressionResistancePriority(.required, for: .horizontal)

        chartFilterButton.bezelStyle = .recessed
        chartFilterButton.font = .systemFont(ofSize: 11)
        chartFilterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter selection")?
            .withSymbolConfiguration(drillConfig)
        chartFilterButton.imagePosition = .imageLeading
        chartFilterButton.contentTintColor = .controlAccentColor
        chartFilterButton.target = self
        chartFilterButton.action = #selector(commitChartSelection)
        chartFilterButton.isHidden = true
        chartFilterButton.setContentHuggingPriority(.required, for: .horizontal)
        chartFilterButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actionStack = NSStackView(views: [chartToggle, chartFilterButton, drillChip, pinButton, exportButton, copyButton, findToolbarButton, resetSortButton, resetFiltersButton, clearSelectionButton])
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
            let editorHeight = totalHeight * savedSplitRatio
            editorHeightConstraint.constant = max(100, editorHeight)

        case .editorExpanded:
            // Hide results area (grid + chart), editor fills all available space
            paneSplitView.isHidden = false
            editorHeightConstraint.constant = totalHeight

        case .resultsExpanded:
            // Hide editor panes, results area fills all available space
            paneSplitView.isHidden = true
            editorHeightConstraint.constant = 0
        }
        // Show grid vs. chart per the active result tab's mode + expand state.
        applyResultAreaVisibility()

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
        // Focus the field and select its text so the user can type a new name immediately.
        alert.window.initialFirstResponder = textField
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

    /// Fires every SQL segment in the focused editor with a max of 3 concurrent
    /// queries. As each finishes, the next from the queue starts. Identical-SQL
    /// segments are naturally deduplicated by the in-flight dedup check in
    /// `performQuery`.
    func runAllSegments() {
        guard let tab = stateManager.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let editor = focusedPaneVC?.editorVC else { return }

        let segments = editor.segments
        guard !segments.isEmpty else { return }

        // Replace any in-progress batch (calling Run All twice = restart).
        runAllPending = segments
        runAllTabId = tab.id

        runAllSubscription?.cancel()
        runAllSubscription = Publishers.Merge(
            stateManager.$tabs.map { _ in () },
            stateManager.$activeTabId.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refillRunAllSlots() }

        refillRunAllSlots()
    }

    private func refillRunAllSlots() {
        guard let tabId = runAllTabId,
              let tab = stateManager.tabs.first(where: { $0.id == tabId }),
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else {
            // Tab gone or disconnected — abort the batch.
            runAllPending.removeAll()
            runAllSubscription?.cancel()
            runAllSubscription = nil
            runAllTabId = nil
            return
        }

        // Pause: only launch new segments while the Run-All tab is the active tab.
        // The subscription stays alive; when the user switches back, the next emission
        // will resume slot-filling.
        guard stateManager.activeTabId == tabId else {
            // If the queue is empty AND the original tab has drained, tear down even
            // while paused — there's nothing left to do.
            if runAllPending.isEmpty && tab.runningQueries.isEmpty {
                runAllSubscription?.cancel()
                runAllSubscription = nil
                runAllTabId = nil
            }
            return
        }

        let availableSlots = max(0, runAllMaxConcurrent - tab.runningQueries.count)
        var launched = 0
        while launched < availableSlots, !runAllPending.isEmpty {
            let segment = runAllPending.removeFirst()
            executeSegment(segment)
            launched += 1
        }

        if runAllPending.isEmpty && tab.runningQueries.isEmpty {
            runAllSubscription?.cancel()
            runAllSubscription = nil
            runAllTabId = nil
        }
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
        createResultTab: Bool,
        destructiveConfirmed: Bool = false
    ) {
        guard let activeTab = stateManager.activeTab,
              let connectionId = activeTab.connectionId,
              stateManager.status(for: connectionId) == .connected else { return }
        let tabId = activeTab.id
        let tabSchema = activeTab.schemaName

        let rendered = VariableSubstitutor.render(querySQL, with: activeTab.variables)
        if !rendered.unresolved.isEmpty || !rendered.invalid.isEmpty {
            presentVariableError(unresolved: rendered.unresolved, invalid: rendered.invalid, tabId: tabId)
            return
        }
        let sql = rendered.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        // Editor-level destructive guard, mirroring the schema browser's.
        // Checked on the rendered SQL so variable values can't sneak past it.
        if !destructiveConfirmed, stateManager.settings.query.confirmDestructive {
            let keywords = DestructiveSQLScanner.destructiveKeywords(in: sql)
            if !keywords.isEmpty {
                presentDestructiveQueryConfirmation(keywords: keywords, sql: sql) { [weak self] in
                    self?.performQuery(
                        querySQL,
                        segmentIndex: segmentIndex,
                        lineRange: lineRange,
                        customLabel: customLabel,
                        createResultTab: createResultTab,
                        destructiveConfirmed: true
                    )
                }
                return
            }
        }

        let normalized = Self.normalizeSQL(sql)

        // Dedup: re-running the same SQL while it's in flight is a no-op (with toast).
        if let existing = activeTab.runningQueries.first(where: { $0.normalizedSQL == normalized }) {
            let elapsed = Self.formatElapsed(CACurrentMediaTime() - existing.startTime)
            let lineFragment: String
            if existing.segmentIndex == -1 {
                lineFragment = "direct SQL"
            } else if existing.lineRange.lowerBound == existing.lineRange.upperBound {
                lineFragment = "line \(existing.lineRange.lowerBound)"
            } else {
                lineFragment = "lines \(existing.lineRange.lowerBound)–\(existing.lineRange.upperBound)"
            }
            Toast.show(
                in: self.view,
                message: "Already running — \(lineFragment) (\(elapsed))",
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
                tab.resultExecutedAt = nil
            }
        }
        if !effectiveCreateResultTab { resultsVC.clear() }
        focusedPaneVC?.clearErrorMarkers()

        // Ensure this tab has a workspace history record (created lazily on first
        // execute) and snapshot its editor text/variables now. The produced result
        // is associated to it on completion.
        let workspaceId = ensureWorkspace(forEditorTabId: tabId)

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
                                tab.resultExecutedAt = Date()
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
                            rt.totalRowCountHint = result.rowCount
                            self.addResultTab(rt, forEditorTab: tabId)
                        } else if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showResult(result)
                        }
                        NotificationCoalescer.post(.queryHistoryDidChange)
                        if let wsId = workspaceId, let hid = result.historyEntryId {
                            self.captureExecutedResult(historyId: hid, editorTabId: tabId, workspaceId: wsId, color: color)
                        }
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
                                tab.resultExecutedAt = Date()
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
                            self.addResultTab(rt, forEditorTab: tabId)
                        } else if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showExecuteResult(result)
                        }
                        NotificationCoalescer.post(.queryHistoryDidChange)
                        if let wsId = workspaceId, let hid = result.historyEntryId {
                            self.captureExecutedResult(historyId: hid, editorTabId: tabId, workspaceId: wsId, color: color)
                        }
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

    /// Surface an unresolved/invalid-variable error before a query runs, and
    /// reveal the variables panel so the user can correct it.
    private func presentVariableError(
        unresolved: [String],
        invalid: [VariableSubstitutor.Invalid],
        tabId: String
    ) {
        var parts: [String] = []
        if !unresolved.isEmpty {
            parts.append("Undefined: " + unresolved.map { "{{\($0)}}" }.joined(separator: ", "))
        }
        for item in invalid {
            parts.append("\(item.name): \(item.reason)")
        }
        Toast.show(
            in: self.view,
            message: parts.joined(separator: " · "),
            style: .error,
            duration: 3.0
        )
        focusedPaneVC?.revealVariablesPanel()
    }

    /// Confirmation sheet for destructive SQL run from the editor. Same style
    /// as the schema browser's truncate/drop guard.
    private func presentDestructiveQueryConfirmation(
        keywords: [String],
        sql: String,
        onConfirm: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Run destructive query?"
        let preview = sql.count > 200 ? String(sql.prefix(200)) + "…" : sql
        alert.informativeText = "This SQL contains \(keywords.joined(separator: ", ")):\n\n\(preview)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        // No window to present on → don't run: an unconfirmed destructive query
        // is worse than a query that silently doesn't fire (matches the schema
        // browser guard's behavior).
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
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

    /// Format an elapsed-time interval as `M:SS` or `H:MM:SS` for runs ≥ 1 hour.
    static func formatElapsed(_ seconds: CFTimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Result Tab Management

    /// Add a result tab to the editor tab that launched the query. A query that
    /// completes while a *different* editor tab is focused must deposit its
    /// result into the originating tab's stored state — not the live (visible)
    /// state, which belongs to whichever tab is focused now.
    private func addResultTab(_ tab: ResultTab, forEditorTab editorTabId: String) {
        guard editorTabId == stateManager.activeTabId else {
            // Background tab: append to its persisted result tabs without
            // touching the live display or the focused pane's gutter. The
            // gutter color and grid are restored from this state when the user
            // switches back (activeTabChanged → reResolveAllResultTabs).
            var stored = resultTabsByEditorTab[editorTabId] ?? []
            stored.append(tab)
            resultTabsByEditorTab[editorTabId] = stored
            activeResultTabIdByEditorTab[editorTabId] = tab.id
            return
        }

        // Tear down any active drill BEFORE capturing grid state: a drill is a
        // transient overlay on the shared filter controller. If left in place,
        // captureGridState() would snapshot the drill filter into the outgoing
        // tab and silently drop the manual filter it displaced. Restoring here
        // makes the captured state reflect the user's real manual filters.
        tearDownDrill(restoreManual: true)

        // Capture the outgoing result tab's grid state before switching away,
        // so filters/sorts/column widths applied to it survive when the user
        // returns (mirrors selectResultTab). Without this, running a new query
        // silently discards the previously-active result's grid state.
        if let outgoingId = activeResultTabId,
           let outgoingIdx = resultTabs.firstIndex(where: { $0.id == outgoingId }) {
            resultTabs[outgoingIdx].gridState = resultsVC.captureGridState()
            captureChartConfig(intoTabAt: outgoingIdx)
        }

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

        // A fresh result defaults to grid; sync the toggle + chart host visibility.
        syncChartToggleToActiveTab()

        // Refresh the history banner for the newly-active result tab. Without
        // this, running a fresh query in an editor that was viewing a history
        // result would keep the old "schema · timestamp" banner visible until
        // the user switched tabs.
        applyResultBanner(from: tab)
    }

    private func selectResultTab(_ tabId: String) {
        // Clicking a result tab is an explicit request to view that result —
        // unpin so the grid follows the selection.
        if stateManager.pinnedResult != nil {
            stateManager.unpinResults()
            resultsVC.setPinState(pinned: false, tabName: nil)
        }

        reResolveAllResultTabs(immediate: true)

        // Tear down any active drill BEFORE capturing grid state (see addResultTab):
        // otherwise the transient drill filter leaks into the outgoing tab's saved
        // gridState and the manual filter it displaced is lost.
        tearDownDrill(restoreManual: true)

        // Capture outgoing result tab's grid state (and any live chart config)
        if let outgoingId = activeResultTabId,
           let outgoingIdx = resultTabs.firstIndex(where: { $0.id == outgoingId }) {
            resultTabs[outgoingIdx].gridState = resultsVC.captureGridState()
            captureChartConfig(intoTabAt: outgoingIdx)
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

        // Restore grid vs. chart view mode for the newly-selected result tab.
        syncChartToggleToActiveTab()

        // Highlight source lines in the editor (skip if stale — line numbers may have shifted)
        if !tab.isStale {
            focusedPaneVC?.highlightLines(tab.lineRange)
        }

        // History banner follows the selected result tab.
        applyResultBanner(from: tab)
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
            syncChartToggleToActiveTab()
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
            let saveSheet = SaveQuerySheet(tabName: "Query", sql: sql, variables: []) { _ in
                NotificationCoalescer.post(.savedQueriesDidChange)
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
              stateManager.status(for: connectionId) == .connected else { return }

        // Don't paginate a pinned cross-tab snapshot.
        guard stateManager.pinnedResult == nil else { return }

        // Resolve the currently displayed result, its SQL, where to write the
        // merged result back, and whether it's still on-screen at completion time.
        // Mirrors the display priority in updateContent: active ResultTab → inline tab.result.
        let existingResult: QueryResult
        let querySQL: String
        let applyMerged: (QueryResult) -> Void
        let isStillDisplaying: () -> Bool

        if let activeRTId = activeResultTabId,
           let rtIdx = resultTabs.firstIndex(where: { $0.id == activeRTId }),
           let rtResult = resultTabs[rtIdx].queryResult {
            existingResult = rtResult
            querySQL = resultTabs[rtIdx].sql
            applyMerged = { [weak self] merged in
                guard let self,
                      let idx = self.resultTabs.firstIndex(where: { $0.id == activeRTId }) else { return }
                self.resultTabs[idx].queryResult = merged
            }
            isStillDisplaying = { [weak self] in
                self?.stateManager.pinnedResult == nil && self?.activeResultTabId == activeRTId
            }
        } else if let inlineResult = tab.result {
            existingResult = inlineResult
            querySQL = tab.sql
            let editorTabId = tab.id
            applyMerged = { [weak self] merged in
                self?.stateManager.updateTab(id: editorTabId) { $0.result = merged }
            }
            isStillDisplaying = { [weak self] in
                self?.stateManager.pinnedResult == nil
                    && self?.activeResultTabId == nil
                    && self?.stateManager.activeTabId == editorTabId
            }
        } else {
            return
        }

        guard existingResult.hasMore else { return }

        let trimmedSQL = querySQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = Int64(existingResult.rows.count)
        let limit = Int64(stateManager.settings.query.defaultLimit)
        let tabSchema = tab.schemaName

        resultsVC.setLoadingMore(true)

        Task {
            do {
                let moreResult = try await PharosCore.fetchMoreRows(
                    connectionId: connectionId,
                    sql: trimmedSQL,
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
                    applyMerged(merged)
                    // Only mutate the visible grid if the paginated result is still shown.
                    if isStillDisplaying() {
                        self.resultsVC.appendRows(from: moreResult)
                    } else {
                        self.resultsVC.setLoadingMore(false)
                    }
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

    // MARK: - Workspace History Capture

    /// Ensure the given editor tab has a persisted workspace, refreshing its
    /// editor/variables snapshot, and return the workspace id. Assigns a new
    /// workspace id to the tab on first call. Returns nil if the tab has no
    /// connection (nothing to record yet).
    @discardableResult
    private func ensureWorkspace(forEditorTabId tabId: String) -> String? {
        guard let tab = stateManager.tabs.first(where: { $0.id == tabId }), tab.connectionId != nil else { return nil }
        let wsId = tab.workspaceId ?? UUID().uuidString
        guard let payload = stateManager.workspaceUpsertPayload(for: tab, workspaceId: wsId) else { return tab.workspaceId }
        do {
            try PharosCore.upsertWorkspace(payload)
            if tab.workspaceId == nil {
                stateManager.updateTab(id: tabId) { $0.workspaceId = wsId }
            }
            return wsId
        } catch {
            NSLog("upsertWorkspace failed: \(error)")
            return tab.workspaceId
        }
    }

    /// Associate a produced result (by its history id) with the editor tab's
    /// workspace, at the next order slot. `color` supplies the persisted palette
    /// index (falls back to an order-cycled color for inline results).
    private func captureExecutedResult(historyId: String, editorTabId: String, workspaceId: String, color: NSColor) {
        let order = resultOrderByEditorTab[editorTabId, default: 0]
        resultOrderByEditorTab[editorTabId] = order + 1
        let colorIndex = ResultTab.palette.firstIndex(of: color) ?? (order % ResultTab.palette.count)
        do {
            try PharosCore.associateResult(.init(
                historyId: historyId, workspaceId: workspaceId,
                resultOrder: order, colorIndex: colorIndex
            ))
            NotificationCoalescer.post(.workspaceHistoryDidChange)
        } catch {
            NSLog("associateResult failed: \(error)")
        }
    }

    /// Centralized tab-close helper. Cancellation of in-flight queries is
    /// handled inside AppStateManager.closeTab via the queriesWillBeCancelled
    /// notification, which seeds cancelledQueryIds via the observer in viewDidLoad.
    func closeTab(id: String) {
        // Flush a final editor snapshot for the closing tab's workspace.
        if let tab = stateManager.tabs.first(where: { $0.id == id }), tab.workspaceId != nil {
            _ = ensureWorkspace(forEditorTabId: id)
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

    func editorPaneDidRequestRunAll(_ pane: EditorPaneVC) {
        stateManager.focusPane(id: pane.paneId)
        runAllSegments()
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
        stateManager.updateTab(id: tab.id) {
            $0.savedQueryId = query.id
            $0.variables = SavedQueryVariables.decode(query.variables)
        }
    }

    @objc private func handleOpenHistoryEntry(_ notification: Notification) {
        guard let entry = notification.userInfo?["entry"] as? QueryHistoryEntry else { return }

        let tabName = entry.tableNames ?? "History"
        let tab = stateManager.createTab(sql: entry.sql, name: tabName)

        do {
            guard let resultData = try PharosCore.getQueryHistoryResult(id: entry.id) else { return }
            let result = QueryResult(
                columns: resultData.columns,
                rows: resultData.rows,
                rowCount: resultData.rows.count,
                executionTimeMs: UInt64(entry.executionTimeMs),
                hasMore: false,
                historyEntryId: entry.id
            )

            // Store the history result in its own ResultTab carrying the
            // history schema + timestamp. Subsequent queries the user runs in
            // this editor tab produce sibling ResultTabs without those fields,
            // so the banner is correctly tied to viewing this result — not to
            // the editor tab as a whole.
            var rt = ResultTab(
                id: UUID().uuidString,
                segmentIndex: -1,
                sql: entry.sql,
                lineRange: 0...0,
                color: ResultTab.nextColor(),
                timestamp: Date()
            )
            rt.customLabel = entry.tableNames ?? "History"
            rt.queryResult = result
            rt.executionTimeMs = UInt64(entry.executionTimeMs)
            rt.totalRowCountHint = result.rowCount
            rt.historySchema = entry.schema
            rt.historyTimestamp = entry.executedAt

            // We CAN'T call addResultTab here: createTab() updates activeTabId
            // synchronously, but activeTabChanged (the Combine sink that swaps
            // the live `resultTabs` array and grid contents) is dispatched on
            // RunLoop.main and fires later. If we appended now, the result
            // would land in the *outgoing* tab's live `resultTabs` array, and
            // when activeTabChanged eventually ran, it would persist that
            // polluted array under the previous tab and load empty results
            // for the new one.
            //
            // Instead, seed the per-editor-tab dictionaries directly. When
            // activeTabChanged fires for the new tab, it reads these,
            // populates the live grid, and applies the history banner.
            resultTabsByEditorTab[tab.id] = [rt]
            activeResultTabIdByEditorTab[tab.id] = rt.id
        } catch {
            NSLog("Failed to load history results: \(error)")
        }
    }

    @objc private func handleShowSQLInInspector(_ notification: Notification) {
        guard let sql = notification.userInfo?["sql"] as? String else { return }
        guard let splitVC = parent as? PharosSplitViewController else { return }
        splitVC.showInspector()
        splitVC.inspectorVC.showSQL(sql)
    }

    @objc private func handleOpenWorkspace(_ notification: Notification) {
        guard let wsId = notification.userInfo?["workspaceId"] as? String else { return }
        let focusResultId = notification.userInfo?["focusResultId"] as? String

        // Already open in a live tab? Just focus it (and the requested result, if any).
        if let existing = stateManager.tabs.first(where: { $0.workspaceId == wsId }) {
            let alreadyActive = stateManager.activeTabId == existing.id
            stateManager.selectTab(id: existing.id)
            if let fid = focusResultId {
                if alreadyActive {
                    focusResultTab(historyId: fid)
                } else {
                    // activeTabChanged is dispatched via RunLoop.main and hasn't
                    // swapped `resultTabs` over to this tab yet — defer so we
                    // search the right array (mirrors handleRunQueryInNewTab).
                    DispatchQueue.main.async { [weak self] in
                        self?.focusResultTab(historyId: fid)
                    }
                }
            }
            return
        }

        // Loading the workspace detail and fetching every cached result blob
        // (each a gzip+JSON FFI round-trip) is expensive for a long session —
        // do it off the main thread so reopening doesn't hitch the UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            // `try?` on an already-Optional-returning throwing function flattens
            // to a single Optional (Swift 5+), so one `guard let` unwraps both
            // the error case and the "workspace no longer exists" case.
            guard let detail = try? PharosCore.loadWorkspace(id: wsId) else { return }

            let vars = (try? JSONDecoder.pharos.decode([QueryVariable].self, from: Data(detail.variablesJson.utf8))) ?? []

            // Rebuild result tabs from metadata; fetch cached blobs eagerly for
            // results that have them, leave "SQL only" ones as re-runnable stubs.
            var restored: [ResultTab] = []
            for meta in detail.results {
                let color = ResultTab.palette[(meta.colorIndex ?? 0) % ResultTab.palette.count]
                var rt = ResultTab(
                    id: UUID().uuidString,
                    segmentIndex: -1,
                    sql: meta.sql,
                    lineRange: 0...0,
                    color: color,
                    timestamp: Date()
                )
                rt.customLabel = meta.customLabel ?? meta.tableNames
                rt.executionTimeMs = UInt64(meta.executionTimeMs)
                rt.historySchema = meta.schema
                rt.historyTimestamp = meta.executedAt
                rt.isStale = true
                rt.totalRowCountHint = meta.rowCount
                // Restore persisted chart config + view mode for this result.
                if let json = meta.chartViewStateJson,
                   let data = json.data(using: .utf8),
                   let state = try? JSONDecoder.pharos.decode(PersistedResultViewState.self, from: data) {
                    rt.chartConfig = state.chartConfig
                    rt.resultViewMode = state.viewMode
                }
                if meta.hasResults, let data = try? PharosCore.getQueryHistoryResult(id: meta.id) {
                    rt.queryResult = QueryResult(
                        columns: data.columns, rows: data.rows,
                        rowCount: data.rows.count, executionTimeMs: UInt64(meta.executionTimeMs),
                        hasMore: false, historyEntryId: meta.id
                    )
                }
                restored.append(rt)
            }

            await MainActor.run {
                guard let self else { return }

                // Re-check already-open: another reopen request could have
                // created a tab for this workspace while we were off-main.
                if let existing = self.stateManager.tabs.first(where: { $0.workspaceId == wsId }) {
                    let alreadyActive = self.stateManager.activeTabId == existing.id
                    self.stateManager.selectTab(id: existing.id)
                    if let fid = focusResultId {
                        if alreadyActive {
                            self.focusResultTab(historyId: fid)
                        } else {
                            DispatchQueue.main.async { [weak self] in
                                self?.focusResultTab(historyId: fid)
                            }
                        }
                    }
                    return
                }

                let tab = self.stateManager.createTab(sql: detail.editorText, name: detail.name)
                self.stateManager.updateTab(id: tab.id) {
                    $0.workspaceId = detail.id
                    $0.connectionId = detail.connectionId
                    $0.variables = vars
                    $0.cursorPosition = detail.cursorPosition ?? 0
                }

                // Seed the per-editor-tab dictionaries directly (same reasoning
                // as the legacy handleOpenHistoryEntry path above —
                // activeTabChanged fires later on RunLoop.main and will read
                // these).
                self.resultTabsByEditorTab[tab.id] = restored
                let focus = focusResultId.flatMap { fid in restored.first(where: { $0.queryResult?.historyEntryId == fid }) } ?? restored.last
                self.activeResultTabIdByEditorTab[tab.id] = focus?.id
                // Subsequently-executed queries in this tab append AFTER the restored
                // results. Seed from MAX(result_order)+1 (not count) so a workspace whose
                // middle results were deleted can't collide a new result's order.
                self.resultOrderByEditorTab[tab.id] = (detail.results.compactMap { $0.resultOrder }.max() ?? -1) + 1
            }
        }
    }

    /// Select the live result tab whose cached result came from the given
    /// query-history id. No-op if it isn't in the currently-displayed
    /// `resultTabs` (e.g. the editor tab isn't focused yet).
    private func focusResultTab(historyId: String) {
        guard let tab = resultTabs.first(where: { $0.queryResult?.historyEntryId == historyId }) else { return }
        selectResultTab(tab.id)
    }
}

// MARK: - Chart Mode

extension ContentViewController {

    /// The active result tab's current view mode, defaulting to grid when no
    /// result tab is active.
    private var activeResultViewMode: ResultViewMode {
        guard let id = activeResultTabId, let tab = resultTabs.first(where: { $0.id == id }) else { return .grid }
        return tab.resultViewMode
    }

    /// Show/hide the results grid vs. the chart host based on the active result
    /// tab's view mode and the current editor/results expand state. Single source
    /// of truth so `applyExpandState`, mode toggles, and tab switches agree.
    func applyResultAreaVisibility() {
        let resultsAreaVisible = (expandState != .editorExpanded)
        let showChart = resultsAreaVisible && activeResultViewMode == .chart
        chartHost.view.isHidden = !showChart
        resultsVC.view.isHidden = !(resultsAreaVisible && !showChart)
        updateExportButtonTarget()
    }

    /// Retarget the shared export button between the grid's copy/export menu
    /// and the chart export menu, based on the active result tab's view mode.
    /// Grid mode is unchanged from before charts existed.
    private func updateExportButtonTarget() {
        if activeResultViewMode == .chart {
            exportButton.target = self
            exportButton.action = #selector(showChartExportMenu)
        } else {
            exportButton.target = resultsVC.copyExport
            exportButton.action = #selector(ResultsCopyExport.showExportMenu)
        }
    }

    /// Apply a view mode to the UI for the given result tab (present the chart if
    /// needed, sync the toggle, flip visibility) WITHOUT persisting. Used on
    /// restore and tab switches where nothing changed.
    private func applyResultViewMode(_ mode: ResultViewMode, for idx: Int) {
        guard idx < resultTabs.count else { return }
        resultTabs[idx].resultViewMode = mode
        chartToggle.selectedSegment = (mode == .chart) ? 1 : 0
        if mode == .chart { presentChart(for: idx) }
        else { cancelServerAggregation() }   // leaving chart mode kills any run
        applyResultAreaVisibility()
    }

    /// Set (and persist) the view mode for the active result tab. Used by the
    /// explicit user toggle and the reopen-into-chart restore.
    func setResultViewMode(_ mode: ResultViewMode) {
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }) else { return }
        applyResultViewMode(mode, for: idx)
        persistChartState(forTabId: id)
    }

    @objc func chartToggleChanged() {
        let mode: ResultViewMode = chartToggle.selectedSegment == 1 ? .chart : .grid
        setResultViewMode(mode)
    }

    /// Sync the toggle + chart/grid visibility to the newly-active result tab
    /// (no persistence). Called after a tab switch or when the active tab clears.
    func syncChartToggleToActiveTab() {
        // A fresh query / tab switch rebuilds the grid, so any drill applied to
        // the previous result no longer applies — drop its bookkeeping + chip.
        // NOTE: this runs AFTER the outgoing path's captureGridState(), so it is
        // NOT the place that protects the outgoing tab's saved filters — the
        // outgoing paths call tearDownDrill(restoreManual: true) themselves,
        // before capture. This call is the belt-and-braces cleanup for the empty
        // (no active tab) case.
        clearStagedChartSelection()
        tearDownDrill(restoreManual: true)
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }) else {
            // No active result tab (last result tab closed, or switched to a tab
            // with no results): kill any in-flight push-down so it isn't orphaned.
            cancelServerAggregation()
            chartToggle.selectedSegment = 0
            applyResultAreaVisibility()
            return
        }
        applyResultViewMode(resultTabs[idx].resultViewMode, for: idx)
    }

    /// Capture the config the user just edited in the chart rail back onto the
    /// (about-to-be-outgoing) result tab, mirroring the gridState capture.
    private func captureChartConfig(intoTabAt idx: Int) {
        guard idx < resultTabs.count, resultTabs[idx].resultViewMode == .chart else { return }
        if let cfg = chartHost.currentConfig { resultTabs[idx].chartConfig = cfg }
    }

    /// Build the chart for the result tab at `idx` and hand it to the host.
    private func presentChart(for idx: Int) {
        guard idx < resultTabs.count else { return }
        // (Re)presenting supersedes any prior tab's server-aggregation run:
        // cancel it so a superseded full-table GROUP BY stops burning server time.
        cancelServerAggregation()
        guard let result = resultTabs[idx].queryResult else {
            // Restored result whose rows were demoted: chart shows a re-run
            // empty state; config is preserved for when it's re-executed.
            chartHost.onConfigChanged = nil
            chartHost.onLoadAll = nil
            chartHost.onSelectionChanged = nil
            chartHost.onServerConfigChanged = nil
            chartHost.onCopySQL = nil
            chartHost.onRunServerAggregation = nil
            chartHost.present(
                result: QueryResult(columns: [], rows: [], rowCount: 0, executionTimeMs: 0, hasMore: false, historyEntryId: nil),
                initialConfig: resultTabs[idx].chartConfig,
                banner: ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "")
            )
            return
        }
        // Drop any stored role whose column no longer exists at the same index.
        var cfg = resultTabs[idx].chartConfig
        cfg?.validate(against: result.columns)

        // Capture the tab's stable id (not its index) so a reorder/close of other
        // tabs while this chart is on screen can't misattribute the edit or the
        // debounced persist to the wrong result tab.
        let tabId = resultTabs[idx].id
        chartHost.onConfigChanged = { [weak self] newCfg in
            guard let self, let i = self.resultTabs.firstIndex(where: { $0.id == tabId }) else { return }
            self.resultTabs[i].chartConfig = newCfg
            self.scheduleChartStatePersist(forTabId: tabId)
            self.refreshPushdownAvailability()
            // Toggling server aggregation off restores the client-side path
            // (the view model recomputes client data itself); cancel any run.
            if !newCfg.serverAggregation { self.cancelServerAggregation() }
        }
        chartHost.onLoadAll = { [weak self] in self?.loadAllRowsForChart() }
        chartHost.onSelectionChanged = { [weak self] keys in self?.chartSelectionChanged(keys) }
        // A rail edit while server mode is on (re)runs the debounced query.
        chartHost.onServerConfigChanged = { [weak self] in self?.runServerAggregation(debounced: true) }
        chartHost.onCopySQL = { [weak self] in self?.copyGeneratedChartSQL() }
        // The reopen "Run…" affordance runs immediately (no debounce).
        chartHost.onRunServerAggregation = { [weak self] in self?.runServerAggregation(debounced: false) }
        chartHost.present(result: result, initialConfig: cfg, banner: bannerInfo(for: idx, result: result))
        // Capture the config the host actually used (inference may have filled it).
        resultTabs[idx].chartConfig = chartHost.currentConfig
        // Reopen is explicit: even with serverAggregation on we do NOT auto-run
        // here — the banner shows the "Run…" state. Just publish availability.
        refreshPushdownAvailability()
    }

    // MARK: Push-down (server aggregation)

    /// Compute push-down availability for the active chart and push it (plus a
    /// disabled-reason) into the view model so the rail can show/hide the toggle.
    private func refreshPushdownAvailability() {
        guard let id = activeResultTabId,
              let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult,
              let cfg = resultTabs[idx].chartConfig else {
            chartHost.setPushdownAvailability(false, reason: nil)
            return
        }
        let userSQL = resultTabs[idx].sql
        if SqlPushdownGenerator.generate(cfg, userSQL: userSQL, columns: result.columns) != nil {
            chartHost.setPushdownAvailability(true, reason: nil)
        } else {
            chartHost.setPushdownAvailability(false, reason: pushdownUnavailableReason(cfg, userSQL: userSQL))
        }
    }

    /// A human explanation for why push-down is unavailable (display only; the
    /// generator remains the authority on availability).
    private func pushdownUnavailableReason(_ cfg: ChartConfig, userSQL: String) -> String {
        switch cfg.chartType {
        case .gantt: return "Not available for this chart type."
        default: break
        }
        let segs = SQLSegmentParser.parse(userSQL)
            .filter { !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if segs.count != 1 { return "Needs a single SELECT/WITH query." }
        let t = segs[0].sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !(t.hasPrefix("select") || t.hasPrefix("with")) { return "Needs a SELECT/WITH query." }
        return "Map a category and value to enable."
    }

    /// Run (or schedule) a push-down aggregation for the active chart.
    private func runServerAggregation(debounced: Bool) {
        // Cancel any superseded run NOW (server-side + pending debounce) rather
        // than letting it burn through the ~0.4s debounce window. This also clears
        // the debounce work item and spinner; we re-show the spinner below for the
        // new run, which then proceeds normally.
        cancelServerAggregation()
        // Show the spinner immediately so a rail tweak feels responsive even
        // while the actual execution is still debouncing.
        chartHost.setServerLoading(true)
        if debounced {
            let item = DispatchWorkItem { [weak self] in self?.performServerAggregation() }
            chartServerAggWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        } else {
            performServerAggregation()
        }
    }

    /// Generate + execute the push-down query for the active chart, build the
    /// ChartData, and push it into the host (last-write-wins on completion).
    private func performServerAggregation() {
        chartServerAggWorkItem = nil
        guard let editorTab = stateManager.activeTab,
              let connectionId = editorTab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let id = activeResultTabId,
              let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult,
              let cfg = resultTabs[idx].chartConfig, cfg.serverAggregation else {
            chartHost.setServerLoading(false)
            return
        }
        guard let pushdown = SqlPushdownGenerator.generate(cfg, userSQL: resultTabs[idx].sql, columns: result.columns) else {
            chartHost.setServerError("Server aggregation isn't available for this configuration.")
            return
        }
        // Supersede any prior in-flight run before starting a new one.
        cancelServerAggregation()
        let queryId = UUID().uuidString
        chartServerQueryId = queryId
        // Remember the pool this run launches against so a later cancel targets it
        // even if the active tab has changed by then (tab switch/close mid-run).
        chartServerConnectionId = connectionId
        chartHost.setServerLoading(true)

        let schema = editorTab.schemaName
        // Pass limit ≥ the generator's group cap so groups aren't silently paged
        // off by executeQuery's own page limit; hasMore then means truncation.
        let cap = max(SqlPushdownGenerator.groupCap, SqlPushdownGenerator.scatterSampleCap)
        let limit = max(Int32(stateManager.settings.query.defaultLimit), Int32(cap))
        let rtId = id
        let layout = pushdown.layout
        let sql = pushdown.sql

        Task {
            do {
                let qr = try await PharosCore.executeQuery(
                    connectionId: connectionId, sql: sql, queryId: queryId,
                    limit: limit, schema: schema, source: "chart-aggregation"
                )
                await MainActor.run {
                    // Last-write-wins: ignore a result whose run was superseded.
                    guard self.chartServerQueryId == queryId else { return }
                    self.chartServerQueryId = nil
                    self.chartServerConnectionId = nil
                    let data = ServerChartDataBuilder.build(qr, layout: layout, config: cfg)
                    let lastRun = LastServerRun(
                        sql: sql,
                        executedAt: ISO8601DateFormatter().string(from: Date()),
                        rowCount: qr.rowCount,
                        truncated: qr.hasMore,
                        sampled: data.wasSampled
                    )
                    self.chartHost.applyServerRun(data, lastRun: lastRun)
                    // Persist the provenance so it survives history pruning + reopen.
                    if let i = self.resultTabs.firstIndex(where: { $0.id == rtId }) {
                        self.resultTabs[i].chartConfig?.lastServerRun = lastRun
                        self.scheduleChartStatePersist(forTabId: rtId)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.chartServerQueryId == queryId else { return }
                    self.chartServerQueryId = nil
                    self.chartServerConnectionId = nil
                    self.chartHost.setServerError(error.localizedDescription)
                }
            }
        }
    }

    /// Cancel the in-flight push-down query server-side and drop its pending
    /// debounce, so a superseded/abandoned run stops consuming DB resources. The
    /// nil'd `chartServerQueryId` also makes any late result a last-write-wins no-op.
    private func cancelServerAggregation() {
        chartServerAggWorkItem?.cancel()
        chartServerAggWorkItem = nil
        // Clear the spinner so an abandoned/superseded run can't strand it on.
        chartHost.setServerLoading(false)
        guard let qid = chartServerQueryId else { return }
        // Cancel against the pool the run was LAUNCHED on — not activeTab, which
        // may already point at a different connection after a tab switch/close.
        let connectionId = chartServerConnectionId
        chartServerQueryId = nil
        chartServerConnectionId = nil
        guard let connectionId else { return }
        Task { _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: qid) }
    }

    /// Copy the current chart's generated push-down SQL to the pasteboard — the
    /// forensic primitive (an auditor re-runs it verbatim to validate the chart).
    /// `@objc` so it doubles as the export menu's "View / Copy Generated SQL"
    /// action (Task 10), alongside the rail button's direct closure call.
    @objc private func copyGeneratedChartSQL() {
        guard let id = activeResultTabId,
              let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult,
              let cfg = resultTabs[idx].chartConfig,
              let pushdown = SqlPushdownGenerator.generate(cfg, userSQL: resultTabs[idx].sql, columns: result.columns) else {
            NSSound.beep(); return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pushdown.sql, forType: .string)
    }

    /// Whether a push-down query can currently be generated for the active
    /// chart — gates the export menu's "View / Copy Generated SQL" item the
    /// same way the rail's copy-SQL button is gated (Task 7): server
    /// aggregation on, and generation actually succeeds (so a stale flag on a
    /// non-aggregating chart type, or an unmappable config, hides the item
    /// rather than offering a dead action).
    private func activePushdownQueryAvailable() -> Bool {
        guard let id = activeResultTabId,
              let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult,
              let cfg = resultTabs[idx].chartConfig, cfg.serverAggregation else { return false }
        return SqlPushdownGenerator.generate(cfg, userSQL: resultTabs[idx].sql, columns: result.columns) != nil
    }

    // MARK: Chart Drill-down

    /// Translate a chart mark's drill keys into a detail query. In client mode
    /// (push-down off, or the chart type doesn't aggregate) this is grid column
    /// filters applied in place; in push-down mode it spawns a filtered detail
    /// query as a new result tab instead.
    /// The chart reported a new staged selection — show/label the commit button.
    private func chartSelectionChanged(_ keys: [DrillKey]) {
        stagedChartKeys = keys
        if keys.isEmpty {
            chartFilterButton.isHidden = true
        } else {
            let server = activeChartUsesServerMode()
            chartFilterButton.title = DrillSummary.label(keys, prefix: server ? "Query Selected Rows" : "Filter in Grid")
            chartFilterButton.toolTip = chartFilterButton.title
            chartFilterButton.isHidden = false
        }
        updateInspectorForChartSelection(keys)
    }

    /// Show aggregate stats for the rows matching the chart selection (client mode).
    /// Server-aggregation mode is skipped — its loaded rows are pre-aggregated and
    /// the drill keys reference original columns not present there.
    private func updateInspectorForChartSelection(_ keys: [DrillKey]) {
        guard let splitVC = parent as? PharosSplitViewController else { return }
        guard !keys.isEmpty, !activeChartUsesServerMode(),
              let fc = resultsVC.columnFilterController else {
            splitVC.inspectorVC.showNoSelection(); return
        }
        let applied = DrillTranslator.filters(for: keys, columns: resultsVC.columns)
        guard !applied.isEmpty else { splitVC.inspectorVC.showNoSelection(); return }
        var filters: [String: ColumnFilter] = [:]
        for a in applied { filters[a.columnId] = a.filter }
        let matchIdx = fc.matchingRows(filters, inputDisplayRows: Array(0..<resultsVC.rows.count))
        let rows = matchIdx.compactMap { $0 < resultsVC.rows.count ? resultsVC.rows[$0] : nil }
        splitVC.inspectorVC.showAggregation(
            columns: resultsVC.columns, rows: rows,
            selectionCount: rows.count, columnCategories: resultsVC.columnCategories)
        splitVC.showInspector()
    }

    /// Drop any *uncommitted* chart selection (button + staged keys + the chart's
    /// staged highlight). Called on result-tab changes so a stale selection from a
    /// previous tab can't be committed against a different result.
    private func clearStagedChartSelection() {
        stagedChartKeys = []
        chartFilterButton.isHidden = true
        chartHost.clearSelection()
    }

    /// Whether the active chart commits via server-aggregation (detail query) vs grid filters.
    private func activeChartUsesServerMode() -> Bool {
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let cfg = resultTabs[idx].chartConfig else { return false }
        return cfg.serverAggregation && chartTypeSupportsServer(cfg.chartType)
    }

    /// Commits the staged chart selection: applies it as a drill (client filter
    /// or server detail query), clears the staged selection, and hides the
    /// commit button.
    @objc private func commitChartSelection() {
        guard !stagedChartKeys.isEmpty else { return }
        applyDrill(stagedChartKeys)          // client: replace + grid filters; server: detail query (branch inside)
        stagedChartKeys = []
        chartFilterButton.isHidden = true
        chartHost.clearSelection()           // clear the chart's staged highlight
    }

    private func applyDrill(_ keys: [DrillKey]) {
        guard let id = activeResultTabId,
              let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult else { return }

        if let cfg = resultTabs[idx].chartConfig, cfg.serverAggregation, chartTypeSupportsServer(cfg.chartType) {
            applyServerDrill(keys, resultTab: resultTabs[idx], columns: result.columns)
            return
        }

        // Replace any prior committed chart filter (restore displaced manual filters first).
        tearDownDrill(restoreManual: true)

        let applied = DrillTranslator.filters(for: keys, columns: result.columns)
        guard !applied.isEmpty else { committedChartKeys = []; chartHost.setCommittedKeys([]); return }
        guard let fc = resultsVC.columnFilterController else { return }
        for a in applied {
            if let existing = fc.filter(forColumn: a.columnId) { displacedFilters[a.columnId] = existing }
            fc.setFilter(a.filter, forColumn: a.columnId)
            if !drillColumns.contains(a.columnId) { drillColumns.append(a.columnId) }
        }
        committedChartKeys = keys
        chartHost.setCommittedKeys(DrillMerge.merge(keys))
        resultsVC.refreshColumnFilters()
        setResultViewMode(.grid)
        updateDrillChip()
    }

    /// Push-down mode drill: translate the drill keys into a SQL predicate
    /// (`DrillSqlTranslator`), wrap the result tab's (already variable-substituted)
    /// SQL in a filtered subquery, and run it through the normal query-run path as
    /// a **new result tab** — this records the run in `query_history`, giving a
    /// self-contained, re-runnable drill trail. Does NOT touch the grid filter /
    /// chip; that overlay is client-mode-only.
    private func applyServerDrill(_ keys: [DrillKey], resultTab: ResultTab, columns: [ColumnDef]) {
        guard !keys.isEmpty else { return }
        let predicate = keys
            .map { "(" + DrillSqlTranslator.predicate(for: $0, columns: columns) + ")" }
            .joined(separator: " AND ")
        guard !predicate.isEmpty else { return }
        let sql = "SELECT * FROM ( \(resultTab.sql) ) AS _pharos_src WHERE \(predicate)"
        performQuery(sql, segmentIndex: -1, lineRange: 0...0, customLabel: nil, createResultTab: true)
    }

    /// Whether the chart type can use server mode: aggregating types, plus
    /// scatter (a deterministic sample). Gantt never pushes down.
    /// Push-down drill only applies to these types; gantt falls back to the
    /// client drill path even if a stale `serverAggregation` flag is still set.
    private func chartTypeSupportsServer(_ type: ChartType) -> Bool { type != .gantt }

    /// Clear the chart drill: restore any manual filter each drill column
    /// displaced, otherwise drop the filter entirely; then refresh + hide chip.
    @objc private func clearDrill() {
        guard !drillColumns.isEmpty, resultsVC.columnFilterController != nil else { return }
        tearDownDrill(restoreManual: true)
        resultsVC.refreshColumnFilters()
    }

    /// Tear down the active drill, undoing its effect on the SHARED column filter
    /// controller. A drill is a transient overlay: it may have displaced a manual
    /// filter on a column. Restoring (`restoreManual: true`) puts each displaced
    /// manual filter back and drops any drill-only filter; otherwise every drill
    /// column is cleared. Callers that need the visible grid to reflect the change
    /// must follow with `resultsVC.refreshColumnFilters()`; on an outgoing-tab
    /// transition no reload is needed because the incoming tab rebuilds the grid.
    /// Crucially this must run BEFORE `captureGridState()` on any outgoing path so
    /// the captured state reflects the user's real manual filters, not the drill.
    private func tearDownDrill(restoreManual: Bool) {
        guard let fc = resultsVC.columnFilterController, !drillColumns.isEmpty else {
            drillColumns.removeAll(); displacedFilters.removeAll()
            committedChartKeys = []
            chartHost.setCommittedKeys([])
            updateDrillChip(); return
        }
        for colId in drillColumns {
            if restoreManual, let restore = displacedFilters[colId] { fc.setFilter(restore, forColumn: colId) }
            else { fc.clearFilter(forColumn: colId) }
        }
        drillColumns.removeAll(); displacedFilters.removeAll()
        committedChartKeys = []
        chartHost.setCommittedKeys([])
        updateDrillChip()
    }

    /// Toolbar "reset filters" action: clears the chart-drill overlay bookkeeping
    /// (+ chip) AND all column filters. `restoreManual: false` because a full reset
    /// means every filter goes — including any manual filter the drill displaced.
    @objc private func resetAllFiltersAndDrill() {
        tearDownDrill(restoreManual: false)
        resultsVC.resetAllColumnFilters()
    }

    /// Show the chip iff a drill is active; label summarizes the committed chart keys.
    private func updateDrillChip() {
        let active = !drillColumns.isEmpty
        drillChip.isHidden = !active
        if active { drillChip.title = DrillSummary.label(committedChartKeys, prefix: "Filtered by Chart") }
    }

    // MARK: Banner

    private func bannerInfo(for idx: Int, result: QueryResult) -> ChartBannerInfo {
        let loaded = result.rows.count
        let canLoadMore = result.hasMore
        // Total from the source (live/history); fall back to loaded when unknown.
        let total = resultTabs[idx].totalRowCountHint ?? loaded
        let subset = canLoadMore || total > loaded
        guard subset else { return ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "") }
        let ofTotal = total > loaded ? " of \(total)" : ""
        let text = "Charting \(loaded)\(ofTotal) loaded rows, aggregated client-side."
        return ChartBannerInfo(shouldShow: true, canLoadAll: canLoadMore, text: text)
    }

    // MARK: Load all (in-memory)

    private func loadAllRowsForChart() {
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult, result.hasMore else { return }
        let cap = 200_000
        fetchAllRemaining(upTo: cap) { [weak self] in
            guard let self, let i = self.resultTabs.firstIndex(where: { $0.id == self.activeResultTabId }) else { return }
            if self.resultTabs[i].resultViewMode == .chart { self.presentChart(for: i) }
        }
    }

    /// Loop the existing fetch-more FFI path (mirrors `loadMoreRows`), appending
    /// rows into the active result tab's in-memory `queryResult` until `hasMore`
    /// is false or the cap is reached. Does NOT write back to the workspace/history
    /// blob — this is an in-memory expansion for charting only.
    private func fetchAllRemaining(upTo cap: Int, completion: @escaping () -> Void) {
        guard let editorTab = stateManager.activeTab,
              let connectionId = editorTab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let id = activeResultTabId,
              let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let current = resultTabs[idx].queryResult, current.hasMore else {
            completion(); return
        }
        let sql = resultTabs[idx].sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let schema = editorTab.schemaName
        let limit = Int64(stateManager.settings.query.defaultLimit)
        let rtId = id

        Task {
            var accumulated = current
            do {
                while accumulated.hasMore && accumulated.rows.count < cap {
                    let offset = Int64(accumulated.rows.count)
                    let more = try await PharosCore.fetchMoreRows(
                        connectionId: connectionId, sql: sql, limit: limit, offset: offset, schema: schema
                    )
                    // Mirror loadMoreRows' merge, keeping columns/exec time/history id.
                    accumulated = QueryResult(
                        columns: accumulated.columns,
                        rows: accumulated.rows + more.rows,
                        rowCount: accumulated.rows.count + more.rows.count,
                        executionTimeMs: accumulated.executionTimeMs,
                        hasMore: more.hasMore,
                        historyEntryId: accumulated.historyEntryId
                    )
                    if more.rows.isEmpty { break }   // guard against a no-progress loop
                }
            } catch {
                NSLog("Chart load-all failed: \(error)")
            }
            let finalResult = accumulated
            await MainActor.run {
                if let i = self.resultTabs.firstIndex(where: { $0.id == rtId }) {
                    self.resultTabs[i].queryResult = finalResult
                }
                completion()
            }
        }
    }

    // MARK: Persistence

    private func scheduleChartStatePersist(forTabId id: String) {
        chartPersistWorkItems[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistChartState(forTabId: id) }
        chartPersistWorkItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func persistChartState(forTabId id: String) {
        chartPersistWorkItems[id] = nil
        guard let tab = resultTabs.first(where: { $0.id == id }) else { return }
        // Only persist for results that belong to a workspace (have a history id).
        guard let resultId = tab.queryResult?.historyEntryId else { return }
        let state = PersistedResultViewState(chartConfig: tab.chartConfig, viewMode: tab.resultViewMode)
        guard let data = try? JSONEncoder.pharos.encode(state) else { return }
        let json = String(decoding: data, as: UTF8.self)
        DispatchQueue.global(qos: .utility).async {
            _ = try? PharosCore.updateResultChartState(resultId: resultId, json: json)
        }
    }

    // MARK: Chart Export

    private enum ChartExportKind { case png, pdf, copy }

    /// Chart-mode export menu (parallels `ResultsCopyExport.showExportMenu` for
    /// grid mode — `updateExportButtonTarget()` swaps the shared export button
    /// between the two based on the active result tab's view mode).
    @objc func showChartExportMenu() {
        let menu = NSMenu()
        for (title, action) in [
            ("Export Chart as PNG\u{2026}", #selector(exportChartAsPNG)),
            ("Export Chart as PDF\u{2026}", #selector(exportChartAsPDF)),
            ("Copy Chart as Image", #selector(copyChartAsImage)),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        // Push-down only (Task 10) — omitted entirely in client mode.
        if activePushdownQueryAvailable() {
            menu.addItem(.separator())
            let item = menu.addItem(
                withTitle: "View / Copy Generated SQL",
                action: #selector(copyGeneratedChartSQL),
                keyEquivalent: ""
            )
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: exportButton.bounds.maxY + 4), in: exportButton)
    }

    @objc private func exportChartAsPNG() { performChartExport(.png) }
    @objc private func exportChartAsPDF() { performChartExport(.pdf) }
    @objc private func copyChartAsImage() { performChartExport(.copy) }

    private func performChartExport(_ kind: ChartExportKind) {
        guard let snapshot = chartHost.buildExportSnapshot() else {
            NSSound.beep()
            return
        }
        switch kind {
        case .png:
            guard let data = ChartExporter.png(of: snapshot.view, size: snapshot.size, timestamp: snapshot.timestamp) else { return }
            saveChartExport(data: data, filename: "\(defaultChartExportBaseName()).png", type: .png)
        case .pdf:
            guard let data = ChartExporter.pdf(of: snapshot.view, size: snapshot.size) else { return }
            saveChartExport(data: data, filename: "\(defaultChartExportBaseName()).pdf", type: .pdf)
        case .copy:
            guard let data = ChartExporter.png(of: snapshot.view, size: snapshot.size, timestamp: snapshot.timestamp) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
    }

    private func saveChartExport(data: Data, filename: String, type: UTType) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [type]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    /// Sanitized result-tab label for use as a save-panel default filename.
    private func defaultChartExportBaseName() -> String {
        guard let id = activeResultTabId, let tab = resultTabs.first(where: { $0.id == id }) else { return "chart" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = tab.label.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "chart" : cleaned
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

    @objc private func handleQueriesWillBeCancelled(_ note: Notification) {
        guard let queryIds = note.userInfo?["queryIds"] as? [String] else { return }
        for id in queryIds {
            cancelledQueryIds.insert(id)
        }
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
                let update = UpdateSavedQuery(id: savedId, name: nil, folder: nil, sql: currentSQL, variables: tab.variables.toSavedJSON())
                _ = try PharosCore.updateSavedQuery(update)
                stateManager.updateTab(id: tab.id) { $0.sql = currentSQL }
                NotificationCoalescer.post(.savedQueriesDidChange)
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
        let raw = focusedPaneVC?.getSQL() ?? ""
        let text = VariableSubstitutor.render(raw, with: tab.variables).sql

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
            sql: focusedPaneVC?.getSQL() ?? "",
            variables: tab.variables
        ) { [weak self] action in
            guard let self else { return }
            let savedQuery: SavedQuery
            switch action {
            case .created(let q): savedQuery = q
            case .replaced(let q): savedQuery = q
            }
            self.stateManager.updateTab(id: tab.id) { $0.savedQueryId = savedQuery.id }
            NotificationCoalescer.post(.savedQueriesDidChange)
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
                applyResultAreaVisibility()
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
