import AppKit
import Combine

class SidebarViewController: NSViewController {

    private let navigatorSelector = NavigatorSelector()
    private let filterBar = SidebarFilterBar()
    private let contentArea = NSView()

    /// Which navigator is showing and what each one is filtered by. Seeded
    /// from the preference in `loadView`.
    private var filterState = NavigatorFilterState()

    // Containers for each panel (only one visible at a time)
    private let savedContainer = NSView()
    private let historyContainer = NSView()
    private let browserContainer = NSView()

    // Child view controllers
    let schemaBrowser = SchemaBrowserVC()
    let savedQueries = SavedQueriesVC()
    let queryHistory = QueryHistoryVC()

    let session: WindowSession
    private let stateManager = AppStateManager.shared

    init(session: WindowSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func loadView() {
        // A plain root. The split view item (`sidebarWithViewController:`)
        // supplies the sidebar material; a vibrancy view of our own here would
        // stack a second material under the system one.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // A plain NSView is accessibility-ignored by default and its
        // identifier would never surface — force it to be a real element.
        container.setAccessibilityElement(true)
        container.setAccessibilityIdentifier("pane.sidebar")
        self.view = container

        // Navigator selector (top) — icon only, Xcode's navigator chooser.
        navigatorSelector.translatesAutoresizingMaskIntoConstraints = false
        navigatorSelector.onChange = { [weak self] navigator in
            self?.select(navigator)
        }

        // Filter bar (bottom) — "+" pull-down and the filter field.
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.onTextChanged = { [weak self] text in
            self?.filterTextChanged(text)
        }
        filterBar.onNewQuery = { [weak self] in
            self?.savedQueries.createNewQuery()
        }
        filterBar.onNewFolder = { [weak self] in
            self?.savedQueries.createNewFolder()
        }

        // Content area holds all three containers
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        savedContainer.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.translatesAutoresizingMaskIntoConstraints = false
        browserContainer.translatesAutoresizingMaskIntoConstraints = false

        historyContainer.isHidden = true
        browserContainer.isHidden = true

        contentArea.addSubview(savedContainer)
        contentArea.addSubview(historyContainer)
        contentArea.addSubview(browserContainer)

        // Each container fills the entire content area
        for child in [savedContainer, historyContainer, browserContainer] {
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: contentArea.topAnchor),
                child.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            ])
        }

        // Embed child VCs
        embedChild(savedQueries, in: savedContainer)
        embedChild(queryHistory, in: historyContainer)
        embedChild(schemaBrowser, in: browserContainer)

        // Layout: navigator selector at the top, the lists in the middle, the
        // filter bar along the bottom.
        container.addSubview(navigatorSelector)
        container.addSubview(contentArea)
        container.addSubview(filterBar)

        NSLayoutConstraint.activate([
            navigatorSelector.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            navigatorSelector.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigatorSelector.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            contentArea.topAnchor.constraint(equalTo: navigatorSelector.bottomAnchor, constant: 4),
            contentArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: filterBar.topAnchor),

            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterBar.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: SidebarFilterBar.height),
        ])

        // Open on the navigator the user was last reading.
        filterState = NavigatorFilterState(current: SidebarNavigatorPrefs.lastNavigator)
        navigatorSelector.selected = filterState.current
        select(filterState.current)

        // Observe connection changes (deduplicate to avoid redundant reloads on tab switch)
        session.$activeConnectionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activeConnectionChanged() }
            .store(in: &cancellables)

        // Dedup before scheduling — unrelated connection-status churn (e.g. a
        // background pool's idle ticks) shouldn't reload the schema browser.
        stateManager.$connectionStatuses
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.connectionStatusChanged() }
            .store(in: &cancellables)

        session.$activeSchema
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] schema in
                if let schema {
                    self?.schemaBrowser.showSchema(schema)
                } else {
                    self?.schemaBrowser.showAllSchemas()
                }
            }
            .store(in: &cancellables)

        // Highlight saved query that's open in the active tab
        session.$activeTabId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let savedQueryId = self?.session.activeTab?.savedQueryId
                self?.savedQueries.highlightQuery(id: savedQueryId)
            }
            .store(in: &cancellables)

        // Refresh saved queries when they change (save, move, delete)
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .savedQueriesDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.savedQueries.reload()
                // Re-apply highlight (savedQueryId may have changed after save)
                let savedQueryId = self?.session.activeTab?.savedQueryId
                self?.savedQueries.highlightQuery(id: savedQueryId)
            }
        )

        // Manual refresh from connection menu
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .connectionMetadataRefreshRequested, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self,
                      let activeId = self.session.activeConnectionId,
                      self.stateManager.status(for: activeId) == .connected else { return }
                self.schemaBrowser.loadSchemas(connectionId: activeId, force: true)
            }
        )
    }

    // MARK: - Navigator Switching

    /// Shows one navigator: swaps the lists, restores that navigator's own
    /// filter text, and remembers the choice for the next launch.
    func showNavigator(_ navigator: Navigator) {
        guard navigator != filterState.current else { return }
        navigatorSelector.selected = navigator
        select(navigator)
    }

    /// The navigator on screen.
    var currentNavigator: Navigator { filterState.current }

    /// Put the caret in the filter field (View ▸ Filter in Navigator).
    func focusFilter() {
        filterBar.focus()
    }

    private func select(_ navigator: Navigator) {
        filterState.select(navigator)

        savedContainer.isHidden = (navigator != .library)
        historyContainer.isHidden = (navigator != .history)
        browserContainer.isHidden = (navigator != .schema)

        // Only the Query Library holds things the user can create.
        filterBar.showsAddButton = (navigator == .library)

        // A pending debounce belongs to the navigator that is leaving; firing
        // it now would filter the incoming list with the outgoing list's text.
        pendingFilterWorkItem?.cancel()
        let text = filterState.currentText
        filterBar.filterField.stringValue = text
        applyFilterToVisibleChild(text)

        SidebarNavigatorPrefs.lastNavigator = navigator
    }

    // MARK: - Filtering

    /// Pending debounced filter dispatch. Coalesces keystrokes so the filter
    /// (which can rebuild large schema trees and hit the SQLite-backed query
    /// history) runs at most once per ~150ms while the user is typing.
    private var pendingFilterWorkItem: DispatchWorkItem?

    private func filterTextChanged(_ text: String) {
        filterState.setText(text)
        pendingFilterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyFilterToVisibleChild(text)
        }
        pendingFilterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func applyFilterToVisibleChild(_ text: String) {
        // Clear all filters first
        schemaBrowser.clearFilter()
        savedQueries.clearFilter()
        queryHistory.clearFilter()

        guard !text.isEmpty else { return }

        switch filterState.current {
        case .library: savedQueries.applyFilter(text)
        case .history: queryHistory.applyFilter(text)
        case .schema: schemaBrowser.applyFilter(text)
        }
    }

    /// Sets the filter text from outside (the toolbar's filter item) and
    /// applies it to the visible list at once, keeping the sidebar's own
    /// field in step.
    func setFilterText(_ text: String) {
        filterState.setText(text)
        filterBar.filterField.stringValue = text
        pendingFilterWorkItem?.cancel()
        applyFilterToVisibleChild(text)
    }

    // MARK: - Connection State

    private func activeConnectionChanged() {
        guard let activeId = session.activeConnectionId else {
            schemaBrowser.clear()
            savedQueries.reload()
            return
        }
        let status = stateManager.status(for: activeId)
        if status == .connected {
            schemaBrowser.loadSchemas(connectionId: activeId)
        } else {
            schemaBrowser.clear()
        }

        savedQueries.reload()
        queryHistory.reload()
    }

    private func connectionStatusChanged() {
        guard let activeId = session.activeConnectionId else { return }
        let status = stateManager.status(for: activeId)
        if status == .connected {
            schemaBrowser.loadSchemas(connectionId: activeId)
        } else if status == .disconnected || status == .error {
            // Clear only this connection's cache; preserve other connections' caches
            schemaBrowser.clearConnection(activeId)
        }
    }

    // MARK: - Helpers

    private func embedChild(_ child: NSViewController, in container: NSView) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
