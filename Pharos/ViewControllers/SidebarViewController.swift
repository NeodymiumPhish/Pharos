import AppKit
import Combine

class SidebarViewController: NSViewController {

    private let filterBar = SidebarFilterBar()
    private let contentArea = NSView()

    /// Which navigator is showing and what each one is filtered by. Seeded
    /// from the preference in `loadView`.
    private var filterState = NavigatorFilterState()

    // Containers for each navigator (only one visible at a time). The
    // Library's holds its scope bar and its two lists.
    private let libraryContainer = NSView()
    private let savedContainer = NSView()
    private let historyContainer = NSView()
    private let browserContainer = NSView()
    private let filesContainer = NSView()
    /// The Library's scope bar: Sessions | History.
    let libraryScopeControl = NSSegmentedControl(
        labels: LibraryScope.allCases.map(\.shortTitle), trackingMode: .selectOne, target: nil, action: nil)

    // Child view controllers
    let schemaBrowser = SchemaBrowserVC()
    let savedQueries = SavedQueriesVC()
    let queryHistory = QueryHistoryVC()
    /// The Files navigator: opened DuckDB databases and data files.
    let filesNavigator = FilesNavigatorVC()

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
        // Content area holds the three navigators' containers.
        for v in [contentArea, libraryContainer, savedContainer, historyContainer, browserContainer, filesContainer,
                  libraryScopeControl] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        historyContainer.isHidden = true
        browserContainer.isHidden = true
        filesContainer.isHidden = true

        contentArea.addSubview(libraryContainer)
        contentArea.addSubview(browserContainer)
        contentArea.addSubview(filesContainer)

