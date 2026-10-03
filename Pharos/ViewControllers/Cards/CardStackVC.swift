import AppKit
import Combine

/// The flipped document view of the card stack.
private final class CardStackDocumentView: NSView {
    override var isFlipped: Bool { true }

    /// VoiceOver reads the cards top to bottom. Subviews are in the order
    /// they were added, so a new version added below an older card would
    /// otherwise be read last (found in the live check, 2026-10-02).
    override func accessibilityChildren() -> [Any]? {
        guard let children = super.accessibilityChildren() else { return nil }
        return children.enumerated().sorted { a, b in
            let ya = (a.element as? NSView)?.frame.minY ?? .greatestFiniteMagnitude
            let yb = (b.element as? NSView)?.frame.minY ?? .greatestFiniteMagnitude
            return ya == yb ? a.offset < b.offset : ya < yb
        }.map(\.element)
    }
}

/// One editor tab's query cards, top to bottom, in one scroll view.
///
/// The tab's `CardDocument` lives on the window session; this controller
/// reads it through `document` and changes it only through `mutate`. It
/// places the cards with `CardStackLayout` at manual frames, and keeps a live
/// `SQLEditorController` only for the cards that need one — those on screen
/// (and a screen either side), the focused card, and cards with undo
/// history. Every other card shows a `CardPreviewView` at the same size, so
/// a stack of hundreds of cards costs a few dozen editors.
final class CardStackVC: NSViewController {

    /// What only the owner knows about a card: whether it runs, whether its
    /// results are in memory and on screen, and whether its text differs from
    /// what ran (after variable substitution).
    struct CardStatus {
        var activity: CardActivity = .idle
        var resultInMemory = false
        var isDisplayed = false
        var isEdited = false
        /// "2 min ago · 45 ms"
        var meta = ""
    }

    // MARK: Wiring (set by EditorPaneVC)

    var document: () -> CardDocument? = { nil }
    var mutate: (_ change: (inout CardDocument) -> Void) -> Void = { _ in }
    var status: (QueryCard) -> CardStatus = { _ in CardStatus() }
    var onRun: ((_ cardId: String, _ mode: CardRunMode) -> Void)?
    var onViewResults: ((_ cardId: String) -> Void)?
    var onCancel: ((_ cardId: String) -> Void)?
    /// After the edit is in the document.
    var onTextEdited: ((_ cardId: String, _ text: String) -> Void)?
    var onFocusChanged: ((_ cardId: String) -> Void)?
    var onVariableChosen: ((String) -> Void)?
    var onRenameRequest: ((_ cardId: String) -> Void)?
    var onClearResults: ((_ cardId: String) -> Void)?
    var onListPasteOffer: ((_ offered: Bool) -> Void)?
    var validationConnectionId: () -> String? = { nil }
    /// The schema the tab's toolbar pull-down shows, for validation on the tab's connection.
    var validationSchema: () -> String? = { nil }

    let completionProvider: SQLCompletionProvider

    private(set) var variableNames: Set<String> = []
    private var completionVariables: [QueryVariable] = []

    // MARK: Views

    private let scrollView = NSScrollView()
    private let documentView = CardStackDocumentView()
    private var cardViews: [String: CardView] = [:]
    private var editors: [String: SQLEditorController] = [:]
    private var previews: [String: CardPreviewView] = [:]
    private var groupViews: [String: VersionGroupView] = [:]
    private lazy var addButton = AddCardButton(target: self, action: #selector(addCardAtEnd))

    private var items: [CardStackItem] = []
    private var frames: [CGRect] = []
    /// The editor tab whose cards are shown.
    private(set) var tabId: String?
    /// Filter cards (phase 9 search field). Empty shows all.
    var filter: String = "" { didSet { if oldValue != filter { reload() } } }

    private static let spacing: CGFloat = 10
    private static let inset: CGFloat = 12
    /// Most cards that keep a live editor only because of their undo history.
    private static let undoEditorCap = 40

    private var editorSettings: EditorSettings = AppStateManager.shared.settings.editor
    private var cancellables = Set<AnyCancellable>()
    private var relayoutScheduled = false
    private var poolScheduled = false

    init(completionProvider: SQLCompletionProvider) {
        self.completionProvider = completionProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        scrollView.setAccessibilityIdentifier("editor.cards")
        scrollView.setAccessibilityLabel(String(localized: "Query cards"))
        // VO-U lists the cards; moving through them reads each card's label.
        let rotor = NSAccessibilityCustomRotor(label: String(localized: "Query Cards"), itemSearchDelegate: self)
        scrollView.setAccessibilityCustomRotors([rotor])
        documentView.addSubview(addButton)
        view = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        AppStateManager.shared.$settings
            .map(\.editor)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] editor in
                guard let self else { return }
                self.editorSettings = editor
                self.refreshPreviews()
                self.scheduleRelayout()
            }
            .store(in: &cancellables)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayout() {
        super.viewDidLayout()
        relayout(anchor: nil)
    }

