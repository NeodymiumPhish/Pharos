import AppKit
import Combine

/// Delegate for EditorPaneVC events that need to be handled by the parent.
protocol EditorPaneDelegate: AnyObject {
    func editorPane(_ pane: EditorPaneVC, didChangeActiveTab tabId: String?)
    /// The context row's connection pop-up: move the tab to this connection
    /// (asking first when that would roll back an open transaction).
    func editorPane(_ pane: EditorPaneVC, didChooseConnection connectionId: String)
    /// The context row's Connect / Try Again.
    func editorPaneDidRequestConnect(_ pane: EditorPaneVC)
    func editorPaneDidRequestSave(_ pane: EditorPaneVC)
    func editorPaneDidRequestSaveAs(_ pane: EditorPaneVC)
    func editorPaneDidRequestExportAsSQL(_ pane: EditorPaneVC)
    func editorPaneDidRequestShowErrors(_ pane: EditorPaneVC)
    /// A `{{` completion row was accepted, or a `{{name}}` token was clicked:
    /// show that variable (creating it when no variable has the name).
    func editorPane(_ pane: EditorPaneVC, didChooseVariable name: String)

    // Query cards
    func editorPane(_ pane: EditorPaneVC, didRequestRunCard cardId: String, mode: CardRunMode)
    func editorPane(_ pane: EditorPaneVC, didRequestViewResultsOfCard cardId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestCancelCard cardId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestRenameCard cardId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestClearResultsOfCard cardId: String)
    func editorPane(_ pane: EditorPaneVC, didEditCard cardId: String)
    /// What the card's name row shows that only the results side knows.
    func editorPane(_ pane: EditorPaneVC, statusOf card: QueryCard, inTab tabId: String) -> CardStackVC.CardStatus
}

/// The editor area: the tab bar, the header row, and the active tab's query
/// cards (`CardStackVC`). It shows `WindowSession.activeTab`.
///
/// Query variables are not here. They are app-wide (`QueryVariableStore`)
/// and edited in the sidebar's Variables navigator; this pane only reports
/// which `{{name}}` tokens the cards reference
/// (`WindowSession.referencedVariableNames`) and highlights the defined names.
class EditorPaneVC: NSViewController {

    /// One completion list for every card of the window.
    let completionProvider = SQLCompletionProvider()
    let cardStack: CardStackVC

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
    private let newCardButton = NSButton()
    private let collapseAllButton = NSButton()

    /// Per-tab failure indicator. Hidden until the pane's active tab has a
    /// failure in its log.
    let errorButton = ErrorBadgeButton()

    /// Coalesces the `{{token}}` scan behind editor typing. The scan is a full
    /// regex pass over the text, so it runs once per pause rather than once per
    /// keystroke.
    private var referencedNamesScanTimer: Timer?
    private let referencedNamesScanDelay: TimeInterval = 0.15

    weak var delegate: EditorPaneDelegate?

