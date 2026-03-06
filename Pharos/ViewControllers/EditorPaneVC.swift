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

        // Run/Stop button (right side)
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

        let saveAsItem = NSMenuItem(title: "Save As…", action: #selector(saveAsTapped), keyEquivalent: "")
        saveAsItem.target = self
        saveAsItem.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)
        saveDropdown.menu?.addItem(saveAsItem)

        // Bottom separator line
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        editorToolbar.addSubview(separator)

        // Layout — all buttons on the left: Format, Save, Execute
        let buttonStack = NSStackView(views: [formatButton, saveDropdown, runStopButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        editorToolbar.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            formatButton.widthAnchor.constraint(equalToConstant: 28),
            formatButton.heightAnchor.constraint(equalToConstant: 28),
            runStopButton.widthAnchor.constraint(equalToConstant: 28),
            runStopButton.heightAnchor.constraint(equalToConstant: 28),
            saveDropdown.widthAnchor.constraint(equalToConstant: 32),

            buttonStack.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor, constant: 8),
            buttonStack.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
