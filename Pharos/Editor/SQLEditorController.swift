import AppKit
import Combine

/// One query card's SQL editor: the text view with its gutter, syntax
/// highlighting, folds, completion, live validation and error markers.
///
/// It knows nothing about where its text is stored. The owner shows a card
/// with `documentId` + `setSQL`, receives each user edit through
/// `onTextEdited`, and says which connection live validation checks against
/// through `validationConnectionId`. The cards on screen share one completion
/// provider.
///
/// A card grows to fit its text (HIG, Scroll views: no vertical scroll view
/// inside another): this editor never scrolls vertically, hands vertical
/// wheel events to the card stack, and reports `contentHeight` for the stack
/// to size the card by. With word wrap off it scrolls sideways itself.
class SQLEditorController: NSViewController {

    let textView = SQLTextView()
    let completionProvider: SQLCompletionProvider
    private var scrollView: NSScrollView!
    private var gutter: LineNumberGutter?
    private let stateManager = AppStateManager.shared

    /// Prefix of the accessibility identifiers: `<prefix>.text`,
    /// `<prefix>.gutter`. Each card passes its own (`editor.card.<n>`).
    var identifierPrefix: String {
        didSet {
            guard isViewLoaded, oldValue != identifierPrefix else { return }
            textView.setAccessibilityIdentifier("\(identifierPrefix).text")
            gutter?.setAccessibilityIdentifier("\(identifierPrefix).gutter")
        }
    }

