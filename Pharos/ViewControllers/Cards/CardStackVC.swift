import AppKit
import Combine

/// The flipped document view of the card stack.
private final class CardStackDocumentView: NSView {
    override var isFlipped: Bool { true }

    /// The pointer moved over the stack (document coordinates), or left it:
    /// the gap "+" follows it.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Added once, following the view (AppKit does not call
        // `updateTrackingAreas` for a view it has just added).
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

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
        /// "2 min ago · 45 ms", or "Running · 42% · …" while it runs.
        var meta = ""
        /// 0–100 while it runs and the engine has an estimate; nil otherwise.
        var progress: Double?
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
    /// The "Change Variable To" submenu for a `{{name}}` chip's context menu.
    var changeVariableMenu: ((_ name: String) -> NSMenu?)?
    var onRenameRequest: ((_ cardId: String) -> Void)?
    var onClearResults: ((_ cardId: String) -> Void)?
    /// After the card is out of the document: its results go with it.
    var onCardDeleted: ((_ cardId: String) -> Void)?
    var onListPasteOffer: ((_ offered: Bool) -> Void)?
    /// After a notes change is in the document (typing, or comments moved
    /// into the notes).
    var onNotesEdited: ((_ cardId: String) -> Void)?
    /// A card's notes lost the keyboard: the moment to store them in history.
    var onNotesEndEditing: ((_ cardId: String) -> Void)?
    /// The cards' order changed (a move, or a card inserted between others):
    /// the tab's text changed, so the tab is edited.
    var onStructureEdited: (() -> Void)?
    var validationConnectionId: () -> String? = { nil }
    /// Whether a data file dropped on a card is queried in place (a DuckDB
    /// tab). Asked at drag time.
    var acceptsDataFileDrops: () -> Bool = { false }
    /// Why the tab's cards cannot run now (no connected database), or nil.
    var runUnavailableReason: () -> String? = { nil }
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
    /// Keyed by `groupKey`: a query can have two folded rows, one each side
    /// of a version whose results are on screen.
    private var groupViews: [String: VersionGroupView] = [:]

    private static func groupKey(_ lineage: String, _ cardIds: [String]) -> String {
        "\(lineage)/\(cardIds.first ?? "")"
    }
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
    /// The card whose notes divider is being dragged: its width lives in the
    /// view until the drag ends, so a refresh must not reset it.
    private var notesDividerDragCard: String?
    /// The card whose height handle is being dragged: a refresh must not put
    /// back its stored height under the pointer.
    private var heightDragCard: String?
    private var poolScheduled = false
    /// The "+" in the gap between two queries, under the pointer.
    private let gapButton = NSButton()
    /// The gap `gapButton` stands in: between rows `k` and `k + 1`.
    private var gapAbove: Int?
    /// Where a dragged card would land.
    private let dropLine = NSView()
    private var isDraggingCard = false
    /// A typed filter shows some cards only: their positions say nothing
    /// about where a move or an insert would go, so both are off.
    private var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
        setUpGapButtonAndDropLine()
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
        currentMatch = nil
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
        let liveGroups = Set(items.compactMap { if case let .versionGroup(l, ids, _) = $0 { return Self.groupKey(l, ids) } else { return nil } })
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
            case let .versionGroup(lineage, ids, isExpanded):
                let key = Self.groupKey(lineage, ids)
                let v = groupViews[key] ?? makeGroupView(lineage)
                groupViews[key] = v
                let name = doc.card(ids.first ?? "")?.name ?? String(localized: "Untitled query")
                v.show(name: name, versions: ids.compactMap { id in doc.card(id).map { (id, $0.version) } },
                       isExpanded: isExpanded)
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

    /// Refresh the cards' name rows, outlines and rings from the document and
    /// the owner's status — every card, or only `only` (a keystroke refreshes
    /// the card being typed in, not the whole stack).
    func refreshStatus(only: Set<String>? = nil) {
        guard let doc = document() else { return }
        var lineageCounts: [String: Int] = [:]
        for c in doc.cards { lineageCounts[c.lineageId, default: 0] += 1 }
        let runReason = runUnavailableReason()
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
            let meta = card.isCollapsed ? SQLSummary.oneLine(card.sql) : st.meta
            view.header.apply(p, isCollapsed: card.isCollapsed, meta: meta,
                              runUnavailableReason: runReason, progress: st.progress)
            view.header.applyNotes(hasNotes: card.hasNotes, isOpen: card.showsNotes, offersImport: offersCommentImport(card))
            if card.showsNotes {
                let notes = view.notesView ?? makeNotesView(id)
                view.setNotesView(notes)
                notes.setText(card.notes ?? "")
                notes.textView.setAccessibilityIdentifier("editor.card.\(position).notes.text")
            }
            view.showsNotes = card.showsNotes
            if notesDividerDragCard != id { view.notesFraction = card.notesWidthFraction.map { CGFloat($0) } }
            if heightDragCard != id { view.minBodyHeight = CGFloat(card.minBodyHeight ?? 0) }
            view.heightHandle.setAccessibilityIdentifier("editor.card.\(position).height")
            view.isFocused = doc.focusedCardId == id
            view.isDisplayed = st.isDisplayed
            view.isLocked = card.isLocked
            if view.isCollapsed != card.isCollapsed { view.isCollapsed = card.isCollapsed }
            view.setAccessibilityLabel(p.accessibilityLabel)
            view.setAccessibilityIdentifier("editor.card.\(position)")
            let up = canMoveCard(id, by: -1), down = canMoveCard(id, by: 1)
            view.header.grip.isActive = up || down
            view.setAccessibilityCustomActions([
                up ? NSAccessibilityCustomAction(name: String(localized: "Move Up")) { [weak self] in self?.moveCard(id, by: -1) ?? false } : nil,
                down ? NSAccessibilityCustomAction(name: String(localized: "Move Down")) { [weak self] in self?.moveCard(id, by: 1) ?? false } : nil,
                NSAccessibilityCustomAction(name: String(localized: "New Card Above")) { [weak self] in self?.insertCard(above: id); return true },
                NSAccessibilityCustomAction(name: String(localized: "New Card Below")) { [weak self] in self?.insertCard(belowQueryOf: id); return true },
            ].compactMap { $0 })
            view.header.setIdentifiers(prefix: "editor.card.\(position)")
            if let editor = editors[id] {
                editor.identifierPrefix = "editor.card.\(position)"
                editor.textView.isEditable = !card.isLocked
            }
        }
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

