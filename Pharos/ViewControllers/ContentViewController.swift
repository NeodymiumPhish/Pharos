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

/// Main content area: the editor above the results grid.
/// Owns the one EditorPaneVC and runs queries.
class ContentViewController: NSViewController {

    private let resultsVC: ResultsGridVC
    /// The "no connection" state. Shown by `updateVisibility`, which today
    /// always hides it — see the note there.
    private let emptyState = EmptyStateView()

    // Action bar — independent element between the editor and the results grid
    let actionBar = ResultsToolbarBar()

    // Whose results these are — between the action bar and the results grid
    private let cardResultsHeader = CardResultsHeaderView()

    // Grid/Chart toggle (front of the action bar) + the SwiftUI chart host that
    // overlays the same region as the results grid, shown only in chart mode.
    private let chartToggle = NSSegmentedControl(labels: ["Grid", "Chart", "Plan"], trackingMode: .selectOne, target: nil, action: nil)
    private let chartHost = ChartHostingController()
    /// The query-plan outline, hosted over the same region as the grid while
    /// the displayed card's results show its plan (`CardResult.showsPlan`).
    private let planHost = PlanViewVC()
    /// Editor tabs whose name has already been put to the model. One ask per
    /// tab, whatever the answer was — a tab that ran ten queries must not open
    /// ten sessions, and a refusal is not worth retrying on the next run.
    private var nameSuggestionAsked: Set<String> = []
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

    // Container that holds the editor + actionBar + the results header + resultsVC.view with constraints
    private let contentStack = NSView()

    // Layout constraints for the editor/results split
    /// Editor above, results area below. See `EditorResultsSplitView`.
    private let editorResultsSplit = EditorResultsSplitView()
    /// Bottom pane of `editorResultsSplit`: action bar, results header, grid/chart.
    /// Sized, not `.zero`: the split view assigns the real frame, but only one
    /// pass after the children below are constrained. At zero the autoresizing
    /// mask contributes a REQUIRED `width == 0`, and the action bar's six 28 pt
    /// buttons cannot fit inside it, so Auto Layout breaks a child constraint
    /// and logs a runtime issue.
    private let resultsArea = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    /// One line above the action bar, for the first unread failure on the
    /// active tab. Zero height and hidden when there is nothing to say.
    private let errorBanner = QueryErrorBanner()
    private var errorBannerHeight: NSLayoutConstraint!
    /// One line below the error banner, for the cell edits the active result
    /// tab is holding. Zero height and hidden when there are none.
    private let pendingEditsBar = PendingEditsBar()
    private var pendingEditsBarHeight: NSLayoutConstraint!
    private var resultsBottomToContainer: NSLayoutConstraint!
    private var cardResultsHeaderHeight: NSLayoutConstraint!

    // Card results — one store for every editor tab — live on the window's
    // session (`WindowSession.resultStore`), reached as `session.resultStore`
    // below. It is written in place there: a computed alias here would make
    // every mutation a get-modify-set and copy the store on each one.

    /// The editor tab whose results the grid is showing. Set by
    /// `activeTabChanged` once the outgoing tab's state has been captured, so
    /// during that capture it still names the outgoing tab.
    private var lastActiveTabId: String?

    /// The displayed editor tab's card results — a view onto
    /// `session.resultStore`, not a copy. With no displayed tab the view is
    /// empty and writes are dropped.
    private var cardResults: [CardResult] {
        get { lastActiveTabId.map { session.resultStore[$0].results } ?? [] }
        set { if let id = lastActiveTabId { session.resultStore[id].results = newValue } }
    }

    /// The card whose results the results area shows, in the displayed editor
    /// tab. A result's id is its card's id, so this also names the result.
    private var displayedCardId: String? {
        get { lastActiveTabId.flatMap { id in session.tabs.first { $0.id == id }?.document.displayedCardId } }
        set {
            guard let id = lastActiveTabId else { return }
            session.updateTab(id: id) { $0.document.displayedCardId = newValue }
        }
    }

    /// Each editor tab's runs, one at a time: every card of a tab runs on the
    /// tab's connection in turn (`CardRunQueue`).
    private var runQueues: [String: CardRunQueue] = [:]
    /// The tab and the card-model ticket of each job that is running.
    private var runningJobs: [String: (tabId: String, ticket: CardRunTicket?)] = [:]
    /// Tabs already told that their cards run on shared connections.
    private var poolRouteNoticeTabs: Set<String> = []

    /// The activity donated for the active tab's workspace, held so it stays
    /// current until the next tab switch replaces it. `becomeCurrent()` does not
    /// retain it: dropping the reference ends the donation.
    private var workspaceActivity: NSUserActivity?


    // Toolbar UI elements (owned here, configured in setupActionBar)
    let statusLabel = NSTextField(labelWithString: "")
    let resultBannerLabel = NSTextField(labelWithString: "")
    let resetSortButton = NSButton()
    let resetFiltersButton = NSButton()
    let clearSelectionButton = NSButton()
    /// The result tools at the front of the action bar. Hidden as a group
    /// while the results area is hidden: a Grid|Chart switch or an export
    /// button for rows that are not on screen would be noise on what is then
    /// a status strip with the two area toggles.
    private let resultToolsStack = NSStackView()
    let tagButton = NSButton()
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

    /// The editor: tab bar, SQL editor, variables and result-tabs panels.
    private let editorPane: EditorPaneVC

    /// Owns the one live query-error sheet. Its `showSheet`/`closeSheet` seams
    /// are filled in `viewDidLoad`.
    private let errorPresenter = QueryErrorPresenter()

    /// This window's tabs, results and connection. Handed in at build time
    /// by `PharosSplitViewController`.
    let session: WindowSession
    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()
    /// Local key monitor so Esc clears an in-progress chart selection. A monitor is
    /// more reliable than the responder chain for a SwiftUI-hosted chart; the guards
    /// ensure it only consumes Esc while a selection is actually staged.
    private var escKeyMonitor: Any?
    private var hasSetInitialSplit = false


    /// Query IDs that the user has cancelled. Checked in the error handler to
    /// suppress the "Query failed" notification for user-initiated cancellations.
    private var cancelledQueryIds: Set<String> = []

    /// Query id of the "Load All Rows" snapshot whose progress the grid's bar
    /// is showing, or nil when no load is in flight. It is what the bar's
    /// Cancel cancels, and what a late progress call is checked against.
    private var snapshotQueryId: String?

    // Editor/results expand state
    /// Driven from `ContentPaneLayout` — the two toggles on the action bar.
    private(set) var expandState: ContentExpandState = .normal
    private var savedSplitRatio: CGFloat = 0.6
    /// Debounced UserDefaults write of `savedSplitRatio` during a divider drag.
    private var splitRatioPersistWork: DispatchWorkItem?

    private static let actionBarHeight: CGFloat = 32
    /// Divider limits for `editorResultsSplit`: the editor never goes below
    /// this, and the results grid keeps at least `minResultsGridHeight` under
    /// the action bar and the result tab bar.
    private static let minEditorHeight: CGFloat = 100
    private static let minResultsGridHeight: CGFloat = 60

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

    // MARK: - Init

    init(session: WindowSession) {
        self.session = session
        self.resultsVC = ResultsGridVC(session: session)
        self.editorPane = EditorPaneVC(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        // A plain root, NOT an `NSBackgroundExtensionView`.
        //
        // That class fills itself with a private hosting view that paints a
        // vertically FLIPPED, blurred copy of its content view. The real
        // content is pinned inside the safe area, so the only strip the copy
        // shows through is the one below the toolbar — and a flipped pane puts
        // its BOTTOM edge there. Measured 2026-09-22: the grid's horizontal
        // scroll bar appeared as a grey pill in the toolbar, at the knob's own
        // x-range, moving with it. The class is made for artwork whose edges
        // may be extended; this pane is chrome. Its last remaining job here was
        // that one strip, because the sidebar and inspector insets went off on
        // 2026-09-16 (design_requirements/HIG Implementation Plan 2026-09.md).
        // The strip now shows the standard window material, as Xcode's does.
        //
        // `container` still sits inside the safe area, so every child below
        // pins to `container`'s own edges.
        let root = NSView()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        // A plain NSView is accessibility-ignored by default and its identifier
        // would never surface — force it to be a real element.
        root.setAccessibilityElement(true)
        root.setAccessibilityIdentifier("pane.content")
        // The safe-area guide, not the view's own edges: the guide follows the
        // sidebar and inspector as they collapse and expand, so the content
        // grows into the space a hidden pane leaves.
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
        ])
        self.view = root

        editorPane.delegate = self
        addChild(editorPane)
        addChild(resultsVC)

        // Content stack: `editorResultsSplit` fills it. The split's top pane is
        // the editor; its bottom pane is `resultsArea`: actionBar (32pt) |
        // the results header | results grid / chart / plan.
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        editorResultsSplit.translatesAutoresizingMaskIntoConstraints = false
        editorResultsSplit.isVertical = false
        editorResultsSplit.delegate = self
        editorResultsSplit.onWillBeginDividerDrag = { [weak self] in
            self?.leaveExpandedStateForDividerDrag()
        }
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        resultsVC.view.translatesAutoresizingMaskIntoConstraints = false

        // The two arranged subviews are frame-managed by the split view; their
        // own children lay out against them with Auto Layout.
        editorPane.view.translatesAutoresizingMaskIntoConstraints = true
        resultsArea.translatesAutoresizingMaskIntoConstraints = true
        editorResultsSplit.addArrangedSubview(editorPane.view)
        editorResultsSplit.addArrangedSubview(resultsArea)
        // The results area, not the editor, absorbs a window resize. Both
        // priorities stay low and only RELATIVE — a high one blocks the drag
        // (tasks/lessons.md).
        editorResultsSplit.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        editorResultsSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        contentStack.addSubview(editorResultsSplit)

        errorBanner.translatesAutoresizingMaskIntoConstraints = false
        errorBanner.isHidden = true
        resultsArea.addSubview(errorBanner)
        pendingEditsBar.translatesAutoresizingMaskIntoConstraints = false
        pendingEditsBar.isHidden = true
        resultsArea.addSubview(pendingEditsBar)
        resultsArea.addSubview(actionBar)
        resultsArea.addSubview(cardResultsHeader)
        resultsArea.addSubview(resultsVC.view)

        // Chart host: sibling of the results grid, pinned to the same region,
        // hidden until the user switches a result tab to Chart mode.
        addChild(chartHost)
        chartHost.view.translatesAutoresizingMaskIntoConstraints = false
        chartHost.view.isHidden = true
        resultsArea.addSubview(chartHost.view)

        // Plan host: the same region again, shown only while the active result
        // tab holds an EXPLAIN plan.
        addChild(planHost)
        planHost.view.translatesAutoresizingMaskIntoConstraints = false
        planHost.view.isHidden = true
        resultsArea.addSubview(planHost.view)

