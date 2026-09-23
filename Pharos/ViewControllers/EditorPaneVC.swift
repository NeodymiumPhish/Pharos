import AppKit
import Combine

/// Delegate for EditorPaneVC events that need to be handled by the parent.
protocol EditorPaneDelegate: AnyObject {
    func editorPane(_ pane: EditorPaneVC, didChangeActiveTab tabId: String?)
    func editorPane(_ pane: EditorPaneVC, didRequestRenameTab tabId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestCloseTab tabId: String)
    func editorPaneDidRequestSave(_ pane: EditorPaneVC)
    func editorPaneDidRequestSaveAs(_ pane: EditorPaneVC)
    func editorPaneDidRequestExportAsSQL(_ pane: EditorPaneVC)
    func editorPane(_ pane: EditorPaneVC, didRequestRunSegment segment: SQLSegment)
    func editorPaneDidEditText(_ pane: EditorPaneVC)
    func editorPaneDidRequestShowErrors(_ pane: EditorPaneVC)
    func editorPane(_ pane: EditorPaneVC, didSelectResultTab resultTabId: String)
    func editorPane(_ pane: EditorPaneVC, didCloseResultTab resultTabId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestResultTabDetail resultTabId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestResultTabRename resultTabId: String)
    /// A `{{` completion row was accepted: show that variable (creating it
    /// when no variable has the name).
    func editorPane(_ pane: EditorPaneVC, didChooseVariable name: String)
}

/// The editor area: the tab bar, the SQL editor and its toolbar, and the
/// vertical result-tabs panel. It shows `AppStateManager.activeTab`.
///
/// Query variables are not here any more. They are app-wide
/// (`QueryVariableStore`) and edited in the sidebar's Variables navigator;
/// this pane only reports which `{{name}}` tokens the editor text references
/// (`WindowSession.referencedVariableNames`) and highlights the defined names.
class EditorPaneVC: NSViewController {

    let editorVC: QueryEditorVC
    private(set) var paneTabBar: PaneTabBar!

    // Editor toolbar (below tab bar)
    /// The header row under the tab bar. Painted the same ground as the tab
    /// bar so the two read as one strip of chrome, not two surfaces.
    private let editorToolbar = EditorHeaderRowView()
    private let formatButton = NSButton()
    /// "Describe the query…" — hidden entirely unless Apple Intelligence is
    /// available, and disabled until the tab has a live connection to read a
    /// schema from.
    private let describeQueryButton = NSButton()
    private var describeQueryPopover: NSPopover?
    /// "Format as SQL list" — hidden until a paste qualifies for the offer.
    private let formatListButton = NSButton()
    private let saveDropdown = NSPopUpButton(frame: .zero, pullsDown: true)

    // Schema selector (in editor toolbar). Run, Cancel and the connection
    // pull-down live in the window toolbar (`MainToolbarController`).

    /// Per-tab failure indicator. Hidden until the pane's active tab has a
    /// failure in its log.
    let errorButton = ErrorBadgeButton()

    /// Width of the result-tabs panel's resize divider.
    private let panelDividerWidth: CGFloat = 5

    /// Smallest editor `viewDidLayout` will leave before it starts reducing the
    /// result-tabs panel. The panel renders at the width the user chose and the
    /// editor absorbs the rest, until the editor reaches this floor; only then
    /// is the panel reduced, and no further than its own `minWidth`. Display
    /// only: the pref is never written from here.
    ///
    /// The floor's value is not what makes a drag exact — `widthForDrag` is. By
    /// stopping a widen at the ceiling, it keeps the pref inside what can be
    /// displayed, so the reduction never engages mid-drag whatever this floor
    /// is set to.
    private let minEditorWidth: CGFloat = 200

    // Vertical result tabs (fed by ContentViewController.refreshResultTabViews)
    private let resultTabsToggle = NSButton()
    private let resultTabsPanelVC = ResultTabsPanelVC()
    private let resultTabsDivider = ResizeDividerView()
    private var resultTabsPanelWidthAtDragStart: CGFloat = 0

