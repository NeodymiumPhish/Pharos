import AppKit
import Combine

/// Delegate for EditorPaneVC events that need to be handled by the parent.
protocol EditorPaneDelegate: AnyObject {
    func editorPane(_ pane: EditorPaneVC, didRequestClosePane paneId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestExpandPane paneId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestAddPane paneId: String)
    func editorPane(_ pane: EditorPaneVC, didFocus paneId: String)
    func editorPane(_ pane: EditorPaneVC, didChangeActiveTab tabId: String?)
    func editorPane(_ pane: EditorPaneVC, didRequestRenameTab tabId: String)
    func editorPaneDidRequestRunQuery(_ pane: EditorPaneVC)
    func editorPaneDidRequestCancelQuery(_ pane: EditorPaneVC)
    func editorPaneDidRequestSave(_ pane: EditorPaneVC)
    func editorPaneDidRequestSaveAs(_ pane: EditorPaneVC)
    func editorPane(_ pane: EditorPaneVC, didRequestRunSegment segment: SQLSegment)
    func editorPane(_ pane: EditorPaneVC, didEditText paneId: String)
}

/// Self-contained editor pane that owns a PaneTabBar and a QueryEditorVC.
/// Each pane manages its own set of tabs independently.
class EditorPaneVC: NSViewController {

    let paneId: String
    let editorVC = QueryEditorVC()
    private(set) var paneTabBar: PaneTabBar!

    // Editor toolbar (below tab bar)
    private let editorToolbar = NSView()
    private let formatButton = NSButton()
    private let runStopButton = NSButton()
    private let saveDropdown = NSPopUpButton(frame: .zero, pullsDown: true)
    private var isExecuting = false

    // Connection / Schema selectors (in editor toolbar, right side)
    private let connectionPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let schemaPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let schemaSpinner = NSProgressIndicator()

