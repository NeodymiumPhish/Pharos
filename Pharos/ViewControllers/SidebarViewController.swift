import AppKit
import Combine

class SidebarViewController: NSViewController {

    private let topSegment = NSSegmentedControl()
    private let navigatorContainer = NSView()
    private let libraryContainer = NSView()

    // Library sub-panel switching
    private let librarySegment = NSSegmentedControl()
    private let savedContainer = NSView()
    private let historyContainer = NSView()

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

        // Top segmented control: Navigator | Library
        topSegment.segmentCount = 2
        topSegment.setLabel("Navigator", forSegment: 0)
        topSegment.setLabel("Library", forSegment: 1)
        topSegment.segmentStyle = .texturedSquare
        topSegment.selectedSegment = 0
        topSegment.target = self
        topSegment.action = #selector(topSegmentChanged(_:))
        topSegment.translatesAutoresizingMaskIntoConstraints = false

        navigatorContainer.translatesAutoresizingMaskIntoConstraints = false
        libraryContainer.translatesAutoresizingMaskIntoConstraints = false
        libraryContainer.isHidden = true

        container.addSubview(topSegment)
        container.addSubview(navigatorContainer)
        container.addSubview(libraryContainer)

        NSLayoutConstraint.activate([
            topSegment.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            topSegment.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            topSegment.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            navigatorContainer.topAnchor.constraint(equalTo: topSegment.bottomAnchor, constant: 8),
            navigatorContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigatorContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navigatorContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            libraryContainer.topAnchor.constraint(equalTo: topSegment.bottomAnchor, constant: 8),
            libraryContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            libraryContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            libraryContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Embed schema browser in navigator container
        embedChild(schemaBrowser, in: navigatorContainer)

        // Build library panel with Saved / History sub-segments
        setupLibraryPanel()

        // Observe connection changes
        stateManager.$activeConnectionId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activeConnectionChanged() }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.connectionStatusChanged() }
            .store(in: &cancellables)
    }

    // MARK: - Library Panel Setup

    private func setupLibraryPanel() {
        librarySegment.segmentCount = 2
        librarySegment.setLabel("Saved", forSegment: 0)
        librarySegment.setLabel("History", forSegment: 1)
        librarySegment.segmentStyle = .texturedSquare
        librarySegment.selectedSegment = 0
        librarySegment.target = self
        librarySegment.action = #selector(librarySegmentChanged(_:))
        librarySegment.translatesAutoresizingMaskIntoConstraints = false

        savedContainer.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.translatesAutoresizingMaskIntoConstraints = false
        historyContainer.isHidden = true

        libraryContainer.addSubview(librarySegment)
        libraryContainer.addSubview(savedContainer)
        libraryContainer.addSubview(historyContainer)

        NSLayoutConstraint.activate([
            librarySegment.topAnchor.constraint(equalTo: libraryContainer.topAnchor),
            librarySegment.leadingAnchor.constraint(equalTo: libraryContainer.leadingAnchor, constant: 12),
            librarySegment.trailingAnchor.constraint(equalTo: libraryContainer.trailingAnchor, constant: -12),

            savedContainer.topAnchor.constraint(equalTo: librarySegment.bottomAnchor, constant: 4),
            savedContainer.leadingAnchor.constraint(equalTo: libraryContainer.leadingAnchor),
            savedContainer.trailingAnchor.constraint(equalTo: libraryContainer.trailingAnchor),
            savedContainer.bottomAnchor.constraint(equalTo: libraryContainer.bottomAnchor),

            historyContainer.topAnchor.constraint(equalTo: librarySegment.bottomAnchor, constant: 4),
            historyContainer.leadingAnchor.constraint(equalTo: libraryContainer.leadingAnchor),
            historyContainer.trailingAnchor.constraint(equalTo: libraryContainer.trailingAnchor),
            historyContainer.bottomAnchor.constraint(equalTo: libraryContainer.bottomAnchor),
        ])

        embedChild(savedQueries, in: savedContainer)
        embedChild(queryHistory, in: historyContainer)
    }

    // MARK: - Segment Actions

    @objc private func topSegmentChanged(_ sender: NSSegmentedControl) {
        let isNavigator = sender.selectedSegment == 0
        navigatorContainer.isHidden = !isNavigator
        libraryContainer.isHidden = isNavigator

        // Refresh library data when switching to it
        if !isNavigator {
            savedQueries.reload()
            queryHistory.reload(connectionId: stateManager.activeConnectionId)
        }
    }

    @objc private func librarySegmentChanged(_ sender: NSSegmentedControl) {
        let isSaved = sender.selectedSegment == 0
        savedContainer.isHidden = !isSaved
        historyContainer.isHidden = isSaved
    }

    // MARK: - Connection State

    private func activeConnectionChanged() {
        guard let activeId = stateManager.activeConnectionId else {
            schemaBrowser.clear()
            return
        }
        let status = stateManager.status(for: activeId)
        if status == .connected {
            schemaBrowser.loadSchemas(connectionId: activeId)
        } else {
            schemaBrowser.clear()
        }
    }

    private func connectionStatusChanged() {
        guard let activeId = stateManager.activeConnectionId else { return }
        let status = stateManager.status(for: activeId)
        if status == .connected {
            schemaBrowser.loadSchemas(connectionId: activeId)
        } else if status == .disconnected || status == .error {
            schemaBrowser.clear()
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