    /// Coalesces the `{{token}}` scan behind editor typing. The scan is a full
    /// regex pass over the text, so it runs once per pause rather than once per
    /// keystroke.
    private var referencedNamesScanTimer: Timer?
    private let referencedNamesScanDelay: TimeInterval = 0.15

    // `resultTabsPanelWidthAtDragStart` above snapshots the **pref**, never the
    // width last displayed. The two differ whenever the narrow-window shrink in
    // `viewDidLayout` is active, and a drag assigns its result back to the pref
    // — so anchoring on the displayed width mixed the two units and made the
    // drag move the panel the WRONG WAY (measured, when two panels shared the
    // budget: a widen collapsed the pref 400 → 285 and the panel fell 42pt).
    // Anchoring on the pref costs a cosmetic lag while shrunk; a divider that
    // moves the wrong way is the bug that was reported. Do not "fix" this back.

    private var isResultTabsPanelVisible: Bool {
        guard stateManager.settings.verticalResultTabs,
              let tabId = lastActiveTabId,
              let tab = session.tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.resultTabsPanelVisible
    }

    weak var delegate: EditorPaneDelegate?

    let session: WindowSession
    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(session: WindowSession) {
        self.session = session
        self.editorVC = QueryEditorVC(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View Lifecycle

    private let tabBarHeight: CGFloat = 32
    /// 28, the sidebar filter bar's height — one height for every secondary
    /// row of chrome in the window.
    private let editorToolbarHeight: CGFloat = 28
    private var totalHeaderHeight: CGFloat {
        tabBarHeight + editorToolbarHeight
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        // Tab bar
        paneTabBar = PaneTabBar()
        paneTabBar.session = session
        paneTabBar.translatesAutoresizingMaskIntoConstraints = false
        // A plain NSView wrapper is accessibility-ignored by default, which
        // would flatten its identifier away and expose only its child
        // segmented control to the AX tree — force it to be a real element
        // so `editor.tabBar` is reachable by the AX walker and UI tests.
        paneTabBar.setAccessibilityElement(true)
        paneTabBar.setAccessibilityIdentifier("editor.tabBar")

        paneTabBar.onSelectTab = { [weak self] tabId in
            guard let self else { return }
            self.session.selectTab(id: tabId)
        }
        paneTabBar.onCloseTab = { [weak self] tabId in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestCloseTab: tabId)
        }
        paneTabBar.onNewTab = { [weak self] in
            guard let self else { return }
            self.session.createTab()
        }
        paneTabBar.onDoubleClickTab = { [weak self] tabId in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestRenameTab: tabId)
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
            self.delegate?.editorPaneDidEditText(self)
            // Adding or removing a `{{token}}` changes which variables are
            // referenced, and therefore which rows the sidebar's Variables
            // navigator flags.
            self.scheduleReferencedNamesScan()
        }
        editorVC.onVariableChosen = { [weak self] name in
            guard let self else { return }
            self.delegate?.editorPane(self, didChooseVariable: name)
        }
        editorVC.textView.onListPasteDetected = { [weak self] in
            self?.formatListButton.isHidden = false
        }
        editorVC.textView.onListPasteOfferInvalidated = { [weak self] in
            self?.formatListButton.isHidden = true
        }
        addChild(editorVC)

        // Highlight the app-wide variable names in the editor and offer them
        // after `{{`, and follow the store: an edit in any window's sidebar
        // reaches every editor.
        applyQueryVariables()
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryVariablesDidChange(_:)),
            name: QueryVariableStore.didChange, object: nil)

        addChild(resultTabsPanelVC)
        resultTabsPanelVC.onSelectRow = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didSelectResultTab: id)
        }
        resultTabsPanelVC.onCloseRow = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didCloseResultTab: id)
        }
        resultTabsPanelVC.onRenameRow = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestResultTabRename: id)
        }
        resultTabsPanelVC.onViewDetail = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestResultTabDetail: id)
        }
        resultTabsDivider.onDragBegan = { [weak self] in
            guard let self else { return }
            self.resultTabsPanelWidthAtDragStart = ResultTabsPanelPrefs.width
        }
        resultTabsDivider.onDrag = { [weak self] offset in
            self?.resizeResultTabsPanel(byOffset: offset)
        }

        container.addSubview(paneTabBar)
        container.addSubview(editorToolbar)
        container.addSubview(editorVC.view)
        container.addSubview(resultTabsPanelVC.view)
        container.addSubview(resultTabsDivider)
        resultTabsPanelVC.view.isHidden = true
        resultTabsDivider.isHidden = true

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

        // Observe the active tab. Settled publisher, no run-loop hop: the
        // editor has loaded its tab's text by the time `selectTab` returns
        // (see `AppStateManager.tabsSettled`).
        session.activeTabIdSettled
            .sink { [weak self] tabId in
                self?.activeTabIdChanged(tabId)
            }
            .store(in: &cancellables)

        // Observe tab content changes (isDirty, isExecuting, name) + rebuild menus.
        // Dedup on the fields this sink actually reads: id / name / isDirty /
        // isExecuting / segmentIndex set. Without this, every
        // keystroke (which updates `tab.sql` via updateTab) republishes the tabs
        // and re-rebuilt all four UI surfaces.
        session.tabsSettled
            .removeDuplicates { lhs, rhs in
                guard lhs.count == rhs.count else { return false }
                for i in 0..<lhs.count {
                    let a = lhs[i], b = rhs[i]
                    if a.id != b.id
                        || a.name != b.name
                        || a.isDirty != b.isDirty
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
            .sink { [weak self] tabs in
                guard let self else { return }
                self.refreshTabBar()
                self.updateEditorToolbarState()
                self.updateGutterPulseForActiveTab(tabs: tabs)
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

        // "Describe the query…" appears and disappears with Apple
        // Intelligence, and takes its enabled state from whether the tab has
        // a connection whose schema the model could read.
        ModelAvailability.shared.publisher(for: .describeQuery)
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                self?.updateDescribeQueryButton(available: available)
            }
            .store(in: &cancellables)

        // The status, not the tab's `connectionId`: a tab can name a
        // connection long before it is connected, and the schema cache is
        // empty until it is. The `tabsSettled` sink cannot see this — its
        // dedup whitelist reads the tab, not the connection.
        stateManager.$connectionStatuses
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDescribeQueryButton() }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Non-flipped: y=0 is bottom. Tab bar + editor toolbar at top via Auto Layout.
        // Horizontal order: editor | divider | result tabs.
        let editorHeight = max(0, view.bounds.height - totalHeaderHeight)
        let showResults = isResultTabsPanelVisible

        var resultsW = showResults ? ResultTabsPanelPrefs.width : 0
        let dividersW = showResults ? panelDividerWidth : 0

        // The panel renders at the width the user chose; the editor absorbs
        // what is left. Only when the editor would fall under its floor is the
        // panel reduced, and never below its own minimum. Display only: the
        // pref is never written from here, so a temporarily narrow window does
        // not destroy it.
        var editorW = view.bounds.width - resultsW - dividersW
        if editorW < minEditorWidth {
            let deficit = minEditorWidth - editorW
            let floor = showResults ? ResultTabsPanelPrefs.minWidth : 0
            resultsW -= min(deficit, max(0, resultsW - floor))
            editorW = view.bounds.width - resultsW - dividersW
        }
        editorW = max(0, editorW)
        editorVC.view.frame = NSRect(x: 0, y: 0, width: editorW, height: editorHeight)

        var x = editorW
        resultTabsDivider.isHidden = !showResults
        resultTabsPanelVC.view.isHidden = !showResults
        if showResults {
            resultTabsDivider.frame = NSRect(x: x, y: 0, width: panelDividerWidth, height: editorHeight)
            x += panelDividerWidth
            resultTabsPanelVC.view.frame = NSRect(x: x, y: 0, width: resultsW, height: editorHeight)
        }
    }

    // MARK: - State Observation

    private var lastActiveTabId: String?

    private func activeTabIdChanged(_ tabId: String?) {
        refreshTabBar()

        // Detect active tab change (the publisher also fires on a re-select).
        if tabId != lastActiveTabId {
            let oldTabId = lastActiveTabId
            lastActiveTabId = tabId
            tabChanged(from: oldTabId, to: tabId)
            delegate?.editorPane(self, didChangeActiveTab: tabId)
        }
    }

    /// Read the active tab from the tabs array and push its running-segment
    /// indices to the gutter (or empty set if the tab isn't executing).
    private func updateGutterPulseForActiveTab(tabs: [QueryTab]) {
        guard let activeTabId = session.activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId }) else {
            editorVC.setRunningSegmentIndices([])
            return
        }
        editorVC.setRunningSegmentIndices(Set(tab.runningQueries.map { $0.segmentIndex }))
    }

    private func refreshTabBar() {
        paneTabBar.update(tabs: session.tabs, activeTabId: session.activeTabId)
    }

    // MARK: - Tab Switching

    private func tabChanged(from oldTabId: String?, to newTabId: String?) {
        // Save cursor position of old tab
        if let oldTabId, editorVC.tabId == oldTabId {
            let cursorPos = editorVC.getCursorPosition()
            session.updateTab(id: oldTabId) { $0.cursorPosition = cursorPos }
        }

        guard let newTabId,
              let tab = session.tabs.first(where: { $0.id == newTabId }) else {
            editorVC.tabId = nil
            editorVC.setSQL("")
            syncResultTabsPanel()
            return
        }

        editorVC.tabId = newTabId
        editorVC.setSQL(tab.sql)
        editorVC.setCursorPosition(tab.cursorPosition)
        editorVC.clearErrorMarkers()

        // Sync global state to this tab's connection/schema so sidebar updates.
        // Only set when the value actually changes to avoid redundant reloads.
        if let connId = tab.connectionId, connId != session.activeConnectionId {
            session.activeConnectionId = connId
        } else if tab.connectionId == nil && session.activeConnectionId != nil {
            session.activeConnectionId = nil
        }
        if tab.schemaName != session.activeSchema {
            session.activeSchema = tab.schemaName
        }

        // Sync gutter pulse to the newly-activated tab.
        editorVC.setRunningSegmentIndices(Set(tab.runningQueries.map { $0.segmentIndex }))

        // The incoming tab's text references a different token set; the
        // sidebar must not wait out the typing debounce to learn it.
        referencedNamesScanTimer?.invalidate()
        publishReferencedNames()
        syncResultTabsPanel()
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

    /// The editor's current font size (9...24) — for the View menu's
    /// Increase/Decrease Editor Font items to validate against the clamp.
    var editorFontSize: Int {
        editorVC.currentFontSize
    }

    /// Steps the editor font size by one, same clamp and save path as a
    /// trackpad pinch. Used by the View menu's ⌘+ / ⌘− commands.
    func stepEditorFontSize(by delta: Int) {
        editorVC.stepFontSize(by: delta)
    }

    /// `range` is in document coordinates — see `QueryEditorVC.markError(range:)`.
    func markError(range: NSRange, message: String? = nil) {
        editorVC.markError(range: range, message: message)
    }

    func revealError(range: NSRange) {
        editorVC.revealError(range: range)
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
        session.updateTab(id: tabId) { $0.cursorPosition = cursorPos }
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

        // "Describe the query…" — next to Format, same treatment. The Apple
        // Intelligence glyph where the SDK has it; `systemSymbolName:` answers
        // nil for a name it does not know, so the fallback is a real check
        // rather than a version test.
        let describeDescription = String(localized: "Describe the query\u{2026}")
        describeQueryButton.image = (NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: describeDescription)
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: describeDescription))?
            .withSymbolConfiguration(fmtConfig)
        describeQueryButton.bezelStyle = .recessed
        describeQueryButton.isBordered = false
        describeQueryButton.contentTintColor = .secondaryLabelColor
        describeQueryButton.target = self
        describeQueryButton.action = #selector(describeQueryTapped)
        describeQueryButton.translatesAutoresizingMaskIntoConstraints = false
        describeQueryButton.setAccessibilityIdentifier("editor.describeQuery")
        describeQueryButton.setAccessibilityLabel(describeDescription)
        // Hidden until the availability sink says otherwise: a feature that
        // cannot run must not leave a disabled stub behind.
        describeQueryButton.isHidden = true

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
        saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
        saveDropdown.menu?.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "Save As\u{2026}", action: #selector(saveAsTapped), keyEquivalent: "")
        saveAsItem.target = self
        saveAsItem.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: "Save As")
        saveDropdown.menu?.addItem(saveAsItem)

        saveDropdown.menu?.addItem(.separator())

        let exportSQLItem = NSMenuItem(title: "Export as SQL File\u{2026}", action: #selector(exportAsSQLTapped), keyEquivalent: "")
        exportSQLItem.target = self
        exportSQLItem.image = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: "Export as SQL File")
        saveDropdown.menu?.addItem(exportSQLItem)

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

        // All controls in one row: Format, Describe, Save, Format-as-SQL-list.
        // The schema selector is in the window toolbar, beside the connection.
        let toolbarStack = NSStackView(
            views: [formatButton, describeQueryButton, saveDropdown, formatListButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        editorToolbar.addSubview(toolbarStack)

        // The error badge and the result-tabs toggle, right-aligned as one
        // group and not part of the leading stack.
        let resultTabsConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        // Not `sidebar.trailing`: that is the Inspector toggle's glyph, drawn
        // in the window toolbar directly above this button.
        resultTabsToggle.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Result Tabs")?.withSymbolConfiguration(resultTabsConfig)
        resultTabsToggle.bezelStyle = .recessed
        resultTabsToggle.isBordered = false
        resultTabsToggle.toolTip = "Show/Hide Result Tabs"
        resultTabsToggle.contentTintColor = .secondaryLabelColor
        resultTabsToggle.target = self
        resultTabsToggle.action = #selector(toggleResultTabsPanel)

        errorButton.target = self
        errorButton.action = #selector(showErrors)

        let trailingGroup = ErrorBadgeButton.makeToolbarTrailingGroup(
            errorButton: errorButton, resultTabsToggle: resultTabsToggle
        )
        editorToolbar.addSubview(trailingGroup)

        NSLayoutConstraint.activate([
            formatButton.widthAnchor.constraint(equalToConstant: 24),
            formatButton.heightAnchor.constraint(equalToConstant: 24),
            describeQueryButton.widthAnchor.constraint(equalToConstant: 24),
            describeQueryButton.heightAnchor.constraint(equalToConstant: 24),
            saveDropdown.widthAnchor.constraint(equalToConstant: 32),

            toolbarStack.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor, constant: 8),
            toolbarStack.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: editorToolbar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: editorToolbar.bottomAnchor),

            trailingGroup.trailingAnchor.constraint(equalTo: editorToolbar.trailingAnchor, constant: -8),
            trailingGroup.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),
        ])
    }

    @objc private func toggleResultTabsPanel() {
        guard let tabId = lastActiveTabId else { return }
        var nowVisible = false
        session.updateTab(id: tabId) {
            $0.resultTabsPanelVisible.toggle()
            nowVisible = $0.resultTabsPanelVisible
        }
        // Remember the choice so new tabs inherit it. Settings ▸ Results ▸
        // Result tabs is the home of that value now; `AppStateManager` pushes
        // it back onto `ResultTabsPanelPrefs`, which is what `QueryTab` reads.
        var updated = AppStateManager.shared.settings
        if updated.results.showResultTabsPanelByDefault != nowVisible {
            updated.results.showResultTabsPanelByDefault = nowVisible
            AppStateManager.shared.saveSettings(updated)
        }
        syncResultTabsPanel()
    }

    /// Push the failure-log state of this pane's active tab onto the badge.
    /// Called by ContentViewController; the `$tabs` sink cannot do this, because
    /// its `removeDuplicates` whitelist does not watch the failure log.
    func setErrorState(total: Int, unread: Int) {
        errorButton.setState(total: total, unread: unread)
    }

    /// Whether this pane is showing `tabId` right now.
    func showsTab(_ tabId: String) -> Bool {
        lastActiveTabId == tabId
    }

    @objc private func showErrors() {
        delegate?.editorPaneDidRequestShowErrors(self)
    }

    /// Width the visible divider takes, so a drag's ceiling is computed from
    /// the same budget `viewDidLayout` divides.
    private var currentDividersWidth: CGFloat {
        isResultTabsPanelVisible ? panelDividerWidth : 0
    }

    /// Resolve one drag event into a width to store, holding two invariants:
    ///
    /// - **Narrowing is always honoured**, unconditionally. The stored width is
    ///   the user's, and a drag that asks for less always gets less.
    /// - **Widening never LOWERS the stored width.** If the room is not there
    ///   the panel simply stops; the pref must not fall. An earlier attempt
    ///   clamped unconditionally to the free space, which forced the pref down
    ///   whenever the free space was below the panel's own minimum — and
    ///   collapsed it on a touch that never moved the pointer.
    ///
    /// The ceiling stops the pref running away past what can ever be displayed.
    /// Without it, over-widening left the pref far above the on-screen width, so
    /// the next drag had to travel that whole difference before the divider
    /// moved at all: measured as a 210pt dead zone.
    private func widthForDrag(requested: CGFloat, current: CGFloat, ceiling: CGFloat) -> CGFloat {
        guard requested > current else { return requested }
        return min(requested, max(current, ceiling))
    }

    /// The panel sits to the right of its divider, so dragging left (negative)
    /// widens it. Deriving the width from the drag-start snapshot each time —
    /// rather than nudging the current width — is what keeps the divider stuck
    /// to the cursor after an overshoot past the min or max.
    private func resizeResultTabsPanel(byOffset offset: CGFloat) {
        ResultTabsPanelPrefs.width = widthForDrag(
            requested: resultTabsPanelWidthAtDragStart - offset,
            current: ResultTabsPanelPrefs.width,
            ceiling: view.bounds.width - currentDividersWidth - minEditorWidth
        )
        view.needsLayout = true
    }

    /// The app-wide variable list changed (this window's sidebar or another's):
    /// recolour the `{{name}}` tokens the editor highlights.
    @objc private func queryVariablesDidChange(_ note: Notification) {
        applyQueryVariables()
    }

    private func applyQueryVariables() {
        let store = QueryVariableStore.shared
        editorVC.setVariableNames(store.definedNames)
        editorVC.setCompletionVariables(store.variables)
    }

    /// Re-scan the editor text for `{{token}}` references and publish the
    /// result on the window's session, where the sidebar's Variables navigator
    /// reads it to decide the red warning state. Debounced.
    private func scheduleReferencedNamesScan() {
        referencedNamesScanTimer?.invalidate()
        referencedNamesScanTimer = Timer.scheduledTimer(
            withTimeInterval: referencedNamesScanDelay, repeats: false
        ) { [weak self] _ in
            self?.publishReferencedNames()
        }
    }

    private func publishReferencedNames() {
        let names = VariableSubstitutor.referencedNames(in: editorVC.textView.string)
        if session.referencedVariableNames != names {
            session.referencedVariableNames = names
        }
    }

    /// Refresh the result-tabs toggle tint, its visibility (the button hides
    /// entirely while the setting selects the horizontal bar), and relayout.
    /// Driven imperatively — `resultTabsPanelVisible` is deliberately absent
    /// from the `$tabs` `removeDuplicates` whitelist. Called on toggle, on tab
    /// switch, and by ContentViewController when the setting flips.
    func syncResultTabsPanel() {
        let tab = lastActiveTabId.flatMap { id in session.tabs.first(where: { $0.id == id }) }
        let verticalMode = stateManager.settings.verticalResultTabs
        resultTabsToggle.isHidden = !verticalMode
        resultTabsToggle.contentTintColor = (verticalMode && (tab?.resultTabsPanelVisible ?? false))
            ? .controlAccentColor : .secondaryLabelColor
        view.needsLayout = true
    }

    /// Rows for this pane's panel, pushed by ContentViewController's
    /// refreshResultTabViews(). `activeId` is the result this pane's own tab
    /// holds, whether or not that tab is the focused one — an unfocused pane
    /// still highlights its own result rather than showing none.
    func updateResultTabs(_ rows: [ResultTabRowModel], activeId: String?) {
        resultTabsPanelVC.update(rows: rows, activeId: activeId)
    }

    @objc private func formatSQLTapped() {
        formatSQL()
    }

    @objc private func formatListTapped() {
        editorVC.textView.applyPendingSQLize()
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
        // "Save" item enabled when the tab has somewhere to save to — either
        // a saved query link or an on-disk source URL.
        let canSaveInPlace = activeTab?.savedQueryId != nil || activeTab?.sourceURL != nil
        if let saveItem = saveDropdown.menu?.item(at: 1) {
            saveItem.isEnabled = canSaveInPlace
        }
        updateDescribeQueryButton()
    }

    // MARK: - Describe the Query

    /// Show the button only where the feature can run, and enable it only
    /// where it has a schema to read.
    ///
    /// `available` is passed in by the availability sink and read from
    /// `ModelAvailability` by everyone else, for the `@Published` `willSet`
    /// reason spelled out in `ModelAvailability.publisher(for:)`.
    private func updateDescribeQueryButton(available: Bool? = nil) {
        let available = available ?? ModelAvailability.shared.isAvailable(for: .describeQuery)
        describeQueryButton.isHidden = !available
        guard available else {
            // A popover left open while the feature is switched off would
            // outlive its own button.
            closeDescribeQueryPopover()
            return
        }

        let connected = tabConnectionId.map { stateManager.status(for: $0) == .connected } ?? false
        describeQueryButton.isEnabled = connected
        describeQueryButton.toolTip = connected
            ? String(localized: "Describe the query\u{2026}")
            : String(localized: "Connect this tab to a database to draft a query.")
    }

    @objc private func describeQueryTapped() {
        guard ModelAvailability.shared.isAvailable(for: .describeQuery),
              describeQueryButton.isEnabled else { return }
        if describeQueryPopover != nil {
            closeDescribeQueryPopover()
            return
        }

        // The snapshot is taken now, so the model reads the schema as it
        // stands rather than whatever the cache held when the pane was built.
        let popoverVC = DescribeQueryPopoverVC(
            snapshot: .fromMetadataCache(metadataCache), defaultSchema: tabSchemaName)
        popoverVC.onInsert = { [weak self] sql in
            guard let self else { return }
            // Close first: the editor can only take the keyboard back once
            // the popover's window has given it up.
            self.closeDescribeQueryPopover()
            self.editorVC.insertDraft(sql)
        }
        popoverVC.onClose = { [weak self] in self?.closeDescribeQueryPopover() }

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.delegate = self
        describeQueryPopover = popover
        popover.show(relativeTo: describeQueryButton.bounds, of: describeQueryButton, preferredEdge: .maxY)
    }

    private func closeDescribeQueryPopover() {
        describeQueryPopover?.performClose(nil)
        describeQueryPopover = nil
    }

    // MARK: - Per-Tab Connection / Schema Helpers

    /// The active tab.
    private var activeTab: QueryTab? {
        session.activeTab
    }

    /// The connection ID for the active tab.
    private var tabConnectionId: String? {
        activeTab?.connectionId
    }

    /// The schema name for the active tab.
    private var tabSchemaName: String? {
        activeTab?.schemaName
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        referencedNamesScanTimer?.invalidate()
    }
}

// MARK: - NSPopoverDelegate

extension EditorPaneVC: NSPopoverDelegate {

    /// A transient popover closes itself when the analyst clicks elsewhere,
    /// and nothing else would tell the pane about it — leaving a stale
    /// reference that makes the next press on the button a no-op toggle.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === describeQueryPopover else {
            return
        }
        describeQueryPopover = nil
    }
}

// MARK: - Header row surface

/// The editor header row's ground: `ContrastInk.chromeGround`, the colour the
/// tab bar above it paints. Drawn, not set on a layer — a layer colour
/// resolved in `loadView` freezes at the launch appearance (tasks/lessons.md,
/// 2026-09-16); `draw(_:)` resolves against the live one every time.
private final class EditorHeaderRowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ContrastInk.chromeGround.setFill()
        bounds.fill()
    }
}
