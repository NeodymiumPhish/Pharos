import AppKit
import Combine

class SidebarViewController: NSViewController, NSSplitViewDelegate {

    private let searchField = NSSearchField()
    private let splitView = NSSplitView()

    // Library pane (top)
    private let libraryContainer = NSView()
    private let librarySegment = NSSegmentedControl()
    private let savedContainer = NSView()
    private let historyContainer = NSView()

    // Navigator pane (bottom)
    private let navigatorContainer = NSView()

    // Child view controllers
    let schemaBrowser = SchemaBrowserVC()
    let savedQueries = SavedQueriesVC()
    let queryHistory = QueryHistoryVC()

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var didSetInitialPosition = false

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // Unified search field
        searchField.placeholderString = "Filter"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        // Split view — horizontal divider (top/bottom)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autosaveName = "PharosSidebarInternalSplit"
        splitView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            splitView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Build panes
        setupLibraryPane()
        setupNavigatorPane()

        splitView.addSubview(libraryContainer)
        splitView.addSubview(navigatorContainer)

        // Observe connection changes
        stateManager.$activeConnectionId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activeConnectionChanged() }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.connectionStatusChanged() }
            .store(in: &cancellables)

        stateManager.$activeSchema
            .receive(on: RunLoop.main)
            .sink { [weak self] schema in
                if let schema {
                    self?.schemaBrowser.showSchema(schema)
                } else {
                    self?.schemaBrowser.showAllSchemas()
                }
            }
            .store(in: &cancellables)

        // Refresh saved queries when they change (save, move, delete)
        NotificationCenter.default.addObserver(
            forName: .savedQueriesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.savedQueries.reload(connectionId: self?.stateManager.activeConnectionId)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Set initial 50/50 split (once, before autosave restores)
        if !didSetInitialPosition && splitView.bounds.height > 0 {
            didSetInitialPosition = true
            splitView.setPosition(splitView.bounds.height / 2, ofDividerAt: 0)
        }
    }

    // MARK: - Library Pane (Top)

    private func setupLibraryPane() {
        libraryContainer.translatesAutoresizingMaskIntoConstraints = false

        // Header label
        let header = NSTextField(labelWithString: "Library")
        header.font = .systemFont(ofSize: 11, weight: .bold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        // Segmented control: Saved | History
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

        libraryContainer.addSubview(header)
        libraryContainer.addSubview(librarySegment)
        libraryContainer.addSubview(savedContainer)
        libraryContainer.addSubview(historyContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: libraryContainer.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: libraryContainer.leadingAnchor, constant: 12),

            librarySegment.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
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

    // MARK: - Navigator Pane (Bottom)

    private func setupNavigatorPane() {
        navigatorContainer.translatesAutoresizingMaskIntoConstraints = false

        // Header label
        let header = NSTextField(labelWithString: "Navigator")
        header.font = .systemFont(ofSize: 11, weight: .bold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let browserContainer = NSView()
        browserContainer.translatesAutoresizingMaskIntoConstraints = false

        navigatorContainer.addSubview(header)
        navigatorContainer.addSubview(browserContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: navigatorContainer.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: navigatorContainer.leadingAnchor, constant: 12),

            browserContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            browserContainer.leadingAnchor.constraint(equalTo: navigatorContainer.leadingAnchor),
            browserContainer.trailingAnchor.constraint(equalTo: navigatorContainer.trailingAnchor),
            browserContainer.bottomAnchor.constraint(equalTo: navigatorContainer.bottomAnchor),
        ])

        embedChild(schemaBrowser, in: browserContainer)
    }

    // MARK: - Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        if text.isEmpty {
            schemaBrowser.clearFilter()
            savedQueries.clearFilter()
            queryHistory.clearFilter()
        } else {
            schemaBrowser.applyFilter(text)
            savedQueries.applyFilter(text)
            queryHistory.applyFilter(text)
        }
    }

    // MARK: - Segment Actions

    @objc private func librarySegmentChanged(_ sender: NSSegmentedControl) {
        let isSaved = sender.selectedSegment == 0
        savedContainer.isHidden = !isSaved
        historyContainer.isHidden = isSaved
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 80
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return splitView.bounds.height - 80
    }

    // MARK: - Connection State

    private func activeConnectionChanged() {
        guard let activeId = stateManager.activeConnectionId else {
            schemaBrowser.clear()
            savedQueries.reload(connectionId: nil)
            return
        }
        let status = stateManager.status(for: activeId)
        if status == .connected {
            schemaBrowser.loadSchemas(connectionId: activeId)
        } else {
            schemaBrowser.clear()
        }

        // Reload library data (always visible now)
        savedQueries.reload(connectionId: activeId)
        queryHistory.reload(connectionId: activeId)
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