        // Each container fills the entire content area
        for child in [libraryContainer, browserContainer, filesContainer] {
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: contentArea.topAnchor),
                child.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            ])
        }

        // The Library: its scope bar under the toolbar glass (the safe area),
        // then Sessions or Results History below it. The lists start under the
        // bar rather than scrolling under the glass: a bar the list scrolled
        // under would hide the rows behind it.
        libraryScopeControl.segmentStyle = .automatic
        libraryScopeControl.controlSize = .small
        libraryScopeControl.target = self
        libraryScopeControl.action = #selector(libraryScopeChosen(_:))
        libraryScopeControl.setAccessibilityLabel(String(localized: "Library"))
        libraryScopeControl.setAccessibilityIdentifier("sidebar.library.scope")
        for scope in LibraryScope.allCases {
            libraryScopeControl.setToolTip(scope.title, forSegment: scope.rawValue)
        }
        libraryContainer.addSubview(libraryScopeControl)
        libraryContainer.addSubview(savedContainer)
        libraryContainer.addSubview(historyContainer)
        NSLayoutConstraint.activate([
            libraryScopeControl.topAnchor.constraint(equalTo: libraryContainer.safeAreaLayoutGuide.topAnchor, constant: 6),
            libraryScopeControl.leadingAnchor.constraint(equalTo: libraryContainer.leadingAnchor, constant: 10),
            libraryScopeControl.trailingAnchor.constraint(equalTo: libraryContainer.trailingAnchor, constant: -10),
        ])
        for list in [savedContainer, historyContainer] {
            NSLayoutConstraint.activate([
                list.topAnchor.constraint(equalTo: libraryScopeControl.bottomAnchor, constant: 6),
                list.leadingAnchor.constraint(equalTo: libraryContainer.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: libraryContainer.trailingAnchor),
                list.bottomAnchor.constraint(equalTo: libraryContainer.bottomAnchor),
            ])
        }

        // Embed child VCs
        embedChild(savedQueries, in: savedContainer)
        embedChild(queryHistory, in: historyContainer)
        embedChild(schemaBrowser, in: browserContainer)
        embedChild(filesNavigator, in: filesContainer)

        // Layout: the lists fill the pane, the filter bar along the bottom.
        // The navigator chooser is a toolbar item now (NavigatorToolbarGroup),
        // not a row in here.
        container.addSubview(contentArea)
        container.addSubview(filterBar)

        NSLayoutConstraint.activate([
            // Pinned to the container, NOT to the safe area: the lists scroll
            // UNDER the toolbar glass, as Xcode's and Calendar's do. Each list's
            // NSScrollView has automaticallyAdjustsContentInsets on (the
            // default), which supplies the titlebar inset. Pinning to the safe
            // area as well would inset the content twice.
            contentArea.topAnchor.constraint(equalTo: container.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: filterBar.topAnchor),

            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterBar.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: SidebarFilterBar.height),
        ])

        // Open on the navigator the user was last reading.
        filterState = NavigatorFilterState(current: SidebarNavigatorPrefs.lastNavigator,
                                           libraryScope: SidebarNavigatorPrefs.libraryScope)
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
            .sink { [weak self] _ in self?.applyActiveSchemaToBrowser() }
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
                // The block is `@Sendable`, so `queue: .main` does not tell
                // the compiler this runs on the main actor; assert it.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.savedQueries.reload()
                    // Re-apply highlight (savedQueryId may have changed after save)
                    let savedQueryId = self.session.activeTab?.savedQueryId
                    self.savedQueries.highlightQuery(id: savedQueryId)
                }
            }
        )

        // Manual refresh from connection menu
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .connectionMetadataRefreshRequested, object: nil, queue: .main
            ) { [weak self] note in
                // `@Sendable` block again — assert the main actor `queue: .main`
                // already guarantees, as the observer above does.
                let target = note.object as? String
                MainActor.assumeIsolated {
                    guard let self,
                          let activeId = self.session.activeConnectionId,
                          target == nil || target == activeId,
                          self.stateManager.status(for: activeId) == .connected else { return }
                    self.schemaBrowser.loadSchemas(connectionId: activeId, force: true)
                    self.applyActiveSchemaToBrowser()
                }
            }
        )
    }

    // MARK: - Navigator Switching

    /// Shows one navigator: swaps the lists, restores that navigator's own
    /// filter text, and remembers the choice for the next launch.
    func showNavigator(_ navigator: Navigator) {
        guard navigator != filterState.current else { return }
        select(navigator)
    }

    /// The navigator on screen.
    var currentNavigator: Navigator { filterState.current }

    /// Fired whenever the navigator on screen changes, including the restore
    /// at launch. The toolbar's navigator group uses it to keep its lit
    /// segment true when the change came from the menu rather than the group.
    var onNavigatorChanged: ((Navigator) -> Void)?

    /// Put the caret in the filter field (View ▸ Filter in Navigator).
    func focusFilter() {
        filterBar.focus()
    }

    /// Show the Library on one of its two lists (View ▸ Navigators ▸
    /// Sessions / Results History, and the scope bar).
    func showLibrary(_ scope: LibraryScope) {
        filterState.selectScope(scope)
        SidebarNavigatorPrefs.libraryScope = scope
        select(.library)
    }

    @objc private func libraryScopeChosen(_ sender: NSSegmentedControl) {
        guard let scope = LibraryScope(rawValue: sender.selectedSegment) else { return }
        showLibrary(scope)
    }

    private func select(_ navigator: Navigator) {
        filterState.select(navigator)
        let list = filterState.currentList

        libraryContainer.isHidden = (navigator != .library)
        savedContainer.isHidden = (list != .sessions)
        historyContainer.isHidden = (list != .history)
        browserContainer.isHidden = (navigator != .schema)
        filesContainer.isHidden = (navigator != .files)
        libraryScopeControl.selectedSegment = filterState.libraryScope.rawValue

        // Only the Sessions list holds things the user can create here.
        filterBar.configureAddControl(for: list)

        // A pending debounce belongs to the list that is leaving; firing it
        // now would filter the incoming list with the outgoing list's text.
        pendingFilterWorkItem?.cancel()
        let text = filterState.currentText
        filterBar.filterField.stringValue = text
        applyFilterToVisibleChild(text)

        SidebarNavigatorPrefs.lastNavigator = navigator

        // The toolbar's navigator group follows this, so ⌥⌘1–4 light the
        // right segment. Held weakly by the toolbar controller.
        onNavigatorChanged?(navigator)
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
        filesNavigator.clearFilter()

        guard !text.isEmpty else { return }

        switch filterState.currentList {
        case .sessions: savedQueries.applyFilter(text)
        case .history: queryHistory.applyFilter(text)
        case .schema: schemaBrowser.applyFilter(text)
        case .files: filesNavigator.applyFilter(text)
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
            applyActiveSchemaToBrowser()
        } else {
            schemaBrowser.clear()
        }

        savedQueries.reload()
        queryHistory.reload()
    }

    /// Pins the session's schema in the schema browser.
    ///
    /// Pushed after every load as well as observed. The browser drops its pin
    /// in `clear()` and `clearConnection(_:)`, while `session.activeSchema`
    /// keeps its value across a disconnect — and the `$activeSchema`
    /// publisher is deduplicated, so it has nothing to say when the value has
    /// not changed. Re-asserting the pin wherever the tree is (re)loaded makes
    /// "the browser shows what the editor's selector reads" an invariant
    /// instead of something that depends on the order two publishers fire in.
    /// `showSchema` ignores a pin it already holds, so the extra calls cost
    /// nothing.
    private func applyActiveSchemaToBrowser() {
        if let schema = session.activeSchema {
            schemaBrowser.showSchema(schema)
        } else {
            schemaBrowser.showAllSchemas()
        }
    }

    private func connectionStatusChanged() {
        guard let activeId = session.activeConnectionId else { return }
        let status = stateManager.status(for: activeId)
        if status == .connected {
            schemaBrowser.loadSchemas(connectionId: activeId)
            applyActiveSchemaToBrowser()
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