    // MARK: - Showing a tab

    /// Show `tabId`'s cards. Drops every live editor of the previous tab.
    func show(tabId: String?) {
        for editor in editors.values { tearDown(editor) }
        editors.removeAll()
        for v in cardViews.values { v.removeFromSuperview() }
        cardViews.removeAll()
        previews.removeAll()
        for v in groupViews.values { v.removeFromSuperview() }
        groupViews.removeAll()
        self.tabId = tabId
        items = []
        frames = []
        reload()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let focused = document()?.focusedCardId { scrollToCard(focused) }
    }

    /// Rebuild the rows from the document: add and remove card views, refresh
    /// every name row, lay out. `anchor` stays where it is on screen.
    func reload(anchor: CardStackItem? = nil) {
        guard isViewLoaded else { return }
        guard let doc = document() else {
            items = []
            relayout(anchor: nil)
            return
        }
        let anchor = anchor ?? doc.focusedCardId.map { CardStackItem.card($0) }
        items = CardStackLayout.items(doc, filter: filter)
        let liveIds = Set(items.compactMap { if case let .card(id) = $0 { return id } else { return nil } })

        for (id, v) in cardViews where !liveIds.contains(id) {
            v.removeFromSuperview()
            cardViews[id] = nil
            if let e = editors.removeValue(forKey: id) { tearDown(e) }
            previews[id] = nil
        }
        let liveGroups = Set(items.compactMap { if case let .versionGroup(l, _) = $0 { return l } else { return nil } })
        for (id, v) in groupViews where !liveGroups.contains(id) {
            v.removeFromSuperview()
            groupViews[id] = nil
        }

        for item in items {
            switch item {
            case let .card(id):
                if cardViews[id] == nil { cardViews[id] = makeCardView(id) }
                // An editor handed over by a split, not yet in its card.
                if let editor = editors[id], let view = cardViews[id], view.body !== editor.view {
                    view.setBody(editor.view)
                }
            case let .versionGroup(lineage, ids):
                let v = groupViews[lineage] ?? makeGroupView(lineage)
                groupViews[lineage] = v
                let name = doc.card(ids.first ?? "")?.name ?? String(localized: "Untitled query")
                v.show(name: name, versions: ids.compactMap { id in doc.card(id).map { (id, $0.version) } })
            case .addCard:
                break
            }
        }
        addButton.isHidden = !items.contains(.addCard)
        refreshStatus()
        relayout(anchor: anchor)
        findTextChanged()
        if let editor = refocusAfterReload {
            refocusAfterReload = nil
            if editor.view.window != nil { view.window?.makeFirstResponder(editor.textView) }
        }
    }

    // MARK: - Name rows

    /// Refresh the cards' name rows, stripes and rings from the document and
    /// the owner's status — every card, or only `only` (a keystroke refreshes
    /// the card being typed in, not the whole stack).
    func refreshStatus(only: Set<String>? = nil) {
        guard let doc = document() else { return }
        var lineageCounts: [String: Int] = [:]
        for c in doc.cards { lineageCounts[c.lineageId, default: 0] += 1 }
        var position = 0
        for item in items {
            guard case let .card(id) = item, let card = doc.card(id), let view = cardViews[id] else { continue }
            position += 1
            if let only, !only.contains(id) {
                view.isFocused = doc.focusedCardId == id
                continue
            }
            let st = status(card)
            let p = CardPresentation.make(card: card, position: position, lineageCount: lineageCounts[card.lineageId] ?? 1,
                                          isEdited: st.isEdited, activity: st.activity,
                                          resultInMemory: st.resultInMemory, isDisplayed: st.isDisplayed)
            let meta = card.isCollapsed ? firstLine(of: card.sql) : st.meta
            view.header.apply(p, color: CardPalette.color(card.colorIndex), isCollapsed: card.isCollapsed, meta: meta)
            view.color = CardPalette.color(card.colorIndex)
            view.isFocused = doc.focusedCardId == id
            view.isDisplayed = st.isDisplayed
            view.isLocked = card.isLocked
            if view.isCollapsed != card.isCollapsed { view.isCollapsed = card.isCollapsed }
            view.setAccessibilityLabel(p.accessibilityLabel)
            view.setAccessibilityIdentifier("editor.card.\(position)")
            view.header.setIdentifiers(prefix: "editor.card.\(position)")
            if let editor = editors[id] {
                editor.identifierPrefix = "editor.card.\(position)"
                editor.textView.isEditable = !card.isLocked
            }
        }
    }

