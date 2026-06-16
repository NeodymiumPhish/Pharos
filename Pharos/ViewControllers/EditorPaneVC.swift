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
    func editorPaneDidRequestRunAll(_ pane: EditorPaneVC)
    func editorPane(_ pane: EditorPaneVC, didRequestCancelQueryId queryId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestCloseTab tabId: String)
    func editorPaneDidRequestSave(_ pane: EditorPaneVC)
    func editorPaneDidRequestSaveAs(_ pane: EditorPaneVC)
    func editorPaneDidRequestExportAsSQL(_ pane: EditorPaneVC)
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
    /// "Format as SQL list" — hidden until a paste qualifies for the offer.
    private let formatListButton = NSButton()
    private let queryIndicator = QueryProgressIndicator()
    private let saveDropdown = NSPopUpButton(frame: .zero, pullsDown: true)
    private var runningQueriesPopover: NSPopover?
    private var runningQueriesPopoverCloseObserver: NSObjectProtocol?

    // Connection / Schema selectors (in editor toolbar, right side)
    private let connectionPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let schemaPopup = SchemaPopUpButton(frame: .zero, pullsDown: true)
    private let schemaSpinner = NSProgressIndicator()
    private var schemaPopover: NSPopover?

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
            self.delegate?.editorPane(self, didRequestCloseTab: tabId)
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
        editorVC.textView.onListPasteDetected = { [weak self] in
            self?.formatListButton.isHidden = false
        }
        editorVC.textView.onListPasteOfferInvalidated = { [weak self] in
            self?.formatListButton.isHidden = true
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

        // Observe tab content changes (isDirty, isExecuting, name) + rebuild menus.
        // Dedup on the fields this sink actually reads: id / name / isDirty /
        // isExecuting / paneId / segmentIndex set. Without this, every
        // keystroke (which updates `tab.sql` via updateTab) republishes $tabs
        // and re-rebuilt all four UI surfaces on every pane in the window.
        stateManager.$tabs
            .removeDuplicates { lhs, rhs in
                guard lhs.count == rhs.count else { return false }
                for i in 0..<lhs.count {
                    let a = lhs[i], b = rhs[i]
                    if a.id != b.id
                        || a.name != b.name
                        || a.isDirty != b.isDirty
                        || a.paneId != b.paneId
                        || a.isExecuting != b.isExecuting
                        || a.connectionId != b.connectionId
                        || a.schemaName != b.schemaName
                    {
                        return false
                    }
                    // Gutter pulse uses the segment indices of running queries
                    // — same count + same indices = same pulse, no rebuild.
                    let aSegs = a.runningQueries.map { $0.segmentIndex }
                    let bSegs = b.runningQueries.map { $0.segmentIndex }
                    if aSegs != bSegs { return false }
                }
                return true
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.refreshTabBar()
                self.updateEditorToolbarState()
                self.rebuildConnectionMenu()
                self.rebuildSchemaMenu()
                self.updateGutterPulseForActiveTab(tabs: tabs)
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

        // Coalesce connection/status changes to rebuild menus at most once per run loop pass
        Publishers.CombineLatest(
            stateManager.$connections,
            stateManager.$connectionStatuses
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in self?.rebuildConnectionMenu() }
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

    /// Read the pane's active tab from the tabs array and push its running-segment
    /// indices to the gutter (or empty set if the tab isn't executing).
    private func updateGutterPulseForActiveTab(tabs: [QueryTab]) {
        guard let activeTabId = stateManager.panes.first(where: { $0.id == paneId })?.activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId }) else {
            editorVC.setRunningSegmentIndices([])
            return
        }
        editorVC.setRunningSegmentIndices(Set(tab.runningQueries.map { $0.segmentIndex }))
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

        // Sync global state to this tab's connection/schema so sidebar updates.
        // Only set when the value actually changes to avoid redundant reloads.
        if let connId = tab.connectionId, connId != stateManager.activeConnectionId {
            stateManager.activeConnectionId = connId
        } else if tab.connectionId == nil && stateManager.activeConnectionId != nil {
            stateManager.activeConnectionId = nil
        }
        if tab.schemaName != stateManager.activeSchema {
            stateManager.activeSchema = tab.schemaName
        }

        // Sync gutter pulse to the newly-activated tab.
        editorVC.setRunningSegmentIndices(Set(tab.runningQueries.map { $0.segmentIndex }))

        // The connection/schema popup labels read from `activeTab?.connectionId`
        // and `activeTab?.schemaName`. When the active tab in this pane changes,
        // the QueryTab objects themselves are unchanged, so $tabs doesn't emit
        // and the popups would stay stuck on the previous tab's values. Rebuild
        // them explicitly here.
        rebuildConnectionMenu()
        rebuildSchemaMenu()
    }

    // MARK: - Focus Tracking

    @objc private func windowDidUpdate(_ notification: Notification) {
        // Early exit if this pane is already focused (most common case)
        guard stateManager.focusedPaneId != paneId else { return }
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return }

        if responder === editorVC.textView || responder.isDescendant(of: editorVC.textView) {
            stateManager.focusPane(id: paneId)
            delegate?.editorPane(self, didFocus: paneId)
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

        saveDropdown.menu?.addItem(.separator())

        let exportSQLItem = NSMenuItem(title: "Export as SQL File\u{2026}", action: #selector(exportAsSQLTapped), keyEquivalent: "")
        exportSQLItem.target = self
        exportSQLItem.image = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: nil)
        saveDropdown.menu?.addItem(exportSQLItem)

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
        schemaPopup.onActivate = { [weak self] button in
            self?.presentSchemaPopover(from: button)
        }

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

        // "Format as SQL list" button — appears only while a list-paste
        // offer is pending; accent-colored so it stands out.
        formatListButton.bezelStyle = .rounded
        formatListButton.bezelColor = .controlAccentColor
        formatListButton.controlSize = .small
        formatListButton.attributedTitle = NSAttributedString(
            string: "Format as SQL list",
            attributes: [
                .foregroundColor: NSColor.alternateSelectedControlTextColor,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            ]
        )
        formatListButton.toolTip = "Format pasted values as a quoted, comma-separated SQL list (Tab)"
        formatListButton.isHidden = true
        formatListButton.target = self
        formatListButton.action = #selector(formatListTapped)
        formatListButton.translatesAutoresizingMaskIntoConstraints = false

        // Bottom separator line
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        editorToolbar.addSubview(separator)

        // All controls in one row: Format, Save, Run/Stop, Connection, Schema, Format-as-SQL-list
        let toolbarStack = NSStackView(views: [formatButton, saveDropdown, runStopButton, connectionPopup, schemaPopup, formatListButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        editorToolbar.addSubview(toolbarStack)

        // Query progress indicator: overlays runStopButton exactly, hidden when idle.
        // Added to editorToolbar (not toolbarStack) so the stack doesn't manage it
        // as an arranged subview, while still constraining to runStopButton's anchors
        // since both share the same coordinate space.
        queryIndicator.translatesAutoresizingMaskIntoConstraints = false
        queryIndicator.isHidden = true
        editorToolbar.addSubview(queryIndicator)

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

            queryIndicator.leadingAnchor.constraint(equalTo: runStopButton.leadingAnchor),
            queryIndicator.trailingAnchor.constraint(equalTo: runStopButton.trailingAnchor),
            queryIndicator.topAnchor.constraint(equalTo: runStopButton.topAnchor),
            queryIndicator.bottomAnchor.constraint(equalTo: runStopButton.bottomAnchor),
        ])
    }

    @objc private func formatSQLTapped() {
        formatSQL()
    }

    @objc private func formatListTapped() {
        editorVC.textView.applyPendingSQLize()
    }

    @objc private func runStopTapped() {
        let running = activeTab?.runningQueries ?? []
        switch running.count {
        case 0:
            let segmentCount = editorVC.segments.count
            if segmentCount <= 1 {
                delegate?.editorPaneDidRequestRunQuery(self)
            } else {
                showRunOptionsMenu()
            }
        case 1:
            delegate?.editorPane(self, didRequestCancelQueryId: running[0].id)
        default:
            showRunningQueriesPopover(running)
        }
    }

    private func showRunningQueriesPopover(_ queries: [RunningQuery]) {
        runningQueriesPopover?.close()

        guard queries.count > 1, let tabId = activeTab?.id else { return }
        let vc = RunningQueriesPopoverVC(stateManager: stateManager, tabId: tabId)
        vc.delegate = self

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: runStopButton.bounds, of: runStopButton, preferredEdge: .minY)
        runningQueriesPopover = popover

        if let existing = runningQueriesPopoverCloseObserver {
            NotificationCenter.default.removeObserver(existing)
            runningQueriesPopoverCloseObserver = nil
        }
        runningQueriesPopoverCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            self?.runningQueriesPopover = nil
        }
    }

    private func showRunOptionsMenu() {
        let menu = NSMenu()

        let focusedItem = NSMenuItem(
            title: "Run Focused Query",
            action: #selector(runFocusedFromMenu),
            keyEquivalent: "\r"
        )
        focusedItem.keyEquivalentModifierMask = .command
        focusedItem.target = self
        menu.addItem(focusedItem)

        let runAllItem = NSMenuItem(
            title: "Run All Queries",
            action: #selector(runAllFromMenu),
            keyEquivalent: ""
        )
        runAllItem.target = self
        menu.addItem(runAllItem)

        let origin = NSPoint(x: 0, y: runStopButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: runStopButton)
    }

    @objc private func runFocusedFromMenu() {
        delegate?.editorPaneDidRequestRunQuery(self)
    }

    @objc private func runAllFromMenu() {
        delegate?.editorPaneDidRequestRunAll(self)
    }

    @objc private func saveTapped() {
        delegate?.editorPaneDidRequestSave(self)
    }

    @objc private func saveAsTapped() {
        delegate?.editorPaneDidRequestSaveAs(self)
    }

    @objc private func exportAsSQLTapped() {
        delegate?.editorPaneDidRequestExportAsSQL(self)
    }

    private func updateEditorToolbarState() {
        guard let pane = stateManager.panes.first(where: { $0.id == paneId }) else { return }
        let activeTab = stateManager.tabs.first { $0.id == pane.activeTabId }
        let count = activeTab?.runningQueries.count ?? 0

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if count == 0 {
            runStopButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Query")?.withSymbolConfiguration(config)
            runStopButton.toolTip = "Run Query (Cmd+Return)"
            runStopButton.contentTintColor = .controlAccentColor
            queryIndicator.isHidden = true
        } else {
            // Hide the button's image so the indicator is the visible element.
            runStopButton.image = nil
            runStopButton.toolTip = count == 1
                ? "Stop Query"
                : "\(count) queries running — click to manage"
            queryIndicator.count = count
            queryIndicator.isHidden = false
        }

        // Update save dropdown: "Save" item enabled when the tab has somewhere
        // to save to — either a saved query link or an on-disk source URL.
        let canSaveInPlace = activeTab?.savedQueryId != nil || activeTab?.sourceURL != nil
        if let saveItem = saveDropdown.menu?.item(at: 1) {
            saveItem.isEnabled = canSaveInPlace
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

        }

        connectionPopup.menu?.addItem(.separator())
        let manageItem = NSMenuItem(title: "Manage Connections…", action: #selector(showConnectionsManager), keyEquivalent: "")
        manageItem.target = self
        connectionPopup.menu?.addItem(manageItem)
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

        // The button shows a single title item; the full schema list and the
        // "All Schemas" / "Set as Default" actions now live in the popover
        // (see presentSchemaPopover), which scrolls naturally for long lists.
        let titleText = activeSchema ?? "All Schemas"
        schemaPopup.addItem(withTitle: titleText)
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
        let connectionChanged = tab.connectionId != connectionId
        // Apply the target connection's configured default schema when switching,
        // falling back to "public" if none is configured.
        let newSchema = stateManager.connections
            .first(where: { $0.id == connectionId })?.defaultSchema ?? "public"
        stateManager.updateTab(id: tab.id) {
            $0.connectionId = connectionId
            if connectionChanged { $0.schemaName = newSchema }
        }
        // Also update global active connection so sidebar/metadata stay in sync
        stateManager.activeConnectionId = connectionId
        if connectionChanged { stateManager.activeSchema = newSchema }
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
        metadataCache.load(connectionId: id, force: true)
        NotificationCenter.default.post(name: .connectionMetadataRefreshRequested, object: nil)
    }

    @objc private func showConnectionsManager() {
        ConnectionsManagerWindowController.show()
    }

    /// Build and present the searchable schema popover anchored to the schema
    /// button. Selection and set-default flow back through the existing
    /// setTabSchema / setDefaultSchemaClicked logic.
    private func presentSchemaPopover(from button: NSView) {
        let schemaNames = metadataCache.schemas.map { $0.name }
        let defaultSchema: String? = {
            guard let connId = tabConnectionId else { return nil }
            return stateManager.connections.first(where: { $0.id == connId })?.defaultSchema
        }()

        let vc = SchemaSelectorPopoverVC(
            schemas: schemaNames,
            activeSchema: tabSchemaName,
            defaultSchema: defaultSchema
        )
        vc.onSelectSchema = { [weak self] schema in
            self?.setTabSchema(schema)
            self?.schemaPopover?.close()
        }
        vc.onSetDefault = { [weak self] in
            self?.setDefaultSchemaClicked()
            self?.schemaPopover?.close()
        }

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        schemaPopover = popover
    }

    @objc private func setDefaultSchemaClicked() {
        guard let connId = tabConnectionId else { return }
        guard var config = stateManager.connections.first(where: { $0.id == connId }) else { return }

        // Current schema selection becomes the default (nil = "All Schemas" = clear default)
        let currentSchema = tabSchemaName
        config.defaultSchema = currentSchema
        stateManager.saveConnection(config)

        // Rebuild menu to update the badge
        rebuildSchemaMenu()
    }

    deinit {
        if let observer = runningQueriesPopoverCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - RunningQueriesPopoverDelegate

extension EditorPaneVC: RunningQueriesPopoverDelegate {
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String) {
        delegate?.editorPane(self, didRequestCancelQueryId: id)
    }
}
