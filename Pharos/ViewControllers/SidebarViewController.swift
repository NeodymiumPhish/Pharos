import AppKit
import Combine

class SidebarViewController: NSViewController {

    private let searchField = NSSearchField()
    private let segmentBar = NSSegmentedControl()
    private let contentArea = NSView()

    // Containers for each panel (only one visible at a time)
    private let savedContainer = NSView()
    private let historyContainer = NSView()
    private let browserContainer = NSView()

    // Child view controllers
    let schemaBrowser = SchemaBrowserVC()
    let savedQueries = SavedQueriesVC()
    let queryHistory = QueryHistoryVC()

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // Search field
        searchField.placeholderString = "Filter"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        // Segment bar (bottom) — icon-only segments
        segmentBar.segmentCount = 3
        segmentBar.trackingMode = .selectOne
        segmentBar.segmentStyle = .capsule
        segmentBar.selectedSegment = 0
        segmentBar.target = self
        segmentBar.action = #selector(segmentChanged(_:))
        segmentBar.translatesAutoresizingMaskIntoConstraints = false

        let segConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        segmentBar.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: "Queries")?.withSymbolConfiguration(segConfig), forSegment: 0)
        segmentBar.setImage(NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")?.withSymbolConfiguration(segConfig), forSegment: 1)
        segmentBar.setImage(NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: "Database")?.withSymbolConfiguration(segConfig), forSegment: 2)

        segmentBar.setToolTip("Query Library", forSegment: 0)
        segmentBar.setToolTip("Results History", forSegment: 1)
        segmentBar.setToolTip("Database Navigation", forSegment: 2)

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

        // Layout: segment bar at top, then search field, then content area
        container.addSubview(segmentBar)
        container.addSubview(searchField)
        container.addSubview(contentArea)

        NSLayoutConstraint.activate([
            segmentBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            segmentBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            searchField.topAnchor.constraint(equalTo: segmentBar.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            contentArea.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            contentArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Observe connection changes (deduplicate to avoid redundant reloads on tab switch)
        stateManager.$activeConnectionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activeConnectionChanged() }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.connectionStatusChanged() }
            .store(in: &cancellables)

        stateManager.$activeSchema
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
        stateManager.$activeTabId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let savedQueryId = self?.stateManager.activeTab?.savedQueryId
                self?.savedQueries.highlightQuery(id: savedQueryId)
            }
            .store(in: &cancellables)

        // Refresh saved queries when they change (save, move, delete)
        NotificationCenter.default.addObserver(
            forName: .savedQueriesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.savedQueries.reload()
            // Re-apply highlight (savedQueryId may have changed after save)
            let savedQueryId = self?.stateManager.activeTab?.savedQueryId
            self?.savedQueries.highlightQuery(id: savedQueryId)
        }

        // Manual refresh from connection menu
        NotificationCenter.default.addObserver(
            forName: .connectionMetadataRefreshRequested, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self,
                  let activeId = self.stateManager.activeConnectionId,
                  self.stateManager.status(for: activeId) == .connected else { return }
            self.schemaBrowser.loadSchemas(connectionId: activeId, force: true)
        }
    }

    // MARK: - Segment Switching

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        savedContainer.isHidden = (index != 0)
        historyContainer.isHidden = (index != 1)
        browserContainer.isHidden = (index != 2)

        // Re-apply search filter to the newly visible child
        applyFilterToVisibleChild(searchField.stringValue)
    }

    // MARK: - Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilterToVisibleChild(sender.stringValue)
    }

    private func applyFilterToVisibleChild(_ text: String) {
        // Clear all filters first
        schemaBrowser.clearFilter()
        savedQueries.clearFilter()
        queryHistory.clearFilter()

        guard !text.isEmpty else { return }

        switch segmentBar.selectedSegment {
        case 0: savedQueries.applyFilter(text)
        case 1: queryHistory.applyFilter(text)
        case 2: schemaBrowser.applyFilter(text)
        default: break
        }
    }

    // MARK: - Connection State

    private func activeConnectionChanged() {
        guard let activeId = stateManager.activeConnectionId else {
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
        guard let activeId = stateManager.activeConnectionId else { return }
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