    private func firstLine(of sql: String) -> String {
        sql.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // MARK: - Layout

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.relayout(anchor: nil)
        }
    }

    private func relayout(anchor: CardStackItem?) {
        guard isViewLoaded else { return }
        let width = max(200, scrollView.contentSize.width)
        let bodyWidth = width - Self.inset * 2 - CardView.stripeWidth - 1
        let oldItems = items
        let oldFrames = frames
        let oldOffset = scrollView.contentView.bounds.origin.y

        func height(_ item: CardStackItem) -> CGFloat {
            switch item {
            case let .card(id):
                guard let view = cardViews[id] else { return CardHeaderView.height }
                if !view.isCollapsed {
                    view.bodyHeight = bodyHeight(for: id, width: bodyWidth)
                }
                return view.fittingHeight
            case .versionGroup: return VersionGroupView.height
            case .addCard: return AddCardButton.height
            }
        }
        frames = CardStackLayout.frames(items, height: height, width: width, spacing: Self.spacing, inset: Self.inset)
        for (item, frame) in zip(items, frames) {
            switch item {
            case let .card(id):
                guard let view = cardViews[id] else { continue }
                if view.superview == nil { documentView.addSubview(view) }
                view.frame = frame
                view.needsLayout = true
            case let .versionGroup(lineage, _):
                guard let view = groupViews[lineage] else { continue }
                if view.superview == nil { documentView.addSubview(view) }
                view.frame = frame
            case .addCard:
                addButton.frame = frame
            }
        }
        let contentHeight = CardStackLayout.contentHeight(frames, inset: Self.inset)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(contentHeight, scrollView.contentSize.height))

        if let anchor, !oldItems.isEmpty {
            let offset = CardStackLayout.anchoredOffset(oldItems: oldItems, oldFrames: oldFrames, newItems: items,
                                                        newFrames: frames, anchor: anchor, oldOffset: oldOffset)
            let maxOffset = max(0, documentView.frame.height - scrollView.contentSize.height)
            if abs(offset - oldOffset) > 0.5 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(offset, maxOffset)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        updateEditorPool()
    }

    /// The body height of a card at `width`: its live editor's, or its preview's.
    private func bodyHeight(for cardId: String, width: CGFloat) -> CGFloat {
        if let editor = editors[cardId] {
            var f = editor.view.frame
            if abs(f.width - width) > 0.5 {
                f.size = NSSize(width: width, height: max(f.height, 40))
                editor.view.frame = f
                editor.view.layoutSubtreeIfNeeded()
            }
            return editor.contentHeight
        }
        let preview = previews[cardId] ?? makePreview(cardId)
        return preview.height(forWidth: width)
    }

    // MARK: - Editor pool

    @objc private func clipBoundsChanged() {
        guard !poolScheduled else { return }
        poolScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.poolScheduled = false
            self?.updateEditorPool()
        }
    }

    /// Give live editors to the cards that need one and previews to the rest.
    private func updateEditorPool() {
        guard let doc = document() else { return }
        let visible = scrollView.contentView.bounds
        let screen = max(visible.height, 200)
        let wide = visible.insetBy(dx: 0, dy: -screen)
        let range = CardStackLayout.visibleIndices(frames, visible: wide)
        var wanted = Set<String>()
        for i in range where i < items.count {
            if case let .card(id) = items[i], doc.card(id)?.isCollapsed == false { wanted.insert(id) }
        }
        if let f = doc.focusedCardId, cardViews[f] != nil, doc.card(f)?.isCollapsed == false { wanted.insert(f) }
        for id in forcedLive where cardViews[id] != nil && doc.card(id)?.isCollapsed == false { wanted.insert(id) }
        // Undo history is a user's work in progress: keep it, up to a cap.
        let withUndo = editors.filter { $0.value.textView.undoManager?.canUndo == true }.map(\.key)
        for id in withUndo.prefix(Self.undoEditorCap) where cardViews[id] != nil { wanted.insert(id) }

        var changed = false
        for id in wanted where editors[id] == nil {
            guard let card = doc.card(id), let view = cardViews[id] else { continue }
            let editor = makeEditor(for: card)
            editors[id] = editor
            previews[id] = nil
            view.setBody(editor.view)
            changed = true
        }
        for (id, editor) in editors where !wanted.contains(id) {
            tearDown(editor)
            editors[id] = nil
            if let view = cardViews[id] {
                view.setBody(makePreview(id))
            }
            changed = true
        }
        if changed {
            refreshStatus()
            scheduleRelayout()
        }
    }

    private func makeEditor(for card: QueryCard) -> SQLEditorController {
        let editor = SQLEditorController(completionProvider: completionProvider)
        addChild(editor)
        _ = editor.view
        editor.documentId = card.id
        editor.setSQL(card.sql)
        editor.setCursorPosition(card.cursorPosition)
        editor.setVariableNames(variableNames)
        editor.setCompletionVariables(completionVariables)
        // One find bar for the whole stack, not one per card.
        editor.textView.usesFindBar = false
        editor.textView.textFinderActionHandler = { [weak self] action in self?.performFind(action) ?? false }
        editor.textView.textFinderActionValidator = { [weak self] action in self?.canPerformFind(action) ?? false }
        editor.validationConnectionId = { [weak self] in self?.validationConnectionId() }
        editor.validationTab = { [weak self] in
            guard let self, let tabId = self.tabId else { return nil }
            return (tabId, self.validationSchema())
        }
        editor.textView.isEditable = !card.isLocked
        editor.onTextEdited = { [weak self] cardId, text in
            guard let self else { return }
            var accepted = false
            self.mutate { doc in accepted = doc.updateSQL(cardId: cardId, text) }
            guard accepted else { return }
            self.findTextChanged()
            self.onTextEdited?(cardId, text)
            self.refreshStatus(only: [cardId])
        }
        editor.onContentHeightChange = { [weak self] in self?.scheduleRelayout() }
        // The card an editor serves can change (a split hands the editor to
        // the new version), so these read `documentId` rather than capture it.
        editor.onFocus = { [weak self, weak editor] in
            guard let id = editor?.documentId else { return }
            self?.cardDidTakeFocus(id)
        }
        editor.onSelectionChange = { [weak self, weak editor] in
            guard let self, let editor, let id = editor.documentId else { return }
            let position = editor.getCursorPosition()
            self.mutate { doc in
                if let i = doc.index(of: id) { doc.cards[i].cursorPosition = position }
            }
            self.keepCaretVisible(id)
        }
        editor.onVariableChosen = { [weak self] name in self?.onVariableChosen?(name) }
        editor.textView.onListPasteDetected = { [weak self] in self?.onListPasteOffer?(true) }
        editor.textView.onListPasteOfferInvalidated = { [weak self] in self?.onListPasteOffer?(false) }
        return editor
    }

    private func tearDown(_ editor: SQLEditorController) {
        // Put the caret where the user left it back into the document, so the
        // next editor for this card opens there.
        if let id = editor.documentId {
            let position = editor.getCursorPosition()
            mutate { doc in if let i = doc.index(of: id) { doc.cards[i].cursorPosition = position } }
        }
        if completionProvider.isShown, view.window?.firstResponder === editor.textView { completionProvider.dismiss() }
        editor.documentId = nil
        editor.view.removeFromSuperview()
        editor.removeFromParent()
    }

    private func makePreview(_ cardId: String) -> CardPreviewView {
        let preview = previews[cardId] ?? CardPreviewView()
        previews[cardId] = preview
        if let card = document()?.card(cardId) { configure(preview, card: card) }
        preview.onActivate = { [weak self] index in self?.focusCard(cardId, characterIndex: index) }
        return preview
    }

    private func configure(_ preview: CardPreviewView, card: QueryCard) {
        preview.show(sql: card.sql, font: SQLEditorController.editorFont(family: editorSettings.fontFamily, size: CGFloat(editorSettings.fontSize)),
                     theme: SQLTheme.named(editorSettings.syntaxTheme), wraps: editorSettings.wordWrap,
                     showsLineNumbers: editorSettings.lineNumbers, variableNames: variableNames)
    }

    private func refreshPreviews() {
        guard let doc = document() else { return }
        for (id, preview) in previews {
            if let card = doc.card(id) { configure(preview, card: card) }
        }
    }

    // MARK: - Card views

    private func makeCardView(_ id: String) -> CardView {
        let view = CardView(cardId: id)
        let h = view.header
        h.onRun = { [weak self] in self?.onRun?(id, .run) }
        h.onRunReplace = { [weak self] in self?.onRun?(id, .replace) }
        h.onCancel = { [weak self] in self?.onCancel?(id) }
        h.onViewResults = { [weak self] in self?.onViewResults?(id) }
        h.onRename = { [weak self] in self?.onRenameRequest?(id) }
        h.onToggleCollapse = { [weak self] in self?.toggleCollapsed(id) }
        h.menuProvider = { [weak self] in self?.menu(for: id) ?? NSMenu() }
        view.setBody(makePreview(id))
        return view
    }

    private func makeGroupView(_ lineage: String) -> VersionGroupView {
        let view = VersionGroupView()
        view.onExpand = { [weak self] in self?.setLineageExpanded(lineage, true) }
        view.onShowVersion = { [weak self] id in self?.onViewResults?(id) }
        return view
    }

    private func menu(for id: String) -> NSMenu {
        let menu = NSMenu()
        guard let card = document()?.card(id) else { return menu }
        let st = status(card)
        func item(_ title: String, _ handler: @escaping () -> Void, enabled: Bool = true) {
            let i = ClosureMenuItem(title: title, handler: handler)
            i.isEnabled = enabled
            menu.addItem(i)
        }
        let runnable = card.kind == .sql
        item(String(localized: "Run"), { [weak self] in self?.onRun?(id, .run) }, enabled: runnable)
        item(String(localized: "Run and Replace Results"), { [weak self] in self?.onRun?(id, .replace) }, enabled: runnable)
        if st.resultInMemory {
            item(String(localized: "View Results"), { [weak self] in self?.onViewResults?(id) })
        }
        menu.addItem(.separator())
        item(String(localized: "Rename\u{2026}"), { [weak self] in self?.onRenameRequest?(id) })
        if card.isLocked {
            item(String(localized: "Edit as New Card"), { [weak self] in self?.editAsNewCard(id) })
        }
        item(String(localized: "Copy SQL"), {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(card.sql, forType: .string)
        })
        item(card.isCollapsed ? String(localized: "Expand Card") : String(localized: "Collapse Card"), { [weak self] in self?.toggleCollapsed(id) })
        if st.resultInMemory {
            item(String(localized: "Clear Results"), { [weak self] in self?.onClearResults?(id) })
        }
        menu.addItem(.separator())
        item(card.isLocked ? String(localized: "Delete Version") : String(localized: "Delete Card"), { [weak self] in self?.deleteCard(id) })
        return menu
    }

    // MARK: - Actions

    @objc private func addCardAtEnd() {
        addCard(after: document()?.cards.last?.id)
    }

    /// A new blank card after `cardId` (at the end when nil), focused.
    func addCard(after cardId: String?, sql: String = "", name: String? = nil) {
        var newId = ""
        mutate { doc in newId = doc.insertCard(after: cardId, sql: sql, name: name) }
        reload(anchor: cardId.map { .card($0) })
        focusCard(newId)
    }

    /// Add a card below the focused one (⌃⌘N).
    func addCardBelowFocused() {
        addCard(after: document()?.focusedCardId)
    }

    func editAsNewCard(_ id: String) {
        var newId: String?
        mutate { doc in newId = doc.editAsNewCard(from: id) }
        reload(anchor: .card(id))
        if let newId { focusCard(newId) }
    }

    func toggleCollapsed(_ id: String) {
        guard let card = document()?.card(id) else { return }
        mutate { doc in doc.setCollapsed(cardId: id, !card.isCollapsed) }
        reload(anchor: .card(id))
    }

    /// Collapse or expand every card.
    func setAllCollapsed(_ collapsed: Bool) {
        mutate { doc in for i in doc.cards.indices { doc.cards[i].isCollapsed = collapsed } }
        reload()
    }

    func setLineageExpanded(_ lineage: String, _ expanded: Bool) {
        mutate { doc in
            if expanded { doc.expandedLineages.insert(lineage) } else { doc.expandedLineages.remove(lineage) }
        }
        reload()
    }

    /// Delete a card. Undo (⌘Z in the card that takes focus) puts it back.
    func deleteCard(_ id: String) {
        var removed: (card: QueryCard, index: Int)?
        mutate { doc in removed = doc.deleteCard(cardId: id) }
        guard let removed else { return }
        reload()
        if let focused = document()?.focusedCardId {
            focusCard(focused)
            let undo = editors[focused]?.textView.undoManager ?? view.window?.undoManager
            undo?.registerUndo(withTarget: self) { target in
                target.mutate { doc in doc.restoreCard(removed.card, at: removed.index) }
                target.reload()
                target.focusCard(removed.card.id)
            }
            undo?.setActionName(String(localized: "Delete Card"))
        }
    }

    // MARK: - Focus

    private func cardDidTakeFocus(_ id: String) {
        guard document()?.focusedCardId != id else { return }
        mutate { doc in doc.focusedCardId = id }
        refreshStatus()
        onFocusChanged?(id)
    }

    /// Put the keyboard in a card, with a live editor, and scroll it into view.
    func focusCard(_ id: String, characterIndex: Int? = nil) {
        guard let doc = document(), let card = doc.card(id) else { return }
        if card.isCollapsed {
            mutate { d in d.setCollapsed(cardId: id, false) }
        }
        if doc.focusedCardId != id {
            mutate { d in d.focusedCardId = id }
            onFocusChanged?(id)
        }
        if !items.contains(.card(id)) { reload() }
        updateEditorPool()
        relayout(anchor: nil)
        guard let editor = editors[id] else { return }
        view.window?.makeFirstResponder(editor.textView)
        if let characterIndex { editor.setCursorPosition(characterIndex) }
        refreshStatus()
        scrollToCard(id)
    }

    /// A run after an edit split `locked` (which keeps its results and its
    /// old SQL) from `new` (the edited SQL). The live editor — the user's
    /// text, caret and undo history — goes to `new`; `locked` shows its own
    /// SQL in a fresh preview. Call before `reload`.
    func cardDidSplit(locked: String, new: String) {
        guard let editor = editors.removeValue(forKey: locked) else { return }
        if view.window?.firstResponder === editor.textView { refocusAfterReload = editor }
        if let old = editors.removeValue(forKey: new) { tearDown(old) }
        editors[new] = editor
        editor.documentId = new
        editor.textView.isEditable = true
        previews[locked] = nil
        cardViews[locked]?.setBody(makePreview(locked))
    }

    /// An editor that had the keyboard when a split moved it between cards.
    private weak var refocusAfterReload: SQLEditorController?

    /// The focused card's live editor.
    var focusedEditor: SQLEditorController? {
        document()?.focusedCardId.flatMap { editors[$0] }
    }

    /// Cards that need a live editor for a moment without taking the focus
    /// (an error marker going on), most recent last.
    private var forcedLive: [String] = []

    /// The card's editor, made live if it was a preview. The focus stays
    /// where it is.
    func editor(for cardId: String) -> SQLEditorController? {
        if editors[cardId] == nil {
            forcedLive.removeAll { $0 == cardId }
            forcedLive.append(cardId)
            if forcedLive.count > 8 { forcedLive.removeFirst() }
            updateEditorPool()
        }
        return editors[cardId]
    }

    /// Move the focus to the card above or below (⌃⌘↑ / ⌃⌘↓).
    func moveFocus(by delta: Int) {
        guard let doc = document() else { return }
        let ids = items.compactMap { if case let .card(id) = $0 { return id } else { return nil } }
        guard !ids.isEmpty else { return }
        let current = doc.focusedCardId.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = max(0, min(ids.count - 1, current + delta))
        focusCard(ids[next])
    }

    func scrollToCard(_ id: String) {
        guard let i = items.firstIndex(of: .card(id)), i < frames.count else { return }
        let frame = frames[i]
        let visible = scrollView.contentView.bounds
        // The whole card when it fits, else its top.
        let target = frame.height <= visible.height ? frame : NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: visible.height)
        documentView.scrollToVisible(target.insetBy(dx: 0, dy: -Self.spacing))
    }

    private func keepCaretVisible(_ id: String) {
        guard let editor = editors[id], let card = cardViews[id], let caret = editor.caretRectInView else { return }
        let inCard = card.convert(caret, from: editor.view)
        let inDoc = documentView.convert(inCard, from: card)
        documentView.scrollToVisible(inDoc.insetBy(dx: 0, dy: -24))
    }

    // MARK: - Find across cards

    private lazy var finderClient = CardStackFinderClient(stack: self)
    private lazy var textFinder: NSTextFinder = {
        let finder = NSTextFinder()
        finder.client = finderClient
        finder.findBarContainer = scrollView
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
        return finder
    }()
    private var finderUsed = false

    /// Edit ▸ Find on the stack. Returns false when the action does not apply.
    @discardableResult
    func performFind(_ action: NSTextFinder.Action) -> Bool {
        guard isViewLoaded, textFinder.validateAction(action) else { return false }
        finderUsed = true
        textFinder.performAction(action)
        return true
    }

    func canPerformFind(_ action: NSTextFinder.Action) -> Bool {
        isViewLoaded && textFinder.validateAction(action)
    }

    /// The cards' text or their order changed: the finder searches anew.
    private func findTextChanged() {
        guard finderUsed else { return }
        finderClient.invalidate()
        textFinder.noteClientStringWillChange()
    }

    /// The cards find searches: the laid-out, unfolded cards, in stack order.
    func findableCards() -> [(id: String, sql: String)] {
        guard let doc = document() else { return [] }
        return items.compactMap { item in
            guard case let .card(id) = item, let card = doc.card(id), !card.isCollapsed else { return nil }
            return (id, card.sql)
        }
    }

    /// The cards at least partly on screen.
    func visibleCardIds() -> [String] {
        let visible = scrollView.contentView.bounds
        return CardStackLayout.visibleIndices(frames, visible: visible).compactMap { i in
            guard i < items.count, case let .card(id) = items[i] else { return nil }
            return id
        }
    }

    /// The focused card's selection, in its own terms.
    func focusedSelection() -> (cardId: String, range: NSRange)? {
        guard let id = document()?.focusedCardId, let editor = editors[id] else { return nil }
        return (id, editor.textView.selectedRange())
    }

    /// Select a match in its card and make that card the focused one, while
    /// the keyboard stays in the find bar.
    func selectMatch(cardId: String, range: NSRange) {
        guard let editor = editor(for: cardId) else { return }
        editor.textView.setSelectedRange(range)
        if document()?.focusedCardId != cardId {
            mutate { doc in doc.focusedCardId = cardId }
            refreshStatus()
            onFocusChanged?(cardId)
        }
    }

    /// Scroll a match into view.
    func revealMatch(cardId: String, range: NSRange) {
        guard let editor = editor(for: cardId), let card = cardViews[cardId] else { return }
        relayout(anchor: nil)
        let textView = editor.textView
        guard let rect = textView.findRects(forCharacterRange: range).first?.rectValue else {
            scrollToCard(cardId)
            return
        }
        let inDoc = documentView.convert(card.convert(rect, from: textView), from: card)
        documentView.scrollToVisible(inDoc.insetBy(dx: 0, dy: -24))
    }

    // MARK: - Variables

    func setVariables(names: Set<String>, completion: [QueryVariable]) {
        variableNames = names
        completionVariables = completion
        for editor in editors.values {
            editor.setVariableNames(names)
            editor.setCompletionVariables(completion)
        }
        refreshPreviews()
    }

    /// The text of every card, for the `{{name}}` scan.
    var allText: String { document()?.cards.map(\.sql).joined(separator: "\n") ?? "" }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func fire() { handler() }
}

// MARK: - VoiceOver rotor

// The SDK marks this delegate main-actor, so the method is isolated like the
// rest of the controller (an earlier `nonisolated` + `assumeIsolated` made the
// result cross actors, which ItemResult cannot).
extension CardStackVC: NSAccessibilityCustomRotorItemSearchDelegate {
    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let ids = items.compactMap { item -> String? in
            if case let .card(id) = item { return id } else { return nil }
        }
        var labels: [String: String] = [:]
        for id in ids { labels[id] = cardViews[id]?.accessibilityLabel() ?? "" }
        let current = (searchParameters.currentItem?.targetElement as? CardView)?.cardId
        guard let target = CardStackLayout.rotorTarget(
            ids: ids, labels: labels, current: current,
            forward: searchParameters.searchDirection == .next, filter: searchParameters.filterString),
              let view = cardViews[target] else { return nil }
        scrollToCard(target)
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: view)
        result.customLabel = labels[target]
        return result
    }
}