    init(completionProvider: SQLCompletionProvider = SQLCompletionProvider(), identifierPrefix: String = "editor") {
        self.completionProvider = completionProvider
        self.identifierPrefix = identifierPrefix
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    private var cancellables = Set<AnyCancellable>()
    /// Applies the scroll-bar setting to the scroll view and follows its changes.
    private var scrollBarPolicy: ScrollBarPolicy?
    private var validationTask: Task<Void, Never>?
    private var foldRegionTask: Task<Void, Never>?

    /// The card this editor shows. nil while it
    /// shows nothing: user edits are then not reported.
    var documentId: String?

    /// The connection live validation checks the text against; nil skips it.
    var validationConnectionId: () -> String? = { nil }

    /// Current fold regions for code folding.
    private var foldRegions: [SQLFoldRegion] = []

    /// The height the text needs, changed: by an edit, a fold, a font or
    /// wrap change. The card stack sizes the card again.
    var onContentHeightChange: (() -> Void)?

    /// The text view took the keyboard: this card is now the focused one.
    var onFocus: (() -> Void)?

    /// The selection moved. The card stack keeps the caret on screen.
    var onSelectionChange: (() -> Void)?

    /// Fired after each user edit (not after `setSQL`) with the document's id
    /// and its whole text. The owner stores the text where it lives.
    var onTextEdited: ((_ documentId: String, _ text: String) -> Void)?

    /// Callback fired when a `{{` completion row is accepted, or a `{{name}}`
    /// token in the text is clicked, with the variable's name. It may not
    /// exist yet.
    var onVariableChosen: ((String) -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        self.view = container

        // Scroll view for text editor — uses frame-based layout since parent
        // (NSSplitView) manages layout via frames, not Auto Layout.
        // Frame is set in viewDidLayout; starts at container bounds minus gutter.
        scrollView = CardEditorScrollView(frame: container.bounds)
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Legacy-and-pinned or follow-the-system, per Settings ▸ Appearance.
        scrollBarPolicy = ScrollBarPolicy(
            scrollView: scrollView,
            alwaysVisible: stateManager.$settings.map(\.alwaysShowScrollBars).eraseToAnyPublisher())

        // Pinch-to-zoom the editor font. Attached to the scroll view (the
        // stable editor rectangle) rather than the text view, whose frame
        // moves with content and word wrap. A pinch starting over the gutter
        // is not handled — it is a small fraction of the editor's width.
        let magnificationGesture = NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:)))
        scrollView.addGestureRecognizer(magnificationGesture)

        // Configure text view sizing — NSScrollView manages its documentView
        // via frames, so do NOT set translatesAutoresizingMaskIntoConstraints = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Stable handles for accessibility tooling and the UI test harness.
        // The gutter names itself in its own initialiser.
        textView.setAccessibilityIdentifier("\(identifierPrefix).text")

        scrollView.documentView = textView

        // Line number gutter — standalone NSView beside the scroll view,
        // outside the scroll view hierarchy to avoid macOS 26's ruler VEV injection.
        let gutterView = LineNumberGutter(textView: textView, scrollView: scrollView,
                                          accessibilityIdentifier: "\(identifierPrefix).gutter")
        gutterView.onWidthChange = { [weak self] in
            self?.view.needsLayout = true
        }
        gutterView.onToggleFold = { [weak self] regionIndex in
            self?.toggleFold(at: regionIndex)
        }
        // The gutter knows which LINE it drew a marker on; only this VC knows
        // the document RANGE that produced it, so the popover's "Go to Error"
        // comes back here to be turned into a selection.
        gutterView.onRevealError = { [weak self] line in
            guard let self, let range = self.errorRangesByLine[line] else { return }
            self.revealError(range: range)
        }
        gutter = gutterView

        container.addSubview(gutterView)
        container.addSubview(scrollView)

        // Autocomplete
        completionProvider.attachTo(textView)
        completionProvider.onVariableChosen = { [weak self] name in
            self?.onVariableChosen?(name)
        }
        textView.onVariableTokenClicked = { [weak self] name in
            self?.onVariableChosen?(name)
        }
        textView.completionDelegate = self

        // Text change handler — sync back to tab state and validate
        textView.onTextChange = { [weak self] newText in
            guard let self, !self.suppressTextChange else { return }
            self.textDidChange(newText)
        }

        // Fold state changed — re-sync gutter line numbers
        textView.onFoldStateChanged = { [weak self] in
            self?.gutter?.invalidateLineNumbers()
            self?.onContentHeightChange?()
        }
        textView.onBecomeFirstResponder = { [weak self] in self?.onFocus?() }

        // Click on fold placeholder — unfold that region
        textView.onPlaceholderClicked = { [weak self] foldEntryId in
            guard let self else { return }
            self.textView.unfold(id: foldEntryId)
            self.recalculateFoldRegions()
        }

        // The card stack keeps the caret on screen as it moves.
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )

        applySettings(stateManager.settings.editor)

        // Re-apply settings when they change. The publisher is narrowed to
        // `\.editor` and deduped, so a republish of an unrelated field (the
        // `AppSettings` struct is shared across every UI surface) does not
        // reach the editor at all — no rebuild, no rehighlight pass.
        //
        // The sink uses the DELIVERED value. Re-reading `stateManager.settings`
        // inside it would race: two saves in flight would both apply whichever
        // value happened to be published last, so the first one's work could
        // be done twice and the second's not at all.
        stateManager.$settings
            .map(\.editor)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] editor in self?.applySettings(editor) }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutGutterAndScrollView()
    }

    private func layoutGutterAndScrollView() {
        let bounds = view.bounds
        let gutterWidth: CGFloat
        if let gutter, !gutter.isHidden {
            gutterWidth = gutter.desiredWidth
            gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        } else {
            gutterWidth = 0
        }
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
        // No-wrap mode keeps the text view at least as large as the clip.
        if textView.textContainer?.widthTracksTextView == false {
            textView.minSize = scrollView.contentSize
        }
    }

    // MARK: - Public API

    func formatSQL() {
        // Unfold all before formatting so we format the full original text
        textView.unfoldAll()
        let current = getSQL()
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Format off main — sqlformat can chew tens of ms on large queries.
        // Bail if the editor text changed under us (user kept typing) so we
        // don't clobber their work with a stale formatted copy.
        Task { @MainActor [weak self] in
            let formatted = await PharosCore.formatSQL(current)
            guard let self, self.getSQL() == current else { return }
            self.setSQL(formatted)
            self.textDidChange(formatted)
        }
    }

    /// Flag to suppress the onTextChange callback during programmatic text updates.
    private var suppressTextChange = false

    func setSQL(_ sql: String) {
        // Programmatic replacement bypasses didChangeText — kill any pending
        // list-paste offer explicitly so it can't survive into new content.
        textView.invalidateListPasteOffer()
        // Same reason: a drafted statement's mark names a range in the OLD
        // text, so a tab switch must take it away rather than leave it
        // sitting over whatever now occupies those characters.
        textView.clearDraftHighlight()
        // Suppress the onTextChange callback: this is not a user edit, and
        // the owner already holds the text.
        // A direct `string =` skips didChangeText, so nothing else resets the
        // per-document state: folds would keep hiding the OLD text's ranges in
        // the new text, and ⌘Z would replay the previous tab's edits here.
        textView.unfoldAll()
        suppressTextChange = true
        // AppKit keeps CRLF as typed; `\r` is invisible in the editor and
        // breaks line-based error math. Store one line ending.
        textView.string = sql.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        suppressTextChange = false
        textView.undoManager?.removeAllActions()
        textView.highlightSyntax()
        gutter?.invalidateLineNumbers()
        onContentHeightChange?()

        // Recalculate fold regions
        recalculateFoldRegions()
    }

    @objc private func editorSelectionDidChange(_: Notification) {
        onSelectionChange?()
    }

    func getSQL() -> String {
        textView.string
    }

    /// Put a model draft in at the cursor and give the editor the keyboard
    /// back. See `SQLTextView.insertDraft` — one undo step, selected, marked
    /// until the next edit, and never run.
    @discardableResult
    func insertDraft(_ sql: String) -> NSRange? {
        let inserted = textView.insertDraft(sql)
        focus()
        return inserted
    }

    /// Set the variable names used for `{{token}}` highlighting.
    func setVariableNames(_ names: Set<String>) {
        textView.variableNames = names
    }

    /// Set the variables the `{{` completion list offers, in list order, and
    /// the values the token tooltips show.
    func setCompletionVariables(_ variables: [QueryVariable]) {
        completionProvider.variables = variables.map {
            .init(name: $0.name, preview: VariableValuePreview.snippet(for: $0.value))
        }
        var values: [String: String] = [:]
        for variable in variables where !variable.name.isEmpty { values[variable.name] = variable.value }
        textView.variableValues = values
    }

    func getCursorPosition() -> Int {
        textView.selectedRange().location
    }

    func setCursorPosition(_ position: Int) {
        let text = textView.string as NSString
        let safePosn = min(position, text.length)
        textView.setSelectedRange(NSRange(location: safePosn, length: 0))
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    /// The schema an unqualified table is looked for in first: the toolbar's
    /// pick, else the connection's default.
    func setCurrentSchema(_ schema: String?) {
        completionProvider.currentSchema = schema
    }

    func updateSchemaMetadata(
        schemas: [SchemaInfo],
        tables: [String: [TableInfo]],
        columnsByTable: [String: [ColumnInfo]]
    ) {
        completionProvider.updateMetadata(schemas: schemas, tables: tables, columnsByTable: columnsByTable)
    }

    // MARK: - Error Markers

    /// Mark an error at `range` in the document: a dot in the gutter and a red
    /// underline on the faulty text.
    ///
    /// The range is in document coordinates, not in the coordinates of the SQL
    /// that produced the error. Those two differ whenever the user runs one
    /// segment out of a longer document, or whenever `{{variable}}` substitution
    /// changed the text — so the caller does the move, with
    /// `SQLErrorLocation.range(of:in:)`.
    /// `message` is the failure text, when the caller has it. The gutter keeps
    /// it beside the marker so VoiceOver reads the error out instead of only
    /// announcing that there is one.
    func markError(range: NSRange, message: String? = nil) {
        let text = textView.string
        guard NSMaxRange(range) <= (text as NSString).length else { return }
        // +1 because lineNumber counts to a 1-based position, which is the form
        // PostgreSQL reports and the form this code has always been given.
        let line = lineNumber(forCharacterIndex: range.location + 1, in: text)
        gutter?.setErrors([line: message])
        // `setErrors` REPLACES the gutter's whole error set, so the remembered
        // ranges are replaced with it — otherwise a stale range from an earlier
        // failure would outlive the marker it belonged to and "Go to Error"
        // would jump into text that is no longer in question.
        errorRangesByLine = [line: range]
        textView.addErrorUnderline(range: range)
    }

    /// The document range each marked error line stands for, so the gutter's
    /// "Go to Error" — which knows only the line — can reveal the exact text.
    private var errorRangesByLine: [Int: NSRange] = [:]

    /// Mark an error whose position counts into the whole document. Live
    /// validation runs on the document text, so it takes this path.
    func markError(_ location: SQLErrorLocation, message: String? = nil) {
        guard let range = location.range(in: textView.string) else { return }
        markError(range: range, message: message)
    }

    /// Put the caret on `range`, scroll it into sight and take focus. Used by the
    /// error sheet's Go to Error button, with a document range.
    func revealError(range: NSRange) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        view.window?.makeFirstResponder(textView)
    }

    /// Clear all error markers (gutter dots + underlines).
    func clearErrorMarkers() {
        gutter?.clearErrors()
        errorRangesByLine.removeAll()
        textView.clearErrorUnderlines()
    }

    // MARK: - Settings

    /// The `EditorSettings` this view is currently showing.
    ///
    /// It doubles as the change signature the rehighlight decision reads: the
    /// whole struct is `Equatable`, so nothing has to be listed twice. `var`,
    /// not `let`, inside: the pinch/⌘+/⌘− paths apply a font size straight to
    /// the view and update just `fontSize` here, so when the save they trigger
    /// republishes settings, `applySettings(_:)` finds it already matching and
    /// skips a redundant rehighlight (no flicker).
    private var lastApplied: EditorSettings?

    /// The font size currently showing in the editor. Normally equal to
    /// `stateManager.settings.editor.fontSize`, but can briefly lead it while
    /// a pinch gesture is in progress (the view updates every frame; the
    /// setting is written once, on `.ended`). Exposed (not private) so the
    /// View menu's Increase/Decrease Editor Font items can validate against
    /// the 9...24 clamp.
    var currentFontSize: Int {
        Int(lastApplied?.fontSize ?? stateManager.settings.editor.fontSize)
    }

    /// Apply one delivered `EditorSettings` snapshot to every part of the
    /// editor that reads it. The argument is the source of truth here —
    /// nothing in this method re-reads the settings store.
    private func applySettings(_ editor: EditorSettings) {
        guard editor != lastApplied else { return }
        let previous = lastApplied
        let needsRehighlight = editor.fontFamily != previous?.fontFamily
            || editor.fontSize != previous?.fontSize
            || editor.tabSize != previous?.tabSize
            || editor.wordWrap != previous?.wordWrap
        lastApplied = editor

        applyFontSize(Int(editor.fontSize))

        // Tab size, and what a Tab actually writes
        textView.tabSize = Int(editor.tabSize)
        textView.insertSpacesForTab = editor.insertSpacesForTab
        textView.autoIndentEnabled = editor.autoIndent
        textView.autoPairBrackets = editor.autoPairBrackets
        textView.autoPairQuotes = editor.autoPairQuotes
        textView.highlightCurrentLine = editor.highlightCurrentLine

        // Completion
        textView.completionTrigger = editor.completionTrigger
        textView.completionMinimumCharacters = Int(editor.completionMinimumCharacters)
        completionProvider.maximumItems = Int(editor.completionMaximumItems)
        completionProvider.keywordCase = editor.completionKeywordCase

        // Paste
        textView.offersSqlListChip = editor.offerSqlListChip
        textView.sqlListQuoteStyle = editor.sqlListQuoteStyle

        // Colours. The theme's own `didSet` re-highlights, so this is not part
        // of `needsRehighlight`.
        let theme = SQLTheme.named(editor.syntaxTheme)
        if editor.syntaxTheme != previous?.syntaxTheme {
            textView.theme = theme
        }

        // Folding. Switching it off unfolds everything (SQLTextView's own
        // `didSet`) and then empties the gutter, which is what takes the
        // chevrons away.
        textView.codeFoldingEnabled = editor.codeFolding
        if editor.codeFolding != previous?.codeFolding
            || editor.minimumLinesToFold != previous?.minimumLinesToFold {
            recalculateFoldRegions()
        }

        // A card is one statement: no statement bands, no run glyphs. The
        // card's own Run button runs it.
        gutter?.setDrawsSegmentBands(false)

        // Line numbers — toggle gutter visibility and re-layout
        gutter?.isHidden = !editor.lineNumbers
        layoutGutterAndScrollView()

        // Word wrap
        if editor.wordWrap {
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size.width = textView.enclosingScrollView?.contentSize.width ?? 0
            textView.isHorizontallyResizable = false
            textView.minSize = NSSize(width: 0, height: 0)
            scrollView.hasHorizontalScroller = false
        } else {
            // Apple's non-wrapping recipe: an unbounded container, a text view
            // that grows with its longest line, a horizontal scroller to reach
            // it, and `minSize` = the clip so the view never shrinks below the
            // visible area (a click right of short text would otherwise miss).
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.size.width = CGFloat.greatestFiniteMagnitude
            textView.isHorizontallyResizable = true
            textView.minSize = scrollView.contentSize
            scrollView.hasHorizontalScroller = true
        }

        if needsRehighlight {
            textView.highlightSyntax()
        }
        onContentHeightChange?()
    }

    /// Builds the editor font at `size` (from the current font family setting)
    /// and applies it to the text view and the gutter — nothing else. Factored
    /// out of `applySettings()` so the live pinch/⌘+/⌘− path and the full
    /// settings apply build the exact same font from the exact same rules.
    private func applyFontSize(_ size: Int) {
        // The family from the snapshot this view last applied, so a pinch
        // mid-flight cannot pick up a family from a save that has not reached
        // `applySettings(_:)` yet.
        let family = lastApplied?.fontFamily ?? stateManager.settings.editor.fontFamily
        let editorFont = Self.editorFont(family: family, size: CGFloat(size))
        textView.font = editorFont
        // The gutter's numbers follow the editor size (see LineNumberGutter.setFont).
        gutter?.setFont(editorFont)
    }

    /// The editor font for a Settings ▸ Editor family and size. Card previews
    /// use it too, so a preview and the editor that replaces it line up.
    static func editorFont(family: String, size: CGFloat) -> NSFont {
        let fontName = family.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? "Menlo"
        if fontName == "System Monospace" {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Pinch / keyboard font size

    /// Font size in effect when the current pinch gesture began.
    private var pinchStartFontSize = 13

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartFontSize = currentFontSize
        case .changed:
            let newSize = FontSizeStepper.size(start: pinchStartFontSize, magnification: recognizer.magnification)
            guard newSize != currentFontSize else { return }
            applyFontSize(newSize)
            lastApplied?.fontSize = UInt32(newSize)
            // The gutter's width derives from the font, so it must re-layout
            // alongside the view-only font change, not just on the next
            // settings-driven applySettings() pass.
            layoutGutterAndScrollView()
        case .ended, .cancelled, .failed:
            persistCurrentFontSize()
        default:
            break
        }
    }

    /// Steps the font size by one, same clamp and save path as the pinch.
    /// Used by the View menu's Increase/Decrease Editor Font commands.
    func stepFontSize(by delta: Int) {
        let newSize = FontSizeStepper.stepped(currentFontSize, by: delta)
        guard newSize != currentFontSize else { return }
        applyFontSize(newSize)
        lastApplied?.fontSize = UInt32(newSize)
        layoutGutterAndScrollView()
        persistCurrentFontSize()
    }

    /// Writes the font size currently showing in the view through the one
    /// settings save path (`AppStateManager.saveSettings`), if it differs
    /// from what's stored. Never called per pinch frame — only once, when a
    /// gesture ends or a keyboard step completes — so a fast pinch does not
    /// hammer SQLite or republish app-wide on every frame.
    private func persistCurrentFontSize() {
        let size = UInt32(currentFontSize)
        var updated = stateManager.settings
        guard updated.editor.fontSize != size else { return }
        updated.editor.fontSize = size
        stateManager.saveSettings(updated)
    }

    // MARK: - Size

    /// The height the card's editor needs to show every line: the used text
    /// plus the text insets, plus a legacy horizontal scroller when one is
    /// showing. Never less than one line.
    var contentHeight: CGFloat {
        guard isViewLoaded, let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
        var height = max(lm.usedRect(for: tc).height, line) + textView.textContainerInset.height * 2
        if scrollView.hasHorizontalScroller, scrollView.scrollerStyle == .legacy,
           let scroller = scrollView.horizontalScroller {
            height += scroller.frame.height
        }
        return ceil(height) + 1
    }

    /// The caret's rect in `view`'s coordinates, for the card stack to keep
    /// on screen.
    var caretRectInView: NSRect? {
        guard isViewLoaded, let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let length = (textView.string as NSString).length
        let location = min(textView.selectedRange().location, length)
        var rect: NSRect
        if length == 0 || location >= length {
            rect = lm.extraLineFragmentRect.isEmpty
                ? lm.boundingRect(forGlyphRange: NSRange(location: max(0, lm.numberOfGlyphs - 1), length: min(1, lm.numberOfGlyphs)), in: tc)
                : lm.extraLineFragmentRect
        } else {
            let glyph = lm.glyphIndexForCharacter(at: location)
            rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return view.convert(rect, from: textView)
    }

    // MARK: - Selection

    /// The editor's selection, or nil when nothing is selected.
    ///
    /// Used by the run scope (Settings ▸ Query ▸ Run). The text is returned
    /// as typed; the resolver decides whether a whitespace-only selection
    /// counts as one.
    func selectedSQL() -> String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    // MARK: - Code Folding

    /// Recalculate fold regions from the current editor text.
    private func recalculateFoldRegions() {
        foldRegions = rebuildFoldRegions()
        gutter?.setFoldRegions(foldRegions)
    }

    /// Re-parse fold regions from the full text and sync collapsed state from FoldState.
    /// Text storage is never modified for folding, so the parser always sees the full SQL.
    private func rebuildFoldRegions() -> [SQLFoldRegion] {
        // Folding off means no regions at all, which is what takes the
        // chevrons out of the gutter. `SQLTextView` has already unfolded
        // whatever was collapsed.
        guard let editor = lastApplied, editor.codeFolding else { return [] }
        var newRegions = SQLFoldingParser.parse(
            textView.string, minimumLines: Int(editor.minimumLinesToFold))
        let foldEntries = textView.foldState.entries

        // Mark regions as collapsed if FoldState has a matching entry
        for idx in 0..<newRegions.count {
            let region = newRegions[idx]
            // A fold entry matches a region if it starts near the region's fold start
            if let entry = foldEntries.first(where: { entry in
                let foldStart = entry.range.location
                return abs(foldStart - region.startCharIndex) <= 2
            }) {
                newRegions[idx].isCollapsed = true
                newRegions[idx].foldEntryId = entry.id
            }
        }

        return newRegions
    }

    /// Toggle fold/unfold for a region at the given index.
    private func toggleFold(at regionIndex: Int) {
        guard regionIndex >= 0, regionIndex < foldRegions.count else { return }

        let region = foldRegions[regionIndex]

        if region.isCollapsed {
            // Unfold: remove the fold entry from FoldState
            guard let entryId = region.foldEntryId else { return }
            textView.unfold(id: entryId)
        } else {
            // Fold: calculate the char range to fold
            let text = textView.string as NSString
            guard text.length > 0 else { return }

            let startCharIdx: Int
            let endCharIdx: Int

            switch region.kind {
            case .parenBlock, .subquery, .cte:
                // Fold only the inner content between ( and )
                startCharIdx = region.startCharIndex // char after '('
                endCharIdx = min(region.closeCharIndex - 1, text.length - 1) // char before ')'
            default:
                // Keyword-based folds: fold the full range
                startCharIdx = region.startCharIndex
                endCharIdx = min(region.endCharIndex, text.length - 1)
            }

            guard startCharIdx < text.length, startCharIdx <= endCharIdx else { return }

            let foldRange = NSRange(location: startCharIdx, length: endCharIdx - startCharIdx + 1)
            let lineCount = region.endLine - region.startLine
            let placeholder = " \u{25B8} \(lineCount) lines "

            textView.fold(range: foldRange, placeholder: placeholder)
        }

        // Rebuild fold regions to sync gutter state
        recalculateFoldRegions()
    }

    // MARK: - Text Changes

    private func textDidChange(_ newText: String) {
        guard let documentId else { return }

        // Clear any execution error markers when user starts typing
        clearErrorMarkers()

        // FoldState.adjustForEdit (called from SQLTextView.didChangeText) automatically
        // removes folds that overlap the edit and shifts folds after it.

        onContentHeightChange?()

        // Debounced fold region recalculation (full document parse — not needed per keystroke)
        foldRegionTask?.cancel()
        foldRegionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            guard !Task.isCancelled, let self else { return }
            self.recalculateFoldRegions()
        }

        // The owner stores the text first, then reacts to the edit (result tab
        // staleness, the referenced-variables scan).
        onTextEdited?(documentId, textView.string)

        // Debounced validation
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard !Task.isCancelled else { return }
            await self?.validateSQL(newText)
        }
    }

    private func validateSQL(_ sql: String) async {
        guard let connectionId = validationConnectionId(),
              stateManager.status(for: connectionId) == .connected,
              !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await MainActor.run { self.clearErrorMarkers() }
            return
        }

        // Skip live validation while unsubstituted variable tokens are present:
        // Postgres would flag `{{...}}` as a syntax error, and substituted-text
        // error offsets wouldn't map back to the editor's token-form text.
        guard !VariableSubstitutor.containsTokens(sql) else {
            await MainActor.run { self.clearErrorMarkers() }
            return
        }

        do {
            let result = try await PharosCore.validateSQL(connectionId: connectionId, sql: sql)
            await MainActor.run {
                if let error = result.error, let position = error.position {
                    self.markError(SQLErrorLocation(
                        charPosition: position,
                        tokenLength: SQLErrorLocation.tokenLength(from: error.message)
                    ), message: error.message)
                } else {
                    self.clearErrorMarkers()
                }
            }
        } catch {
            // Validation failure is non-critical, just clear markers
            await MainActor.run { self.clearErrorMarkers() }
        }
    }

    private func lineNumber(forCharacterIndex index: Int, in text: String) -> Int {
        var line = 1
        var pos = 0
        for char in text {
            if pos >= index { break }
            if char == "\n" { line += 1 }
            pos += 1
        }
        return line
    }
}

// MARK: - SQLTextViewCompletionDelegate

extension SQLEditorController: SQLTextViewCompletionDelegate {

    var isCompletionShown: Bool { completionProvider.isShown }

    func triggerCompletion() {
        completionProvider.showCompletions(for: textView)
    }

    func updateCompletion() {
        completionProvider.showCompletions(for: textView)
    }

    func dismissCompletion() {
        completionProvider.dismiss()
    }

    func completionMoveUp() -> Bool {
        guard completionProvider.isShown else { return false }
        completionProvider.moveUp()
        return true
    }

    func completionMoveDown() -> Bool {
        guard completionProvider.isShown else { return false }
        completionProvider.moveDown()
        return true
    }

    func acceptCompletion() -> Bool {
        guard completionProvider.isShown else { return false }
        completionProvider.acceptSelected()
        return true
    }
}

/// The card editor's scroll view: sideways only. A vertical wheel or trackpad
/// movement goes to the card stack, so scrolling over a card scrolls the
/// stack instead of stopping dead.
final class CardEditorScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