    weak var delegate: EditorPaneDelegate?

    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(paneId: String) {
        self.paneId = paneId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View Lifecycle

    private let tabBarHeight: CGFloat = 32
    private let editorToolbarHeight: CGFloat = 32
    private var totalHeaderHeight: CGFloat { tabBarHeight + editorToolbarHeight }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        // Tab bar
        paneTabBar = PaneTabBar(paneId: paneId)
        paneTabBar.translatesAutoresizingMaskIntoConstraints = false

        paneTabBar.onSelectTab = { [weak self] tabId in
            guard let self else { return }
            self.stateManager.selectTab(id: tabId, inPane: self.paneId)
        }
        paneTabBar.onCloseTab = { [weak self] tabId in
            guard let self else { return }
            self.stateManager.closeTab(id: tabId)
        }
        paneTabBar.onNewTab = { [weak self] in
            guard let self else { return }
            self.stateManager.createTab(inPane: self.paneId)
        }
        paneTabBar.onAddPane = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestAddPane: self.paneId)
        }
        paneTabBar.onClosePane = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestClosePane: self.paneId)
        }
        paneTabBar.onExpandPane = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestExpandPane: self.paneId)
        }
        paneTabBar.onDoubleClickTab = { [weak self] tabId in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestRenameTab: tabId)
        }
        paneTabBar.onReorderTabs = { [weak self] newTabIds in
            guard let self else { return }
            self.stateManager.reorderTabs(newTabIds, inPane: self.paneId)
        }

        // Editor toolbar (below tab bar)
        setupEditorToolbar()

        // Editor — wire segment run and text edit callbacks
        editorVC.onRunSegment = { [weak self] segment in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestRunSegment: segment)
        }
        editorVC.onTextEdited = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didEditText: self.paneId)
        }
        addChild(editorVC)

        container.addSubview(paneTabBar)
        container.addSubview(editorToolbar)
        container.addSubview(editorVC.view)

        NSLayoutConstraint.activate([
            paneTabBar.topAnchor.constraint(equalTo: container.topAnchor),
            paneTabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneTabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneTabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            editorToolbar.topAnchor.constraint(equalTo: paneTabBar.bottomAnchor),
            editorToolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorToolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorToolbar.heightAnchor.constraint(equalToConstant: editorToolbarHeight),
        ])

        // Editor view uses frame-based layout — positioned in viewDidLayout.
        // Set initial frame below the tab bar + editor toolbar so it doesn't cover them.
        editorVC.view.frame = NSRect(
            x: 0, y: 0,
            width: container.bounds.width,
            height: max(0, container.bounds.height - totalHeaderHeight)
        )

        // Observe pane state changes
        stateManager.$panes
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in
                self?.paneStateChanged(panes)
            }
            .store(in: &cancellables)

        // Observe tab content changes (isDirty, isExecuting, name)
        stateManager.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshTabBar()
                self?.updateEditorToolbarState()
            }
            .store(in: &cancellables)

        // Observe focused pane changes
        stateManager.$focusedPaneId
            .receive(on: RunLoop.main)
            .sink { [weak self] focusedId in
                guard let self else { return }
                self.paneTabBar.setFocused(focusedId == self.paneId)
            }
            .store(in: &cancellables)

        // Push schema metadata to editor
        Publishers.CombineLatest3(
            metadataCache.$schemas,
            metadataCache.$tables,
            metadataCache.$columnsByTable
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] schemas, tables, columns in
            self?.editorVC.updateSchemaMetadata(
                schemas: schemas, tables: tables, columnsByTable: columns)
        }
        .store(in: &cancellables)

        // Observe connection/schema state for editor toolbar selectors
        stateManager.$connections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildConnectionMenu() }
            .store(in: &cancellables)

        // Rebuild selectors when tabs change (per-tab connection/schema)
        stateManager.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildConnectionMenu()
                self?.rebuildSchemaMenu()
            }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildConnectionMenu() }
            .store(in: &cancellables)

        metadataCache.$schemas
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildSchemaMenu() }
            .store(in: &cancellables)

        metadataCache.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in self?.updateSchemaLoading(loading) }
            .store(in: &cancellables)

        // Track focus: when editor text view becomes first responder, notify delegate
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification, object: nil
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Non-flipped: y=0 is bottom. Tab bar + editor toolbar at top via Auto Layout.
        // Editor fills from bottom up to the editor toolbar.
        editorVC.view.frame = NSRect(
            x: 0, y: 0,
            width: view.bounds.width,
            height: max(0, view.bounds.height - totalHeaderHeight)
        )
    }

    // MARK: - State Observation

    private var lastActiveTabId: String?

    private func paneStateChanged(_ panes: [EditorPane]) {
        guard let pane = panes.first(where: { $0.id == paneId }) else { return }

        let paneTabs = stateManager.tabs(forPane: paneId)
        let canClose = panes.count > 1

        paneTabBar.update(
            tabs: paneTabs,
            activeTabId: pane.activeTabId,
            isExpanded: pane.isExpanded,
            canClose: canClose
        )

        // Detect active tab change
        if pane.activeTabId != lastActiveTabId {
            let oldTabId = lastActiveTabId
            lastActiveTabId = pane.activeTabId
            tabChanged(from: oldTabId, to: pane.activeTabId)
            delegate?.editorPane(self, didChangeActiveTab: pane.activeTabId)
        }
    }

    private func refreshTabBar() {
        guard let pane = stateManager.panes.first(where: { $0.id == paneId }) else { return }
        let paneTabs = stateManager.tabs(forPane: paneId)
        let canClose = stateManager.panes.count > 1

        paneTabBar.update(
            tabs: paneTabs,
            activeTabId: pane.activeTabId,
            isExpanded: pane.isExpanded,
            canClose: canClose
        )
    }

    // MARK: - Tab Switching

    private func tabChanged(from oldTabId: String?, to newTabId: String?) {
        // Save cursor position of old tab
        if let oldTabId, editorVC.tabId == oldTabId {
            let cursorPos = editorVC.getCursorPosition()
            stateManager.updateTab(id: oldTabId) { $0.cursorPosition = cursorPos }
        }

        guard let newTabId,
              let tab = stateManager.tabs.first(where: { $0.id == newTabId }) else {
            editorVC.tabId = nil
            editorVC.setSQL("")
            return
        }

        editorVC.tabId = newTabId
        editorVC.setSQL(tab.sql)
        editorVC.setCursorPosition(tab.cursorPosition)
        editorVC.clearErrorMarkers()

        // Sync global state to this tab's connection/schema so sidebar updates
        if let connId = tab.connectionId {
            stateManager.activeConnectionId = connId
        }
        stateManager.activeSchema = tab.schemaName
    }

    // MARK: - Focus Tracking

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return }

        if responder === editorVC.textView || responder.isDescendant(of: editorVC.textView) {
            if stateManager.focusedPaneId != paneId {
                stateManager.focusPane(id: paneId)
                delegate?.editorPane(self, didFocus: paneId)
            }
        }
    }

    // MARK: - Public API

    func focus() {
        editorVC.focus()
    }

    func getSQL() -> String {
        editorVC.getSQL()
    }

    func formatSQL() {
        editorVC.formatSQL()
    }

    func markError(charPosition: Int, tokenLength: Int) {
        editorVC.markError(charPosition: charPosition, tokenLength: tokenLength)
    }

    func clearErrorMarkers() {
        editorVC.clearErrorMarkers()
    }

    func insertText(_ text: String) {
        let range = editorVC.textView.selectedRange()
        editorVC.textView.insertText(text, replacementRange: range)
    }

    func highlightLines(_ range: ClosedRange<Int>) {
        editorVC.highlightLines(range)
    }

    func setSegmentColor(_ color: NSColor?, forSegmentIndex index: Int) {
        editorVC.setSegmentColor(color, forSegmentIndex: index)
    }

    func clearSegmentColors() {
        editorVC.clearSegmentColors()
    }

    /// Save the current tab's cursor position.
    func saveCurrentTabState() {
        guard let tabId = editorVC.tabId else { return }
        let cursorPos = editorVC.getCursorPosition()
        stateManager.updateTab(id: tabId) { $0.cursorPosition = cursorPos }
    }

    // MARK: - Editor Toolbar

    private func setupEditorToolbar() {
        editorToolbar.wantsLayer = true
        editorToolbar.translatesAutoresizingMaskIntoConstraints = false

        // Format button (left side)
        let fmtConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        formatButton.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Format SQL")?.withSymbolConfiguration(fmtConfig)
        formatButton.bezelStyle = .recessed
        formatButton.isBordered = false
        formatButton.toolTip = "Format SQL (Ctrl+I)"
        formatButton.contentTintColor = .secondaryLabelColor
        formatButton.target = self
        formatButton.action = #selector(formatSQLTapped)
        formatButton.translatesAutoresizingMaskIntoConstraints = false

        // Run/Stop button
        let runConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        runStopButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Query")?.withSymbolConfiguration(runConfig)
        runStopButton.bezelStyle = .recessed
        runStopButton.isBordered = false
        runStopButton.toolTip = "Run Query (Cmd+Return)"
        runStopButton.contentTintColor = .controlAccentColor
        runStopButton.target = self
        runStopButton.action = #selector(runStopTapped)
        runStopButton.translatesAutoresizingMaskIntoConstraints = false

        // Save dropdown (pull-down button)
        saveDropdown.bezelStyle = .recessed
        saveDropdown.isBordered = false
        saveDropdown.controlSize = .regular
        saveDropdown.translatesAutoresizingMaskIntoConstraints = false
        (saveDropdown.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        let saveConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let saveImage = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")?.withSymbolConfiguration(saveConfig)

        // Pull-down: first item is the displayed button title/image
        saveDropdown.addItem(withTitle: "")
        saveDropdown.item(at: 0)?.image = saveImage

        let saveItem = NSMenuItem(title: "Save", action: #selector(saveTapped), keyEquivalent: "")
        saveItem.target = self
        saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        saveDropdown.menu?.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "Save As\u{2026}", action: #selector(saveAsTapped), keyEquivalent: "")
        saveAsItem.target = self
        saveAsItem.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)
        saveDropdown.menu?.addItem(saveAsItem)

        // Connection popup (right side)
        connectionPopup.bezelStyle = .recessed
        connectionPopup.isBordered = false
        connectionPopup.controlSize = .small
        connectionPopup.translatesAutoresizingMaskIntoConstraints = false
        (connectionPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        // Schema popup (right side)
        schemaPopup.bezelStyle = .recessed
        schemaPopup.isBordered = false
        schemaPopup.controlSize = .small
        schemaPopup.translatesAutoresizingMaskIntoConstraints = false
        (schemaPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        // Schema spinner overlay
        schemaSpinner.style = .spinning
        schemaSpinner.controlSize = .small
        schemaSpinner.isDisplayedWhenStopped = false
        schemaSpinner.translatesAutoresizingMaskIntoConstraints = false
        schemaPopup.addSubview(schemaSpinner)
        NSLayoutConstraint.activate([
            schemaSpinner.trailingAnchor.constraint(equalTo: schemaPopup.trailingAnchor, constant: -20),
            schemaSpinner.centerYAnchor.constraint(equalTo: schemaPopup.centerYAnchor),
        ])

        // Bottom separator line
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        editorToolbar.addSubview(separator)

        // All controls in one row: Format, Save, Run/Stop, Connection, Schema
        let toolbarStack = NSStackView(views: [formatButton, saveDropdown, runStopButton, connectionPopup, schemaPopup])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        editorToolbar.addSubview(toolbarStack)

        NSLayoutConstraint.activate([
            formatButton.widthAnchor.constraint(equalToConstant: 28),
            formatButton.heightAnchor.constraint(equalToConstant: 28),
            runStopButton.widthAnchor.constraint(equalToConstant: 28),
            runStopButton.heightAnchor.constraint(equalToConstant: 28),
            saveDropdown.widthAnchor.constraint(equalToConstant: 32),

            connectionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            connectionPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            schemaPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            schemaPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 160),

            toolbarStack.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor, constant: 8),
            toolbarStack.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: editorToolbar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: editorToolbar.bottomAnchor),
        ])
    }

    @objc private func formatSQLTapped() {
        formatSQL()
    }

    @objc private func runStopTapped() {
        if isExecuting {
            delegate?.editorPaneDidRequestCancelQuery(self)
        } else {
            delegate?.editorPaneDidRequestRunQuery(self)
        }
    }

    @objc private func saveTapped() {
        delegate?.editorPaneDidRequestSave(self)
    }

    @objc private func saveAsTapped() {
        delegate?.editorPaneDidRequestSaveAs(self)
    }

    private func updateEditorToolbarState() {
        guard let pane = stateManager.panes.first(where: { $0.id == paneId }) else { return }
        let activeTab = stateManager.tabs.first { $0.id == pane.activeTabId }
        let executing = activeTab?.isExecuting ?? false

        if executing != isExecuting {
            isExecuting = executing
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if executing {
                runStopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Query")?.withSymbolConfiguration(config)
                runStopButton.toolTip = "Stop Query"
                runStopButton.contentTintColor = .systemRed
            } else {
                runStopButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Query")?.withSymbolConfiguration(config)
                runStopButton.toolTip = "Run Query (Cmd+Return)"
                runStopButton.contentTintColor = .controlAccentColor
            }
        }

        // Update save dropdown: "Save" item enabled only when tab has a saved query link
        let hasSavedQuery = activeTab?.savedQueryId != nil
        if let saveItem = saveDropdown.menu?.item(at: 1) {
            saveItem.isEnabled = hasSavedQuery
        }
    }

    // MARK: - Per-Tab Connection / Schema Helpers

    /// Returns the active tab for this pane.
    private var activeTab: QueryTab? {
        guard let pane = stateManager.panes.first(where: { $0.id == paneId }),
              let tabId = pane.activeTabId else { return nil }
        return stateManager.tabs.first { $0.id == tabId }
    }

    /// The connection ID for the active tab in this pane.
    private var tabConnectionId: String? {
        activeTab?.connectionId
    }

    /// The schema name for the active tab in this pane.
    private var tabSchemaName: String? {
        activeTab?.schemaName
    }

    // MARK: - Connection / Schema Selectors

    private func rebuildConnectionMenu() {
        connectionPopup.removeAllItems()

        let connections = stateManager.connections
        let activeId = tabConnectionId

        // First item in a pull-down button is the button's displayed title
        let buttonTitle: String
        if let activeId,
           let config = connections.first(where: { $0.id == activeId }) {
            let status = stateManager.status(for: config.id)
            let statusIcon = statusString(for: status)
            buttonTitle = "\(statusIcon)\(config.name)"
        } else if connections.isEmpty {
            buttonTitle = "No Connections"
        } else {
            buttonTitle = "Select Connection"
        }
        connectionPopup.addItem(withTitle: buttonTitle)
        connectionPopup.isEnabled = true

        // Style the title item with colored status indicator
        if let activeId,
           let config = connections.first(where: { $0.id == activeId }) {
            let status = stateManager.status(for: config.id)
            if let titleItem = connectionPopup.item(at: 0) {
                titleItem.attributedTitle = styledTitle(buttonTitle, status: status)
            }
        }

        if !connections.isEmpty {
            connectionPopup.menu?.addItem(.separator())
            for config in connections {
                let status = stateManager.status(for: config.id)
                let icon = statusString(for: status)
                let title = "\(icon)\(config.name)"
                let menuItem = NSMenuItem(title: title, action: #selector(connectionItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = config.id
                menuItem.attributedTitle = styledTitle(title, status: status)
                if config.id == activeId {
                    menuItem.state = .on
                }
                connectionPopup.menu?.addItem(menuItem)
            }

            connectionPopup.menu?.addItem(.separator())

            let connectItem = NSMenuItem(title: "Connect", action: #selector(connectSelected), keyEquivalent: "")
            connectItem.target = self
            connectionPopup.menu?.addItem(connectItem)

            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectSelected), keyEquivalent: "")
            disconnectItem.target = self
            connectionPopup.menu?.addItem(disconnectItem)

            let refreshItem = NSMenuItem(title: "Refresh Connection", action: #selector(refreshConnection), keyEquivalent: "")
            refreshItem.target = self
            if let activeId, stateManager.status(for: activeId) == .connected {
                refreshItem.isEnabled = true
            } else {
                refreshItem.isEnabled = false
            }
            connectionPopup.menu?.addItem(refreshItem)

            connectionPopup.menu?.addItem(.separator())

            let editItem = NSMenuItem(title: "Edit Connection...", action: #selector(editConnection), keyEquivalent: "")
            editItem.target = self
            connectionPopup.menu?.addItem(editItem)

            let deleteItem = NSMenuItem(title: "Delete Connection", action: #selector(deleteConnection), keyEquivalent: "")
            deleteItem.target = self
            connectionPopup.menu?.addItem(deleteItem)
        }

        connectionPopup.menu?.addItem(.separator())
        let newItem = NSMenuItem(title: "New Connection...", action: #selector(showAddConnectionSheet), keyEquivalent: "")
        newItem.target = self
        connectionPopup.menu?.addItem(newItem)
    }

    private func rebuildSchemaMenu() {
        schemaPopup.removeAllItems()

        let schemas = metadataCache.schemas
        let activeSchema = tabSchemaName

        let isConnected: Bool
        if let activeId = tabConnectionId {
            isConnected = stateManager.status(for: activeId) == .connected
        } else {
            isConnected = false
        }

        guard isConnected, !schemas.isEmpty else {
            schemaPopup.addItem(withTitle: "No Schema")
            schemaPopup.isEnabled = false
            return
        }

        schemaPopup.isEnabled = true

        let titleText = activeSchema ?? "All Schemas"
        schemaPopup.addItem(withTitle: titleText)

        let allItem = NSMenuItem(title: "All Schemas", action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = nil
        if activeSchema == nil { allItem.state = .on }
        schemaPopup.menu?.addItem(allItem)

        schemaPopup.menu?.addItem(.separator())

        for schema in schemas {
            let item = NSMenuItem(title: schema.name, action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = schema.name
            if activeSchema == schema.name { item.state = .on }
            schemaPopup.menu?.addItem(item)
        }
    }

    private func updateSchemaLoading(_ loading: Bool) {
        if loading {
            schemaPopup.removeAllItems()
            schemaPopup.addItem(withTitle: "Loading\u{2026}")
            schemaPopup.isEnabled = false
            schemaSpinner.startAnimation(nil)
        } else {
            schemaSpinner.stopAnimation(nil)
            rebuildSchemaMenu()
        }
    }

    // MARK: - Connection / Schema Helpers

    private func statusString(for status: ConnectionStatus) -> String {
        switch status {
        case .connected: return "\u{25CF} "   // filled circle
        case .connecting: return "\u{25CB} "   // empty circle
        case .error: return "\u{25CF} "        // filled circle (red)
        case .disconnected: return "  "
        }
    }

    private func styledTitle(_ title: String, status: ConnectionStatus) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: title)
        let color: NSColor?
        switch status {
        case .connected: color = .systemGreen
        case .error: color = .systemRed
        default: color = nil
        }
        if let color {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 2))
        }
        return attributed
    }

    // MARK: - Connection / Schema Actions

    /// Update the active tab's connectionId and also sync global state.
    private func setTabConnection(_ connectionId: String) {
        guard let tab = activeTab else { return }
        // Clear schema when switching connections so stale schema doesn't stick
        let connectionChanged = tab.connectionId != connectionId
        stateManager.updateTab(id: tab.id) {
            $0.connectionId = connectionId
            if connectionChanged { $0.schemaName = nil }
        }
        // Also update global active connection so sidebar/metadata stay in sync
        stateManager.activeConnectionId = connectionId
        if connectionChanged { stateManager.activeSchema = nil }
    }

    /// Update the active tab's schemaName and also sync global state.
    private func setTabSchema(_ schemaName: String?) {
        guard let tab = activeTab else { return }
        stateManager.updateTab(id: tab.id) { $0.schemaName = schemaName }
        stateManager.activeSchema = schemaName
    }

    @objc private func connectionItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setTabConnection(id)
        let status = stateManager.status(for: id)
        if status == .disconnected {
            stateManager.connect(id: id)
        }
    }

    @objc private func connectSelected() {
        guard let id = tabConnectionId else { return }
        stateManager.connect(id: id)
    }

    @objc private func disconnectSelected() {
        guard let id = tabConnectionId else { return }
        stateManager.disconnect(id: id)
    }

    @objc private func refreshConnection() {
        guard let id = tabConnectionId,
              stateManager.status(for: id) == .connected else { return }
        metadataCache.load(connectionId: id)
        NotificationCenter.default.post(name: .connectionMetadataRefreshRequested, object: nil)
    }

    @objc private func showAddConnectionSheet() {
        let sheet = ConnectionSheet.forNew { [weak self] config in
            self?.stateManager.saveConnection(config)
        }
        view.window?.contentViewController?.presentAsSheet(sheet)
    }

    @objc private func editConnection() {
        guard let id = tabConnectionId,
              let config = stateManager.connections.first(where: { $0.id == id }) else { return }
        let sheet = ConnectionSheet.forEdit(config) { [weak self] updated in
            self?.stateManager.saveConnection(updated)
        }
        view.window?.contentViewController?.presentAsSheet(sheet)
    }

    @objc private func deleteConnection() {
        guard let id = tabConnectionId,
              let config = stateManager.connections.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(config.name)\"?"
        alert.informativeText = "This will remove the connection and its saved password."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                self.stateManager.deleteConnection(id: id)
            }
        }
    }

    @objc private func schemaItemClicked(_ sender: NSMenuItem) {
        setTabSchema(sender.representedObject as? String)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