    let session: WindowSession
    let stateManager = AppStateManager.shared
    let metadataCache = MetadataCache.shared
    /// The tab's connection › schema, its state and its transaction chip, at
    /// the start of the header row (`EditorPaneVC+TabContext.swift`).
    let tabContextBar = TabContextBar()
    /// Ticks once a second while a transaction is open, for the chip's age.
    var transactionChipTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(session: WindowSession) {
        self.session = session
        self.cardStack = CardStackVC(completionProvider: completionProvider)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View Lifecycle

    /// The pane's whole header: the tab's context row (connection › schema,
    /// state, transaction chip, then the editor's buttons). The tab bar is the
    /// window's own (native window tabs). 36, to hold regular-size pop-up
    /// buttons; the pane is still shorter than it was with its own tab bar.
    private let editorToolbarHeight: CGFloat = 36
    private var totalHeaderHeight: CGFloat { editorToolbarHeight }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        // Editor toolbar
        setupEditorToolbar()

        wireCardStack()
        addChild(cardStack)

        // Highlight the app-wide variable names in the cards and offer them
        // after `{{`, and follow the store: an edit in any window's sidebar
        // reaches every card.
        applyQueryVariables()
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryVariablesDidChange(_:)),
            name: QueryVariableStore.didChange, object: nil)

        container.addSubview(editorToolbar)
        container.addSubview(cardStack.view)
        wireTabContext()
        NotificationCenter.default.addObserver(
            self, selector: #selector(tabSessionDidChange(_:)),
            name: TabSessionMonitor.didChange, object: nil)

        NSLayoutConstraint.activate([
            editorToolbar.topAnchor.constraint(equalTo: container.topAnchor),
            editorToolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorToolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorToolbar.heightAnchor.constraint(equalToConstant: editorToolbarHeight),
        ])

        // The card stack uses frame-based layout — positioned in viewDidLayout.
        cardStack.view.frame = NSRect(
            x: 0, y: 0,
            width: container.bounds.width,
            height: max(0, container.bounds.height - totalHeaderHeight)
        )

        // Observe the active tab. Settled publisher, no run-loop hop: the
        // cards of the new tab are on screen by the time `selectTab` returns
        // (see `AppStateManager.tabsSettled`).
        session.activeTabIdSettled
            .sink { [weak self] tabId in
                self?.activeTabIdChanged(tabId)
            }
            .store(in: &cancellables)

        // Observe tab content changes (isDirty, isExecuting, name) + rebuild menus.
        // Dedup on the fields this sink actually reads. Without this, every
        // keystroke (which updates the tab's document via updateTab)
        // republishes the tabs and rebuilt every surface. Card state is not
        // here: the card stack is driven directly.
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
                        || a.runningQueries.map(\.cardId) != b.runningQueries.map(\.cardId)
                    {
                        return false
                    }
                }
                return true
            }
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateEditorToolbarState()
                self.cardStack.refreshStatus()
                self.refreshTabContext()
            }
            .store(in: &cancellables)
        // A card added, deleted or edited while a filter is typed changes the
        // count. Every keystroke republishes the tabs; the update is a no-op
        // when the text is unchanged.
        session.tabsSettled
            .sink { [weak self] _ in self?.updateCardFilterCount() }
            .store(in: &cancellables)

        // Push THIS window's connection's metadata to the completion list, once
        // per change to it. Another window's connection never reaches it.
        session.$activeConnectionId
            .removeDuplicates()
            .map { [metadataCache] id in metadataCache.publisher(for: id) }
            .switchToLatest()
            .receive(on: RunLoop.main)
            .sink { [weak self] metadata in
                self?.completionProvider.updateMetadata(
                    schemas: metadata.schemas, tables: metadata.tables, columnsByTable: metadata.columnsByTable)
            }
            .store(in: &cancellables)

        // The schema completion looks in first: the toolbar's pick for this
        // connection, else the connection's default.
        Publishers.CombineLatest(session.$activeSchema, session.$activeConnectionId)
            .receive(on: RunLoop.main)
            .sink { [weak self] schema, connectionId in
                guard let self else { return }
                let fallback = connectionId.flatMap { self.session.hooks.defaultSchema($0) }
                self.completionProvider.currentSchema = schema ?? fallback
            }
            .store(in: &cancellables)

        // Columns load per schema, lazily: the list asks for the schemas the
        // statement names so they are there by the next keystroke.
        completionProvider.onSchemaNeeded = { [weak self] schema in
            guard let self, let connectionId = self.session.activeConnectionId else { return }
            self.metadataCache.prioritize(schema: schema, connectionId: connectionId)
        }

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
        // dedup whitelist reads the tab, not the connection. The cards' Run
        // buttons grey out and ungrey on the same change (and on a rename,
        // which their reason quotes).
        stateManager.$connectionStatuses
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateDescribeQueryButton()
                self?.cardStack.refreshStatus()
                self?.refreshTabContext()
            }
            .store(in: &cancellables)
        stateManager.$connections
            .map { $0.map(\.name) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cardStack.refreshStatus() }
            .store(in: &cancellables)
        // The context row lists every connection (and its default schema), and
        // shows a failed connect's reason.
        Publishers.CombineLatest(stateManager.$connections, stateManager.$connectionErrors)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshTabContext() }
            .store(in: &cancellables)
        // The schema pop-up's title follows this tab's connection's metadata.
        session.$activeConnectionId
            .removeDuplicates()
            .map { [metadataCache] id in metadataCache.publisher(for: id) }
            .switchToLatest()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTabContext() }
            .store(in: &cancellables)
    }

    /// Connect the card stack to the active tab's document and to the
    /// delegate.
    private func wireCardStack() {
        cardStack.document = { [weak self] in
            guard let self, let id = self.cardStack.tabId else { return nil }
            return self.session.tabs.first(where: { $0.id == id })?.document
        }
        cardStack.mutate = { [weak self] change in
            guard let self, let id = self.cardStack.tabId else { return }
            self.session.updateTab(id: id) { change(&$0.document) }
        }
        cardStack.status = { [weak self] card in
            guard let self, let tabId = self.cardStack.tabId,
                  let delegate = self.delegate else { return CardStackVC.CardStatus() }
            return delegate.editorPane(self, statusOf: card, inTab: tabId)
        }
        cardStack.onRun = { [weak self] id, mode in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestRunCard: id, mode: mode)
        }
        cardStack.onViewResults = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestViewResultsOfCard: id)
        }
        cardStack.onCancel = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestCancelCard: id)
        }
        cardStack.onRenameRequest = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestRenameCard: id)
        }
        cardStack.onClearResults = { [weak self] id in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestClearResultsOfCard: id)
        }
        cardStack.onTextEdited = { [weak self] id, _ in
            guard let self, let tabId = self.cardStack.tabId else { return }
            self.session.updateTab(id: tabId) { $0.isDirty = true }
            self.delegate?.editorPane(self, didEditCard: id)
            // Adding or removing a `{{token}}` changes which variables are
            // referenced, and therefore which rows the sidebar's Variables
            // navigator flags.
            self.scheduleReferencedNamesScan()
        }
        cardStack.onVariableChosen = { [weak self] name in
            guard let self else { return }
            self.delegate?.editorPane(self, didChooseVariable: name)
        }
        cardStack.onListPasteOffer = { [weak self] offered in
            self?.formatListButton.isHidden = !offered
        }
        cardStack.validationConnectionId = { [weak self] in self?.session.activeConnectionId }
        // The same test `ContentViewController.runCard` applies, on the tab
        // the stack shows.
        cardStack.runUnavailableReason = { [weak self] in
            guard let self, let tabId = self.cardStack.tabId else { return nil }
            let connectionId = self.session.tabs.first(where: { $0.id == tabId })?.connectionId
            return CardRunAvailability.reason(
                connectionId: connectionId,
                connectionName: connectionId.flatMap { id in self.stateManager.connections.first(where: { $0.id == id })?.name },
                status: connectionId.map { self.stateManager.status(for: $0) })
        }
        cardStack.validationSchema = { [weak self] in self?.session.activeTab?.schemaName }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Non-flipped: y=0 is bottom. The header row is at the top via Auto
        // Layout; the cards fill the rest.
        let below = max(0, view.bounds.height - totalHeaderHeight)
        cardStack.view.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: below)
    }

    // MARK: - Tab session (the transaction chip)

    @objc private func tabSessionDidChange(_ note: Notification) {
        guard let tabId = note.userInfo?["tabId"] as? String, tabId == session.activeTabId else { return }
        refreshTransactionChip()
    }

    /// The chip's menu, and Query ▸ Commit / Roll Back Transaction.
    func sessionBannerAction(_ action: TabSessionBannerAction) {
        guard let tabId = session.activeTabId else { return }
        switch action {
        case .dismiss:
            TabSessionMonitor.shared.dismissReset(tabId)
        case .commit, .rollBack:
            let commit = action == .commit
            Task { @MainActor [weak self] in
                do {
                    let result = try await PharosCore.sessionEndTransaction(tabId: tabId, commit: commit)
                    TabSessionMonitor.shared.record(result.session)
                    if commit && !result.committed, let view = self?.view {
                        Toast.show(in: view, message: String(localized: "The transaction had failed, so it was rolled back."),
                                   style: .warning, duration: 4.0)
                    }
                } catch {
                    TabSessionMonitor.shared.refresh(tabId)
                    if let view = self?.view {
                        Toast.show(in: view, message: error.localizedDescription, style: .error, duration: 5.0)
                    }
                }
            }
        }
    }

    // MARK: - State Observation

    private var lastActiveTabId: String?

    private func activeTabIdChanged(_ tabId: String?) {
        refreshTabContext()

        // Detect active tab change (the publisher also fires on a re-select).
        if tabId != lastActiveTabId {
            let oldTabId = lastActiveTabId
            lastActiveTabId = tabId
            tabChanged(from: oldTabId, to: tabId)
            delegate?.editorPane(self, didChangeActiveTab: tabId)
        }
    }

    // MARK: - Tab Switching

    private func tabChanged(from oldTabId: String?, to newTabId: String?) {
        // A filter belongs to the tab it was typed for.
        if !cardFilterField.stringValue.isEmpty {
            cardFilterField.stringValue = ""
            cardStack.filter = ""
            updateCardFilterCount()
        }
        guard let newTabId,
              let tab = session.tabs.first(where: { $0.id == newTabId }) else {
            cardStack.show(tabId: nil)
            return
        }

        cardStack.show(tabId: newTabId)

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

        // The incoming tab's cards reference a different token set; the
        // sidebar must not wait out the typing debounce to learn it.
        referencedNamesScanTimer?.invalidate()
        publishReferencedNames()
        updateCollapseAllButton()
    }

    // MARK: - Public API

    /// Put the keyboard in the focused card.
    func focus() {
        guard let id = cardStack.document()?.focusedCardId else { return }
        cardStack.focusCard(id)
    }

    /// Format the focused card. A locked card keeps its text.
    func formatSQL() {
        guard let editor = cardStack.focusedEditor, editor.textView.isEditable else { return }
        editor.formatSQL()
    }

    /// The editor font size (9...24) — for the View menu's Increase/Decrease
    /// Editor Font items to validate against the clamp.
    var editorFontSize: Int {
        cardStack.focusedEditor?.currentFontSize ?? Int(stateManager.settings.editor.fontSize)
    }

    /// Steps the editor font size by one, same clamp and save path as a
    /// trackpad pinch. Used by the View menu's ⌘+ / ⌘− commands.
    func stepEditorFontSize(by delta: Int) {
        if let editor = cardStack.focusedEditor {
            editor.stepFontSize(by: delta)
            return
        }
        let size = FontSizeStepper.stepped(editorFontSize, by: delta)
        var updated = stateManager.settings
        guard updated.editor.fontSize != UInt32(size) else { return }
        updated.editor.fontSize = UInt32(size)
        stateManager.saveSettings(updated)
    }

    /// `range` counts into the card's text.
    func markError(cardId: String, range: NSRange, message: String? = nil) {
        cardStack.editor(for: cardId)?.markError(range: range, message: message)
    }

    func revealError(cardId: String, range: NSRange) {
        cardStack.focusCard(cardId)
        cardStack.editor(for: cardId)?.revealError(range: range)
    }

    func clearErrorMarkers(cardId: String) {
        cardStack.focusedEditor.flatMap { $0.documentId == cardId ? $0 : nil }?.clearErrorMarkers()
    }

    /// Put `text` in at the caret of the focused card, or in a new card when
    /// the focused card is locked.
    func insertText(_ text: String) {
        guard let doc = cardStack.document() else { return }
        if let id = doc.focusedCardId, doc.card(id)?.isLocked == false, let editor = cardStack.editor(for: id) {
            cardStack.focusCard(id)
            let range = editor.textView.selectedRange()
            editor.textView.insertText(text, replacementRange: range)
        } else {
            cardStack.addCard(after: doc.focusedCardId, sql: text)
        }
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

    /// The cards' run state or results changed: refresh the name rows.
    func refreshCards() {
        cardStack.refreshStatus()
    }

    /// The active tab's cards changed shape (a split, a new card): rebuild,
    /// keeping `anchor` in place on screen.
    func reloadCards(anchor: String? = nil, splitFrom locked: String? = nil) {
        if let locked, let anchor { cardStack.cardDidSplit(locked: locked, new: anchor) }
        cardStack.reload(anchor: anchor.map { .card($0) })
        updateCollapseAllButton()
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

        // New query card below the focused one (⌃⌘N).
        newCardButton.image = NSImage(systemSymbolName: "plus.rectangle", accessibilityDescription: String(localized: "New Query Card"))?.withSymbolConfiguration(fmtConfig)
        newCardButton.bezelStyle = .recessed
        newCardButton.isBordered = false
        newCardButton.toolTip = String(localized: "New Query Card (⌃⌘N)")
        newCardButton.contentTintColor = .secondaryLabelColor
        newCardButton.target = self
        newCardButton.action = #selector(newCardTapped)
        newCardButton.translatesAutoresizingMaskIntoConstraints = false
        newCardButton.setAccessibilityIdentifier("editor.newCard")

        // After the tab's context: Format, Describe, Save, New Card,
        // Format-as-SQL-list.
        let toolbarStack = NSStackView(
            views: [formatButton, describeQueryButton, saveDropdown, newCardButton, formatListButton])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        editorToolbar.addSubview(toolbarStack)
        tabContextBar.translatesAutoresizingMaskIntoConstraints = false
        editorToolbar.addSubview(tabContextBar)

        // The error badge and Collapse All, right-aligned as one group and
        // not part of the leading stack.
        collapseAllButton.bezelStyle = .recessed
        collapseAllButton.isBordered = false
        collapseAllButton.contentTintColor = .secondaryLabelColor
        collapseAllButton.target = self
        collapseAllButton.action = #selector(toggleCollapseAll)
        collapseAllButton.setAccessibilityIdentifier("editor.collapseAll")
        updateCollapseAllButton()

        errorButton.target = self
        errorButton.action = #selector(showErrors)

        let trailingGroup = ErrorBadgeButton.makeToolbarTrailingGroup(
            errorButton: errorButton, trailingButton: collapseAllButton
        )
        editorToolbar.addSubview(trailingGroup)

        // Filter cards: shows the cards whose name or SQL holds the text
        // (Apple HIG, Search fields: filter in place, as you type).
        cardFilterField.placeholderString = String(localized: "Filter Cards")
        cardFilterField.controlSize = .small
        cardFilterField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cardFilterField.sendsSearchStringImmediately = true
        cardFilterField.target = self
        cardFilterField.action = #selector(cardFilterChanged(_:))
        cardFilterField.translatesAutoresizingMaskIntoConstraints = false
        cardFilterField.setAccessibilityIdentifier("editor.filterCards")
        editorToolbar.addSubview(cardFilterField)

        cardFilterCountLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cardFilterCountLabel.textColor = .secondaryLabelColor
        cardFilterCountLabel.alignment = .right
        cardFilterCountLabel.lineBreakMode = .byTruncatingHead
        cardFilterCountLabel.isHidden = true
        cardFilterCountLabel.translatesAutoresizingMaskIntoConstraints = false
        // It gives way before the field and the buttons in a narrow pane.
        cardFilterCountLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        cardFilterCountLabel.setAccessibilityIdentifier("editor.filterCount")
        editorToolbar.addSubview(cardFilterCountLabel)

        NSLayoutConstraint.activate([
            formatButton.widthAnchor.constraint(equalToConstant: 24),
            formatButton.heightAnchor.constraint(equalToConstant: 24),
            describeQueryButton.widthAnchor.constraint(equalToConstant: 24),
            describeQueryButton.heightAnchor.constraint(equalToConstant: 24),
            saveDropdown.widthAnchor.constraint(equalToConstant: 32),
            newCardButton.widthAnchor.constraint(equalToConstant: 24),
            newCardButton.heightAnchor.constraint(equalToConstant: 24),

            tabContextBar.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor, constant: 10),
            tabContextBar.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),
            // 999: holds whenever the row has a width; gives way quietly in
            // the first layout at width 0 instead of breaking a required one.
            { let gap = toolbarStack.leadingAnchor.constraint(equalTo: tabContextBar.trailingAnchor, constant: 14)
              gap.priority = NSLayoutConstraint.Priority(999)
              return gap }(),
            toolbarStack.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: editorToolbar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: editorToolbar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: editorToolbar.bottomAnchor),

            trailingGroup.trailingAnchor.constraint(equalTo: editorToolbar.trailingAnchor, constant: -8),
            trailingGroup.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),

            cardFilterField.trailingAnchor.constraint(equalTo: trailingGroup.leadingAnchor, constant: -8),
            cardFilterField.centerYAnchor.constraint(equalTo: editorToolbar.centerYAnchor),
            // The field is 160 pt when there is room and gives way first in a
            // narrow pane, down to 80 pt. The gap to the leading buttons is
            // 999, not required, so the toolbar's first layout at width 0 does
            // not break (and log) a constraint.
            { let width = cardFilterField.widthAnchor.constraint(equalToConstant: 160)
              width.priority = .defaultHigh
              return width }(),
            cardFilterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cardFilterCountLabel.trailingAnchor.constraint(equalTo: cardFilterField.leadingAnchor, constant: -8),
            cardFilterCountLabel.firstBaselineAnchor.constraint(equalTo: cardFilterField.firstBaselineAnchor),
            { let gap = cardFilterField.leadingAnchor.constraint(greaterThanOrEqualTo: toolbarStack.trailingAnchor, constant: 8)
              gap.priority = NSLayoutConstraint.Priority(999)
              return gap }(),
            { let gap = cardFilterCountLabel.leadingAnchor.constraint(greaterThanOrEqualTo: toolbarStack.trailingAnchor, constant: 8)
              gap.priority = NSLayoutConstraint.Priority(999)
              return gap }(),
        ])
    }

    /// The Filter Cards field.
    let cardFilterField = NSSearchField()

    @objc private func cardFilterChanged(_ sender: NSSearchField) {
        cardStack.filter = sender.stringValue
        updateCardFilterCount()
    }

    /// "3 of 12 cards" left of the Filter Cards field while a filter is
    /// typed, so the user sees how much of the tab the filter hides.
    let cardFilterCountLabel = NSTextField(labelWithString: "")

    private func updateCardFilterCount() {
        guard let document = session.tab?.document,
              let count = CardStackLayout.filterCount(document, filter: cardFilterField.stringValue) else {
            cardFilterCountLabel.isHidden = true
            cardFilterCountLabel.stringValue = ""
            return
        }
        let text = CardStackLayout.filterCountText(shown: count.shown, total: count.total)
        guard cardFilterCountLabel.stringValue != text || cardFilterCountLabel.isHidden else { return }
        cardFilterCountLabel.stringValue = text
        cardFilterCountLabel.isHidden = false
    }

    @objc private func showErrors() {
        delegate?.editorPaneDidRequestShowErrors(self)
    }

    /// The app-wide variable list changed (this window's sidebar or another's):
    /// recolour the `{{name}}` tokens the editor highlights.
    @objc private func queryVariablesDidChange(_ note: Notification) {
        applyQueryVariables()
    }

    private func applyQueryVariables() {
        let store = QueryVariableStore.shared
        cardStack.setVariables(names: store.definedNames, completion: store.variables)
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
        let names = VariableSubstitutor.referencedNames(in: cardStack.allText)
        if session.referencedVariableNames != names {
            session.referencedVariableNames = names
        }
    }

    @objc private func formatSQLTapped() {
        formatSQL()
    }

    @objc private func formatListTapped() {
        cardStack.focusedEditor?.textView.applyPendingSQLize()
    }

    @objc private func newCardTapped() {
        cardStack.addCardBelowFocused()
    }

    /// Collapse every card, or expand them all when every card is collapsed.
    @objc private func toggleCollapseAll() {
        let allCollapsed = cardStack.document()?.cards.allSatisfy(\.isCollapsed) ?? false
        cardStack.setAllCollapsed(!allCollapsed)
        updateCollapseAllButton()
    }

    private func updateCollapseAllButton() {
        let allCollapsed = cardStack.document()?.cards.allSatisfy(\.isCollapsed) ?? false
        let title = allCollapsed ? String(localized: "Expand All Cards") : String(localized: "Collapse All Cards")
        collapseAllButton.image = NSImage(systemSymbolName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                                          accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        collapseAllButton.toolTip = title
        collapseAllButton.setAccessibilityLabel(title)
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

        // The keys, enum labels and comments are fetched now, while the
        // analyst types; the catalogue itself is read when Draft is pressed,
        // so it holds whatever the cache has loaded by then.
        let connectionId = session.activeConnectionId
        let facts = Self.fetchDraftFacts(
            metadataCache.metadata(for: connectionId), connectionId: connectionId, defaultSchema: tabSchemaName)
        let popoverVC = DescribeQueryPopoverVC(
            catalog: { [metadataCache] in
                DraftCatalog.from(metadataCache.metadata(for: connectionId), facts: await facts.value)
            },
            defaultSchema: tabSchemaName)
        popoverVC.onInsert = { [weak self] sql in
            guard let self else { return }
            // Close first: the editor can only take the keyboard back once
            // the popover's window has given it up.
            self.closeDescribeQueryPopover()
            self.insertDraft(sql)
        }
        popoverVC.onClose = { [weak self] in self?.closeDescribeQueryPopover() }

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.delegate = self
        describeQueryPopover = popover
        popover.show(relativeTo: describeQueryButton.bounds, of: describeQueryButton, preferredEdge: .maxY)
    }

    /// A drafted statement goes into the focused card when it is empty, else
    /// into a new card below it: one statement per card.
    private func insertDraft(_ sql: String) {
        guard let doc = cardStack.document() else { return }
        if let id = doc.focusedCardId, let card = doc.card(id), !card.isLocked,
           card.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let editor = cardStack.editor(for: id) {
            cardStack.focusCard(id)
            editor.insertDraft(sql)
        } else {
            cardStack.addCard(after: doc.focusedCardId)
            if let id = cardStack.document()?.focusedCardId, let editor = cardStack.editor(for: id) {
                editor.insertDraft(sql)
            }
        }
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

    /// The most schemas whose draft facts are fetched for one popover. Keys
    /// are stored on the referencing side, so a schema left out still shows
    /// the keys that point INTO it from the schemas fetched.
    private static let draftFactsSchemaLimit = 12

    /// Starts one facts query per schema, in parallel: the tab's schema
    /// first, then `public`, then the rest in catalogue order. A schema that
    /// fails is left out, and its tables keep the cache's types and no keys.
    private static func fetchDraftFacts(
        _ metadata: MetadataCache.ConnectionMetadata, connectionId: String?, defaultSchema: String?
    ) -> Task<[String: SchemaDraftFacts], Never> {
        var names = metadata.schemas.map(\.name)
        for first in [defaultSchema, "public"].compactMap({ $0 }).reversed() {
            if let at = names.firstIndex(of: first) { names.insert(names.remove(at: at), at: 0) }
        }
        let schemas = Array(names.prefix(draftFactsSchemaLimit))
        return Task {
            guard let connectionId else { return [:] }
            return await withTaskGroup(of: (String, SchemaDraftFacts?).self) { group in
                for schema in schemas {
                    group.addTask {
                        do {
                            return (schema, try await PharosCore.getSchemaDraftFacts(connectionId: connectionId, schema: schema))
                        } catch {
                            Log.intelligence.error("draft-sql: facts for a schema failed")
                            return (schema, nil)
                        }
                    }
                }
                var out: [String: SchemaDraftFacts] = [:]
                for await (schema, facts) in group { out[schema] = facts }
                return out
            }
        }
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
    /// The schema popover's close releases the schema pop-up's pressed look.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === describeQueryPopover {
            describeQueryPopover = nil
        } else {
            tabContextBar.schemaButton.isPresenting = false
        }
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
