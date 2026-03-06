import AppKit
import Combine

/// Main content area: editor panes + results grid.
/// Manages multiple EditorPaneVCs and query execution.
class ContentViewController: NSViewController {

    private let resultsVC = ResultsGridVC()
    private let splitView = NSSplitView()           // Vertical: panes on top, results on bottom
    private let paneSplitView = NSSplitView()       // Horizontal: side-by-side editor panes
    private let emptyState = NSView()

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

    override func loadView() {
        let container = NSView()
        self.view = container

        // Pane split view: horizontal split for side-by-side editor panes
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.delegate = self

        // Main split view: paneSplitView (top) + results (bottom)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autosaveName = "PharosEditorResultsSplit"

        addChild(resultsVC)

        // NSSplitView manages subview frames — do NOT disable autoresizing masks
        splitView.addSubview(paneSplitView)
        splitView.addSubview(resultsVC.view)

        // Empty state (no connection)
        setupEmptyState()

        container.addSubview(splitView)
        container.addSubview(emptyState)

        let safeTop = container.safeAreaLayoutGuide.topAnchor

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: safeTop),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

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

        // Observe state
        stateManager.$activeConnectionId
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
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &cancellables)

        stateManager.$activeSchema
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

        // Observe "insert text in editor" from schema browser context menu
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInsertTextInEditor(_:)),
            name: .insertTextInEditor, object: nil
        )

        updateVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Restore saved split ratio once the split view has real height
        if !hasSetInitialSplit, splitView.bounds.height > 0 {
            hasSetInitialSplit = true
            let saved = UserDefaults.standard.double(forKey: Self.splitRatioKey)
            let ratio = saved > 0 ? saved : 0.6
            let editorHeight = splitView.bounds.height * ratio
            splitView.setPosition(editorHeight, ofDividerAt: 0)
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

        // Add new panes
        for pane in panes where !currentPaneIds.contains(pane.id) {
            let paneVC = EditorPaneVC(paneId: pane.id)
            paneVC.delegate = self
            addChild(paneVC)
            paneSplitView.addSubview(paneVC.view)
            editorPanes.append(paneVC)
        }

        // Reorder to match state manager order
        let ordered = panes.compactMap { pane in
            editorPanes.first { $0.paneId == pane.id }
        }
        editorPanes = ordered

        // Handle expansion: hide non-expanded panes when one is expanded
        let expandedPane = panes.first(where: { $0.isExpanded })
        for paneVC in editorPanes {
            if let expanded = expandedPane {
                paneVC.view.isHidden = paneVC.paneId != expanded.id
            } else {
                paneVC.view.isHidden = false
            }
        }

        // Split evenly when adding a new pane
        if editorPanes.count > 1 && expandedPane == nil {
            DispatchQueue.main.async {
                let totalWidth = self.paneSplitView.bounds.width
                let paneWidth = totalWidth / CGFloat(self.editorPanes.count)
                for i in 0..<(self.editorPanes.count - 1) {
                    self.paneSplitView.setPosition(paneWidth * CGFloat(i + 1), ofDividerAt: i)
                }
            }
        }

        updateSplitViewVisibility()
    }

    // MARK: - Active Tab Changed (results grid update)

    private var lastActiveTabId: String?

    private func activeTabChanged(_ tabId: String?) {
        // Save grid state of the tab we're leaving
        if let previousTabId = lastActiveTabId {
            let gridState = resultsVC.captureGridState()
            stateManager.updateTab(id: previousTabId) { tab in
                tab.gridState = gridState
            }
        }
        lastActiveTabId = tabId

        guard let tabId, let tab = stateManager.tabs.first(where: { $0.id == tabId }) else {
            resultsVC.clear()
            updateSplitViewVisibility()
            return
        }

        updateSplitViewVisibility()

        // Update results grid for the new active tab
        if let pinnedResult = stateManager.pinnedResult {
            resultsVC.showResult(pinnedResult)
            resultsVC.setPinState(pinned: true, tabName: stateManager.pinnedTabName)
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

        // Show/hide history context for this tab
        if let historyTimestamp = tab.historyTimestamp {
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
            let selectedRows = dataIndices.compactMap { idx -> [String: AnyCodable]? in
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

        if hasConnection {
            stateManager.ensureTab()
        }

        updateSplitViewVisibility()
    }

    private func updateSplitViewVisibility() {
        let hasConnection: Bool
        if let activeId = stateManager.activeConnectionId {
            hasConnection = stateManager.status(for: activeId) == .connected
        } else {
            hasConnection = false
        }
        let hasTab = stateManager.activeTabId != nil
        splitView.isHidden = !hasConnection || !hasTab
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

        let querySQL = sql ?? focusedPaneVC?.getSQL() ?? ""
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
        focusedPaneVC?.clearErrorMarkers()

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
                        limit: limit,
                        schema: self.stateManager.activeSchema
                    )
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.result = result
                        }
                        if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showResult(result)
                        }
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
                    }
                } else {
                    let result = try await PharosCore.executeStatement(
                        connectionId: connectionId,
                        sql: trimmed,
                        schema: self.stateManager.activeSchema
                    )
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.executeResult = result
                        }
                        if self.stateManager.activeTabId == tabId {
                            self.resultsVC.showExecuteResult(result)
                        }
                        NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
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
                        self.markEditorError(message: message, sql: trimmed)
                    }
                }
            }
        }
    }

    /// Load more rows for pagination.
    private func loadMoreRows() {
        guard let connectionId = stateManager.activeConnectionId,
              stateManager.status(for: connectionId) == .connected,
              let tab = stateManager.activeTab,
              let existingResult = tab.result,
              existingResult.hasMore else { return }

        let sql = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = Int64(existingResult.rows.count)
        let limit = Int64(stateManager.settings.query.defaultLimit)

        resultsVC.setLoadingMore(true)

        Task {
            do {
                let moreResult = try await PharosCore.fetchMoreRows(
                    connectionId: connectionId,
                    sql: sql,
                    limit: limit,
                    offset: offset,
                    schema: self.stateManager.activeSchema
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

    @objc private func handleInsertTextInEditor(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        guard stateManager.activeTab != nil else { return }
        focusedPaneVC?.insertText(text)
        focusedPaneVC?.focus()
    }
}

// MARK: - Save Query (Cmd+S)

extension ContentViewController {

    @objc func menuSaveQuery(_: Any?) {
        guard let tab = stateManager.activeTab else { return }

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
        } else {
            presentSaveQuerySheet(tab: tab)
        }
    }

    @objc func menuSaveQueryAs(_: Any?) {
        guard let tab = stateManager.activeTab else { return }
        presentSaveQuerySheet(tab: tab)
    }

    private func presentSaveQuerySheet(tab: QueryTab) {
        let sheet = SaveQuerySheet(
            tabName: tab.name,
            sql: focusedPaneVC?.getSQL() ?? "",
            connectionId: stateManager.activeConnectionId,
            connectionName: stateManager.activeConnection?.name
        ) { [weak self] savedQuery in
            guard let self else { return }
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
        stateManager.closeTab(id: tabId)
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
        if splitView === self.splitView {
            return 100 // Minimum editor area height
        }
        return 100 // Minimum editor pane width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === self.splitView {
            return splitView.bounds.height - 60 // Minimum results height
        }
        return splitView.bounds.width - 100 // Minimum right editor pane width
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let notifSplit = notification.object as? NSSplitView,
              notifSplit === self.splitView else { return }
        guard hasSetInitialSplit, self.splitView.bounds.height > 0 else { return }
        let ratio = paneSplitView.frame.height / self.splitView.bounds.height
        UserDefaults.standard.set(ratio, forKey: Self.splitRatioKey)
    }
}
