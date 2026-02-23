import AppKit
import Combine

/// Main content area: tab bar + SQL editor + results grid.
/// Manages tab switching and query execution.
class ContentViewController: NSViewController {

    private let tabBar = QueryTabBar()
    private let editorVC = QueryEditorVC()
    private let resultsVC = ResultsGridVC()
    private let splitView = NSSplitView()
    private let emptyState = NSView()

    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasSetInitialSplit = false

    override func loadView() {
        let container = NSView()
        self.view = container

        // Tab bar
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelectTab = { [weak self] id in
            self?.stateManager.activeTabId = id
        }
        tabBar.onCloseTab = { [weak self] id in
            self?.stateManager.closeTab(id: id)
        }
        tabBar.onNewTab = { [weak self] in
            self?.stateManager.createTab()
        }
        tabBar.onDoubleClickTab = { [weak self] id in
            self?.renameTab(id: id)
        }

        // Split view: editor (top) + results (bottom)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autosaveName = "PharosEditorResultsSplit"

        addChild(editorVC)
        addChild(resultsVC)

        // NSSplitView manages subview frames — do NOT disable autoresizing masks
        splitView.addSubview(editorVC.view)
        splitView.addSubview(resultsVC.view)

        // Empty state (no connection)
        setupEmptyState()

        container.addSubview(tabBar)
        container.addSubview(splitView)
        container.addSubview(emptyState)

        let safeTop = container.safeAreaLayoutGuide.topAnchor

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: safeTop),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),

            splitView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyState.topAnchor.constraint(equalTo: safeTop),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Wire up execution
        editorVC.onExecute = { [weak self] sql in
            self?.executeQuery(sql)
        }

        // Observe state
        stateManager.$activeConnectionId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        stateManager.$activeTabId
            .receive(on: RunLoop.main)
            .sink { [weak self] tabId in self?.tabChanged(tabId) }
            .store(in: &cancellables)

        updateVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Set initial split position once (60% editor, 40% results)
        if !hasSetInitialSplit, splitView.bounds.height > 0 {
            hasSetInitialSplit = true
            let editorHeight = splitView.bounds.height * 0.6
            splitView.setPosition(editorHeight, ofDividerAt: 0)
        }
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
        let hasConnection: Bool
        if let activeId = stateManager.activeConnectionId {
            let status = stateManager.status(for: activeId)
            hasConnection = (status == .connected)
        } else {
            hasConnection = false
        }

        emptyState.isHidden = hasConnection
        tabBar.isHidden = !hasConnection
        splitView.isHidden = !hasConnection

        if hasConnection {
            stateManager.ensureTab()
        }
    }

    // MARK: - Tab Switching

    private func tabChanged(_ tabId: String?) {
        // Save cursor position of the tab we're leaving
        if let previousTabId = editorVC.tabId {
            let cursorPos = editorVC.getCursorPosition()
            stateManager.updateTab(id: previousTabId) { tab in
                tab.cursorPosition = cursorPos
            }
        }

        guard let tabId, let tab = stateManager.tabs.first(where: { $0.id == tabId }) else { return }

        editorVC.tabId = tabId
        editorVC.setSQL(tab.sql)
        editorVC.setCursorPosition(tab.cursorPosition)

        // Restore results if available
        if let result = tab.result {
            resultsVC.showResult(result)
        } else if let execResult = tab.executeResult {
            resultsVC.showExecuteResult(execResult)
        } else if let error = tab.error {
            resultsVC.showError(error)
        } else {
            resultsVC.clear()
        }

        editorVC.focus()
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
        guard let connectionId = stateManager.activeConnectionId,
              stateManager.status(for: connectionId) == .connected else { return }
        guard let tabId = stateManager.activeTabId else { return }

        let querySQL = sql ?? editorVC.getSQL()
        let trimmed = querySQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let queryId = UUID().uuidString

        // Mark tab as executing
        stateManager.updateTab(id: tabId) { tab in
            tab.isExecuting = true
            tab.queryId = queryId
            tab.error = nil
            tab.result = nil
            tab.executeResult = nil
        }
        resultsVC.clear()

        let limit = Int32(stateManager.settings.query.defaultLimit)
        let isSelectLike = trimmed.uppercased().hasPrefix("SELECT")
            || trimmed.uppercased().hasPrefix("WITH")
            || trimmed.uppercased().hasPrefix("EXPLAIN")
            || trimmed.uppercased().hasPrefix("SHOW")
            || trimmed.uppercased().hasPrefix("TABLE")
            || trimmed.uppercased().hasPrefix("VALUES")

        Task {
            do {
                if isSelectLike {
                    let result = try await PharosCore.executeQuery(
                        connectionId: connectionId,
                        sql: trimmed,
                        queryId: queryId,
                        limit: limit
                    )
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.result = result
                            tab.executionTime = result.executionTimeMs
                        }
                        if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showResult(result)
                        }
                    }
                } else {
                    let result = try await PharosCore.executeStatement(
                        connectionId: connectionId,
                        sql: trimmed
                    )
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.executeResult = result
                            tab.executionTime = result.executionTimeMs
                        }
                        if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showExecuteResult(result)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    self.stateManager.updateTab(id: tabId) { tab in
                        tab.isExecuting = false
                        tab.queryId = nil
                        tab.error = message
                    }
                    if self.stateManager.activeTabId == tabId {
                        self.resultsVC.showError(message)
                    }
                }
            }
        }
    }

    /// Cancel a running query in the active tab.
    func cancelQuery() {
        guard let connectionId = stateManager.activeConnectionId,
              let tab = stateManager.activeTab,
              tab.isExecuting,
              let queryId = tab.queryId else { return }

        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: queryId)
        }
    }
}

// MARK: - Menu Actions (Responder Chain)

extension ContentViewController {

    @objc func menuRunQuery(_ sender: Any?) {
        executeQuery()
    }

    @objc func menuCancelQuery(_ sender: Any?) {
        cancelQuery()
    }

    @objc func menuNewTab(_ sender: Any?) {
        stateManager.createTab()
    }

    @objc func menuCloseTab(_ sender: Any?) {
        guard let tabId = stateManager.activeTabId else { return }
        stateManager.closeTab(id: tabId)
    }

    @objc func menuReopenTab(_ sender: Any?) {
        stateManager.reopenLastClosedTab()
    }

    @objc func menuSelectTab(_ sender: NSMenuItem) {
        let index = sender.tag // Zero-based
        stateManager.selectTabByIndex(index)
    }
}

// MARK: - NSSplitViewDelegate

extension ContentViewController: NSSplitViewDelegate {

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        100 // Minimum editor height
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - 60 // Minimum results height
    }
}