    /// `settling` is the second pass after the first one showed or hid a
    /// legacy scroll bar; it does not try again, so it cannot loop.
    private func relayout(anchor: CardStackItem?, settling: Bool = false) {
        guard isViewLoaded else { return }
        let width = max(200, scrollView.contentSize.width)
        let bodyWidth = width - Self.inset * 2 - CardView.stripeWidth - 1
        let contentWidth = CardView.contentWidth(cardWidth: max(0, width - Self.inset * 2))
        let oldItems = items
        let oldFrames = frames
        let oldOffset = scrollView.contentView.bounds.origin.y

        func height(_ item: CardStackItem) -> CGFloat {
            switch item {
            case let .card(id):
                guard let view = cardViews[id] else { return CardHeaderView.height }
                if !view.isCollapsed {
                    // With notes open the SQL is narrower, and the card is as
                    // tall as the taller of the two.
                    let notes = view.showsNotes ? view.notesView : nil
                    // The notes are measured at exactly the width
                    // `CardView.layout` gives them, or a line could wrap
                    // there that did not wrap here.
                    let notesWidth = CardView.split(contentWidth: contentWidth, showsNotes: true, fraction: view.notesFraction).notes
                    var h = bodyHeight(for: id, width: notes == nil ? bodyWidth : bodyWidth - notesWidth)
                    if let notes { h = max(h, notes.height(forWidth: notesWidth)) }
                    // The user's extra room, never less than the content.
                    view.contentBodyHeight = h
                    view.bodyHeight = max(h, view.minBodyHeight)
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
            case let .versionGroup(lineage, ids, _):
                guard let view = groupViews[Self.groupKey(lineage, ids)] else { continue }
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
        // The rows moved under the gap "+": it comes back at the next move.
        if gapAbove != nil { hideGapButton() }
        updateEditorPool()
        // The width above can be stale. When the editor area gets shorter,
        // the old, taller document shows a legacy scroll bar until the frame
        // above shrinks it, and that hides the bar again. Lay out once more
        // at the width the clip has now, or the cards stay a scroll bar
        // narrower (and jump back on the next pass).
        if !settling, abs(max(200, scrollView.contentSize.width) - width) > 0.5 {
            relayout(anchor: anchor, settling: true)
        }
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
        editor.textView.findHighlights = highlights(for: card.id)
        editor.textView.changeVariableMenu = { [weak self] name in self?.changeVariableMenu?(name) }
        editor.validationConnectionId = { [weak self] in self?.validationConnectionId() }
        editor.textView.acceptsDataFileDrops = { [weak self] in self?.acceptsDataFileDrops() ?? false }
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
        preview.findHighlights = highlights(for: card.id)
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
        h.onNotes = { [weak self] in self?.notesButtonClicked(id) }
        h.onToggleLock = { [weak self] in self?.toggleLock(id) }
        let divider = view.notesDivider
        divider.onDrag = { [weak self, weak view] x in
            guard let self, let view else { return }
            self.notesDividerDragCard = id
            view.notesFraction = view.notesFraction(forDividerAt: x)
            self.relayout(anchor: .card(id))
        }
        divider.onDragEnd = { [weak self, weak view] in
            guard let self, let view else { return }
            self.notesDividerDragCard = nil
            self.setNotesWidth(id, fraction: view.notesFraction)
        }
        divider.onReset = { [weak self] in self?.setNotesWidth(id, fraction: nil) }
        divider.onStep = { [weak self, weak view] direction in
            guard let self, let view else { return }
            let step = (view.notesFraction ?? CardNotesView.defaultFraction) + 0.05 * CGFloat(direction)
            let content = CardView.contentWidth(cardWidth: view.bounds.width)
            guard content > 0 else { return }
            self.setNotesWidth(id, fraction: CardNotesView.width(forBody: content, fraction: step) / content)
        }
        h.grip.onPress = { [weak self] event in self?.dragCard(id, from: event) }
        let handle = view.heightHandle
        handle.onDrag = { [weak self, weak view] bottom in
            guard let self, let view else { return }
            self.heightDragCard = id
            view.minBodyHeight = view.bodyHeight(forBottomAt: bottom)
            self.relayout(anchor: .card(id))
        }
        handle.onDragEnd = { [weak self, weak view] in
            guard let self, let view else { return }
            self.heightDragCard = nil
            self.setMinBodyHeight(id, view.minBodyHeight)
        }
        handle.onReset = { [weak self] in self?.setMinBodyHeight(id, 0) }
        handle.onStep = { [weak self, weak view] direction in
            guard let self, let view else { return }
            self.setMinBodyHeight(id, view.bodyHeight + CardHeightHandle.step * CGFloat(direction))
        }
        h.menuProvider = { [weak self] in self?.menu(for: id) ?? NSMenu() }
        view.setBody(makePreview(id))
        return view
    }

    private func makeNotesView(_ id: String) -> CardNotesView {
        let notes = CardNotesView()
        notes.onChange = { [weak self] text in self?.notesEdited(id, text) }
        notes.onEndEditing = { [weak self] in self?.onNotesEndEditing?(id) }
        return notes
    }

    private func makeGroupView(_ lineage: String) -> VersionGroupView {
        let view = VersionGroupView()
        view.onToggle = { [weak self] in
            guard let self else { return }
            self.setLineageExpanded(lineage, !(self.document()?.expandedLineages.contains(lineage) ?? false))
        }
        view.onShowVersion = { [weak self] id in self?.onViewResults?(id) }
        return view
    }

    private func menu(for id: String) -> NSMenu {
        let menu = NSMenu()
        // The items carry their own enabled state. With autoenabling on, AppKit
        // enabled every item, because each one's target answers its action.
        menu.autoenablesItems = false
        guard let card = document()?.card(id) else { return menu }
        let st = status(card)
        func item(_ title: String, _ handler: @escaping () -> Void, enabled: Bool = true) {
            let i = ClosureMenuItem(title: title, handler: handler)
            i.isEnabled = enabled
            menu.addItem(i)
        }
        let runnable = card.kind == .sql && runUnavailableReason() == nil
        item(String(localized: "Run"), { [weak self] in self?.onRun?(id, .run) }, enabled: runnable)
        item(String(localized: "Run and Replace Results"), { [weak self] in self?.onRun?(id, .replace) }, enabled: runnable)
        if st.resultInMemory {
            item(String(localized: "View Results"), { [weak self] in self?.onViewResults?(id) })
        }
        menu.addItem(.separator())
        item(String(localized: "New Card Above"), { [weak self] in self?.insertCard(above: id) }, enabled: !isFiltering)
        item(String(localized: "New Card Below"), { [weak self] in self?.insertCard(belowQueryOf: id) }, enabled: !isFiltering)
        item(String(localized: "Move Up"), { [weak self] in self?.moveCard(id, by: -1) }, enabled: canMoveCard(id, by: -1))
        item(String(localized: "Move Down"), { [weak self] in self?.moveCard(id, by: 1) }, enabled: canMoveCard(id, by: 1))
        menu.addItem(.separator())
        item(String(localized: "Rename\u{2026}"), { [weak self] in self?.onRenameRequest?(id) })
        item(card.showsNotes ? String(localized: "Hide Notes") : String(localized: "Show Notes"),
             { [weak self] in self?.setNotesShown(id, !card.showsNotes) })
        if offersCommentImport(card) {
            item(String(localized: "Import Comments to Note"), { [weak self] in self?.importCommentsToNotes(id) })
            item(String(localized: "Keep Comments in Query"), { [weak self] in self?.keepCommentsInQuery(id) })
        }
        if card.isLocked {
            item(String(localized: "Unlock Version"), { [weak self] in self?.toggleLock(id) })
            item(String(localized: "Edit as New Card"), { [weak self] in self?.editAsNewCard(id) })
        } else if card.isUnlockedVersion == true {
            item(String(localized: "Lock Version"), { [weak self] in self?.toggleLock(id) })
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
        item(card.isLocked || card.isUnlockedVersion == true ? String(localized: "Delete Version") : String(localized: "Delete Card"), { [weak self] in self?.deleteCard(id) })
        return menu
    }

    // MARK: - Insert and move

    /// Which undo manager a card change registers on: the focused card's
    /// editor (each editor has its own, so ⌘Z in that card undoes it), else
    /// the window's — as Delete Card does.
    private func undoManagerForFocus() -> UndoManager? {
        guard let focused = document()?.focusedCardId else { return view.window?.undoManager }
        return editors[focused]?.textView.undoManager ?? view.window?.undoManager
    }

    /// A new card before `id`'s query.
    func insertCard(above id: String) {
        guard !isFiltering else { return }
        var newId = ""
        mutate { doc in newId = doc.insertCard(before: id) }
        didInsert(newId, anchor: id)
    }

    /// A new card after `id`'s query (after its newest version).
    func insertCard(belowQueryOf id: String) {
        guard !isFiltering else { return }
        var newId = ""
        mutate { doc in newId = doc.insertCard(afterQueryOf: id) }
        didInsert(newId, anchor: id)
    }

    private func didInsert(_ newId: String, anchor: String) {
        reload(anchor: .card(anchor))
        focusCard(newId)
        onStructureEdited?()
        let undo = undoManagerForFocus()
        undo?.registerUndo(withTarget: self) { target in
            target.mutate { doc in _ = doc.deleteCard(cardId: newId) }
            target.reload()
            target.onCardDeleted?(newId)
            target.onStructureEdited?()
        }
        undo?.setActionName(String(localized: "New Card"))
    }

    /// Whether `id`'s query can move one place up (-1) or down (+1).
    func canMoveCard(_ id: String, by delta: Int) -> Bool {
        guard !isFiltering, let doc = document(), let b = doc.blockIndex(of: id) else { return false }
        return delta < 0 ? b > 0 : b < doc.lineageBlocks.count - 1
    }

    /// Move `id`'s query one place up or down (⋯ menu, Query menu, VoiceOver).
    @discardableResult
    func moveCard(_ id: String, by delta: Int) -> Bool {
        guard canMoveCard(id, by: delta), let b = document()?.blockIndex(of: id) else { return false }
        return moveCard(id, toBlockOffset: delta < 0 ? b - 1 : b + 2)
    }

    /// Move the focused card's query (Query ▸ Move Card Up / Down).
    func moveFocusedCard(by delta: Int) {
        guard let id = document()?.focusedCardId else { return }
        moveCard(id, by: delta)
    }

    func canMoveFocusedCard(by delta: Int) -> Bool {
        guard let id = document()?.focusedCardId else { return false }
        return canMoveCard(id, by: delta)
    }

    /// Move `id`'s query to block `offset` (`CardDocument.moveLineage`), keep
    /// it focused and on screen, and make the move undoable.
    @discardableResult
    func moveCard(_ id: String, toBlockOffset offset: Int) -> Bool {
        guard !isFiltering, let old = document()?.blockIndex(of: id) else { return false }
        var moved = false
        mutate { doc in moved = doc.moveLineage(of: id, toBlockOffset: offset) }
        guard moved else { return false }
        reload(anchor: .card(id))
        focusCard(id)
        findTextChanged()
        onStructureEdited?()
        let undo = undoManagerForFocus()
        undo?.registerUndo(withTarget: self) { target in
            guard let back = target.document()?.undoOffset(for: id, oldIndex: old) else { return }
            target.moveCard(id, toBlockOffset: back)
        }
        undo?.setActionName(String(localized: "Move Card"))
        return true
    }

    // MARK: Gap "+" and drag

    private func setUpGapButtonAndDropLine() {
        gapButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: String(localized: "New Card Here"))?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        gapButton.isBordered = false
        gapButton.imagePosition = .imageOnly
        gapButton.contentTintColor = .controlAccentColor
        gapButton.toolTip = String(localized: "New Card Here")
        gapButton.setAccessibilityLabel(String(localized: "New Card Here"))
        gapButton.setAccessibilityIdentifier("editor.cards.insert")
        gapButton.target = self
        gapButton.action = #selector(gapButtonClicked)
        gapButton.isHidden = true
        gapButton.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        documentView.addSubview(gapButton)

        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropLine.layer?.cornerRadius = 1
        dropLine.isHidden = true
        documentView.addSubview(dropLine)

        documentView.onMouseMoved = { [weak self] point in self?.pointerMoved(to: point) }
        documentView.onMouseExited = { [weak self] in self?.hideGapButton() }
    }

    private func pointerMoved(to point: NSPoint) {
        guard !isDraggingCard, !isFiltering, let doc = document(),
              let k = CardStackLayout.insertionGap(at: point.y, items: items, frames: frames, document: doc) else {
            // Over the button itself (it overlaps the cards a little): keep it.
            if !gapButton.isHidden, gapButton.frame.insetBy(dx: -2, dy: -2).contains(point) { return }
            hideGapButton()
            return
        }
        gapAbove = k
        let mid = (frames[k].maxY + frames[k + 1].minY) / 2
        gapButton.frame.origin = NSPoint(x: frames[k].midX - gapButton.frame.width / 2, y: mid - gapButton.frame.height / 2)
        // Above the cards, which it overlaps by a few points.
        if gapButton.superview != nil, documentView.subviews.last !== gapButton {
            documentView.addSubview(gapButton, positioned: .above, relativeTo: nil)
        }
        gapButton.isHidden = false
    }

    private func hideGapButton() {
        gapButton.isHidden = true
        gapAbove = nil
    }

    @objc private func gapButtonClicked() {
        guard let k = gapAbove, k < items.count else { return }
        let above: String?
        switch items[k] {
        case let .card(id): above = id
        case let .versionGroup(_, ids, _): above = ids.last
        case .addCard: above = nil
        }
        hideGapButton()
        if let above { insertCard(belowQueryOf: above) }
    }

    /// Drag a card by its grip: a line shows where its query will land, the
    /// stack scrolls at the edges, Escape cancels.
    private func dragCard(_ id: String, from event: NSEvent) {
        guard !isFiltering, canMoveCard(id, by: -1) || canMoveCard(id, by: 1),
              let doc = document(), let card = cardViews[id], let window = view.window else { return }
        hideGapButton()
        isDraggingCard = true
        defer { isDraggingCard = false }
        let start = event.locationInWindow
        var started = false
        var target: Int?
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .keyDown {
                if next.keyCode == 53 { target = nil; break } // Escape: no move
                continue
            }
            if next.type == .leftMouseUp { break }
            if !started {
                guard hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 3 else { continue }
                started = true
                card.alphaValue = 0.5
                documentView.addSubview(dropLine, positioned: .above, relativeTo: nil)
            }
            _ = scrollView.contentView.autoscroll(with: next)
            let p = documentView.convert(next.locationInWindow, from: nil)
            if let t = CardStackLayout.dropTarget(at: p.y, items: items, frames: frames, document: doc) {
                target = t.blockOffset
                let x = frames.first?.minX ?? Self.inset
                dropLine.frame = NSRect(x: x, y: t.lineY - 1, width: max(0, documentView.bounds.width - x * 2), height: 2)
                dropLine.isHidden = false
            }
        }
        card.alphaValue = 1
        dropLine.isHidden = true
        if started, let target { moveCard(id, toBlockOffset: target) }
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

    /// The lock button: open a locked version for editing, or lock an
    /// unlocked one again. Each is one undo step.
    func toggleLock(_ id: String) {
        guard let card = document()?.card(id) else { return }
        if card.isLocked {
            unlockVersion(id)
        } else if card.isUnlockedVersion == true {
            relockVersion(id)
        }
    }

    /// Open a locked version; its editor takes the keyboard. `restoring`, from
    /// an undo of `relockVersion`, puts the edit back; `manager` is the undo
    /// manager that undo runs on, so the redo goes there too.
    private func unlockVersion(_ id: String, restoring edit: CardEdit? = nil, on manager: UndoManager? = nil) {
        var unlocked = false
        mutate { doc in unlocked = doc.unlockVersion(cardId: id) }
        guard unlocked else { return }
        editors[id]?.textView.isEditable = true
        reload(anchor: .card(id))
        focusCard(id)
        let undo = manager ?? undoManagerForFocus()
        if let edit, apply(edit, keepingUndoOf: undo) { findTextChanged() }
        undo?.registerUndo(withTarget: self) { target in target.relockVersion(id, on: undo) }
        undo?.setActionName(String(localized: "Unlock Version"))
        scheduleRelayout()
    }

    /// Lock an unlocked version again. Its text goes back to the SQL of its
    /// results first, through the editor while it can still change, so an
    /// undo puts the edit back.
    private func relockVersion(_ id: String, on manager: UndoManager? = nil) {
        guard let card = document()?.card(id), card.isUnlockedVersion == true else { return }
        let undo = manager ?? undoManagerForFocus()
        var revert: CardEdit?
        if let ran = card.lastRun?.rawSQL, ran != card.sql {
            let edit = CardEdit(cardId: id, edits: [TextEdit(range: NSRange(location: 0, length: (card.sql as NSString).length),
                                                             replacement: ran)],
                                oldSQL: card.sql, newSQL: ran)
            if apply(edit, keepingUndoOf: undo) {
                revert = edit
                findTextChanged()
            }
        }
        mutate { doc in doc.relockVersion(cardId: id) }
        editors[id]?.textView.isEditable = false
        reload(anchor: .card(id))
        undo?.registerUndo(withTarget: self) { target in
            target.unlockVersion(id, restoring: revert.map(CardTextEdits.inverse(of:)), on: undo)
        }
        undo?.setActionName(String(localized: "Lock Version"))
    }

    func toggleCollapsed(_ id: String) {
        guard let card = document()?.card(id) else { return }
        let expanding = card.isCollapsed
        mutate { doc in doc.setCollapsed(cardId: id, !card.isCollapsed) }
        reload(anchor: .card(id))
        if expanding { revealExpandedCard(id) }
    }

    /// A card that opened past the bottom of the editor area scrolls up so
    /// its top meets the top of the area (`CardStackLayout.offsetAfterExpanding`).
    private func revealExpandedCard(_ id: String) {
        guard let i = items.firstIndex(of: .card(id)), i < frames.count else { return }
        let clip = scrollView.contentView
        guard let y = CardStackLayout.offsetAfterExpanding(
            cardFrame: frames[i], visible: clip.bounds,
            contentHeight: documentView.frame.height, topMargin: Self.spacing) else { return }
        let origin = NSPoint(x: clip.bounds.origin.x, y: y)
        // A short scroll shows where the card went; none with Reduce Motion
        // (Apple HIG, Motion).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    // MARK: - Notes

    /// True while the Notes button offers to move the card's leading comments
    /// into its notes: a card from a `.sql` file, still unlocked, with no
    /// notes yet and comments still before its statement.
    private func offersCommentImport(_ card: QueryCard) -> Bool {
        card.offersCommentImport == true && !card.hasNotes && !card.isLocked && card.kind == .sql
            && PharosCore.extractLeadingNotes(card.sql) != nil
    }

    /// The ids of every version of the card's query.
    private func lineageIds(of id: String) -> Set<String> {
        guard let doc = document(), let lineage = doc.card(id)?.lineageId else { return [id] }
        return Set(doc.cards.filter { $0.lineageId == lineage }.map(\.id))
    }

    private func notesButtonClicked(_ id: String) {
        guard let card = document()?.card(id) else { return }
        if offersCommentImport(card) {
            importCommentsToNotes(id)
        } else {
            setNotesShown(id, !card.showsNotes)
        }
    }

    /// Open or close the card's notes. Opening puts the keyboard in them, and
    /// opens a folded card first.
    func setNotesShown(_ id: String, _ open: Bool) {
        guard let card = document()?.card(id) else { return }
        mutate { doc in doc.setNotesOpen(cardId: id, open) }
        if open, card.isCollapsed {
            toggleCollapsed(id)
        } else {
            refreshStatus(only: [id])
            relayout(anchor: .card(id))
        }
        if open, let notes = cardViews[id]?.notesView {
            view.window?.makeFirstResponder(notes.textView)
        } else if !open, let notes = cardViews[id]?.notesView, view.window?.firstResponder === notes.textView {
            focusCard(id)
        }
    }

    private func notesEdited(_ id: String, _ text: String) {
        var changed = false
        mutate { doc in changed = doc.setNotes(cardId: id, text) }
        guard changed else { return }
        onNotesEdited?(id)
        refreshStatus(only: lineageIds(of: id))
        scheduleRelayout()
    }

    /// Move the comments before the card's statement into its notes, and open
    /// them. Like Format SQL, the new text replaces the editor's undo history.
    func importCommentsToNotes(_ id: String) {
        guard let card = document()?.card(id), let extracted = PharosCore.extractLeadingNotes(card.sql) else { return }
        var applied = false
        mutate { doc in applied = doc.importCommentsToNotes(cardId: id, notes: extracted.notes, sql: extracted.sql) }
        guard applied else { return }
        if let editor = editors[id] {
            editor.setSQL(extracted.sql)
        } else if let preview = previews[id], let updated = document()?.card(id) {
            configure(preview, card: updated)
        }
        findTextChanged()
        onTextEdited?(id, extracted.sql)
        onNotesEdited?(id)
        let lineage = lineageIds(of: id)
        refreshStatus(only: lineage)
        for cardId in lineage {
            cardViews[cardId]?.notesView?.setText(extracted.notes, force: true)
        }
        relayout(anchor: .card(id))
    }

    /// Store the card's least body height and lay out. At or below what the
    /// content needs it is "fit content" (nil): the handle only adds room.
    private func setMinBodyHeight(_ id: String, _ height: CGFloat) {
        guard let view = cardViews[id] else { return }
        let floor: CGFloat? = height > view.contentBodyHeight + 0.5 ? height.rounded() : nil
        mutate { doc in doc.setMinBodyHeight(cardId: id, floor.map { Double($0) }) }
        view.minBodyHeight = floor ?? 0
        relayout(anchor: .card(id))
    }

    /// Store how wide the card's notes are (nil: the default) and lay out.
    private func setNotesWidth(_ id: String, fraction: CGFloat?) {
        mutate { doc in doc.setNotesWidth(cardId: id, fraction: fraction.map { Double($0) }) }
        cardViews[id]?.notesFraction = fraction
        relayout(anchor: .card(id))
    }

    /// Stop offering to move the card's comments into its notes.
    func keepCommentsInQuery(_ id: String) {
        mutate { doc in doc.dismissCommentImport(cardId: id) }
        refreshStatus(only: [id])
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
        onCardDeleted?(id)
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

    // MARK: - Find and Replace across cards

    /// The Find and Replace bar, made the first time Find is used.
    private var findBar: CardFindBar?
    /// Every match, in stack order.
    private var findOrder: [(cardId: String, range: NSRange)] = []
    private var findByCard: [String: [NSRange]] = [:]
    /// The match the bar is on; one of `findOrder`.
    private var currentMatch: (cardId: String, range: NSRange)?
    private var findMatcher = CardTextMatcher(pattern: "", mode: .contains, matchCase: false)
    private var findRefreshScheduled = false
    /// What the last Replace All did, said in place of the count until the
    /// search changes.
    private var findNote: String?

    private var isFindBarShown: Bool { findBar != nil && scrollView.isFindBarVisible }

    private func makeFindBar() -> CardFindBar {
        if let findBar { return findBar }
        let bar = CardFindBar(frame: NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: 0))
        bar.onSearchChange = { [weak self] in self?.searchChanged() }
        bar.onNext = { [weak self] in self?.step(forward: true) }
        bar.onPrevious = { [weak self] in self?.step(forward: false) }
        bar.onDone = { [weak self] in self?.hideFindBar() }
        bar.onReplace = { [weak self] in self?.replaceCurrent() }
        bar.onReplaceAll = { [weak self] in self?.replaceAll() }
        bar.onHeightChange = { [weak self] in self?.scrollView.findBarViewDidChangeHeight() }
        findBar = bar
        scrollView.findBarPosition = .aboveContent
        scrollView.findBarView = bar
        return bar
    }

    private func showFindBar(replace: Bool) {
        let bar = makeFindBar()
        bar.showsReplace = replace
        if !scrollView.isFindBarVisible { scrollView.isFindBarVisible = true }
        refreshFind()
        if replace, !bar.pattern.isEmpty { bar.focusReplace() } else { bar.focusFind() }
    }

    /// Done or Esc: the highlights go, and the current match is selected in
    /// its card with the keyboard there, so typing replaces it.
    private func hideFindBar() {
        guard isFindBarShown else { return }
        scrollView.isFindBarVisible = false
        let match = currentMatch
        currentMatch = nil
        refreshFind()
        if let match, let editor = editor(for: match.cardId) {
            view.window?.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(match.range)
        } else if let editor = focusedEditor {
            view.window?.makeFirstResponder(editor.textView)
        }
    }

    /// Edit ▸ Find on the stack. Returns false when the action does not apply.
    @discardableResult
    func performFind(_ action: NSTextFinder.Action) -> Bool {
        guard canPerformFind(action) else { return false }
        switch action {
        case .showFindInterface:
            showFindBar(replace: false)
        case .showReplaceInterface:
            showFindBar(replace: true)
        case .hideFindInterface:
            hideFindBar()
        case .nextMatch, .previousMatch:
            if !isFindBarShown { showFindBar(replace: findBar?.showsReplace ?? false) }
            step(forward: action == .nextMatch)
        case .setSearchString:
            guard let (cardId, range) = focusedSelection(), let sql = document()?.card(cardId)?.sql else { return false }
            makeFindBar().setPattern((sql as NSString).substring(with: range))
        case .replace:
            replaceCurrent(andStep: false)
        case .replaceAndFind:
            replaceCurrent()
        case .replaceAll:
            replaceAll()
        default:
            return false
        }
        return true
    }

    func canPerformFind(_ action: NSTextFinder.Action) -> Bool {
        guard isViewLoaded else { return false }
        switch action {
        case .showFindInterface, .showReplaceInterface: return true
        case .hideFindInterface: return isFindBarShown
        case .nextMatch, .previousMatch: return !(findBar?.pattern.isEmpty ?? true)
        case .setSearchString: return (focusedSelection()?.range.length ?? 0) > 0
        case .replace, .replaceAndFind: return isFindBarShown && currentMatch != nil
        case .replaceAll: return isFindBarShown && !findOrder.isEmpty
        default: return false
        }
    }

    /// Edit ▸ Find while the keyboard is in the find bar (a card's editor
    /// answers for itself, through `textFinderActionHandler`). Anything the
    /// stack does not do goes on up the chain, to the results grid's find.
    @objc override func performTextFinderAction(_ sender: Any?) {
        if let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
           let action = NSTextFinder.Action(rawValue: tag), performFind(action) { return }
        nextResponder?.performTextFinderAction(sender)
    }

    /// The cards' text or their order changed: search again, once per turn
    /// of the run loop however many edits there were.
    private func findTextChanged() {
        guard isFindBarShown, !findRefreshScheduled else { return }
        findRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.findRefreshScheduled = false
            self.refreshFind()
        }
    }

    /// The pattern or an option changed: search, and go to the first match
    /// from the caret on, as you type.
    private func searchChanged() {
        findNote = nil
        currentMatch = nil
        refreshFind()
        if isFindBarShown, !findOrder.isEmpty { step(forward: true) }
    }

    /// Find every match, and give each card its own.
    private func refreshFind() {
        guard let bar = findBar else { return }
        findMatcher = CardTextMatcher(pattern: bar.pattern, mode: bar.mode, matchCase: bar.matchCase)
        findOrder = []
        findByCard = [:]
        if isFindBarShown {
            for (id, sql) in findableCards() {
                let ranges = findMatcher.ranges(in: sql)
                guard !ranges.isEmpty else { continue }
                findByCard[id] = ranges
                findOrder += ranges.map { (id, $0) }
            }
        }
        if let c = currentMatch, findByCard[c.cardId]?.contains(c.range) != true { currentMatch = nil }
        pushHighlights()
        updateFindCount()
    }

    private func highlights(for cardId: String) -> FindHighlights {
        FindHighlights(ranges: findByCard[cardId] ?? [],
                       current: currentMatch?.cardId == cardId ? currentMatch?.range : nil)
    }

    private func pushHighlights() {
        for (id, editor) in editors { editor.textView.findHighlights = highlights(for: id) }
        for (id, preview) in previews { preview.findHighlights = highlights(for: id) }
    }

    private func updateFindCount() {
        guard let bar = findBar else { return }
        let index = currentMatch.flatMap { c in findOrder.firstIndex { $0.cardId == c.cardId && $0.range == c.range } }
        bar.setCount(current: index.map { $0 + 1 }, total: findOrder.count,
                     isInvalid: !findMatcher.isValid, note: findNote)
    }

    /// The next or previous match: from the current one, else from the
    /// focused card's caret. Wraps at either end.
    private func step(forward: Bool) {
        guard !findOrder.isEmpty else {
            NSSound.beep()
            return
        }
        let n = findOrder.count
        if let c = currentMatch, let at = findOrder.firstIndex(where: { $0.cardId == c.cardId && $0.range == c.range }) {
            go(to: forward ? (at + 1) % n : (at - 1 + n) % n)
            return
        }
        guard let doc = document(), let focused = doc.focusedCardId else {
            go(to: forward ? 0 : n - 1)
            return
        }
        let caret = editors[focused]?.textView.selectedRange().location ?? doc.card(focused)?.cursorPosition ?? 0
        go(to: matchIndex(from: focused, caret, forward: forward))
    }

    /// The first match at or after `location` in `cardId` (forward), or the
    /// last one before it, in stack order. Wraps.
    private func matchIndex(from cardId: String, _ location: Int, forward: Bool) -> Int {
        let rank = Dictionary(findableCards().enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let start = (rank[cardId] ?? 0, location)
        func key(_ m: (cardId: String, range: NSRange)) -> (Int, Int) { (rank[m.cardId] ?? 0, m.range.location) }
        if forward { return findOrder.firstIndex { key($0) >= start } ?? 0 }
        return findOrder.lastIndex { key($0) < start } ?? findOrder.count - 1
    }

    /// Make a match current: open its card (and a fold that hides it), put
    /// the caret there and scroll it into view. The keyboard stays in the bar.
    private func go(to index: Int) {
        let match = findOrder[index]
        currentMatch = match
        if document()?.card(match.cardId)?.isCollapsed == true {
            mutate { doc in doc.setCollapsed(cardId: match.cardId, false) }
            reload(anchor: .card(match.cardId))
        }
        editor(for: match.cardId)?.textView.unfold(intersecting: match.range)
        selectMatch(cardId: match.cardId, range: NSRange(location: match.range.location, length: 0))
        pushHighlights()
        updateFindCount()
        revealMatch(cardId: match.cardId, range: match.range)
    }

    /// Replace the current match, then (`andStep`) go to the next one.
    private func replaceCurrent(andStep: Bool = true) {
        guard let bar = findBar, let match = currentMatch, let card = document()?.card(match.cardId) else {
            NSSound.beep()
            return
        }
        if card.isLocked {
            findNote = String(localized: "This version is locked")
            updateFindCount()
            NSSound.beep()
            return
        }
        guard let edit = CardTextEdits.replace(match.range, in: EditableCardText(id: card.id, sql: card.sql, isLocked: false),
                                               matcher: findMatcher, template: bar.template) else {
            NSSound.beep()
            return
        }
        applyEdits([edit], actionName: String(localized: "Replace"))
        findNote = nil
        currentMatch = nil
        refreshFind()
        guard andStep, !findOrder.isEmpty else { return }
        let resume = match.range.location + ((edit.edits.first?.replacement ?? "") as NSString).length
        go(to: matchIndex(from: match.cardId, resume, forward: true))
    }

    /// Replace every match, in every card the stack shows or in the focused
    /// one (the bar's scope). Locked versions keep their text.
    private func replaceAll() {
        guard let bar = findBar, let doc = document(), findMatcher.isValid, !bar.pattern.isEmpty else { return }
        let ids: [String]
        switch bar.scope {
        case .allCards: ids = findableCards().map(\.id)
        case .thisCard: ids = (currentMatch?.cardId ?? doc.focusedCardId).map { [$0] } ?? []
        }
        let cards = ids.compactMap { doc.card($0) }.map { EditableCardText(id: $0.id, sql: $0.sql, isLocked: $0.isLocked) }
        let plan = CardTextEdits.replaceAll(in: cards, matcher: findMatcher, template: bar.template)
        applyEdits(plan.cards, actionName: String(localized: "Replace All"))
        currentMatch = nil
        refreshFind()
        var note = String(localized: "Replaced \(CountedNounText.phrase(plan.editCount, "match"))")
        if plan.lockedCardsSkipped > 0 {
            note += " · " + String(localized: "\(CountedNounText.phrase(plan.lockedCardsSkipped, "version")) skipped (locked)")
        }
        findNote = note
        updateFindCount()
    }

    /// The cards find searches: every card the stack lays out (not the ones
    /// a typed filter hides, nor older versions folded into their row), in
    /// stack order. A collapsed card is searched, and opens when a match in
    /// it becomes current.
    func findableCards() -> [(id: String, sql: String)] {
        guard let doc = document() else { return [] }
        return items.compactMap { item in
            guard case let .card(id) = item, let card = doc.card(id) else { return nil }
            return (id, card.sql)
        }
    }

    /// The focused card's selection, in its own terms.
    func focusedSelection() -> (cardId: String, range: NSRange)? {
        guard let id = document()?.focusedCardId, let editor = editors[id] else { return nil }
        return (id, editor.textView.selectedRange())
    }

    /// Select a range in its card and make that card the focused one, while
    /// the keyboard stays where it is.
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

    // MARK: - Edits across cards

    /// Make `edits` as one step, which ⌘Z in the focused card takes back
    /// (and ⇧⌘Z makes again). A card whose text is no longer the text the
    /// edit was planned on is left alone.
    func applyEdits(_ edits: [CardEdit], actionName: String) {
        guard !edits.isEmpty else { return }
        let undo = undoManagerForFocus()
        let made = edits.filter { apply($0, keepingUndoOf: undo) }
        guard !made.isEmpty else { return }
        undo?.registerUndo(withTarget: self) { target in
            target.applyEdits(made.map(CardTextEdits.inverse(of:)), actionName: actionName)
        }
        undo?.setActionName(actionName)
        findTextChanged()
        scheduleRelayout()
    }

    /// One card's edit: through its live editor (whose text-change path
    /// stores the text, refolds and recolours), else in the document.
    private func apply(_ edit: CardEdit, keepingUndoOf undo: UndoManager?) -> Bool {
        if let editor = editors[edit.cardId] {
            let textView = editor.textView
            guard textView.string == edit.oldSQL else { return false }
            let manager = textView.undoManager
            manager?.disableUndoRegistration()
            for e in edit.edits.sorted(by: { $0.range.location > $1.range.location }) {
                guard textView.shouldChangeText(in: e.range, replacementString: e.replacement) else { continue }
                textView.textStorage?.replaceCharacters(in: e.range, with: e.replacement)
                textView.didChangeText()
            }
            manager?.enableUndoRegistration()
            // This editor's own steps name places in the old text; the step
            // that takes the edit back is on `undo`.
            if manager !== undo { manager?.removeAllActions() }
            return true
        }
        guard document()?.card(edit.cardId)?.sql == edit.oldSQL else { return false }
        var accepted = false
        mutate { doc in accepted = doc.updateSQL(cardId: edit.cardId, edit.newSQL) }
        guard accepted else { return false }
        if let preview = previews[edit.cardId], let card = document()?.card(edit.cardId) { configure(preview, card: card) }
        onTextEdited?(edit.cardId, edit.newSQL)
        refreshStatus(only: [edit.cardId])
        return true
    }

    /// Change every `{{from}}` in the tab's cards to `{{to}}`, as one undo
    /// step. Locked versions keep their SQL; the plan counts them.
    @discardableResult
    func changeVariable(from: String, to: String) -> CardEditPlan {
        guard let doc = document() else { return CardEditPlan() }
        let cards = doc.cards.map { EditableCardText(id: $0.id, sql: $0.sql, isLocked: $0.isLocked) }
        let plan = CardTextEdits.changeVariable(in: cards, from: from, to: to)
        applyEdits(plan.cards, actionName: String(localized: "Change Variable"))
        return plan
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

// MARK: - Menu validation

extension CardStackVC: NSMenuItemValidation {
    /// Edit ▸ Find items while the keyboard is in the find bar.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performTextFinderAction(_:)),
              let action = NSTextFinder.Action(rawValue: menuItem.tag) else { return true }
        return canPerformFind(action)
    }
}