        // The results header: hidden until a card's results are shown.
        cardResultsHeader.translatesAutoresizingMaskIntoConstraints = false
        cardResultsHeader.isHidden = true
        cardResultsHeader.onGoToCard = { [weak self] in
            guard let self, let id = self.displayedCardId else { return }
            self.editorPane.cardStack.scrollToCard(id)
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

        let safeTop = container.topAnchor

        errorBannerHeight = errorBanner.heightAnchor.constraint(equalToConstant: 0)
        pendingEditsBarHeight = pendingEditsBar.heightAnchor.constraint(equalToConstant: 0)
        cardResultsHeaderHeight = cardResultsHeader.heightAnchor.constraint(equalToConstant: 0)
        resultsBottomToContainer = resultsVC.view.bottomAnchor.constraint(equalTo: resultsArea.bottomAnchor)
            .yieldingBottom()

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: safeTop),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // The editor/results split fills the content stack. The split
            // view positions its two panes itself; the divider position is
            // driven by `applyExpandState` and by the user's drag.
            editorResultsSplit.topAnchor.constraint(equalTo: contentStack.topAnchor),
            editorResultsSplit.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            editorResultsSplit.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            editorResultsSplit.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),

            // Error banner: the very top of the results area, above the action
            // bar, taking no height at all until it has something to show.
            errorBanner.topAnchor.constraint(equalTo: resultsArea.topAnchor),
            errorBanner.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            errorBanner.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            errorBannerHeight,

            // Pending-edits bar: directly under the error banner, so a failed
            // run and a set of uncommitted edits can both be on screen.
            pendingEditsBar.topAnchor.constraint(equalTo: errorBanner.bottomAnchor),
            pendingEditsBar.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            pendingEditsBar.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            pendingEditsBarHeight,

            // Action bar: below the banners, full width, fixed height
            actionBar.topAnchor.constraint(equalTo: pendingEditsBar.bottomAnchor),
            actionBar.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: Self.actionBarHeight),

            // Results header: below the action bar, full width
            cardResultsHeader.topAnchor.constraint(equalTo: actionBar.bottomAnchor),
            cardResultsHeader.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            cardResultsHeader.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            cardResultsHeaderHeight,

            // Results: below the header, full width, fills remaining space
            resultsVC.view.topAnchor.constraint(equalTo: cardResultsHeader.bottomAnchor),
            resultsVC.view.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            resultsVC.view.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            resultsBottomToContainer,

            // Chart host occupies the same region as the results grid.
            chartHost.view.topAnchor.constraint(equalTo: cardResultsHeader.bottomAnchor),
            chartHost.view.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            chartHost.view.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            chartHost.view.bottomAnchor.constraint(equalTo: resultsArea.bottomAnchor).yieldingBottom(),

            // Plan host occupies the same region as the results grid.
            planHost.view.topAnchor.constraint(equalTo: cardResultsHeader.bottomAnchor),
            planHost.view.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            planHost.view.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            planHost.view.bottomAnchor.constraint(equalTo: resultsArea.bottomAnchor).yieldingBottom(),

            emptyState.topAnchor.constraint(equalTo: safeTop),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Wire up load more / load all
        resultsVC.onLoadMore = { [weak self] in
            self?.loadMoreRows()
        }
        resultsVC.onLoadAll = { [weak self] in
            self?.loadAllRowsSnapshot()
        }
        resultsVC.onCancelLoad = { [weak self] in
            guard let self, let id = self.snapshotQueryId else { return }
            self.cancelQuery(id: id)
        }

        // Inline cell editing: the grid owns the pending set, this owns the
        // bar that reports it and the sheet that applies it.
        resultsVC.onPendingEditsChanged = { [weak self] in
            self?.refreshPendingEditsBar()
        }
        pendingEditsBar.onReview = { [weak self] in
            self?.presentReviewRowChanges()
        }
        pendingEditsBar.onDiscard = { [weak self] in
            self?.confirmDiscardPendingEdits()
        }

        // Wire up selection changes for inspector. Drag-select fires this for
        // every cell the cursor crosses; the inspector rebuild only matters
        // for the settled selection, so debounce ~50ms to coalesce drag ticks
        // into a single update at rest.
        resultsVC.onSelectionChanged = { [weak self] selectedIndices in
            self?.scheduleInspectorUpdate(selectedIndices: selectedIndices)
        }

        resultsVC.onTagMapChanged = { [weak self] in
            guard let self,
                  let splitVC = self.parent as? PharosSplitViewController,
                  // The Inspector is SHARED: the schema browser and the SQL
                  // view write to it too, and `clear()` alone lands a blank
                  // map on every query. Without this test the refresh would
                  // replace a table's detail with "No Selection" and leave no
                  // trace of why.
                  splitVC.inspectorVC.isShowingRowDetail
            else { return }
            self.updateInspector(selectedIndices: self.lastInspectorIndices)
        }

        wireInspectorTagControls()

        // Wire up expand editor / results (handled by action bar buttons directly)

        // Observe state
        session.$activeConnectionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
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

        // Metadata load reacts to THIS window's connection's status only.
        // Combining activeConnectionId with the statuses dict and mapping down
        // to its status avoids the original problem (a removeDuplicates on
        // activeConnectionId alone would suppress the connected→ready
        // transition) while still firing only on real status changes. The
        // cache keeps one entry per connection, so a window that changes or
        // drops its connection clears nothing other windows use.
        Publishers.CombineLatest(session.$activeConnectionId, stateManager.$connectionStatuses)
            .map { activeId, statuses in
                ActiveConnectionStatus(id: activeId, status: activeId.flatMap { statuses[$0] })
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                if let id = snapshot.id, snapshot.status == .connected {
                    self.metadataCache.load(connectionId: id)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(session.$activeSchema, session.$activeConnectionId)
            .receive(on: RunLoop.main)
            .sink { [weak self] schema, connectionId in
                if let schema, let connectionId {
                    self?.metadataCache.prioritize(schema: schema, connectionId: connectionId)
                }
            }
            .store(in: &cancellables)

        // The tab sinks below subscribe to the SETTLED publishers and take no
        // run-loop hop: they run on the mutating caller's stack, after the
        // property is set, so `session.selectTab(...)` returns with the
        // grid and the editor already switched. See `AppStateManager.tabsSettled`.
        // Release the per-editor-tab result state of a tab that no longer
        // exists: an opened item installed over an untouched blank tab
        // (`WindowSession.install`) replaces it.
        //
        // Deduped on the id set so the sweep does not run on every keystroke
        // (tabs republish on each SQL edit). The sweep reads the live
        // `session.tabs`, which the settled publisher guarantees is
        // already the new value.
        session.tabsSettled
            .map { Set($0.map(\.id)) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.pruneRetiredEditorTabState() }
            .store(in: &cancellables)

        // Observe active tab changes to update results grid. `selectTab`
        // assigns `activeTabId` even when it does not change (a click on the
        // current tab), and the
        // publisher emits on every assignment — without the dedup each of
        // those tore the grid down and rebuilt it, dropping the cell selection.
        session.activeTabIdSettled
            .removeDuplicates()
            .sink { [weak self] tabId in self?.activeTabChanged(tabId) }
            .store(in: &cancellables)

        // A tab is bound to a workspace by its FIRST query, not by being
        // selected, so the activity donation has to follow that id as well as
        // the tab switch. `donateWorkspaceActivity` dedupes, so the two paths
        // overlapping costs nothing.
        Publishers.CombineLatest(session.tabsSettled, session.activeTabIdSettled)
            .map { tabs, activeId -> String? in tabs.first { $0.id == activeId }?.workspaceId }
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.donateWorkspaceActivity(for: self.session.activeTab)
            }
            .store(in: &cancellables)

        // Drive the action-bar pulse from the active tab's executing state. We
        // map down to the single Bool we actually care about and
        // removeDuplicates so unrelated mutations (any keystroke republishes
        // the tabs) don't reassign isPulsing every time.
        Publishers.CombineLatest(session.tabsSettled, session.activeTabIdSettled)
        .map { tabs, activeTabId -> Bool in
            tabs.first { $0.id == activeTabId }?.isExecuting == true
        }
        .removeDuplicates()
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

        errorPresenter.showCancelledDialog = { [weak self] in
            self?.stateManager.settings.query.showCancelledQueryDialog ?? false
        }
        errorPresenter.failureAlertStyle = { [weak self] in
            self?.stateManager.settings.query.failureAlertStyle ?? .sheet
        }
        errorPresenter.errorSheetTrigger = { [weak self] in
            self?.stateManager.settings.query.errorSheetTrigger ?? .secondFailure
        }
        // The Notification style of Settings ▸ Query ▸ Errors. The same
        // system banner `announceFailure` posts for a background tab, asked
        // for here because the user chose it instead of the sheet.
        errorPresenter.postNotification = { failure in
            QueryNotifier.shared.notifyQueryFailed(
                failureId: failure.id,
                tabId: failure.tabId,
                subheader: failure.subheader,
                message: failure.message,
                connectionName: failure.connectionName
            )
        }
        errorPresenter.showSheet = { [weak self] sheet in self?.presentAsSheet(sheet) }
        errorPresenter.closeSheet = { [weak self] sheet in self?.dismiss(sheet) }
        errorPresenter.showBanner = { [weak self] failure in self?.showErrorBanner(failure) }
        // The one place the error sheet learns about Apple Intelligence. The
        // sheet itself knows only the protocol, so nothing that compiles it
        // needs FoundationModels; the view hides itself when the model is
        // unavailable or the setting is off.
        QueryErrorSheet.explanationFactory = { ErrorExplanationView() }

        // A click on a failure banner (in-app or system) lands here.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateTabForFailure(_:)),
            name: QueryNotifier.activateTabNotification,
            object: nil
        )

        updateVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Restore saved split ratio once the content area has real height
        if !hasSetInitialSplit, editorResultsSplit.bounds.height > 0 {
            hasSetInitialSplit = true
            // Settings ▸ General ▸ Session. A stored 0 is not a ratio —
            // it is what `UserDefaults.double` returns for an absent key —
            // so the model's own default stands in for it.
            let stored = stateManager.settings.session.defaultEditorSplitRatio
            savedSplitRatio = CGFloat(stored > 0 ? stored : 0.6)
            applyExpandState()
        }
    }

    // MARK: - Active Tab Changed (results grid update)

    /// Drop the per-editor-tab result state of every tab that is no longer in
    /// `session.tabs`.
    ///
    /// Each stored `CardResult` holds a whole `QueryResult` — every fetched row
    /// plus the `RowIdentity` block — so without this a session that opens and
    /// closes query tabs holds the row data of every result those tabs ever
    /// produced until it quits.
    ///
    /// Nothing is lost. A result reaches SQLite when it runs
    /// (`captureExecutedResult` → `associateResult`), its chart config is
    /// written by `persistChartState`, and reopening the workspace rebuilds the
    /// result tabs from `PharosCore.loadWorkspace` +
    /// `getQueryHistoryResult` — never from the store. The order counter is
    /// likewise re-seeded from `MAX(result_order) + 1` on reopen, and tab ids
    /// are UUIDs, so a dropped key can never be asked for again.
    private func pruneRetiredEditorTabState() {
        session.resultStore.prune(keeping: Set(session.tabs.map { $0.id }))
    }

    private func activeTabChanged(_ tabId: String?) {
        // The sink is deduplicated; this guard covers any direct caller. A
        // same-tab pass would capture the grid into the tab and restore it
        // straight back, losing the cell selection on the way.
        if let tabId, tabId == lastActiveTabId { return }

        // Save grid state and result tabs of the tab we're leaving
        if let previousTabId = lastActiveTabId {
            // Tear down any active drill BEFORE capturing grid state (see
            // addResultTab / selectResultTab): switching editor tabs is another
            // outgoing path where the transient drill filter would otherwise leak
            // into the saved gridState and lose the manual filter it displaced.
            // This runs even for a retired tab: the drill is controller-wide
            // state that must be cleared before the incoming tab loads.
            tearDownDrill(restoreManual: true)

            // The tab we are leaving may be the one that was just CLOSED.
            // `closeTab` removes it from `tabs` (the prune sweep runs there,
            // synchronously) before it moves `activeTabId`, so by the time
            // this runs the sweep has dropped the tab's store entry. Writing
            // into `cardResults` now would re-create it — with every row of
            // every result the tab ever produced. A retired tab has nothing
            // left to restore into anyway. The guard also covers any mutator
            // that orders the two writes the other way round.
            if session.tabs.contains(where: { $0.id == previousTabId }) {
                if let activeRTId = displayedCardId,
                   let rtIdx = cardResults.firstIndex(where: { $0.id == activeRTId }) {
                    // Save grid state (and any live chart config) to the active
                    // result tab. `cardResults` still views the outgoing tab
                    // here — `lastActiveTabId` moves below.
                    cardResults[rtIdx].gridState = resultsVC.captureGridState()
                    captureChartConfig(intoTabAt: rtIdx)
                }
            }
        }
        lastActiveTabId = tabId

        guard let tabId, let tab = session.tabs.first(where: { $0.id == tabId }) else {
            donateWorkspaceActivity(for: nil)
            resultsVC.clear()
            refreshCardResultsUI()
            syncChartToggleToActiveTab()
            updateSplitViewVisibility()
            return
        }

        donateWorkspaceActivity(for: tab)
        updateSplitViewVisibility()
        loadResultState(for: tab)
    }

    /// Donate the active tab's workspace as an `NSUserActivity`, so it turns up
    /// in Spotlight and the app can be sent back to it.
    ///
    /// A tab has no workspace until its first query runs, so most switches
    /// invalidate rather than donate — that is correct, not a miss: there is
    /// nothing to come back to yet. Handoff is off: a workspace names a
    /// connection and a local history row, neither of which mean anything on
    /// another Mac.
    private func donateWorkspaceActivity(for tab: QueryTab?) {
        guard let tab, let workspaceId = tab.workspaceId else {
            workspaceActivity?.invalidate()
            workspaceActivity = nil
            return
        }
        guard workspaceActivity?.userInfo?[PharosActivity.workspaceIdKey] as? String != workspaceId else {
            return
        }
        workspaceActivity?.invalidate()
        let activity = NSUserActivity(activityType: PharosActivity.workspace)
        activity.title = tab.name
        activity.userInfo = [PharosActivity.workspaceIdKey: workspaceId]
        activity.requiredUserInfoKeys = [PharosActivity.workspaceIdKey]
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = true
        activity.becomeCurrent()
        workspaceActivity = activity
        Log.ui.info("Donated workspace activity \(workspaceId, privacy: .public)")
    }

    /// Bring the live result surface — `cardResults`, the grid, the gutter
    /// colours, the banner, the chart toggle — in line with what is stored
    /// for `tab`. The tail of `activeTabChanged`, and also called by the two
    /// paths that create a tab and then seed its stored results: with
    /// synchronous delivery the switch has already run by the time they seed,
    /// so they must apply the seed themselves.
    private func loadResultState(for tab: QueryTab) {
        // `cardResults` / `displayedCardId` already view this tab's store
        // entry: `lastActiveTabId` is `tab.id` by the time this runs.

        restoreGrid(for: tab)
        refreshCardResultsUI()

        // Update the result banner ("schema · executed-at"). When a CardResult
        // is active, its own timestamp / history fields drive the banner.
        // Otherwise the legacy inline-result path falls back to the editor
        // tab's stored execution time and schema.
        applyResultBanner(from: displayedResult)

        // Restore grid vs. chart view mode for the newly-active result tab.
        syncChartToggleToActiveTab()
    }

    /// Update the results grid banner from the currently displayed result tab.
    /// Shown for every result — fresh queries display when the query completed,
    /// history replays display the original execution time — so the user can
    /// always see at a glance how recent the visible result is.
    private func applyResultBanner(from resultTab: CardResult?) {
        guard let resultTab else {
            resultsVC.hideResultBanner()
            return
        }
        // History replays carry the original execution time as an ISO string;
        // fresh queries use the CardResult's own creation timestamp.
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
        let schema = resultTab.historySchema ?? session.activeTab?.schemaName
        resultsVC.showResultBanner(schema: schema, date: date)
    }

    // MARK: - Inspector

    /// Pending debounced inspector update; cancelled on each new selection
    /// tick so a fast cell-drag results in a single inspector rebuild at rest.
    private var pendingInspectorWorkItem: DispatchWorkItem?

    /// The last selection handed to `updateInspector` — recorded on entry, so
    /// it holds selections that the guards below then rejected as well as the
    /// ones that reached the pane. A tag-map change replays it to refresh the
    /// Tags section without waiting for a new selection tick; that replay
    /// tests what the Inspector currently SHOWS before it runs, because this
    /// value says nothing about that.
    private var lastInspectorIndices = IndexSet()

    private func scheduleInspectorUpdate(selectedIndices: IndexSet) {
        pendingInspectorWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateInspector(selectedIndices: selectedIndices)
        }
        pendingInspectorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func updateInspector(selectedIndices: IndexSet) {
        lastInspectorIndices = selectedIndices
        guard let splitVC = parent as? PharosSplitViewController else { return }

        if selectedIndices.isEmpty {
            // WITHDRAW, not blank: an empty grid selection is not always a
            // user act. Loading a new result set rebuilds the grid and clears
            // its selection, and a re-sort invalidates it — neither is grounds
            // to wipe a schema-browser table detail off the shared pane.
            splitVC.inspectorVC.withdraw(.results)
            return
        }

        if selectedIndices.count == 1 {
            let displayIndex = selectedIndices.first!
            guard displayIndex < resultsVC.displayRows.count else { return }
            let dataIndex = resultsVC.displayRows[displayIndex]
            guard dataIndex < resultsVC.rows.count else { return }
            let rowData = resultsVC.rows[dataIndex]
            let entries = TagInspectorModel.entries(
                matches: resultsVC.matchesByRow[dataIndex] ?? [],
                tags: TagStore.shared.tags,
                columns: resultsVC.columns,
                rowText: rowData.map { $0.stringValue })
            splitVC.inspectorVC.showRowDetail(
                columns: resultsVC.columns,
                row: rowData,
                rowNumber: displayIndex + 1,
                dataRow: dataIndex,
                totalRows: resultsVC.displayRows.count,
                columnCategories: resultsVC.columnCategories,
                tagEntries: entries
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

    /// Wires the Inspector's per-tag controls once, at setup. `addTagSection`
    /// reads these closures while it builds a row's buttons, so wiring them
    /// per selection would leave that ordering to chance.
    private func wireInspectorTagControls() {
        guard let inspectorVC = (parent as? PharosSplitViewController)?.inspectorVC else {
            // The buttons would simply never render. That is exactly the kind
            // of silent read-layer failure this phase keeps producing, so it
            // gets a line in the log rather than nothing at all.
            Log.ui.error("Inspector tag controls not wired: no split view controller parent yet.")
            return
        }
        inspectorVC.onEditTag = { [weak self] tagId in
            guard let self else { return }
            // The store can lose the tag between the repaint and the click.
            guard TagStore.shared.tag(id: tagId) != nil else {
                NSSound.beep()
                return
            }
            self.resultsVC.presentTagManageSheet(preselect: tagId)
        }
        inspectorVC.onDeleteTag = { [weak self] tagId in
            self?.confirmDeleteTag(id: tagId)
        }
    }

    /// The Inspector's per-tag "Remove Tag…": deletes the whole TAG after a
    /// count-bearing confirmation. Tuple-level removal is the removal sheet's
    /// job, reached from the grid.
    private func confirmDeleteTag(id: String) {
        guard let tag = TagStore.shared.tag(id: id), let window = view.window else {
            // Either the tag went away since this section was drawn, or there
            // is no window to hang the confirmation on. Both leave the click
            // with nothing to do, and silence would read as a dead button.
            NSSound.beep()
            return
        }
        let text = TagInspectorModel.deleteConfirmation(
            name: tag.name, ruleCount: tag.rules.count)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Tag")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // Cancel takes Return, not Delete. The delete is global and permanent
        // — ON DELETE CASCADE takes every tuple — so the habitual key must not
        // be the one that destroys a tag. The Tag Manager reaches the same end
        // by a different route: nothing it stages is destructive until Save,
        // and its footer states what a save would remove before the analyst
        // presses it.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do { try TagStore.shared.deleteTag(id: id) }
            catch {
                Log.ui.error("Tag delete failed: \(error.localizedDescription, privacy: .public)")
                // Deferred by a turn: this runs inside the confirmation
                // alert's completion handler, and AppKit tears a sheet down
                // ASYNCHRONOUSLY, so presenting in the same turn can be
                // dropped (tasks/lessons.md, 2026-08-06). Without the alert
                // the analyst confirms a destructive action, the tag stays on
                // screen, and nothing says why.
                DispatchQueue.main.async {
                    // `localizedDescription`, not interpolation: what reaches
                    // here is `PharosCoreError` from the FFI, and interpolating
                    // it prints `rustError("…")` — the Swift case, not the
                    // sentence the case carries. Escaped like every other
                    // failure surface, because the text can quote a tag name.
                    self?.presentTagError(
                        title: "Could not delete the tag",
                        message: DisplayEscape.escapedMultiline(error.localizedDescription))
                }
            }
        }
    }

    private func presentTagError(title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Action Bar Setup

    private func setupActionBar() {
        // Draw separator lines on top and bottom of action bar
        actionBar.drawsBottomSeparator = true
        actionBar.contentViewController = self

        // -- Status Labels (right-justified, order: history | row/time) --

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

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

        let labelStack = NSStackView(views: [resultBannerLabel, statusLabel])
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

        // No accent here: reset-sort and reset-filters mark an APPLIED state
        // the button undoes; a selection is not a state the grid is in.
        configureToolbarButtonAppearance(clearSelectionButton, symbol: "eraser", tooltip: "Clear Selection")
        clearSelectionButton.isHidden = true
        clearSelectionButton.target = resultsVC
        clearSelectionButton.action = #selector(ResultsGridVC.clearCellSelection)

        configureToolbarButtonAppearance(tagButton, symbol: "tag", tooltip: "Show tagged rows even when a filter hides them")
        tagButton.isHidden = true
        tagButton.target = resultsVC
        tagButton.action = #selector(ResultsGridVC.toggleForceShowTags)

        // -- Grid/Chart toggle (front of the action bar) --

        chartToggle.selectedSegment = 0
        // The same two lines the editor tab bar uses, so the two bars share one
        // idiom (and match the navigator capsule): a neutral lit segment, not
        // an accent-filled one that reads as a call to action.
        chartToggle.segmentStyle = .capsule
        chartToggle.selectedSegmentBezelColor = .controlColor
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

        let actionStack = resultToolsStack
        for view in [chartToggle, chartFilterButton, drillChip, exportButton, copyButton,
                     findToolbarButton, tagButton, resetSortButton, resetFiltersButton, clearSelectionButton] {
            actionStack.addArrangedSubview(view)
        }
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.setHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // -- Expand Buttons (right side) --

        // The two area toggles, as Xcode's debug-area button works: lit while
        // the area is on screen, pressed to hide it, pressed again to bring it
        // back. Tooltips and enabled state follow in `updateExpandButtonUI`.
        configureToolbarButton(expandEditorButton, symbol: "rectangle.tophalf.inset.filled",
                               target: self, action: #selector(expandEditorTapped), tooltip: "Hide Editor")
        configureToolbarButton(expandResultsButton, symbol: "rectangle.bottomhalf.inset.filled",
                               target: self, action: #selector(expandResultsTapped), tooltip: "Hide Results")
        expandEditorButton.setAccessibilityIdentifier("results.toggleEditor")
        expandResultsButton.setAccessibilityIdentifier("results.toggleResults")

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

    @objc private func expandEditorTapped() { toggleEditorArea() }
    @objc private func expandResultsTapped() { toggleResultsArea() }

    private func configureToolbarButton(_ button: NSButton, symbol: String, target: AnyObject, action: Selector, tooltip: String) {
        configureToolbarButtonAppearance(button, symbol: symbol, tooltip: tooltip)
        button.target = target
        button.action = action
    }

    static let toolbarSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    private func configureToolbarButtonAppearance(_ button: NSButton, symbol: String, tooltip: String) {
        let config = ContentViewController.toolbarSymbolConfiguration
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
        emptyState.show(
            symbol: "cylinder.split.1x2",
            title: String(localized: "No Connection"),
            message: String(localized: "Choose a connection for this tab to start."),
            actionTitle: String(localized: "Choose Connection…")
        ) { [weak self] in
            self?.chooseConnectionForActiveTab()
        }
    }

    /// The empty state's button. There is no way to drop the toolbar's
    /// connection pull-down from here, so it does the thing that pull-down
    /// would lead to: the first saved connection when there is one, and the
    /// Connections Manager when there is nothing to choose from yet.
    private func chooseConnectionForActiveTab() {
        guard let first = stateManager.connections.first, let tabId = session.activeTabId else {
            ConnectionsManagerWindowController.show()
            return
        }
        stateManager.useConnection(first.id, forTabId: tabId, in: session)
    }

    // MARK: - Visibility

    private func updateVisibility() {
        // Always show the editor — users can select a connection from the
        // toolbar's connection pull-down, and the editor is usable without one.
        // The "No Connection" empty state is therefore built and wired but never
        // shown: it covers the whole pane, so showing it would take the editor
        // away. It stays here for the day the pane gains a state with no editor
        // in it; until then this line is the whole of its show/hide rule.
        emptyState.isHidden = true

        let hasConnection: Bool
        if let activeId = session.activeConnectionId {
            let status = stateManager.status(for: activeId)
            hasConnection = (status == .connected)
        } else {
            hasConnection = false
        }

        if hasConnection {
            session.ensureTab()
        }

        // Always ensure at least one tab so the editor is usable
        session.ensureTab()

        updateSplitViewVisibility()
    }

    private func updateSplitViewVisibility() {
        // Content stack is always visible — editor is usable without a connection.
        contentStack.isHidden = false
    }

    // MARK: - Editor / Results area toggles

    private var paneLayout: ContentPaneLayout { ContentPaneLayout(expandState) }

    /// The Editor toggle: hides the editor area, or brings it back. A no-op
    /// while the editor is the only area on screen (its button is disabled).
    func toggleEditorArea() { apply(layout: paneLayout.togglingEditor()) }

    /// The Results toggle: hides the results area, or brings it back. A no-op
    /// while the results are the only area on screen.
    func toggleResultsArea() { apply(layout: paneLayout.togglingResults()) }

    private func apply(layout: ContentPaneLayout) {
        let newState = layout.expandState
        guard newState != expandState else { return }
        if expandState == .normal { rememberSplitRatio() }
        expandState = newState
        applyExpandState()
    }

    /// Height of the results area's fixed chrome: the action bar plus the
    /// results header when it is shown. The grid sits below both.
    private var resultsAreaChromeHeight: CGFloat {
        Self.actionBarHeight + cardResultsHeaderHeight.constant
            + errorBannerHeight.constant + pendingEditsBarHeight.constant
    }

    /// The editor's share of the split, as the split view has it now.
    private func rememberSplitRatio() {
        let total = editorResultsSplit.bounds.height
        guard total > 0, !editorPane.view.isHidden else { return }
        savedSplitRatio = editorPane.view.frame.height / total
    }

    private func applyExpandState() {
        let total = editorResultsSplit.bounds.height
        guard total > 0 else { return }

        switch expandState {
        case .normal:
            // A hidden arranged subview is a collapsed one; un-hide first so
            // the divider has a pane to move.
            editorPane.view.isHidden = false
            let editorHeight = min(total - resultsAreaChromeHeight - Self.minResultsGridHeight,
                                   max(Self.minEditorHeight, total * savedSplitRatio))
            editorResultsSplit.setPosition(editorHeight, ofDividerAt: 0)

        case .editorExpanded:
            // The results area keeps only its chrome — the action bar, which
            // holds the two toggles and the status text — and sits flush with
            // the bottom edge at exactly that height. The grid, chart and plan
            // views are hidden below it; their bottom constraints yield (see
            // `yieldingBottom`) so a hidden view's own minimum cannot push the
            // pane taller than the bar (measured: 48pt instead of 32, the bar
            // floating 16pt above the window's edge).
            editorPane.view.isHidden = false
            editorResultsSplit.setPosition(total - resultsAreaChromeHeight, ofDividerAt: 0)

        case .resultsExpanded:
            // Collapse the editor; the results area fills the split.
            editorPane.view.isHidden = true
        }
        editorResultsSplit.adjustSubviews()
        // Show grid vs. chart per the active result tab's mode + expand state.
        applyResultAreaVisibility()

        updateExpandButtonUI()
        persistSplitRatio()
        editorResultsSplit.layoutSubtreeIfNeeded()
    }

    /// A mouse-down on the action bar in an expanded state. Restore the
    /// normal layout at the saved ratio. In both expanded states the bar
    /// sits inside the divider's min or max zone, so no restore can leave it
    /// under the cursor for the drag to continue (tried and measured); the
    /// click restores, the next drag resizes.
    private func leaveExpandedStateForDividerDrag() {
        guard expandState != .normal else { return }
        let previousState = expandState
        expandState = .normal
        applyExpandState()
        if Haptics.shouldTap(from: previousState, to: expandState, normal: .normal) {
            Haptics.alignment()
        }
    }

    private func updateExpandButtonUI() {
        let layout = paneLayout
        // Lit while its area is on screen; disabled while its area is the
        // only one, so the pane can never be emptied.
        expandEditorButton.contentTintColor = layout.editorVisible ? .controlAccentColor : .secondaryLabelColor
        expandEditorButton.isEnabled = layout.editorToggleEnabled
        expandEditorButton.toolTip = layout.editorTooltip
        expandEditorButton.setAccessibilityLabel(layout.editorTooltip)
        expandResultsButton.contentTintColor = layout.resultsVisible ? .controlAccentColor : .secondaryLabelColor
        expandResultsButton.isEnabled = layout.resultsToggleEnabled
        expandResultsButton.toolTip = layout.resultsTooltip
        expandResultsButton.setAccessibilityLabel(layout.resultsTooltip)
        // With the results hidden the bar is a status strip with two toggles;
        // the result tools come back with the results.
        resultToolsStack.isHidden = !layout.resultsVisible
    }

    private func persistSplitRatio() {
        guard expandState == .normal else { return }
        // Rounded to three decimals: the divider reports a new fraction on
        // every frame of a drag, and an unrounded value would write — and
        // republish — the settings on each of them.
        let rounded = (Double(savedSplitRatio) * 1000).rounded() / 1000
        guard rounded > 0, rounded < 1 else { return }
        var updated = stateManager.settings
        guard updated.session.defaultEditorSplitRatio != rounded else { return }
        updated.session.defaultEditorSplitRatio = rounded
        stateManager.saveSettings(updated)
    }

    // MARK: - Rename Tab

    private func renameTab(id: String) {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab:"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = AuthoredLabelTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = AuthoredLabelSanitizer.sanitized(tab.name)
        alert.accessoryView = textField

        guard let window = view.window else { return }
        // Focus the field and select its text so the user can type a new name immediately.
        alert.window.initialFirstResponder = textField
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
                if !newName.isEmpty {
                    self?.session.updateTab(id: id) { $0.name = newName }
                }
            }
        }
        // Started after the sheet is up, so the dialog appears at once with the
        // name it has always shown.
        suggestName(into: textField, of: alert, sql: tab.document.cards.map(\.sql).joined(separator: ";\n"), kind: .editorTab)
    }

    // MARK: - Suggested names

    /// Fill a rename dialog's field with a suggested name, if the user has not
    /// started typing by the time it arrives.
    ///
    /// The two rename dialogs are `NSAlert`s, and an alert's accessory view is
    /// live while the sheet is up — they are opened with `beginSheetModal`, so
    /// the main run loop is not blocked and the continuation below is
    /// delivered. `runModal` would starve it.
    private func suggestName(
        into field: NSTextField,
        of alert: NSAlert,
        sql: String,
        kind: NameSuggestion.Kind
    ) {
        // The same switch as the Save Query sheet: both fill a name field the
        // user is looking at and about to accept or overwrite.
        guard ModelAvailability.shared.isAvailable(for: .suggestSavedQueryNames) else { return }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // The text on screen now. A suggestion only replaces THIS — anything
        // else in the field is the user's own typing.
        let untouched = field.stringValue
        field.toolTip = String(localized: "Name suggested by Apple Intelligence")

        Task { [weak alert] in
            do {
                let suggestion = try await NameSuggester().suggest(
                    sql: sql, existingFolders: [], kind: kind)
                guard let alert, alert.window.isVisible,
                      !suggestion.title.isEmpty,
                      field.stringValue == untouched else {
                    field.toolTip = nil
                    return
                }
                field.stringValue = suggestion.title
                field.selectText(nil)
            } catch {
                field.toolTip = nil
                Log.intelligence.error(
                    "Name suggestion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Give an editor tab a name from its SQL the first time it runs anything.
    ///
    /// Only a tab still carrying its generated "Query <n>" is touched, and it is
    /// checked twice — once here and once when the answer lands — so a name the
    /// user typed while the model was thinking always wins. A tab restored from
    /// a session arrives with the name it was saved under, which is not
    /// "Query <n>" once it has been suggested, so restoring never re-names.
    private func suggestEditorTabNameIfAutomatic(forEditorTab tabId: String, sql: String) {
        guard ModelAvailability.shared.isAvailable(for: .nameTabsAutomatically) else { return }
        guard let tab = session.tabs.first(where: { $0.id == tabId }),
              !AppStateManager.isCustomTabName(tab.name),
              !nameSuggestionAsked.contains(tabId) else { return }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Asked once per tab, even if the answer never comes: a tab whose
        // second query lands while the first suggestion is in flight must not
        // open a second session for the same name.
        nameSuggestionAsked.insert(tabId)

        Task { [weak self] in
            do {
                let suggestion = try await NameSuggester().suggest(
                    sql: sql, existingFolders: [], kind: .editorTab)
                guard let self, !suggestion.title.isEmpty else { return }
                guard let current = self.session.tabs.first(where: { $0.id == tabId }),
                      !AppStateManager.isCustomTabName(current.name) else { return }
                self.session.updateTab(id: tabId) {
                    $0.name = suggestion.title
                    // Still an automatic name, so the session records it as
                    // one: the user has not named this tab, the model has.
                    $0.nameIsSuggested = true
                }
            } catch {
                Log.intelligence.error(
                    "Tab name suggestion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Give a card a name from its SQL the first time it runs, as tabs get
    /// one. Only a card with no name is touched, checked again when the answer
    /// lands, so a name the user typed meanwhile always wins. The name goes to
    /// every version of the card.
    private func suggestCardNameIfAutomatic(cardId: String, inTab tabId: String, sql: String) {
        guard ModelAvailability.shared.isAvailable(for: .nameTabsAutomatically) else { return }
        guard let card = session.tabs.first(where: { $0.id == tabId })?.document.card(cardId),
              card.name == nil, card.kind == .sql,
              !nameSuggestionAsked.contains(card.lineageId),
              !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        nameSuggestionAsked.insert(card.lineageId)

        Task { [weak self] in
            do {
                let suggestion = try await NameSuggester().suggest(sql: sql, existingFolders: [], kind: .queryCard)
                guard let self, !suggestion.title.isEmpty else { return }
                var applied = false
                self.session.updateTab(id: tabId) {
                    applied = $0.document.applySuggestedName(suggestion.title, to: cardId)
                }
                if applied {
                    self.applyCardNameToHistory(cardId: cardId, inTab: tabId)
                    if self.editorPane.showsTab(tabId) { self.editorPane.refreshCards() }
                    self.updateResultsHeader()
                }
            } catch {
                Log.intelligence.error(
                    "Card name suggestion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Query Execution

    /// True when the active tab has a connected connection — the precondition
    /// `executeQuery` needs. Shared with menu validation so Run is greyed out
    /// for the same reason it would do nothing.
    var canRunQuery: Bool {
        guard let tab = session.activeTab, let connectionId = tab.connectionId else { return false }
        return stateManager.status(for: connectionId) == .connected
    }

    /// True when the active tab has a query in flight.
    var canCancelQuery: Bool {
        !(session.activeTab?.runningQueries.isEmpty ?? true)
    }

    // Connection predicates for the File menu and the toolbar pull-down.
    // All read the active tab's connection.
    var canConnect: Bool {
        guard let id = session.activeTab?.connectionId else { return false }
        let status = stateManager.status(for: id)
        return status == .disconnected || status == .error
    }

    var canDisconnect: Bool {
        guard let id = session.activeTab?.connectionId else { return false }
        let status = stateManager.status(for: id)
        return status == .connected || status == .connecting
    }

    var canRefreshMetadata: Bool {
        guard let id = session.activeTab?.connectionId else { return false }
        return stateManager.status(for: id) == .connected
    }

    /// ⌘↩: run the focused card. With Settings ▸ Query ▸ Run set to run a
    /// selection, a selection in the card runs as a new card below it.
    func executeQuery() {
        guard let tab = session.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else {
            // Say so. A silent return on ⌘↩ reads as a key the app did not receive.
            if isViewLoaded {
                Toast.show(in: view, message: "Connect to a database to run a query.", style: .warning)
            }
            return
        }
        guard let cardId = tab.document.focusedCardId ?? tab.document.cards.first?.id else { return }
        if stateManager.settings.query.runScope == .selectionElseStatement,
           let editor = editorPane.cardStack.focusedEditor, editor.documentId == cardId,
           let selected = editor.selectedSQL(),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           selected.trimmingCharacters(in: .whitespacesAndNewlines) != tab.document.card(cardId)?.sql.trimmingCharacters(in: .whitespacesAndNewlines) {
            runGeneratedCard(sql: selected, name: nil, inTab: tab.id, after: cardId)
            return
        }
        runCard(cardId, mode: .run, inTab: tab.id)
    }

    /// ⇧⌘↩: run the focused card and replace its results in place.
    func executeQueryReplacingResults() {
        guard let tab = session.activeTab, let cardId = tab.document.focusedCardId else { return }
        runCard(cardId, mode: .replace, inTab: tab.id)
    }

    /// Run every card of the active tab, top to bottom, one at a time. The
    /// first failure stops the rest (a failed transaction would make them
    /// fail anyway); a toast offers to continue.
    func runAllCards() {
        guard let tab = session.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else { return }
        let ids = tab.document.cards
            .filter { $0.kind == .sql && !$0.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
        runBatch(ids, inTab: tab.id)
    }

    private func runBatch(_ cardIds: [String], inTab tabId: String) {
        guard !cardIds.isEmpty else { return }
        var queue = runQueues[tabId] ?? CardRunQueue()
        let start = queue.enqueueBatch(cardIds: cardIds)
        runQueues[tabId] = queue
        editorPane.refreshCards()
        if let start { startJob(start, inTab: tabId) }
    }

    /// Queue a card's run on its tab. It starts at once when nothing else of
    /// the tab is running.
    func runCard(_ cardId: String, mode: CardRunMode, inTab tabId: String) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }),
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else {
            if isViewLoaded {
                Toast.show(in: view, message: "Connect to a database to run a query.", style: .warning)
            }
            return
        }
        var queue = runQueues[tabId] ?? CardRunQueue()
        let outcome = queue.enqueue(cardId: cardId, mode: mode)
        runQueues[tabId] = queue
        switch outcome {
        case .alreadyQueued:
            Toast.show(in: view, message: String(localized: "This card is already running."), style: .info, duration: 2.0)
        case .queued:
            editorPane.refreshCards()
        case let .startNow(job):
            startJob(job, inTab: tabId)
        }
    }

    /// Add a card holding SQL the user did not type in the card stack — a
    /// browse action, a drill-down, a selection — and run it. After
    /// `after`, or at the end.
    private func runGeneratedCard(sql: String, name: String?, inTab tabId: String, after: String? = nil) {
        var newId = ""
        session.updateTab(id: tabId) { tab in
            newId = tab.document.insertCard(after: after ?? tab.document.cards.last?.id, sql: sql, name: name)
        }
        if editorPane.showsTab(tabId) {
            editorPane.reloadCards(anchor: newId)
            editorPane.cardStack.scrollToCard(newId)
        }
        runCard(newId, mode: .run, inTab: tabId)
    }

    /// The job ended: tell the queue, and start what comes next.
    private func finishJob(_ jobId: String, inTab tabId: String, _ how: CardRunQueue.Finish) {
        runningJobs[jobId] = nil
        guard var queue = runQueues[tabId] else { return }
        let result = queue.finish(jobId: jobId, how)
        runQueues[tabId] = queue
        if !result.stoppedCardIds.isEmpty {
            let stopped = result.stoppedCardIds
            Toast.show(in: view, message: String(localized: "Run All stopped: \(CountedNounText.phrase(stopped.count, "card")) did not run."),
                       style: .warning, duration: 6.0) { [weak self] in
                self?.runBatch(stopped, inTab: tabId)
            }
        }
        if let next = result.next {
            startJob(next, inTab: tabId)
        }
        if editorPane.showsTab(tabId) { editorPane.refreshCards() }
    }

    /// Run a job of the tab's queue: check the card's variables and, for a
    /// destructive statement, ask; then send it.
    private func startJob(_ job: CardRunQueue.Job, inTab tabId: String) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }),
              let card = tab.document.card(job.cardId),
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else {
            finishJob(job.id, inTab: tabId, .failed)
            return
        }
        runningJobs[job.id] = (tabId, nil)

        let rendered = VariableSubstitutor.render(card.sql, with: QueryVariableStore.shared.variables)
        if !rendered.unresolved.isEmpty || !rendered.invalid.isEmpty {
            presentVariableError(unresolved: rendered.unresolved, invalid: rendered.invalid, tabId: tabId)
            finishJob(job.id, inTab: tabId, .failed)
            return
        }
        let sql = rendered.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty, let ticket = tab.document.beginRun(cardId: card.id, mode: job.mode, renderedSQL: sql) else {
            finishJob(job.id, inTab: tabId, .failed)
            return
        }

        // Editor-level destructive guard, mirroring the schema browser's.
        // Checked on the rendered SQL so variable values can't sneak past it.
        if stateManager.settings.query.confirmDestructive {
            // Which KINDS still ask is Settings ▸ Query ▸ Safety. Every kind
            // is on by default, so this filter changes nothing until the user
            // turns one off.
            let keywords = stateManager.settings.query.destructiveConfirmations
                .filtered(DestructiveSQLScanner.destructiveKeywords(in: sql))
            if !keywords.isEmpty {
                // On confirm, run the exact SQL the sheet displayed against the
                // captured tab/connection — never re-derive from the active tab,
                // which could have changed while the sheet was up.
                presentDestructiveQueryConfirmation(keywords: keywords, sql: sql, onConfirm: { [weak self] in
                    self?.sendCardRun(ticket, jobId: job.id, sql: sql, tabId: tabId, connectionId: connectionId)
                }, onCancel: { [weak self] in
                    self?.finishJob(job.id, inTab: tabId, .cancelled)
                })
                return
            }
        }
        sendCardRun(ticket, jobId: job.id, sql: sql, tabId: tabId, connectionId: connectionId)
    }

    /// Say once per tab that its cards run on shared connections (the server
    /// has its share of tab connections, or cannot hold one).
    private func noteRunRoute(_ route: CardRunRoute, tabId: String) {
        guard case let .pool(reason?) = route, !poolRouteNoticeTabs.contains(tabId) else { return }
        poolRouteNoticeTabs.insert(tabId)
        Toast.show(in: view, message: reason, style: .warning, duration: 6.0)
    }

    /// Send a card's rendered SQL and apply what comes back.
    private func sendCardRun(_ ticket: CardRunTicket, jobId: String, sql: String, tabId: String, connectionId: String) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }),
              stateManager.status(for: connectionId) == .connected else {
            finishJob(jobId, inTab: tabId, .failed)
            return
        }
        runningJobs[jobId] = (tabId, ticket)
        let queryId = jobId
        let cardName = tab.document.card(ticket.cardId)?.name ?? String(localized: "Untitled query")
        let runningQuery = RunningQuery(
            id: queryId, cardId: ticket.cardId, kind: .card, label: cardName,
            normalizedSQL: Self.normalizeSQL(sql), startTime: CACurrentMediaTime())
        session.updateTab(id: tabId) { $0.runningQueries.append(runningQuery) }
        if editorPane.showsTab(tabId) {
            editorPane.clearErrorMarkers(cardId: ticket.cardId)
            editorPane.refreshCards()
        }

        // Ensure this tab has a workspace history record (created lazily on first
        // execute) and snapshot its cards now. The produced result is associated
        // to it on completion.
        let workspaceId = ensureWorkspace(forEditorTabId: tabId)
        let tabSchema = tab.schemaName
        let limit = Int32(stateManager.settings.query.defaultLimit)
        let isSelectLike = Self.isSelectLikeSQL(sql)

        Task {
            // One interval per run, begun before the FFI call and ended on
            // every path out of it — success, failure and cancellation — so an
            // Instruments trace shows the whole cost of a run, not only the
            // runs that worked.
            let signpost = Log.signposter.beginInterval("execute", id: Log.signposter.makeSignpostID())
            defer { Log.signposter.endInterval("execute", signpost) }
            do {
                // The tab's own connection: SET, temp tables and transactions
                // carry from card to card. The pool only when the tab cannot
                // have one.
                let target = TabSessionTarget(sessionId: tabId, connectionId: connectionId, schema: tabSchema, queryId: queryId)
                if isSelectLike {
                    let outcome = try await CardExecutor.query(target: target, sql: sql, limit: limit)
                    let result = outcome.result
                    await MainActor.run {
                        self.noteRunRoute(outcome.route, tabId: tabId)
                        var cr = CardResult(cardId: ticket.cardId, runId: ticket.runId, sql: sql, rawSQL: ticket.rawSQL)
                        cr.queryResult = result
                        cr.executionTimeMs = result.executionTimeMs
                        cr.totalRowCountHint = result.rowCount
                        cr.historyResultId = result.historyEntryId
                        self.completeCardRun(
                            ticket, jobId: jobId, tabId: tabId, workspaceId: workspaceId, result: cr,
                            summary: .rows(count: result.rowCount, hasMore: result.hasMore))
                        self.fireCompletionNotification(
                            tabId: tabId, connectionId: connectionId,
                            outcome: .select(rowCount: result.rowCount), durationMs: result.executionTimeMs)
                    }
                } else {
                    let outcome = try await CardExecutor.statement(target: target, sql: sql)
                    let result = outcome.result
                    await MainActor.run {
                        self.noteRunRoute(outcome.route, tabId: tabId)
                        var cr = CardResult(cardId: ticket.cardId, runId: ticket.runId, sql: sql, rawSQL: ticket.rawSQL)
                        cr.executeResult = result
                        cr.executionTimeMs = result.executionTimeMs
                        cr.historyResultId = result.historyEntryId
                        self.completeCardRun(
                            ticket, jobId: jobId, tabId: tabId, workspaceId: workspaceId, result: cr,
                            summary: .affected(Int(result.rowsAffected)))
                        self.fireCompletionNotification(
                            tabId: tabId, connectionId: connectionId,
                            outcome: .statement(rowsAffected: Int(result.rowsAffected)), durationMs: result.executionTimeMs)
                    }
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    // Read the cancel flag once. It says whether the user asked
                    // for this, which decides the sheet title and keeps a
                    // cancellation quiet.
                    let wasCancelled = self.cancelledQueryIds.remove(queryId) != nil
                    self.session.updateTab(id: tabId) { tab in
                        tab.runningQueries.removeAll { $0.id == queryId }
                    }
                    let failure = QueryFailure(
                        id: queryId,
                        sql: sql,
                        message: message,
                        kind: wasCancelled ? .cancelled : .error,
                        tabId: tabId,
                        tabName: self.session.tabs.first { $0.id == tabId }?.name ?? "Query",
                        connectionName: self.stateManager.connections.first { $0.id == connectionId }?.name,
                        timestamp: Date(),
                        rawSQL: ticket.rawSQL,
                        cardId: ticket.cardId
                    )
                    // A failed or cancelled run never locks the card: the next
                    // run tries again in place.
                    self.session.updateTab(id: tabId) { tab in
                        _ = tab.document.completeRun(ticket, outcome: wasCancelled ? .cancelled : .failure(failureId: queryId))
                    }
                    if !wasCancelled { self.recordFailure(failure, connectionId: connectionId) }
                    self.finishJob(jobId, inTab: tabId, wasCancelled ? .cancelled : .failed)
                }
            }
        }
    }

    /// A card's run succeeded: let the card model decide which card the
    /// results belong to (the same card, or the new version an edit made),
    /// keep them there, and show them.
    private func completeCardRun(
        _ ticket: CardRunTicket, jobId: String, tabId: String, workspaceId: String?,
        result: CardResult, summary: CardRunRecord.Summary
    ) {
        session.updateTab(id: tabId) { tab in
            tab.runningQueries.removeAll { $0.id == jobId }
        }
        cancelledQueryIds.remove(jobId)
        NotificationCoalescer.post(.queryHistoryDidChange)

        // A query can outlive its editor tab: `closeTab` asks the server to
        // cancel the in-flight queries, but a result already on the wire still
        // lands here. The result is in SQLite already; only the in-memory copy
        // is dropped.
        guard session.tabs.contains(where: { $0.id == tabId }) else {
            runningJobs[jobId] = nil
            return
        }

        var effect = CardRunEffect.dropped
        session.updateTab(id: tabId) { tab in
            effect = tab.document.completeRun(ticket, outcome: .success(
                summary: summary, finishedAt: Date(), executionTimeMs: result.executionTimeMs,
                historyResultId: result.historyResultId))
        }
        let ownerId: String
        switch effect {
        case let .replaced(cardId): ownerId = cardId
        case let .split(_, newCardId): ownerId = newCardId
        case .dropped, .failed, .cancelled:
            finishJob(jobId, inTab: tabId, .succeeded)
            return
        }
        // The result belongs to the card that owns it now.
        var owned = CardResult(cardId: ownerId, runId: result.runId, sql: result.sql, rawSQL: result.rawSQL, timestamp: result.timestamp)
        owned.queryResult = result.queryResult
        owned.executeResult = result.executeResult
        owned.executionTimeMs = result.executionTimeMs
        owned.totalRowCountHint = result.totalRowCountHint
        owned.historyResultId = result.historyResultId

        // Every successful run arrives here — foreground and background — so
        // this is the one place a tab's first run can be seen.
        suggestEditorTabNameIfAutomatic(forEditorTab: tabId, sql: result.sql)
        suggestCardNameIfAutomatic(cardId: ownerId, inTab: tabId, sql: result.rawSQL)

        if let wsId = workspaceId, let hid = result.historyResultId {
            captureExecutedResult(historyId: hid, editorTabId: tabId, workspaceId: wsId, cardId: ownerId)
        }
        depositResult(owned, forEditorTab: tabId)
        if editorPane.showsTab(tabId) {
            if case let .split(lockedId, _) = effect {
                editorPane.reloadCards(anchor: ownerId, splitFrom: lockedId)
            } else {
                editorPane.refreshCards()
            }
        }
        finishJob(jobId, inTab: tabId, .succeeded)
    }

    /// Surface an unresolved/invalid-variable error before a query runs, and
    /// bring the sidebar's Variables navigator forward so the user can correct
    /// it. Variables are app-wide (`QueryVariableStore`), so the fix is made
    /// there, not in the tab.
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
        (parent as? PharosSplitViewController)?.revealNavigator(.variables)
    }

    /// Confirmation sheet for destructive SQL run from the editor. Same style
    /// as the schema browser's truncate/drop guard.
    private func presentDestructiveQueryConfirmation(
        keywords: [String],
        sql: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let alert = NSAlert()
        alert.messageText = DestructiveConfirmationText.destructiveQueryTitle(keywords: keywords)
        // Rendered through the disclosing builder: the SQL here has variables
        // already substituted, so a hostile variable value could otherwise
        // make the preview read as a different statement than will run.
        alert.informativeText = DestructiveConfirmationText.destructiveQueryMessage(keywords: keywords, sql: sql)
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        // No window to present on → don't run: an unconfirmed destructive query
        // is worse than a query that silently doesn't fire (matches the schema
        // browser guard's behavior).
        guard let window = view.window else { onCancel(); return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            } else {
                onCancel()
            }
        }
    }

    // MARK: - Explain

    /// Explain the focused card and show its plan as a view of the card's
    /// results (Grid | Chart | Plan).
    ///
    /// Variables are substituted first, for the same reason the destructive
    /// guard checks rendered SQL: a variable value must not be able to change
    /// what is explained.
    ///
    /// A plan is NOT a run: it never locks the card or makes a version, it is
    /// never written to query history and never associated with the
    /// workspace, so it does not come back when a workspace is reopened. A
    /// plan is cheap to ask for again.
    func explainCurrentStatement(analyze: Bool) {
        guard let activeTab = session.activeTab,
              let connectionId = activeTab.connectionId,
              stateManager.status(for: connectionId) == .connected else {
            if isViewLoaded {
                Toast.show(in: view, message: String(localized: "Connect to a database to explain a query."), style: .warning)
            }
            return
        }
        guard let cardId = activeTab.document.focusedCardId,
              let card = activeTab.document.card(cardId), card.kind == .sql,
              !card.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let rendered = VariableSubstitutor.render(card.sql, with: QueryVariableStore.shared.variables)
        if !rendered.unresolved.isEmpty || !rendered.invalid.isEmpty {
            presentVariableError(unresolved: rendered.unresolved, invalid: rendered.invalid, tabId: activeTab.id)
            return
        }
        let sql = rendered.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        // EXPLAIN ANALYZE really runs the statement. The core wraps it in a
        // transaction it always rolls back, but that is a safety net and not a
        // licence: a rollback cannot undo a DROP's effect on a concurrent
        // session, nor the work a TRUNCATE did while the lock was held. So a
        // destructive statement is refused outright rather than confirmed.
        if analyze {
            // NOT filtered by Settings ▸ Query ▸ Safety. That setting chooses
            // which kinds raise a CONFIRMATION; this is a refusal, and a
            // refusal the user can switch off is not a safety rule.
            let keywords = DestructiveSQLScanner.destructiveKeywords(in: sql)
            if !keywords.isEmpty {
                presentExplainAnalyzeRefusal(keywords: keywords)
                return
            }
        }

        let tabId = activeTab.id
        let rawSQL = card.sql
        let tabSchema = activeTab.schemaName

        Task {
            do {
                // On the tab's own connection when it has one: the plan then
                // sees its temp tables and settings, and an open transaction
                // stays open (ANALYZE is undone to a savepoint).
                let json: String
                if let target = CardExecutor.auxTarget(tabId: tabId, connectionId: connectionId, schema: tabSchema) {
                    do {
                        let r = try await PharosCore.sessionExplain(target, sql: sql, analyze: analyze)
                        TabSessionMonitor.shared.record(r.session)
                        json = r.plan
                    } catch {
                        TabSessionMonitor.shared.refresh(tabId)
                        throw error
                    }
                } else {
                    json = try await PharosCore.explainQuery(connectionId: connectionId, sql: sql, analyze: analyze)
                }
                let plan = try QueryPlan(json: json)
                await MainActor.run {
                    guard self.session.tabs.contains(where: { $0.id == tabId }) else { return }
                    var result = self.session.resultStore[tabId].result(forCard: cardId)
                        ?? CardResult(cardId: cardId, sql: sql, rawSQL: rawSQL)
                    result.plan = plan
                    result.planJSON = json
                    result.planIsAnalyze = analyze
                    result.showsPlan = true
                    self.session.resultStore[tabId].deposit(result)
                    if self.session.activeTabId == tabId {
                        self.displayResults(ofCard: cardId)
                    }
                }
            } catch {
                await MainActor.run {
                    // A refused or failed EXPLAIN goes through the same failure
                    // channel as a failed run, so it lands in the error banner
                    // the user already watches rather than a separate surface.
                    let failure = QueryFailure(
                        id: UUID().uuidString,
                        sql: sql,
                        message: error.localizedDescription,
                        kind: .error,
                        tabId: tabId,
                        tabName: self.session.tabs.first { $0.id == tabId }?.name ?? "Query",
                        connectionName: self.stateManager.connections.first { $0.id == connectionId }?.name,
                        timestamp: Date(),
                        rawSQL: rawSQL,
                        cardId: cardId
                    )
                    self.recordFailure(failure, connectionId: connectionId)
                }
            }
        }
    }

    private func presentExplainAnalyzeRefusal(keywords: [String]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Explain Analyze runs the statement.")
        alert.informativeText = String(localized: "Pharos does not run destructive statements under EXPLAIN ANALYZE. This statement contains \(keywords.joined(separator: ", ")). Use Explain Query for an estimated plan instead.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
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
        let tabName = session.tabs.first { $0.id == tabId }?.name ?? "Query"
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
        DurationText.clock(seconds: seconds)
    }

    // MARK: - Card Results

    /// Put a card's new result in its editor tab's store, apply the result
    /// limit, and show it when the tab is on screen (Settings: new results
    /// show automatically). A result for a background tab waits in the store.
    private func depositResult(_ result: CardResult, forEditorTab editorTabId: String) {
        guard session.tabs.contains(where: { $0.id == editorTabId }) else { return }
        let isForeground = editorTabId == session.activeTabId && lastActiveTabId == editorTabId
        let displayedHere = session.tabs.first { $0.id == editorTabId }?.document.displayedCardId
        if isForeground, displayedHere == result.id {
            // The grid is about to show the new rows of the same card: what
            // the user did to the old rows (widths, sort, filters) does not
            // carry over, but the drill bookkeeping must go first.
            tearDownDrill(restoreManual: true)
        }
        // The new rows replace the card's old result; its view state goes too,
        // apart from the chart setup, which belongs to the query, not the rows.
        var incoming = result
        if let old = session.resultStore[editorTabId].result(forCard: result.id) {
            incoming.chartConfig = old.chartConfig
            incoming.resultViewMode = old.resultViewMode
        }
        session.resultStore[editorTabId].deposit(incoming)
        evictResultsOverLimit(inTab: editorTabId, keeping: result.id)

        let follow = stateManager.settings.results.showNewResultsAutomatically
        if follow || displayedHere == nil || displayedHere == result.id {
            if isForeground {
                // The grid's state belongs to the rows it shows. When the card
                // on screen ran again, those rows are gone: nothing of theirs
                // is carried onto the new ones.
                displayResults(ofCard: result.id, captureOutgoing: displayedHere != result.id)
            } else {
                session.updateTab(id: editorTabId) { $0.document.displayedCardId = result.id }
            }
        } else if isForeground {
            refreshCardResultsUI()
        }
    }

    /// Show one card's results in the results area (View Results, a new run,
    /// a reopen). The card stays where it is in the stack; only the results
    /// area changes.
    func displayResults(ofCard cardId: String, captureOutgoing: Bool = true) {
        // Tear down any active drill BEFORE capturing grid state: otherwise the
        // transient drill filter leaks into the outgoing result's saved
        // gridState and the manual filter it displaced is lost.
        tearDownDrill(restoreManual: true)
        if captureOutgoing { captureOutgoingResultState() }

        displayedCardId = cardId
        markResultViewed(cardId)
        showDisplayedResult()
    }

    /// Save the grid state, pending edits and chart setup of the result on
    /// screen into its card's result, before the grid shows something else.
    private func captureOutgoingResultState() {
        guard let outgoingId = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == outgoingId }),
              cardResults[idx].hasPayload else { return }
        cardResults[idx].gridState = resultsVC.captureGridState()
        // Beside the grid state and for the same reason: the rows stay in
        // memory, so their uncommitted cell edits are still valid when the
        // user comes back to them.
        cardResults[idx].pendingEdits = resultsVC.pendingEdits
        captureChartConfig(intoTabAt: idx)
    }

    /// Put the displayed card's result on screen — grid, chart or plan — or
    /// clear the grid when the card has nothing in memory.
    private func showDisplayedResult() {
        if let r = displayedResult {
            if r.showsPlan, let plan = r.plan {
                planHost.show(plan: plan, json: r.planJSON ?? "", isAnalyze: r.planIsAnalyze)
            }
            if let result = r.queryResult {
                resultsVC.showResult(result)
            } else if let exec = r.executeResult {
                resultsVC.showExecuteResult(exec)
            } else {
                // A plan only, a restored "SQL only" result, or one the
                // limit let go: nothing of the last result may stay on screen.
                resultsVC.clear()
            }
            if r.hasPayload {
                if let gridState = r.gridState { resultsVC.restoreGridState(gridState) }
                restorePendingEdits(from: r)
            }
        } else {
            resultsVC.clear()
        }
        syncChartToggleToActiveTab()
        applyResultBanner(from: displayedResult)
        refreshCardResultsUI()
    }

    // MARK: - The result limit (Settings ▸ Results)

    /// Most results one editor tab keeps in memory. 0 is unlimited.
    private var resultLimit: Int {
        Int(AppStateManager.shared.settings.results.maximumResultTabs)
    }

    /// Let go of the oldest results nobody has looked at, until the tab is at
    /// the limit. The cards stay: they show "Results removed" and run again.
    private func evictResultsOverLimit(inTab tabId: String, keeping newId: String) {
        let held = session.resultStore[tabId].results.filter(\.hasPayload)
        let displayed = session.tabs.first { $0.id == tabId }?.document.displayedCardId
        let candidates = held.enumerated().map { order, r in
            CardResultEviction.Candidate(
                cardId: r.id, order: order, hasBeenViewed: r.hasBeenViewed || r.id == newId,
                isDisplayed: r.id == displayed)
        }
        let evicted = CardResultEviction.toEvict(candidates, limit: resultLimit)
        guard !evicted.isEmpty else { return }
        for id in evicted {
            session.resultStore[tabId].results.removeAll { $0.id == id }
        }
        session.updateTab(id: tabId) { tab in
            for id in evicted { if let i = tab.document.index(of: id) { tab.document.cards[i].resultsRemoved = true } }
        }
        let names = evicted.compactMap { id in session.tabs.first { $0.id == tabId }?.document.card(id)?.name }
        let message = evicted.count == 1
            ? String(localized: "Results of “\(names.first ?? String(localized: "Untitled query"))” were removed: the result limit was reached. Run the card again to get them back.")
            : String(localized: "Results of \(evicted.count) cards were removed: the result limit was reached.")
        Toast.show(in: view, message: message, style: .info)
    }

    /// Note that the user has seen this result, so the limit will not take it.
    private func markResultViewed(_ cardId: String) {
        _ = mutateResult(cardId: cardId) { $0.hasBeenViewed = true }
    }

    /// The card's menu ▸ Clear Results: let go of the rows. The card stays and
    /// can run again.
    func clearResults(ofCard cardId: String) {
        guard let tabId = session.resultStore.editorTabId(forCard: cardId) else { return }
        if displayedCardId == cardId { tearDownDrill(restoreManual: true) }
        session.resultStore[tabId].results.removeAll { $0.id == cardId }
        session.updateTab(id: tabId) { tab in
            if let i = tab.document.index(of: cardId), tab.document.cards[i].lastRun != nil {
                tab.document.cards[i].resultsRemoved = true
            }
        }
        if lastActiveTabId == tabId, displayedCardId == cardId { showDisplayedResult() } else { refreshCardResultsUI() }
    }

    /// One card's result, whichever editor tab holds it.
    private func result(forCard cardId: String) -> CardResult? {
        session.resultStore.result(forCard: cardId)
    }

    /// Apply a change to a card's result wherever it lives, and hand back the
    /// changed result.
    private func mutateResult(cardId: String, _ body: (inout CardResult) -> Void) -> CardResult? {
        session.resultStore.mutateResult(cardId: cardId, body)
    }

    /// Rename a card (and every version of its query). Clearing the name
    /// leaves the card untitled.
    private func renameCard(_ cardId: String) {
        guard let tab = session.activeTab, let card = tab.document.card(cardId), let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Card")
        alert.informativeText = String(localized: "Every version of this query takes the name. Leave the field empty for no name.")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = AuthoredLabelTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = AuthoredLabelSanitizer.sanitized(card.name ?? "")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let tabId = tab.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = AuthoredLabelSanitizer.sanitized(field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
            self.applyCardName(name.isEmpty ? nil : name, to: cardId, inTab: tabId)
        }
        suggestName(into: field, of: alert, sql: card.sql, kind: .queryCard)
    }

    /// Set (or clear) a card's name, and write it to the history rows of
    /// every version that has one, so Results History shows the name too.
    private func applyCardName(_ name: String?, to cardId: String, inTab tabId: String) {
        session.updateTab(id: tabId) { tab in
            tab.document.rename(cardId: cardId, name: name)
            tab.isDirty = true
        }
        refreshCardResultsUI()
        applyCardNameToHistory(cardId: cardId, inTab: tabId)
    }

    /// Write the card's current name to the history rows of every version
    /// that has one, so Results History shows it too.
    private func applyCardNameToHistory(cardId: String, inTab tabId: String) {
        guard let document = session.tabs.first(where: { $0.id == tabId })?.document,
              let lineage = document.card(cardId)?.lineageId else { return }
        let lineageCards = document.cards.filter { $0.lineageId == lineage }
        let name = lineageCards.first?.name
        for card in lineageCards {
            guard let historyResultId = session.resultStore[tabId].result(forCard: card.id)?.historyResultId
                    ?? card.lastRun?.historyResultId else { continue }
            do {
                // The empty string CLEARS the stored name; nil would mean "leave it
                // alone" (see the note on `updateResultMeta`).
                try PharosCore.updateResultMeta(resultId: historyResultId, customLabel: name ?? "")
            } catch {
                Log.query.error("updateResultMeta failed for result \(historyResultId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        NotificationCoalescer.post(.workspaceHistoryDidChange)
    }

    /// Refresh the results header and the cards' name rows.
    private func refreshCardResultsUI() {
        updateResultsHeader()
        editorPane.refreshCards()
    }

    /// Whose results are on screen, in the header above the grid.
    private func updateResultsHeader() {
        guard let tab = session.activeTab, lastActiveTabId == tab.id,
              let cardId = tab.document.displayedCardId,
              let card = tab.document.card(cardId) else {
            cardResultsHeader.isHidden = true
            cardResultsHeaderHeight.constant = 0
            return
        }
        let versions = tab.document.cards.filter { $0.lineageId == card.lineageId }.count
        cardResultsHeader.show(
            title: card.name ?? String(localized: "Untitled query"),
            versionChip: versions > 1 ? "v\(card.version)" : nil,
            meta: resultsMeta(for: card, result: tab.id == lastActiveTabId ? displayedResult : nil),
            color: CardPalette.color(card.colorIndex))
        cardResultsHeader.isHidden = false
        cardResultsHeaderHeight.constant = CardResultsHeaderView.height
    }

    /// "1,420 rows · 45 ms · ran 2 min ago", or why there are none.
    private func resultsMeta(for card: QueryCard, result: CardResult?) -> String {
        guard let result, result.hasPayload || result.plan != nil else {
            return card.lastRun != nil
                ? String(localized: "Results removed — run the card again")
                : String(localized: "Not run")
        }
        var parts: [String] = []
        if let run = card.lastRun, result.hasPayload {
            parts.append(CardPresentation.summaryText(run.summary))
            parts.append(DurationText.short(milliseconds: run.executionTimeMs))
            parts.append(String(localized: "ran \(Self.relativeTime(run.finishedAt))"))
        } else if result.hasPayload, let q = result.queryResult {
            parts.append(CardPresentation.summaryText(.rows(count: q.rowCount, hasMore: q.hasMore)))
        }
        if result.plan != nil && result.showsPlan {
            parts.append(result.planIsAnalyze ? String(localized: "plan, measured") : String(localized: "plan, estimated"))
        }
        if let run = card.lastRun, let tab = session.activeTab,
           tab.document.isEdited(cardId: card.id, renderedSQL: VariableSubstitutor.render(card.sql, with: QueryVariableStore.shared.variables).sql),
           result.hasPayload, !run.rawSQL.isEmpty {
            parts.append(String(localized: "from the SQL before the edit"))
        }
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relativeTime(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 30 { return String(localized: "just now") }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Load more rows for pagination.
    private func loadMoreRows() {
        guard let tab = session.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else { return }

        // The displayed result tab, its SQL, where to write the merged result
        // back, and whether it is still on screen at completion time.
        guard let activeRTId = displayedCardId,
              let rtIdx = cardResults.firstIndex(where: { $0.id == activeRTId }),
              let existingResult = cardResults[rtIdx].queryResult else { return }
        let querySQL = cardResults[rtIdx].sql
        // The page belongs to this run's rows. If the card runs again while the
        // page loads, the new rows are a different result and the page is
        // dropped.
        let runId = cardResults[rtIdx].runId
        // Through the store, so the page lands on its card's result even after
        // the user has switched editor tabs while it was loading.
        let applyMerged: (QueryResult) -> Void = { [weak self] merged in
            self?.session.resultStore.mutateResult(cardId: activeRTId) {
                if $0.runId == runId { $0.queryResult = merged }
            }
            self?.noteRowsLoaded(forCard: activeRTId, runId: runId, result: merged)
        }
        let isStillDisplaying: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.displayedCardId == activeRTId
                && self.displayedResult?.runId == runId
        }

        guard existingResult.hasMore else { return }

        let trimmedSQL = querySQL.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = Int64(existingResult.rows.count)
        let limit = Int64(stateManager.settings.query.defaultLimit)
        let tabSchema = tab.schemaName
        let tabId = tab.id

        resultsVC.setLoadingMore(true)

        Task {
            do {
                // The next page comes from the connection the card ran on:
                // the tab's own, which sees its temp tables and uncommitted rows.
                let moreResult: QueryResult
                if let target = CardExecutor.auxTarget(tabId: tabId, connectionId: connectionId, schema: tabSchema) {
                    do {
                        let r = try await PharosCore.sessionFetchMoreRows(target, sql: trimmedSQL, limit: limit, offset: offset)
                        TabSessionMonitor.shared.record(r.session)
                        moreResult = r.payload
                    } catch {
                        TabSessionMonitor.shared.refresh(tabId)
                        throw error
                    }
                } else {
                    moreResult = try await PharosCore.fetchMoreRows(
                        connectionId: connectionId,
                        sql: trimmedSQL,
                        limit: limit,
                        offset: offset,
                        schema: tabSchema
                    )
                }
                await MainActor.run {
                    let merged = QueryResult(
                        columns: existingResult.columns,
                        rows: existingResult.rows + moreResult.rows,
                        rowCount: existingResult.rows.count + moreResult.rows.count,
                        executionTimeMs: existingResult.executionTimeMs,
                        hasMore: moreResult.hasMore,
                        historyEntryId: existingResult.historyEntryId,
                        // Row keys are PER ROW, so a merge must concatenate them.
                        // Omitting this would take the nil default and drop every
                        // tag in the grid on the first Load More.
                        rowIdentity: existingResult.rowIdentity?.appendingPage(
                            moreResult.rowIdentity, pageRowCount: moreResult.rows.count)
                    )
                    applyMerged(merged)
                    // Only mutate the visible grid if the paginated result is still shown.
                    if isStillDisplaying() {
                        // Say so when the pages cannot be trusted to line up:
                        // without an outermost ORDER BY, PostgreSQL may return
                        // a different order for this second execution.
                        self.resultsVC.pagedWithoutOrderBy = !SQLOrderStability.hasTopLevelOrderBy(querySQL)
                        self.resultsVC.appendRows(from: moreResult)
                    } else {
                        self.resultsVC.setLoadingMore(false)
                    }
                }
            } catch {
                await MainActor.run {
                    self.resultsVC.setLoadingMore(false)
                    Log.query.error("Failed to load more rows: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Load More and Load All grow a card's result after its run. The card's
    /// name row and the results header show the run record's row count, so
    /// give the record the count the result holds now.
    private func noteRowsLoaded(forCard cardId: String, runId: String, result: QueryResult) {
        guard let tabId = session.resultStore.editorTabId(forCard: cardId) else { return }
        var changed = false
        session.updateTab(id: tabId) {
            changed = $0.document.rowsLoaded(cardId: cardId, runId: runId,
                                             count: result.rows.count, hasMore: result.hasMore)
        }
        guard changed else { return }
        if editorPane.showsTab(tabId) { editorPane.refreshCards() }
        if cardId == displayedCardId { updateResultsHeader() }
    }

    /// The result tab the grid is currently showing for the active editor tab,
    /// or nil when this editor tab's results still live in the legacy inline
    /// fields.
    private var displayedResult: CardResult? {
        displayedCardId.flatMap { id in cardResults.first { $0.id == id } }
    }

    /// Put the grid back on whatever the active editor tab owns.
    private func restoreGrid(for tab: QueryTab) {
        showDisplayedResult()
    }

    /// The card's Cancel: a waiting card leaves the queue, a running one is
    /// cancelled on the server.
    func cancelCard(_ cardId: String) {
        guard let tab = session.activeTab else { return }
        if var queue = runQueues[tab.id], queue.cancelWaiting(cardId: cardId) {
            runQueues[tab.id] = queue
            editorPane.refreshCards()
            return
        }
        for q in tab.runningQueries where q.cardId == cardId {
            cancelQuery(id: q.id)
        }
    }

    /// Menubar/keyboard Cancel: cancels the most recently started query in the
    /// active tab. For targeted cancellation by id (used by the popover), use
    /// `cancelQuery(id:)`.
    func cancelQuery() {
        guard let tab = session.activeTab,
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
        guard let tab = session.activeTab,
              let connectionId = tab.connectionId,
              tab.runningQueries.contains(where: { $0.id == id }) else { return }
        cancelledQueryIds.insert(id)
        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: id)
        }
    }

    /// Cancel every in-flight query in the active tab (Cancel All, ⌥⌘.).
    func cancelAllQueries() {
        guard let tab = session.activeTab else { return }
        if var queue = runQueues[tab.id] {
            _ = queue.cancelAll()
            runQueues[tab.id] = queue
        }
        for query in tab.runningQueries {
            cancelQuery(id: query.id)
        }
    }

    // MARK: - Workspace History Capture

    /// Ensure the given editor tab has a persisted workspace, refreshing its
    /// editor/variables snapshot, and return the workspace id. Assigns a new
    /// workspace id to the tab on first call. Returns nil if the tab has no
    /// connection (nothing to record yet).
    @discardableResult
    private func ensureWorkspace(forEditorTabId tabId: String) -> String? {
        guard let tab = session.tabs.first(where: { $0.id == tabId }), tab.connectionId != nil else { return nil }
        let wsId = tab.workspaceId ?? UUID().uuidString
        guard let payload = stateManager.workspaceUpsertPayload(for: tab, workspaceId: wsId) else { return tab.workspaceId }
        do {
            try PharosCore.upsertWorkspace(payload)
            if tab.workspaceId == nil {
                session.updateTab(id: tabId) { $0.workspaceId = wsId }
            }
            return wsId
        } catch {
            Log.query.error("upsertWorkspace failed: \(error.localizedDescription, privacy: .public)")
            return tab.workspaceId
        }
    }

    /// Associate a produced result (by its history id) with the editor tab's
    /// workspace, at the next order slot, with the card it belongs to.
    private func captureExecutedResult(historyId: String, editorTabId: String, workspaceId: String, cardId: String) {
        let order = session.resultStore[editorTabId].nextOrder
        // Same late-result case as `depositResult`: the association below still
        // belongs in the workspace, but the counter must not outlive the tab —
        // the store subscript would create an entry for a retired tab.
        if session.tabs.contains(where: { $0.id == editorTabId }) {
            session.resultStore[editorTabId].nextOrder = order + 1
        }
        let card = session.tabs.first { $0.id == editorTabId }?.document.card(cardId)
        do {
            try PharosCore.associateResult(.init(
                historyId: historyId, workspaceId: workspaceId,
                resultOrder: order, colorIndex: card?.colorIndex ?? (order % CardPalette.colors.count),
                rawSql: card?.lastRun?.rawSQL ?? card?.sql,
                lineStart: nil, lineEnd: nil,
                customLabel: card?.name,
                cardId: cardId, cardVersion: card?.version
            ))
            NotificationCoalescer.post(.workspaceHistoryDidChange)
        } catch {
            Log.query.error("associateResult failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bring this tab to the front: its window, selected in its tab group.
    func frontThisTab() {
        view.window?.makeKeyAndOrderFront(nil)
    }

    /// The window is closing (its tab with it): cards still waiting to run go
    /// too. The running ones are cancelled by `AppStateManager.retire`.
    func cancelQueuedRuns() {
        for tabId in Array(runQueues.keys) {
            if var queue = runQueues[tabId] { _ = queue.cancelAll() }
        }
        runQueues.removeAll()
    }

    // MARK: - Query Failures

    /// Push the log state of `tabId` to the editor. No effect when the editor
    /// shows a different tab — the state arrives later, through
    /// `didChangeActiveTab`.
    private func refreshErrorBadge(forTabId tabId: String) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }),
              editorPane.showsTab(tabId) else { return }
        editorPane.setErrorState(total: tab.failureLog.count, unread: tab.failureLog.unreadCount)
    }

    /// Record a failure on its tab, then decide what the user sees. The sheet and
    /// the editor marker are for the active tab only; a background tab gets the
    /// pulsing button.
    /// - Parameter connectionId: the connection the query ran on, when the
    ///   caller knows it. Passing it lets a failure that means the CONNECTION
    ///   is gone move that connection to Error — see
    ///   `AppStateManager.markConnectionLost`. Every failure path that has a
    ///   connection in scope should pass it; the classifier ignores the ones
    ///   that are merely a bad query.
    private func recordFailure(_ failure: QueryFailure, connectionId: String? = nil) {
        if let connectionId, failure.kind == .error {
            stateManager.markConnectionLost(id: connectionId, reason: failure.message)
        }

        // Query History, before anything is shown. This is the single funnel
        // every failure crosses, which is why the record is made here and not
        // at the half-dozen sites that build a QueryFailure.
        recordFailedQueryInHistory(failure, connectionId: connectionId)

        // Read BEFORE the append: the presenter's banner rule asks how many
        // unread failures the tab had before this one, and the append would
        // have already counted it.
        let unreadBefore = session.tabs.first { $0.id == failure.tabId }?.failureLog.unreadCount ?? 0
        session.updateTab(id: failure.tabId) { $0.failureLog.append(failure) }

        if session.activeTabId == failure.tabId {
            markEditor(with: failure, in: editorPane)
            let entries = session.tabs.first { $0.id == failure.tabId }?.failureLog.entries ?? []
            errorPresenter.failureDidArrive(
                failure, entries: entries, unreadBefore: unreadBefore, delegate: self
            )
        }

        // Always, not only for a background tab: a sheet that opens behind another
        // app is a sheet the user cannot see, and that case needs the banner most.
        // `QueryFailureChannel` returns `.none` for the one case that needs
        // nothing — the active tab with Pharos in front, where the sheet is
        // already on screen.
        announceFailure(failure)

        refreshErrorBadge(forTabId: failure.tabId)
    }

    /// Put a failed run in Query History, when it is one worth keeping.
    ///
    /// Two gates, and they are not the same gate:
    ///
    /// 1. Settings ▸ Library & History ▸ **Record failed queries** — the
    ///    user's answer to whether they want failures at all.
    /// 2. `HistoryFailureFilter.shouldRecord` — whether THIS failure is one a
    ///    history can be asked about. A server's answer is; a refusal that
    ///    never left this Mac ("connect to a database first") is not, and a
    ///    history full of those buries the real failures.
    ///
    /// The connection is needed to name the row, so a failure with no
    /// connection in scope — and none on its tab either — is not recorded.
    /// That is the same class of failure gate 2 already drops.
    private func recordFailedQueryInHistory(_ failure: QueryFailure, connectionId: String?) {
        guard stateManager.settings.history.recordFailedQueries else { return }
        guard HistoryFailureFilter.shouldRecord(failure.message) else { return }

        let tab = session.tabs.first { $0.id == failure.tabId }
        guard let connectionId = connectionId ?? tab?.connectionId else { return }

        let record = PharosCore.FailedQueryRecord(
            connectionId: connectionId,
            sql: failure.sql,
            rawSql: failure.rawSQL,
            message: failure.message,
            status: failure.kind == .cancelled
                ? QueryHistoryStatus.cancelled
                : QueryHistoryStatus.error,
            schema: tab?.schemaName,
            // The workspace and the card are two things the core cannot
            // know; both are nil for a run that has neither, and the row is
            // still recorded.
            workspaceId: tab?.workspaceId,
            executionTimeMs: 0,
            cardId: failure.cardId
        )

        // Off the main thread: this is SQLite IO on the way out of a failure,
        // and the user is already looking at a sheet.
        Task.detached(priority: .utility) {
            do {
                _ = try PharosCore.recordFailedQuery(record)
                await MainActor.run {
                    NotificationCoalescer.post(.queryHistoryDidChange)
                    NotificationCoalescer.post(.workspaceHistoryDidChange)
                }
            } catch {
                // A history row is never worth a second error on top of the
                // one the user is already reading.
                Log.query.error("Failed to record a failed query in history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Inline Error Banner

    /// Show the one-line banner for `failure`, in place of the sheet. Called by
    /// the presenter, which owns the rule about when that happens.
    private func showErrorBanner(_ failure: QueryFailure) {
        errorBanner.onGoToError = { [weak self] in
            guard let self, let failure = self.bannerFailure() else { return }
            self.hideErrorBanner()
            self.revealFailure(failure)
        }
        errorBanner.onDetails = { [weak self] in
            guard let self,
                  let tabId = self.errorBanner.tabId,
                  let failureId = self.errorBanner.failureId,
                  let log = self.session.tabs.first(where: { $0.id == tabId })?.failureLog,
                  let index = log.index(of: failureId) else { return }
            self.hideErrorBanner()
            self.errorPresenter.open(entries: log.entries, index: index, tabId: tabId, delegate: self)
        }
        errorBanner.onClose = { [weak self] in
            guard let self else { return }
            // Dismissing is reading it: the tab's error button stops pulsing,
            // and the next failure is then a first unread one again — so it
            // gets a banner too, instead of a sheet out of nowhere.
            if let tabId = self.errorBanner.tabId, let failureId = self.errorBanner.failureId {
                self.session.updateTab(id: tabId) { $0.failureLog.markRead(id: failureId) }
                self.refreshErrorBadge(forTabId: tabId)
            }
            self.hideErrorBanner()
        }

        errorBanner.show(failure)
        errorBannerHeight.constant = QueryErrorBanner.height
    }

    /// Take the banner off screen, whatever put it there.
    func hideErrorBanner() {
        guard !errorBanner.isHidden else { return }
        errorBanner.hide()
        errorBannerHeight.constant = 0
    }

    // MARK: - Pending Cell Edits

    /// Put the grid's pending set back on the grid after a `showResult`, which
    /// clears it. Only the tab-switch paths call this: the rows are the same
    /// rows, so the data-row keys still point where they did.
    private func restorePendingEdits(from tab: CardResult) {
        resultsVC.pendingEdits = tab.pendingEdits
        resultsVC.notifyPendingEditsChanged()
        resultsVC.tableView.reloadData()
    }

    /// Show, hide or update the bar from whatever the grid is holding. The one
    /// writer of the bar's height, so the two cannot disagree.
    private func refreshPendingEditsBar() {
        let count = resultsVC.pendingEdits.count
        guard count > 0 else {
            guard !pendingEditsBar.isHidden else { return }
            pendingEditsBar.hide()
            pendingEditsBarHeight.constant = 0
            return
        }
        pendingEditsBar.show(changeCount: count, tableDisplay: resultsVC.pendingEditsTableDisplay)
        pendingEditsBarHeight.constant = PendingEditsBar.height
    }

    /// "Discard" on the bar. Asked once, because there is no undo for it: the
    /// user's typing is the only copy of a pending edit.
    private func confirmDiscardPendingEdits() {
        let count = resultsVC.pendingEdits.count
        guard count > 0, let window = view.window else { return }
        let alert = NSAlert()
        // "change", not "pending change": the automatic inflector works on
        // ordinary English nouns, and a two-word one comes back as
        // "1 pending changes" — seen on the live app. The word "pending" is
        // on the bar and in the sentence below, where it needs no agreement.
        alert.messageText = String(localized: "Discard \(CountedNounText.phrase(count, "change"))?")
        alert.informativeText = String(localized: "The cells go back to the values the query returned. Nothing has been written to the database.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.resultsVC.discardPendingEdits()
        }
    }

    /// "Review Changes…" on the bar: the sheet with the exact statements.
    ///
    /// Shown whatever `confirmDestructive` says. It is not a confirmation — it
    /// is the only place this SQL is ever visible, because the user did not
    /// write it.
    private func presentReviewRowChanges() {
        guard let request = resultsVC.makeRowUpdateRequest() else {
            Toast.show(in: view, message: String(localized: "These changes can no longer be matched to rows. Discard them and try again."),
                       style: .warning, duration: 4.0)
            return
        }
        // No window means do not run — the same rule as
        // `presentDestructiveQueryConfirmation`. An unreviewed write is worse
        // than one that silently does not happen.
        guard view.window != nil else { return }
        let resultTabId = displayedCardId
        presentAsSheet(ReviewRowChangesSheet(request: request) { [weak self] in
            self?.applyRowUpdates(request, forCard: resultTabId)
        })
    }

    /// Send the request to the core and act on what comes back.
    ///
    /// On success the pending set is gone and the rows are re-read from the
    /// server, so what is on screen is what is in the table — not what the app
    /// believes it wrote. On failure the pending set is KEPT: the core rolls
    /// the whole transaction back, so nothing changed, and throwing the user's
    /// edits away on top of that would be a second loss.
    private func applyRowUpdates(_ request: RowUpdateRequest, forCard resultTabId: String?) {
        guard let tab = session.activeTab,
              let connectionId = tab.connectionId,
              stateManager.status(for: connectionId) == .connected else {
            Toast.show(in: view, message: String(localized: "Connect to a database to apply changes."),
                       style: .warning)
            return
        }
        let editorTabId = resultTabId.flatMap { session.resultStore.editorTabId(forCard: $0) } ?? tab.id
        Task {
            do {
                // On the tab's own connection when it has one: in its open
                // transaction the edit joins that transaction (saved at Commit)
                // instead of waiting on the rows the transaction has locked.
                let result: RowUpdateResult
                var joinedTransaction = false
                if let target = CardExecutor.auxTarget(tabId: editorTabId, connectionId: connectionId, schema: tab.schemaName) {
                    do {
                        let r = try await PharosCore.sessionApplyRowUpdates(target, request: request)
                        TabSessionMonitor.shared.record(r.session)
                        result = r.result
                        joinedTransaction = r.inTransaction
                    } catch {
                        TabSessionMonitor.shared.refresh(editorTabId)
                        throw error
                    }
                } else {
                    result = try await PharosCore.applyRowUpdates(connectionId: connectionId, request: request)
                }
                await MainActor.run {
                    Log.query.info("Applied row updates: \(result.rowsUpdated, privacy: .public) rows")
                    self.resultsVC.pendingEdits.removeAll()
                    self.resultsVC.notifyPendingEditsChanged()
                    if let resultTabId {
                        self.session.resultStore.mutateResult(cardId: resultTabId) { $0.pendingEdits.removeAll() }
                    }
                    // The core records the write in query history like any
                    // other statement, so the history list has to hear about it.
                    NotificationCoalescer.post(.queryHistoryDidChange)
                    let applied = String(localized: "Applied \(CountedNounText.phrase(result.rowsUpdated, "row")) in \(DurationText.short(milliseconds: result.executionTimeMs))")
                    Toast.show(in: self.view,
                               message: joinedTransaction
                                   ? applied + " " + String(localized: "They are saved when you commit the tab's transaction.")
                                   : applied,
                               style: .success)
                    self.reloadResultTabAfterEdit(resultTabId)
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    Log.query.error("Row update failed: \(message, privacy: .public)")
                    guard let window = self.view.window else {
                        Toast.show(in: self.view, message: message, style: .error, duration: 5.0)
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = String(localized: "The changes were not applied.")
                    // The core's own words. It names the 1-based row of the
                    // request that failed, which is what tells the user which
                    // of their edits to look at.
                    alert.informativeText = DisplayEscape.escaped(message)
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    /// Re-read the rows of the result tab an edit was applied to, so the grid
    /// shows what the server now holds — including anything a trigger or a
    /// default changed on the way in.
    private func reloadResultTabAfterEdit(_ resultTabId: String?) {
        guard let resultTabId,
              let editorTabId = session.resultStore.editorTabId(forCard: resultTabId),
              let editorTab = session.tabs.first(where: { $0.id == editorTabId }),
              let connectionId = editorTab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let rt = session.resultStore.result(forCard: resultTabId),
              let current = rt.queryResult else { return }
        let sql = rt.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        // At least as many rows as were on screen, so a grid the user had
        // paged out does not shrink back to one page under them.
        let limit = Int32(clamping: max(Int(stateManager.settings.query.defaultLimit), current.rows.count))
        let schema = editorTab.schemaName
        Task {
            // Re-read on the connection that wrote: in an open transaction only
            // the tab's own connection sees the new values.
            let refreshed: QueryResult
            if let target = CardExecutor.auxTarget(tabId: editorTabId, connectionId: connectionId, schema: schema) {
                guard let r = try? await PharosCore.sessionExecuteQuery(target, sql: sql, limit: limit, aux: true) else {
                    TabSessionMonitor.shared.refresh(editorTabId)
                    return
                }
                TabSessionMonitor.shared.record(r.session)
                refreshed = r.payload
            } else {
                guard let r = try? await PharosCore.executeQuery(
                    connectionId: connectionId, sql: sql, limit: limit, schema: schema,
                    source: "row-edit-refresh") else { return }
                refreshed = r
            }
            await MainActor.run {
                self.session.resultStore.mutateResult(cardId: resultTabId) { $0.queryResult = refreshed }
                guard self.displayedCardId == resultTabId else { return }
                // Keep the user's widths, sort and filters across the swap, the
                // way the Load All snapshot does.
                let gridState = self.resultsVC.captureGridState()
                self.resultsVC.showResult(refreshed)
                if let gridState { self.resultsVC.restoreGridState(gridState) }
            }
        }
    }

    /// Ask before something throws the pending set away, and say how many
    /// changes are at stake. `proceed` runs only on Discard.
    ///
    /// Cancel ABORTS the caller — a Load All that quietly discarded a set of
    /// edits would be indistinguishable from the app losing them.
    private func confirmDiscardingPendingEdits(forCard resultTabId: String,
                                               proceed: @escaping () -> Void) {
        let count = session.resultStore.result(forCard: resultTabId)?.pendingEdits.count ?? 0
        let liveCount = displayedCardId == resultTabId ? resultsVC.pendingEdits.count : count
        guard liveCount > 0, let window = view.window else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard \(CountedNounText.phrase(liveCount, "change"))?")
        alert.informativeText = String(localized: "Reloading this result replaces its rows, so the changes can no longer be matched to them.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.session.resultStore.mutateResult(cardId: resultTabId) { $0.pendingEdits.removeAll() }
            if self?.displayedCardId == resultTabId { self?.resultsVC.discardPendingEdits() }
            proceed()
        }
    }

    /// The log entry the banner is showing, looked up fresh — the copy the
    /// banner was given could have been removed from the log since.
    private func bannerFailure() -> QueryFailure? {
        guard let tabId = errorBanner.tabId, let failureId = errorBanner.failureId else { return nil }
        return session.tabs.first { $0.id == tabId }?.failureLog.entries.first { $0.id == failureId }
    }

    /// Put the gutter dot and the underline on the faulty text.
    ///
    /// The failure carries the substituted segment that ran, and its position
    /// counts into that segment — not into the document. `range(of:in:)` moves it,
    /// and gives nil when the move would be a guess (substitution changed the
    /// text, the user has edited, or the segment is in the document twice). Nil
    /// marks nothing: a red underline under innocent text is worse than none.
    private func markEditor(with failure: QueryFailure, in pane: EditorPaneVC) {
        guard let range = errorRange(of: failure) else { return }
        pane.markError(cardId: failure.cardId ?? "", range: range, message: failure.message)
    }

    /// Where the failure points in its card's text, or nil when that would be
    /// a guess (variables changed the text, or the card was edited since).
    private func errorRange(of failure: QueryFailure) -> NSRange? {
        guard let location = failure.location, let cardId = failure.cardId,
              let card = session.tabs.first(where: { $0.id == failure.tabId })?.document.card(cardId)
        else { return nil }
        return location.range(of: failure.sql, in: card.sql)
    }

    /// Temporary alert for a failure the user is not looking at. Nothing goes to
    /// Notification Center for longer than the banner: the tab's error button is
    /// the record.
    private func announceFailure(_ failure: QueryFailure) {
        // A cancellation is the user's own doing, so it never raises an alert.
        guard failure.kind == .error else { return }

        let channel = QueryFailureChannel.choose(
            appInactive: !NSApp.isActive,
            isBackgroundTab: (NSApp.delegate as? AppDelegate)?.isTabOutOfSight(failure.tabId) ?? false,
            notifyWhenAppInactive: stateManager.settings.query.notifyWhenAppInactive,
            notifyWhenBackgroundTab: stateManager.settings.query.notifyWhenBackgroundTab
        )

        switch channel {
        case .none:
            break
        case .inAppBanner:
            let short = failure.message.count > 120
                ? String(failure.message.prefix(120)) + "…" : failure.message
            Toast.show(
                in: view,
                message: "\(DisplayEscape.escaped(failure.tabName)) · \(DisplayEscape.escaped(short))",
                style: .error, duration: 4.0
            ) { [weak self] in
                self?.openFailure(tabId: failure.tabId, failureId: failure.id)
            }
        case .systemBanner:
            QueryNotifier.shared.notifyQueryFailed(
                failureId: failure.id,
                tabId: failure.tabId,
                subheader: failure.subheader,
                message: failure.message,
                connectionName: failure.connectionName
            )
        }
    }

    /// Open the sheet on one entry, after a banner click. Goes to the tab first.
    private func openFailure(tabId: String, failureId: String?) {
        frontThisTab()
        // `newestUnreadIndex` is nil for an empty log, so this one guard covers
        // both "no such tab" and "nothing to show".
        guard let log = session.tabs.first(where: { $0.id == tabId })?.failureLog,
              let fallback = log.newestUnreadIndex else { return }
        let index = failureId.flatMap { log.index(of: $0) } ?? fallback
        errorPresenter.open(entries: log.entries, index: index, tabId: tabId, delegate: self)
    }

    @objc private func handleActivateTabForFailure(_ notification: Notification) {
        guard let tabId = notification.userInfo?["tabId"] as? String,
              let failureId = notification.userInfo?["failureId"] as? String else { return }
        // The window that OWNS the failing tab answers, not every window.
        guard session.tabs.contains(where: { $0.id == tabId }) else { return }
        // AppDelegate's observer of the same notification also fronts the
        // tab's window. Both are idempotent, so the order does not matter.
        openFailure(tabId: tabId, failureId: failureId)
    }
}

// MARK: - EditorPaneDelegate

extension ContentViewController: EditorPaneDelegate {

    func editorPane(_ pane: EditorPaneVC, didChangeActiveTab tabId: String?) {
        // The banner belongs to the tab whose failure it shows, and the results
        // area below it is about to be another tab's. It goes, unread: the
        // incoming tab's error button still carries the entry, so nothing is
        // lost by not bringing it back.
        hideErrorBanner()

        // activeTabId publisher handles results grid update. The error badge
        // is refreshed here, after the editor has switched tabs, so it shows
        // the incoming tab's log.
        guard let tabId else {
            pane.setErrorState(total: 0, unread: 0)
            return
        }
        refreshErrorBadge(forTabId: tabId)
    }

    func editorPaneDidRequestShowErrors(_ pane: EditorPaneVC) {
        guard let tabId = session.activeTabId,
              let log = session.tabs.first(where: { $0.id == tabId })?.failureLog,
              let index = log.newestUnreadIndex else { return }
        errorPresenter.open(entries: log.entries, index: index, tabId: tabId, delegate: self)
    }

    func editorPane(_ pane: EditorPaneVC, didChooseConnection connectionId: String) {
        guard let tab = session.tab else { return }
        let tabId = tab.id
        let open = tabsWithOpenTransaction(among: [tabId])
        // Moving the tab to another connection closes its own connection,
        // rolling back an open transaction there: ask first.
        guard connectionId != tab.connectionId, !open.isEmpty else {
            stateManager.useConnection(connectionId, forTabId: tabId, in: session)
            return
        }
        confirmRollingBack(open, action: .switchConnection) { [weak self] proceed in
            guard let self, proceed else { return }
            Task { @MainActor in
                _ = await TabSessionMonitor.shared.close(tabId)
                self.stateManager.useConnection(connectionId, forTabId: tabId, in: self.session)
            }
        }
    }

    func editorPaneDidRequestConnect(_ pane: EditorPaneVC) {
        menuConnect(nil)
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

    func editorPane(_ pane: EditorPaneVC, didRequestRunCard cardId: String, mode: CardRunMode) {
        guard let tabId = session.activeTabId else { return }
        runCard(cardId, mode: mode, inTab: tabId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestViewResultsOfCard cardId: String) {
        guard let card = session.activeTab?.document.card(cardId) else { return }
        // A failed card's button reads "View Error": open its failure.
        if let failureId = card.lastFailureId,
           let tabId = session.activeTabId,
           let log = session.tabs.first(where: { $0.id == tabId })?.failureLog,
           let index = log.index(of: failureId) {
            errorPresenter.open(entries: log.entries, index: index, tabId: tabId, delegate: self)
            return
        }
        displayResults(ofCard: cardId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestCancelCard cardId: String) {
        cancelCard(cardId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestRenameCard cardId: String) {
        renameCard(cardId)
    }

    func editorPane(_ pane: EditorPaneVC, didRequestClearResultsOfCard cardId: String) {
        clearResults(ofCard: cardId)
    }

    func editorPane(_ pane: EditorPaneVC, didEditCard cardId: String) {
        // The header's "from the SQL before the edit" follows the typing.
        if cardId == displayedCardId { updateResultsHeader() }
    }

    func editorPane(_ pane: EditorPaneVC, statusOf card: QueryCard, inTab tabId: String) -> CardStackVC.CardStatus {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else { return CardStackVC.CardStatus() }
        var st = CardStackVC.CardStatus()
        if let running = tab.runningQueries.first(where: { $0.cardId == card.id && $0.kind == .card }) {
            st.activity = .running(startedAt: Date(timeIntervalSinceNow: -(CACurrentMediaTime() - running.startTime)))
        } else if runQueues[tabId]?.isWaiting(cardId: card.id) == true {
            st.activity = .waiting
        }
        let held = session.resultStore[tabId].result(forCard: card.id)
        st.resultInMemory = held?.hasPayload == true
        st.isDisplayed = tab.document.displayedCardId == card.id
        if card.lastRun != nil, card.kind == .sql {
            let rendered = VariableSubstitutor.render(card.sql, with: QueryVariableStore.shared.variables).sql
            st.isEdited = tab.document.isEdited(cardId: card.id, renderedSQL: rendered)
        }
        if card.lastFailureId != nil,
           let failure = tab.failureLog.entries.first(where: { $0.id == card.lastFailureId }) {
            st.meta = failure.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        } else if let run = card.lastRun {
            st.meta = "\(Self.relativeTime(run.finishedAt)) · \(DurationText.short(milliseconds: run.executionTimeMs))"
        }
        return st
    }

    func editorPane(_ pane: EditorPaneVC, didChooseVariable name: String) {
        (parent as? PharosSplitViewController)?.revealVariable(named: name)
    }
}

// MARK: - Open Saved Query

extension ContentViewController {

    /// A broadcast that makes or targets a TAB must land in exactly ONE window,
    /// or every open window answers it and the user gets N copies of the tab.
    ///
    /// `sessionId` in the userInfo names the window — that is how session
    /// restore aims each stored window's tabs. With none, the key window takes
    /// it, which is what the sidebar, the schema browser and a Spotlight or
    /// Handoff activity mean: the window the user is in.
    private func ownsBroadcast(_ notification: Notification) -> Bool {
        if let id = notification.userInfo?["sessionId"] as? String { return id == session.id }
        return AppStateManager.shared.keySession === session
    }

    // MARK: - Opening items into tabs

    /// The content controller of the tab, in any window, that `predicate`
    /// matches — brought to the front. Every tab is its own window, so "is it
    /// already open?" is a question about all of them.
    private func frontExistingTab(where predicate: (QueryTab) -> Bool) -> ContentViewController? {
        guard let found = AppStateManager.shared.findTab(where: predicate),
              let target = (NSApp.delegate as? AppDelegate)?.contentController(for: found.session) else { return nil }
        target.frontThisTab()
        return target
    }

    /// A new tab for an opened item, on this tab's connection and schema.
    private func newTab(name: String, document: CardDocument) -> QueryTab {
        QueryTab(name: name, connectionId: session.tab?.connectionId, schemaName: session.tab?.schemaName,
                 document: document)
    }

    /// Put `tab` where an opened item goes, and return the content controller
    /// that shows it. A broadcast that names this window (session restore,
    /// which built the window for this tab) fills this window's own tab;
    /// otherwise this tab when it is untouched, else a new tab beside it.
    private func open(_ tab: QueryTab, from notification: Notification) -> ContentViewController? {
        if notification.userInfo?["sessionId"] != nil {
            session.install(tab)
            return self
        }
        return (NSApp.delegate as? AppDelegate)?.openItem(tab).splitViewController.contentVC
    }

    @objc private func handleOpenSavedQuery(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        guard let query = notification.userInfo?["query"] as? SavedQuery else { return }
        // Settings ▸ Library & History ▸ On double-click, decided by the
        // sender. Absent means "just open", which every other sender wants.
        let run = notification.userInfo?["run"] as? Bool ?? false
        if let target = frontExistingTab(where: { $0.savedQueryId == query.id }) {
            if run { target.runSavedQuery() }
            return
        }
        // A saved query is a whole tab of cards.
        let document = CardPersistence.decode(json: query.cardsJson, text: query.sql).forReuse()
        var tab = newTab(name: query.name, document: document)
        tab.savedQueryId = query.id
        guard let target = open(tab, from: notification) else { return }
        if run { target.runSavedQuery() }
    }

    /// Run every card of a saved query's tab, top to bottom.
    ///
    /// Deferred one turn of the run loop, so the tab's window has finished
    /// showing it. The tab still has to be CONNECTED; a double-click on a
    /// query whose tab has no connection opens it and stops there.
    private func runSavedQuery() {
        DispatchQueue.main.async { [weak self] in self?.runAllCards() }
    }

    @objc private func handleOpenHistoryEntry(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        guard let entry = notification.userInfo?["entry"] as? QueryHistoryEntry else { return }

        // One card holding the entry's SQL, named for its tables.
        var card = QueryCard(name: entry.tableNames, sql: entry.sql)
        let tabName = entry.tableNames ?? "History"

        // A failed entry has no result to restore. Its SQL is now in the card,
        // which is the useful thing: read the message in the navigator, fix
        // the statement, run it again.
        guard entry.isSucceeded,
              let resultData = try? PharosCore.getQueryHistoryResult(id: entry.id) else {
            _ = open(newTab(name: tabName, document: CardDocument(cards: [card])), from: notification)
            return
        }
        let result = QueryResult.fromHistory(
            resultData, historyEntryId: entry.id, executionTimeMs: UInt64(entry.executionTimeMs))
        card.colorIndex = 0
        card.lastRun = CardRunRecord(
            runId: UUID().uuidString, rawSQL: entry.sql, renderedSQL: entry.sql,
            finishedAt: ISO8601DateFormatter().date(from: entry.executedAt) ?? Date(),
            executionTimeMs: UInt64(entry.executionTimeMs),
            summary: .rows(count: result.rowCount, hasMore: result.hasMore), historyResultId: entry.id)
        var doc = CardDocument(cards: [card])
        doc.displayedCardId = card.id

        // The history schema + timestamp drive the banner while this result
        // is on screen.
        var cr = CardResult(cardId: card.id, sql: entry.sql, rawSQL: entry.sql)
        cr.queryResult = result
        cr.executionTimeMs = UInt64(entry.executionTimeMs)
        cr.totalRowCountHint = result.rowCount
        cr.historySchema = entry.schema
        cr.historyTimestamp = entry.executedAt
        cr.historyResultId = entry.id
        cr.hasBeenViewed = true

        let tab = newTab(name: tabName, document: doc)
        guard let target = open(tab, from: notification) else { return }
        // The target already shows the tab — delivery is synchronous. Seed its
        // store entry and apply it, so the grid and the history banner show now.
        target.session.resultStore[tab.id] = EditorTabResults(results: [cr])
        target.applySeededResultState(forTabId: tab.id)
    }

    @objc private func handleShowSQLInInspector(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        guard let sql = notification.userInfo?["sql"] as? String else { return }
        guard let splitVC = parent as? PharosSplitViewController else { return }
        splitVC.showInspector()
        splitVC.inspectorVC.showSQL(sql)
    }

    @objc private func handleOpenWorkspace(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        guard let wsId = notification.userInfo?["workspaceId"] as? String else { return }
        let focusResultId = notification.userInfo?["focusResultId"] as? String
        let sessionText = notification.userInfo?["sessionText"] as? String
        let sessionCardsJson = notification.userInfo?["sessionCardsJson"] as? String

        // Already open in a tab, in any window? Just front it (and the
        // requested result, if any).
        if let target = frontExistingTab(where: { $0.workspaceId == wsId }) {
            if let fid = focusResultId { target.focusResult(historyId: fid) }
            return
        }

        // Loading the workspace detail and fetching every cached result blob
        // (each a gzip+JSON FFI round-trip) is expensive for a long session —
        // do it off the main thread so reopening doesn't hitch the UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let detail = try? PharosCore.loadWorkspace(id: wsId) else { return }
            // Blobs for the results that have them; the rest are "SQL only".
            var blobs: [String: QueryResult] = [:]
            for meta in detail.results where meta.isSucceeded && meta.hasResults {
                if let data = try? PharosCore.getQueryHistoryResult(id: meta.id) {
                    blobs[meta.id] = QueryResult.fromHistory(data, historyEntryId: meta.id, executionTimeMs: UInt64(meta.executionTimeMs))
                }
            }
            let loaded = blobs

            await MainActor.run { [weak self] in
                guard let self else { return }

                // Re-check already-open: another reopen request could have
                // created a tab for this workspace while we were off-main.
                if let target = self.frontExistingTab(where: { $0.workspaceId == wsId }) {
                    if let fid = focusResultId { target.focusResult(historyId: fid) }
                    return
                }

                // Session restore hands over the session row's copy, which
                // is newer than the workspace's.
                var document = sessionText.map { CardPersistence.decode(json: sessionCardsJson, text: $0) }
                    ?? CardPersistence.decode(json: detail.cardsJson, text: detail.editorText)
                let results = Self.restoreResults(detail.results, blobs: loaded, into: &document)
                let focus = focusResultId.flatMap { fid in results.first(where: { $0.historyResultId == fid }) } ?? results.last
                document.displayedCardId = focus?.id

                var tab = self.newTab(name: detail.name, document: document)
                tab.workspaceId = detail.id
                tab.connectionId = detail.connectionId
                guard let target = self.open(tab, from: notification) else { return }

                // Seed the store entry, then apply it: the target already shows
                // the tab (synchronous delivery) and read it empty. Results run
                // later go AFTER the restored ones: from MAX(result_order)+1,
                // not the count, so a workspace whose middle results were
                // deleted cannot collide.
                target.session.resultStore[tab.id] = EditorTabResults(
                    results: results,
                    nextOrder: (detail.results.compactMap { $0.resultOrder }.max() ?? -1) + 1)
                target.applySeededResultState(forTabId: tab.id)
            }
        }
    }

    /// Put a workspace's stored results back on their cards. A result names
    /// its card (`cardId`); a result recorded before cards existed is matched
    /// to the first card whose SQL is the SQL it ran. The newest result of a
    /// card wins. Cards get the run record their state is shown from.
    private static func restoreResults(_ metas: [WorkspaceResultMeta], blobs: [String: QueryResult],
                                       into document: inout CardDocument) -> [CardResult] {
        var byCard: [String: CardResult] = [:]
        var order: [String] = []
        for meta in metas.sorted(by: { ($0.resultOrder ?? 0) < ($1.resultOrder ?? 0) }) where meta.isSucceeded {
            let raw = meta.rawSql ?? meta.sql
            let cardId = meta.cardId.flatMap { id in document.card(id) != nil ? id : nil }
                ?? document.cards.first(where: {
                    CardDocument.normalized($0.sql) == CardDocument.normalized(raw)
                        || CardDocument.normalized($0.sql) == CardDocument.normalized(meta.sql)
                })?.id
            guard let cardId, let i = document.index(of: cardId) else { continue }

            var cr = CardResult(cardId: cardId, sql: meta.sql, rawSQL: raw)
            cr.executionTimeMs = UInt64(meta.executionTimeMs)
            cr.historySchema = meta.schema
            cr.historyTimestamp = meta.executedAt
            cr.historyResultId = meta.id
            cr.totalRowCountHint = meta.rowCount
            if let json = meta.chartViewStateJson, let data = json.data(using: .utf8),
               let state = try? JSONDecoder.pharos.decode(PersistedResultViewState.self, from: data) {
                cr.chartConfig = state.chartConfig
                cr.resultViewMode = state.viewMode
            }
            cr.queryResult = blobs[meta.id]

            let card = document.cards[i]
            if card.lastRun == nil || card.lastRun?.historyResultId != meta.id {
                document.cards[i].lastRun = CardRunRecord(
                    runId: cr.runId, rawSQL: raw, renderedSQL: meta.sql,
                    finishedAt: ISO8601DateFormatter().date(from: meta.executedAt) ?? Date(),
                    executionTimeMs: UInt64(meta.executionTimeMs),
                    summary: .rows(count: meta.rowCount ?? 0, hasMore: false), historyResultId: meta.id)
            }
            if document.cards[i].colorIndex == nil { document.cards[i].colorIndex = meta.colorIndex }
            if document.cards[i].name == nil, let label = meta.customLabel, !label.isEmpty {
                document.cards[i].name = label
            }
            document.cards[i].resultsRemoved = cr.queryResult == nil
            if byCard[cardId] == nil { order.append(cardId) }
            byCard[cardId] = cr
        }
        return order.compactMap { byCard[$0] }
    }

    /// Apply results seeded into the store for a tab that is already active.
    private func applySeededResultState(forTabId tabId: String) {
        guard session.activeTabId == tabId,
              let tab = session.tabs.first(where: { $0.id == tabId }) else { return }
        editorPane.reloadCards()
        loadResultState(for: tab)
    }

    /// Show the card result that came from the given query-history id.
    /// No-op when the displayed tab holds none.
    private func focusResult(historyId: String) {
        guard let r = cardResults.first(where: { $0.historyResultId == historyId }) else { return }
        displayResults(ofCard: r.id)
        editorPane.cardStack.scrollToCard(r.id)
    }
}

// MARK: - Chart Mode

extension ContentViewController {

    /// The active result tab's current view mode, defaulting to grid when no
    /// result tab is active.
    private var activeResultViewMode: ResultViewMode {
        guard let id = displayedCardId, let tab = cardResults.first(where: { $0.id == id }) else { return .grid }
        return tab.resultViewMode
    }

    /// Show/hide the results grid vs. the chart host based on the active result
    /// tab's view mode and the current editor/results expand state. Single source
    /// of truth so `applyExpandState`, mode toggles, and tab switches agree.
    func applyResultAreaVisibility() {
        let resultsAreaVisible = (expandState != .editorExpanded)
        // The plan outranks the view mode while it is chosen.
        let showPlan = resultsAreaVisible && displayedResultShowsPlan
        let showChart = resultsAreaVisible && !showPlan && activeResultViewMode == .chart
        planHost.view.isHidden = !showPlan
        chartHost.view.isHidden = !showChart
        resultsVC.view.isHidden = !(resultsAreaVisible && !showChart && !showPlan)
        // Plan is offered only when the card has been explained; Grid and
        // Chart only when it has rows.
        let r = displayedResult
        chartToggle.setEnabled(r?.plan != nil, forSegment: 2)
        chartToggle.setEnabled(r?.queryResult != nil, forSegment: 1)
        chartToggle.selectedSegment = showPlan ? 2 : (activeResultViewMode == .chart ? 1 : 0)
        updateExportButtonTarget()
    }

    /// Whether the displayed card's results show its EXPLAIN plan.
    var displayedResultShowsPlan: Bool {
        guard let r = displayedResult else { return false }
        return r.showsPlan && r.plan != nil
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
        guard idx < cardResults.count else { return }
        cardResults[idx].resultViewMode = mode
        if mode == .chart { presentChart(for: idx) }
        else { cancelServerAggregation() }   // leaving chart mode kills any run
        applyResultAreaVisibility()
    }

    /// Set (and persist) the view mode for the active result tab. Used by the
    /// explicit user toggle and the reopen-into-chart restore.
    func setResultViewMode(_ mode: ResultViewMode) {
        guard let id = displayedCardId, let idx = cardResults.firstIndex(where: { $0.id == id }) else { return }
        applyResultViewMode(mode, for: idx)
        persistChartState(forTabId: id)
    }

    @objc func chartToggleChanged() {
        guard let id = displayedCardId else { return }
        if chartToggle.selectedSegment == 2 {
            _ = mutateResult(cardId: id) { $0.showsPlan = true }
            if let r = displayedResult, let plan = r.plan {
                planHost.show(plan: plan, json: r.planJSON ?? "", isAnalyze: r.planIsAnalyze)
            }
            applyResultAreaVisibility()
            updateResultsHeader()
            return
        }
        _ = mutateResult(cardId: id) { $0.showsPlan = false }
        let mode: ResultViewMode = chartToggle.selectedSegment == 1 ? .chart : .grid
        setResultViewMode(mode)
        updateResultsHeader()
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
        guard let id = displayedCardId, let idx = cardResults.firstIndex(where: { $0.id == id }) else {
            // No active result tab (last result tab closed, or switched to a tab
            // with no results): kill any in-flight push-down so it isn't orphaned.
            cancelServerAggregation()
            chartToggle.selectedSegment = 0
            applyResultAreaVisibility()
            return
        }
        applyResultViewMode(cardResults[idx].resultViewMode, for: idx)
    }

    /// Capture the config the user just edited in the chart rail back onto the
    /// (about-to-be-outgoing) result tab, mirroring the gridState capture.
    private func captureChartConfig(intoTabAt idx: Int) {
        guard idx < cardResults.count, cardResults[idx].resultViewMode == .chart else { return }
        if let cfg = chartHost.currentConfig { cardResults[idx].chartConfig = cfg }
    }

    /// Build the chart for the result tab at `idx` and hand it to the host.
    private func presentChart(for idx: Int) {
        guard idx < cardResults.count else { return }
        // (Re)presenting supersedes any prior tab's server-aggregation run:
        // cancel it so a superseded full-table GROUP BY stops burning server time.
        cancelServerAggregation()
        guard let result = cardResults[idx].queryResult else {
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
                sql: cardResults[idx].sql,
                initialConfig: cardResults[idx].chartConfig,
                banner: ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "")
            )
            return
        }
        // Drop any stored role whose column no longer exists at the same index.
        var cfg = cardResults[idx].chartConfig
        cfg?.validate(against: result.columns)

        // Capture the tab's stable id (not its index) so a reorder/close of other
        // tabs while this chart is on screen can't misattribute the edit or the
        // debounced persist to the wrong result tab.
        let tabId = cardResults[idx].id
        chartHost.onConfigChanged = { [weak self] newCfg in
            guard let self, let i = self.cardResults.firstIndex(where: { $0.id == tabId }) else { return }
            self.cardResults[i].chartConfig = newCfg
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
        chartHost.present(result: result, sql: cardResults[idx].sql, initialConfig: cfg, banner: bannerInfo(for: idx, result: result))
        // Capture the config the host actually used (inference may have filled it).
        cardResults[idx].chartConfig = chartHost.currentConfig
        // Reopen is explicit: even with serverAggregation on we do NOT auto-run
        // here — the banner shows the "Run…" state. Just publish availability.
        refreshPushdownAvailability()
    }

    // MARK: Push-down (server aggregation)

    /// Compute push-down availability for the active chart and push it (plus a
    /// disabled-reason) into the view model so the rail can show/hide the toggle.
    private func refreshPushdownAvailability() {
        guard let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              let result = cardResults[idx].queryResult,
              let cfg = cardResults[idx].chartConfig else {
            chartHost.setPushdownAvailability(false, reason: nil)
            return
        }
        let userSQL = cardResults[idx].sql
        if SqlPushdownGenerator.generate(cfg.resolvingAutoBins(for: result), userSQL: userSQL, columns: result.columns) != nil {
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
        guard let editorTab = session.activeTab,
              let connectionId = editorTab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              let result = cardResults[idx].queryResult,
              let cfg = cardResults[idx].chartConfig, cfg.serverAggregation else {
            chartHost.setServerLoading(false)
            return
        }
        guard let pushdown = SqlPushdownGenerator.generate(cfg.resolvingAutoBins(for: result), userSQL: cardResults[idx].sql, columns: result.columns) else {
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
        let editorTabId = editorTab.id
        // Pass limit ≥ the generator's group cap so groups aren't silently paged
        // off by executeQuery's own page limit; hasMore then means truncation.
        let cap = max(SqlPushdownGenerator.groupCap, SqlPushdownGenerator.scatterSampleCap)
        let limit = max(Int32(stateManager.settings.query.defaultLimit), Int32(cap))
        let rtId = id
        let layout = pushdown.layout
        let sql = pushdown.sql

        Task {
            do {
                // On the tab's own connection when it has one, so the
                // aggregation sees what the card saw (temp tables, open
                // transaction); it runs inside a savepoint there.
                let qr: QueryResult
                if let target = CardExecutor.auxTarget(
                    tabId: editorTabId, connectionId: connectionId, schema: schema, queryId: queryId) {
                    do {
                        let r = try await PharosCore.sessionExecuteQuery(target, sql: sql, limit: limit, aux: true)
                        TabSessionMonitor.shared.record(r.session)
                        qr = r.payload
                    } catch {
                        TabSessionMonitor.shared.refresh(editorTabId)
                        throw error
                    }
                } else {
                    qr = try await PharosCore.executeQuery(
                        connectionId: connectionId, sql: sql, queryId: queryId,
                        limit: limit, schema: schema, source: "chart-aggregation"
                    )
                }
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
                    if let i = self.cardResults.firstIndex(where: { $0.id == rtId }) {
                        self.cardResults[i].chartConfig?.lastServerRun = lastRun
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
        guard let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              let result = cardResults[idx].queryResult,
              let cfg = cardResults[idx].chartConfig,
              let pushdown = SqlPushdownGenerator.generate(cfg.resolvingAutoBins(for: result), userSQL: cardResults[idx].sql, columns: result.columns) else {
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
        guard let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              let result = cardResults[idx].queryResult,
              let cfg = cardResults[idx].chartConfig, cfg.serverAggregation else { return false }
        return SqlPushdownGenerator.generate(cfg.resolvingAutoBins(for: result), userSQL: cardResults[idx].sql, columns: result.columns) != nil
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
            splitVC.inspectorVC.withdraw(.results); return
        }
        let applied = DrillTranslator.filters(for: keys, columns: resultsVC.columns)
        guard !applied.isEmpty else { splitVC.inspectorVC.withdraw(.results); return }
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
        guard let id = displayedCardId, let idx = cardResults.firstIndex(where: { $0.id == id }),
              let cfg = cardResults[idx].chartConfig else { return false }
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
        guard let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              let result = cardResults[idx].queryResult else { return }

        if let cfg = cardResults[idx].chartConfig, cfg.serverAggregation, chartTypeSupportsServer(cfg.chartType) {
            applyServerDrill(keys, resultTab: cardResults[idx], columns: result.columns)
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
    /// (`DrillSqlTranslator`), wrap the card's (already variable-substituted)
    /// SQL in a filtered subquery, and run it as a **new card** below the
    /// source card — this records the run in `query_history`, giving a
    /// self-contained, re-runnable drill trail. Does NOT touch the grid filter /
    /// chip; that overlay is client-mode-only.
    private func applyServerDrill(_ keys: [DrillKey], resultTab: CardResult, columns: [ColumnDef]) {
        guard !keys.isEmpty else { return }
        let predicate = keys
            .map { "(" + DrillSqlTranslator.predicate(for: $0, columns: columns) + ")" }
            .joined(separator: " AND ")
        guard !predicate.isEmpty else { return }
        let sql = "SELECT * FROM ( \(resultTab.sql) ) AS _pharos_src WHERE \(predicate)"
        guard let tabId = session.activeTabId else { return }
        let sourceName = session.activeTab?.document.card(resultTab.id)?.name ?? String(localized: "Untitled query")
        runGeneratedCard(sql: sql, name: String(localized: "Drill: \(sourceName)"), inTab: tabId, after: resultTab.id)
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
        let total = cardResults[idx].totalRowCountHint ?? loaded
        let subset = canLoadMore || total > loaded
        guard subset else { return ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "") }
        let ofTotal = total > loaded ? " of \(total)" : ""
        let text = "Charting \(loaded)\(ofTotal) loaded rows, aggregated client-side."
        return ChartBannerInfo(shouldShow: true, canLoadAll: canLoadMore, text: text)
    }

    // MARK: Load all (in-memory)

    private func loadAllRowsForChart() {
        guard let id = displayedCardId, let idx = cardResults.firstIndex(where: { $0.id == id }),
              let result = cardResults[idx].queryResult, result.hasMore else { return }
        let cap = 200_000
        fetchAllRemaining(upTo: cap) { [weak self] in
            guard let self, let i = self.cardResults.firstIndex(where: { $0.id == self.displayedCardId }) else { return }
            if self.cardResults[i].resultViewMode == .chart { self.presentChart(for: i) }
        }
    }

    /// Replace the active result tab's in-memory `queryResult` with one
    /// consistent snapshot of every row (up to `cap`), through the server
    /// cursor path. Does NOT write back to the workspace/history blob — this
    /// is an in-memory expansion for charting only. It used to loop the
    /// OFFSET pager, which can repeat or skip rows between pages without an
    /// ORDER BY; a chart over such rows was quietly wrong.
    private func fetchAllRemaining(upTo cap: Int, completion: @escaping () -> Void) {
        guard let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              let current = cardResults[idx].queryResult, current.hasMore else {
            completion(); return
        }
        runSnapshotLoad(forCard: id, cap: cap, showInGrid: false) { _ in completion() }
    }

    /// Rows a "Load All Rows" snapshot will take before it stops and says the
    /// result is larger. A hard ceiling on client memory, not a page size.
    private static let snapshotRowCap = 500_000

    /// "Load All Rows": the explicit alternative to paging by OFFSET. Re-runs
    /// the displayed result's statement through a server cursor in one
    /// transaction and replaces the result with a consistent snapshot.
    private func loadAllRowsSnapshot() {
        guard let id = displayedCardId,
              let idx = cardResults.firstIndex(where: { $0.id == id }),
              cardResults[idx].queryResult?.hasMore == true else { return }
        runSnapshotLoad(forCard: id, cap: Self.snapshotRowCap, showInGrid: true) { [weak self] capped in
            guard let self, capped else { return }
            Toast.show(
                in: self.view,
                message: "Loaded the first \(ResultsGridVC.rowCountFormatter.string(from: NSNumber(value: Self.snapshotRowCap)) ?? "\(Self.snapshotRowCap)") rows as one snapshot. The result is larger.",
                style: .warning, duration: 4.0)
        }
    }

    /// Shared body of "Load All Rows" and the chart's load-all. Registers a
    /// running query on the editor tab so the pulse, the running-queries
    /// popover and Cancel (⌘.) all see it, then replaces the result tab's
    /// rows with the snapshot. `completion` receives whether the cap cut the
    /// snapshot short.
    private func runSnapshotLoad(forCard rtId: String, cap: Int, showInGrid: Bool,
                                 completion: @escaping (Bool) -> Void) {
        // This is the ONE path on which a run replaces a result tab's rows in
        // place. Every other run appends a NEW result tab, which leaves the old
        // tab's rows — and therefore its pending cell edits — exactly where
        // they were. A snapshot re-executes the statement and swaps the rows
        // wholesale, so the data-row indices the pending set is keyed on stop
        // meaning anything. Ask first; Cancel aborts the load.
        if session.resultStore.result(forCard: rtId)?.pendingEdits.isEmpty == false
            || (displayedCardId == rtId && !resultsVC.pendingEdits.isEmpty) {
            confirmDiscardingPendingEdits(forCard: rtId) { [weak self] in
                self?.runSnapshotLoad(forCard: rtId, cap: cap, showInGrid: showInGrid,
                                      completion: completion)
            }
            return
        }
        guard let editorTabId = session.resultStore.editorTabId(forCard: rtId),
              let editorTab = session.tabs.first(where: { $0.id == editorTabId }),
              let connectionId = editorTab.connectionId,
              stateManager.status(for: connectionId) == .connected,
              let rt = session.resultStore.result(forCard: rtId),
              let current = rt.queryResult else {
            completion(false); return
        }
        let sql = rt.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let schema = editorTab.schemaName
        let queryId = UUID().uuidString

        // A distinct normalized key: this must not be deduplicated against a
        // normal run of the same statement, nor block one.
        let running = RunningQuery(
            id: queryId,
            cardId: rtId,
            kind: .snapshot,
            label: editorTab.document.card(rtId)?.name ?? String(localized: "Untitled query"),
            normalizedSQL: "snapshot:" + Self.normalizeSQL(sql),
            startTime: CACurrentMediaTime()
        )
        session.updateTab(id: editorTabId) { $0.runningQueries.append(running) }
        if showInGrid {
            snapshotQueryId = queryId
            resultsVC.beginLoadingAll(cap: cap)
        }

        // The progress callback lands on the main actor. It must not touch the
        // grid once the user has moved to another result tab: the bar down
        // there belongs to whatever is on screen now, not to this load.
        let onProgress: @Sendable (Int) -> Void = { [weak self] rows in
            MainActor.assumeIsolated {
                guard let self, showInGrid,
                      self.snapshotQueryId == queryId,
                      self.displayedCardId == rtId else { return }
                self.resultsVC.updateLoadingAll(rows: rows)
            }
        }

        Task {
            let outcome: Result<QueryResult, Error>
            do {
                // One snapshot on the connection the card ran on (the tab's
                // own when it has one), inside a savepoint in its transaction.
                if let target = CardExecutor.auxTarget(
                    tabId: editorTabId, connectionId: connectionId, schema: schema, queryId: queryId) {
                    do {
                        let r = try await PharosCore.sessionFetchAllRows(
                            target, sql: sql, maxRows: Int64(cap), onProgress: onProgress)
                        TabSessionMonitor.shared.record(r.session)
                        outcome = .success(r.payload)
                    } catch {
                        TabSessionMonitor.shared.refresh(editorTabId)
                        throw error
                    }
                } else {
                    outcome = .success(try await PharosCore.fetchAllRows(
                        connectionId: connectionId, sql: sql, queryId: queryId,
                        maxRows: Int64(cap), schema: schema, onProgress: onProgress))
                }
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.session.updateTab(id: editorTabId) { $0.runningQueries.removeAll { $0.id == queryId } }
                let wasCancelled = self.cancelledQueryIds.remove(queryId) != nil
                let stillDisplaying = self.displayedCardId == rtId
                if self.snapshotQueryId == queryId { self.snapshotQueryId = nil }
                if showInGrid { self.resultsVC.endLoadingAll() }

                switch outcome {
                case .failure(let error):
                    if !wasCancelled {
                        Toast.show(in: self.view, message: "Load All failed: \(error.localizedDescription)",
                                   style: .error, duration: 4.0)
                    }
                    completion(false)
                case .success(let snapshot):
                    // The snapshot replaces the rows wholesale — it is one
                    // execution, and the first page came from another. Keep
                    // the original timing and history id: the result tab is
                    // the same result, now complete.
                    let replaced = QueryResult(
                        columns: snapshot.columns.isEmpty ? current.columns : snapshot.columns,
                        rows: snapshot.rows,
                        rowCount: snapshot.rows.count,
                        executionTimeMs: current.executionTimeMs,
                        hasMore: snapshot.hasMore,
                        historyEntryId: current.historyEntryId,
                        rowIdentity: snapshot.rowIdentity ?? current.rowIdentity
                    )
                    let held = self.session.resultStore.mutateResult(cardId: rtId) {
                        $0.queryResult = replaced
                        if !snapshot.hasMore { $0.totalRowCountHint = snapshot.rows.count }
                    }
                    if let held { self.noteRowsLoaded(forCard: rtId, runId: held.runId, result: replaced) }
                    if showInGrid && stillDisplaying {
                        // Keep the user's widths, sort and filters across the swap.
                        let gridState = self.resultsVC.captureGridState()
                        self.resultsVC.showResult(replaced)
                        if let gridState { self.resultsVC.restoreGridState(gridState) }
                    }
                    completion(snapshot.hasMore)
                }
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
        // Any editor tab's result: a debounced persist can fire after the
        // user has switched tabs, and used to be dropped silently then.
        guard let tab = session.resultStore.result(forCard: id) else { return }
        // Only persist for results that belong to a workspace (have a history
        // row). `historyResultId`, not the rows' own id: a restored "SQL only"
        // result has a history row and no rows.
        guard let resultId = tab.historyResultId else { return }
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
    ///
    /// Two passes, covering different families. `SavedQueryFilename` is the
    /// app's one filename sanitiser and handles the INVISIBLE class — controls,
    /// bidi, zero-width — which this function used to miss entirely. The local
    /// set is punctuation this panel has always replaced and the shared
    /// sanitiser deliberately does not, because a saved query named `50%`
    /// should keep its `%`.
    private func defaultChartExportBaseName() -> String {
        guard let id = displayedCardId,
              let name = session.activeTab?.document.card(id)?.name
        else { return "chart" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = SavedQueryFilename.sanitize(name)
            .components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        // Checked AFTER sanitising, and against `untitled` as well as empty:
        // the shared sanitiser strips leading dots, so a label of "..." arrives
        // here as its own fallback rather than as an empty string, and this
        // panel's fallback should still win.
        return cleaned.isEmpty || cleaned == "untitled" ? "chart" : cleaned
    }
}

// MARK: - Run Query / Insert Text (from schema browser context menu)

extension ContentViewController {

    @objc private func handleRunQueryInCurrentTab(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        guard let sql = notification.userInfo?["sql"] as? String,
              let resultName = notification.userInfo?["resultName"] as? String,
              let tabId = session.activeTabId else { return }
        // A browse action is a new named card at the end of the active tab.
        runGeneratedCard(sql: sql, name: resultName, inTab: tabId)
    }

    @objc private func handleInsertTextInEditor(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        guard let text = notification.userInfo?["text"] as? String else { return }
        guard session.activeTab != nil else { return }
        editorPane.insertText(text)
        editorPane.focus()
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
        let affectedTabIds = session.tabs.compactMap { $0.connectionId == connectionId ? $0.id : nil }
        for tabId in affectedTabIds {
            // Nothing queued can run on a connection that is gone.
            if var queue = runQueues[tabId] {
                _ = queue.cancelAll()
                runQueues[tabId] = queue
            }
            session.updateTab(id: tabId) { tab in
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
        guard let tab = session.activeTab else { return }

        // A bound tab writes back where it came from. A scratch tab has
        // nowhere to write to, so it asks.
        if UnsavedWorkPolicy.canSaveInPlace(unsavedWorkTab(tab)) {
            saveTabInPlace(id: tab.id)
            return
        }

        // New tab: prompt to save into the saved-queries store.
        presentSaveQuerySheet(tab: tab)
    }

    /// Write one tab's edits back to whatever binds it — its file, or its saved
    /// query — and mark it clean. Returns false when the tab is bound to
    /// nothing (the caller must present the Save Query sheet instead) or the
    /// write failed.
    ///
    /// Works for ANY tab, not only the one on screen: the SQL comes from the
    /// editor for the visible tab and from the tab's own `sql` otherwise, and
    /// `EditorPaneVC` writes every keystroke into the tab (`onTextEdited`), so a
    /// background tab's `sql` is current. That is what lets the close and quit
    /// warnings save tabs the user is not looking at.
    ///
    /// Clearing `isDirty` is the point of the "in place" in the name: before
    /// this existed, only the FILE branch cleared it, so a tab bound to a
    /// saved query stayed dirty for the rest of its life after one edit.
    @discardableResult
    func saveTabInPlace(id: String, reportErrors: Bool = true) -> Bool {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return false }
        // Every version, with its name and lock, as `-- name:` comments.
        let currentSQL = CardText.text(of: tab.document)

        if let url = tab.sourceURL {
            do {
                try SQLFileWriter.write(currentSQL, to: url)
                session.updateTab(id: id) {
                    $0.isDirty = false
                }
                return true
            } catch {
                Log.query.error("Failed to save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if reportErrors {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save \(url.lastPathComponent)"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return false
            }
        }

        if let savedId = tab.savedQueryId {
            do {
                // The latest version of each query as the text (Spotlight,
                // Shortcuts, Copy), every card in the JSON.
                let stored = CardPersistence.encode(tab.document, mode: .latest)
                let update = UpdateSavedQuery(id: savedId, name: nil, folder: nil, sql: stored.text, variables: nil,
                                              cardsJson: stored.json)
                _ = try PharosCore.updateSavedQuery(update)
                session.updateTab(id: id) {
                    // The bug this line fixes: the saved query HAS been
                    // written, so the tab is no longer dirty.
                    $0.isDirty = false
                }
                NotificationCoalescer.post(.savedQueriesDidChange)
                return true
            } catch {
                Log.query.error("Failed to update saved query: \(error.localizedDescription, privacy: .public)")
                if reportErrors {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Couldn't save “\(tab.name)”")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return false
            }
        }

        return false
    }

    @objc func menuSaveQueryAs(_: Any?) {
        guard let tab = session.activeTab else { return }
        presentSaveQuerySheet(tab: tab)
    }

    @objc func menuExportEditorAsSQL(_: Any?) {
        guard let tab = session.activeTab else { return }
        // A script to run elsewhere: the latest version of each query, with
        // the variables substituted.
        let raw = CardText.text(of: tab.document, mode: .latest)
        let text = VariableSubstitutor.render(raw, with: QueryVariableStore.shared.variables).sql

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

    /// Ask for a name and a folder, then put this tab's SQL in the library.
    ///
    /// `onFinish` reports whether the tab came out of the sheet SAVED. The
    /// close/quit warning needs that answer: a cancelled sheet has to cancel
    /// the close rather than drop the tab the user just declined to save. The
    /// SQL is taken from the editor for the visible tab and from the tab's own
    /// `sql` otherwise, so the sheet can serve a background tab too.
    func presentSaveQuerySheet(tab: QueryTab, onFinish: ((Bool) -> Void)? = nil) {
        var didSave = false
        let stored = CardPersistence.encode(tab.document, mode: .latest)
        let sheet = SaveQuerySheet(
            tabName: tab.name,
            sql: stored.text,
            cardsJson: stored.json
        ) { [weak self] action in
            didSave = true
            guard let self else { return }
            let savedQuery: SavedQuery
            switch action {
            case .created(let q): savedQuery = q
            case .replaced(let q): savedQuery = q
            }
            self.session.updateTab(id: tab.id) {
                $0.savedQueryId = savedQuery.id
                // The sheet wrote this tab's cards into the store, so the tab
                // matches what is saved: it is no longer dirty.
                $0.isDirty = false
            }
            NotificationCoalescer.post(.savedQueriesDidChange)
        }
        // Fires however the sheet ends — Save, Cancel or Escape — and after
        // the save callback above, so `didSave` is settled by now.
        sheet.onDismiss = { onFinish?(didSave) }
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

    @objc func menuCancelAllQueries(_: Any?) {
        cancelAllQueries()
    }

    /// Whether a tab still has a card running or waiting to run (Run All).
    func hasRunsInProgress(inTab tabId: String) -> Bool {
        guard let queue = runQueues[tabId] else { return false }
        return queue.running != nil || !queue.waiting.isEmpty
    }

    @objc func menuRunAllQueries(_: Any?) {
        runAllCards()
    }

    @objc func menuRunAndReplaceResults(_: Any?) {
        executeQueryReplacingResults()
    }

    @objc func menuNewCard(_: Any?) {
        editorPane.cardStack.addCardBelowFocused()
    }

    @objc func menuPreviousCard(_: Any?) {
        editorPane.cardStack.moveFocus(by: -1)
    }

    @objc func menuNextCard(_: Any?) {
        editorPane.cardStack.moveFocus(by: 1)
    }

    @objc func menuCollapseAllCards(_: Any?) {
        editorPane.cardStack.setAllCollapsed(true)
    }

    @objc func menuExpandAllCards(_: Any?) {
        editorPane.cardStack.setAllCollapsed(false)
    }

    @objc func menuExplainQuery(_: Any?) {
        explainCurrentStatement(analyze: false)
    }

    @objc func menuExplainAnalyzeQuery(_: Any?) {
        explainCurrentStatement(analyze: true)
    }

    @objc func menuConnect(_: Any?) {
        guard let id = session.activeTab?.connectionId else { return }
        stateManager.connect(id: id, in: session)
    }

    @objc func menuDisconnect(_: Any?) {
        guard let id = session.activeTab?.connectionId else { return }
        // Disconnecting closes every tab connection on this server, in every
        // window, rolling back their open transactions: ask first.
        let open = stateManager.sessions.flatMap(\.tabs).filter {
            $0.connectionId == id && TabSessionMonitor.shared.hasOpenTransaction($0.id)
        }
        confirmRollingBack(open, action: .disconnect) { [weak self] proceed in
            guard proceed else { return }
            self?.stateManager.disconnect(id: id)
        }
    }

    @objc func menuRefreshMetadata(_: Any?) {
        guard let id = session.activeTab?.connectionId,
              stateManager.status(for: id) == .connected else { return }
        MetadataCache.shared.load(connectionId: id, force: true)
        NotificationCenter.default.post(name: .connectionMetadataRefreshRequested, object: nil)
    }

    /// Query ▸ Commit Transaction: the tab's own connection's transaction.
    @objc func menuCommitTransaction(_: Any?) {
        editorPane.sessionBannerAction(.commit)
    }

    /// Query ▸ Roll Back Transaction.
    @objc func menuRollBackTransaction(_: Any?) {
        editorPane.sessionBannerAction(.rollBack)
    }

    /// File ▸ Rename Tab…: the native tab bar has no rename of its own.
    @objc func menuRenameTab(_: Any?) {
        guard let tabId = session.activeTabId else { return }
        renameTab(id: tabId)
    }

    /// File ▸ Duplicate Tab: a copy beside this tab, with fresh card ids —
    /// results are filed by card, and the copy has none.
    @objc func menuDuplicateTab(_: Any?) {
        guard let tab = session.tab,
              let delegate = NSApp.delegate as? AppDelegate,
              let controller = view.window?.windowController as? MainWindowController else { return }
        let copy = QueryTab(name: "\(tab.name) Copy", connectionId: tab.connectionId, schemaName: tab.schemaName,
                            document: tab.document.forReuse())
        delegate.openTab(copy, beside: controller)
    }

    /// The cards with results in memory, in stack order: what ⌥⌘] cycles.
    private var cardsWithResults: [String] {
        guard let doc = session.activeTab?.document else { return [] }
        let held = Set(cardResults.filter(\.hasPayload).map(\.id))
        return doc.cards.map(\.id).filter(held.contains)
    }

    /// ⌥⌘]: show the results of the next card that has some.
    @objc func menuSelectNextResultTab(_: Any?) {
        let ids = cardsWithResults
        guard ids.count > 1 else { return }
        let idx = displayedCardId.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = ids[(idx + 1) % ids.count]
        displayResults(ofCard: next)
        editorPane.cardStack.scrollToCard(next)
    }

    @objc func menuSelectPreviousResultTab(_: Any?) {
        let ids = cardsWithResults
        guard ids.count > 1 else { return }
        let idx = displayedCardId.flatMap { ids.firstIndex(of: $0) } ?? 0
        let previous = ids[(idx - 1 + ids.count) % ids.count]
        displayResults(ofCard: previous)
        editorPane.cardStack.scrollToCard(previous)
    }

    @objc func showFind() {
        resultsVC.showFind()
    }

    @objc func showFilter() {
        resultsVC.showFilter()
    }

    /// Fallback for the Edit > Find submenu when neither the editor nor the
    /// results grid is first responder (both implement
    /// `performTextFinderAction(_:)` themselves and are tried first via the
    /// responder chain since the menu items use a nil target).
    @objc override func performTextFinderAction(_ sender: Any?) {
        let tag: Int?
        if let menuItem = sender as? NSMenuItem {
            tag = menuItem.tag
        } else if let validated = sender as? NSValidatedUserInterfaceItem {
            tag = validated.tag
        } else {
            tag = nil
        }
        guard let tag, let action = NSTextFinder.Action(rawValue: tag) else { return }

        switch action {
        case .showFindInterface:
            resultsVC.showFind()
        case .hideFindInterface:
            resultsVC.findController.closeFind(nil)
        case .nextMatch:
            resultsVC.findController.findNext(nil)
        case .previousMatch:
            resultsVC.findController.findPrevious(nil)
        default:
            break
        }
    }

    @objc func menuTagRow(_ sender: Any?) {
        resultsVC.presentTagSheet(sender)
    }

    @objc func menuManageTags(_ sender: Any?) {
        resultsVC.presentTagManageSheet(preselect: nil)
    }

    @objc func menuFormatSQL(_: Any?) {
        editorPane.formatSQL()
    }

    @objc func menuIncreaseEditorFont(_: Any?) {
        editorPane.stepEditorFontSize(by: 1)
    }

    @objc func menuDecreaseEditorFont(_: Any?) {
        editorPane.stepEditorFontSize(by: -1)
    }
}

// MARK: - NSSplitViewDelegate

// Delegate for `editorResultsSplit` (editor above results).
extension ContentViewController: NSSplitViewDelegate {

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.minEditorHeight
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // `setPosition` consults this too (measured: the editor-expanded
        // position stopped 60pt short), so the expanded state may take
        // the grid's minimum; a drag never can, because a drag from an
        // expanded state restores the normal state first.
        let gridMinimum = expandState == .editorExpanded ? 0 : Self.minResultsGridHeight
        return splitView.bounds.height - resultsAreaChromeHeight - gridMinimum
    }

    /// The action bar is the editor/results divider: its blank stretch starts
    /// a drag. Controls on it still win the click — see
    /// `EditorResultsSplitView.hitTest`.
    func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
        guard splitView === editorResultsSplit, actionBar.window != nil else { return .zero }
        return splitView.convert(actionBar.bounds, from: actionBar)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard (notification.object as? NSSplitView) === editorResultsSplit,
              hasSetInitialSplit, expandState == .normal else { return }
        // A drag or a window resize moved the divider: remember the editor's
        // share, and write it out once the movement settles rather than on
        // every tick.
        rememberSplitRatio()
        splitRatioPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSplitRatio() }
        splitRatioPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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

        var tab = newTab(name: name, document: CardText.document(from: text))
        tab.sourceURL = url
        (NSApp.delegate as? AppDelegate)?.openItem(tab)
    }
}

// MARK: - QueryErrorSheetDelegate

extension ContentViewController: QueryErrorSheetDelegate {

    func errorSheet(_ sheet: QueryErrorSheet, didShow failureId: String, tabId: String) {
        session.updateTab(id: tabId) { $0.failureLog.markRead(id: failureId) }
        refreshErrorBadge(forTabId: tabId)
    }

    func errorSheet(_ sheet: QueryErrorSheet, didRequestDismiss failureId: String, tabId: String) {
        var removedIndex = 0
        var remaining = 0
        session.updateTab(id: tabId) { tab in
            removedIndex = tab.failureLog.index(of: failureId) ?? 0
            tab.failureLog.remove(id: failureId)
            remaining = tab.failureLog.count
        }
        refreshErrorBadge(forTabId: tabId)

        guard let next = QueryFailureLog.indexAfterRemoval(
                  removedIndex: removedIndex, remainingCount: remaining
              ),
              let log = session.tabs.first(where: { $0.id == tabId })?.failureLog else {
            errorPresenter.close()
            return
        }
        errorPresenter.refresh(entries: log.entries, index: next, tabId: tabId)
    }

    func errorSheetDidRequestDismissAll(_ sheet: QueryErrorSheet, tabId: String) {
        session.updateTab(id: tabId) { $0.failureLog.removeAll() }
        refreshErrorBadge(forTabId: tabId)
        errorPresenter.close()
    }

    func errorSheet(_ sheet: QueryErrorSheet, didRequestGoToError failure: QueryFailure) {
        errorPresenter.close()
        revealFailure(failure)
    }

    /// "Go to Error", from the sheet or from the inline banner: go to the tab
    /// the failure belongs to and put the editor on the failing text.
    func revealFailure(_ failure: QueryFailure) {
        frontThisTab()
        if let cardId = failure.cardId { editorPane.cardStack.focusCard(cardId) }
        guard failure.location != nil else { return }
        let pane = editorPane
        // The cards of the tab are on screen inside `selectTab` (settled,
        // synchronous delivery).
        markEditor(with: failure, in: pane)
        guard let cardId = failure.cardId, let range = errorRange(of: failure) else {
            // The sheet cannot know the document text, so its button stays
            // enabled whenever the message holds a position. Say why nothing
            // moved, rather than answering the click with silence.
            Toast.show(
                in: view,
                message: "The card has changed since this query ran",
                style: .warning,
                duration: 3.0
            )
            return
        }
        pane.revealError(cardId: cardId, range: range)
    }

    func errorSheetDidRequestClose(_ sheet: QueryErrorSheet) {
        errorPresenter.close()
    }
}

// MARK: - NSMenuItemValidation

extension ContentViewController: NSMenuItemValidation {
    /// Only the items named here are gated — the two tag items, Run, Cancel,
    /// the tab-cycling items, and the two editor font-size items; every other
    /// menu item keeps its always-enabled behaviour, so the default MUST
    /// stay `true`.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performTextFinderAction(_:)) {
            guard let action = NSTextFinder.Action(rawValue: menuItem.tag) else { return true }
            switch action {
            case .nextMatch, .previousMatch:
                return resultsVC.findController.isFindVisible
            default:
                return true
            }
        }
        if menuItem.action == #selector(menuRunQuery(_:)) { return canRunQuery }
        if menuItem.action == #selector(menuCancelQuery(_:)) { return canCancelQuery }
        if menuItem.action == #selector(menuCancelAllQueries(_:)) { return canCancelQuery }
        if menuItem.action == #selector(menuRunAllQueries(_:)) { return canRunQuery }
        // Both explain items need exactly what Run needs: a connected tab.
        // Whether the statement itself can be explained is the server's answer,
        // and a destructive one is refused with a reason rather than a dead key.
        if menuItem.action == #selector(menuExplainQuery(_:)) { return canRunQuery }
        if menuItem.action == #selector(menuExplainAnalyzeQuery(_:)) { return canRunQuery }
        if menuItem.action == #selector(menuConnect(_:)) { return canConnect }
        if menuItem.action == #selector(menuDisconnect(_:)) { return canDisconnect }
        if menuItem.action == #selector(menuRefreshMetadata(_:)) { return canRefreshMetadata }
        if menuItem.action == #selector(menuCommitTransaction(_:)) || menuItem.action == #selector(menuRollBackTransaction(_:)) {
            guard let tabId = session.activeTabId, let report = TabSessionMonitor.shared.report(for: tabId),
                  report.open else { return false }
            if menuItem.action == #selector(menuCommitTransaction(_:)) { return report.txn == .inTransaction }
            return report.txn == .inTransaction || report.txn == .failed
        }
        if menuItem.action == #selector(menuRenameTab(_:)) || menuItem.action == #selector(menuDuplicateTab(_:)) {
            return session.tab != nil
        }
        if menuItem.action == #selector(menuSelectNextResultTab(_:)) || menuItem.action == #selector(menuSelectPreviousResultTab(_:)) {
            return cardsWithResults.count >= 2
        }
        if menuItem.action == #selector(menuRunAndReplaceResults(_:)) { return canRunQuery }
        if menuItem.action == #selector(menuNewCard(_:)) || menuItem.action == #selector(menuCollapseAllCards(_:))
            || menuItem.action == #selector(menuExpandAllCards(_:)) {
            return session.activeTab != nil
        }
        if menuItem.action == #selector(menuPreviousCard(_:)) || menuItem.action == #selector(menuNextCard(_:)) {
            return (session.activeTab?.document.cards.count ?? 0) >= 2
        }
        if menuItem.action == #selector(menuTagRow(_:)) {
            // `selectedDataRows()`, not `tagTargetDataRows()`: validation runs
            // on menu-open and key-equivalent resolution, which can happen long
            // after the last click, and `tagTargetDataRows()` starts from
            // `tableView.clickedRow`, which `ResultsTableView.mouseDown` never
            // resets (it never calls `super.mouseDown`, the one path that
            // clears clickedRow after a plain left-click — verified
            // empirically). The title must match what ⌘L actually acts on.
            let targets = resultsVC.selectedDataRows()
            menuItem.title = targets.count > 1
                ? "Add Tag to \(targets.count) Rows…"
                : "Add Tag…"
            // No source-table condition any more: matching needs columns and
            // values only, so every result is taggable.
            menuItem.toolTip = nil
            return !targets.isEmpty
        }
        if menuItem.action == #selector(menuManageTags(_:)) {
            // BOTH conditions `presentTagManageSheet` enforces, not just the
            // store one: a sheet needs a window to hang from, so testing the
            // tag list alone would enable the item into a beep.
            return resultsVC.isViewLoaded && resultsVC.view.window != nil
                && !TagStore.shared.tags.isEmpty
        }
        if menuItem.action == #selector(menuIncreaseEditorFont(_:)) {
            return editorPane.editorFontSize < FontSizeStepper.range.upperBound
        }
        if menuItem.action == #selector(menuDecreaseEditorFont(_:)) {
            return editorPane.editorFontSize > FontSizeStepper.range.lowerBound
        }
        return true
    }
}

// MARK: - Constraint helpers

private extension NSLayoutConstraint {
    /// A bottom pin that gives way when the pane is shorter than the view's
    /// own minimum (the load-more bar's 32pt, say) — which only happens while
    /// the view is hidden in the results-hidden layout. `NSSplitView` sizes
    /// its panes from their FITTING height, hidden children included, so a
    /// required pin here made the collapsed results pane 48pt instead of the
    /// bar's 32. At `.defaultHigh` the pin still holds in every layout the
    /// view is actually visible in.
    func yieldingBottom() -> NSLayoutConstraint {
        priority = .defaultHigh
        return self
    }
}
