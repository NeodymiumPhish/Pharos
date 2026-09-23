import AppKit

// MARK: - Completion Delegate

protocol SQLTextViewCompletionDelegate: AnyObject {
    var isCompletionShown: Bool { get }
    func triggerCompletion()
    func updateCompletion()
    func dismissCompletion()
    func completionMoveUp() -> Bool
    func completionMoveDown() -> Bool
    func acceptCompletion() -> Bool
}

// MARK: - SQLTextView

/// NSTextView subclass with SQL syntax highlighting via shared SQLLexer state map.
class SQLTextView: NSTextView {

    weak var completionDelegate: SQLTextViewCompletionDelegate?

    /// Number of spaces inserted when pressing Tab.
    var tabSize: Int = 2

    var theme = SQLTheme.default {
        didSet { highlightSyntax() }
    }

    // MARK: - Settings ▸ Editor
    //
    // Every one of these defaults to what this view did before the setting
    // existed, so a host that never sets them behaves exactly as before.
    // `QueryEditorVC.applySettings(_:)` pushes the stored values in.

    /// Tab writes `tabSize` spaces. Off writes one tab character.
    var insertSpacesForTab: Bool = true

    /// Return copies the current line's leading whitespace.
    var autoIndentEnabled: Bool = true

    /// Typing `(` or `[` also writes the closer (and Backspace over the pair
    /// takes both out).
    var autoPairBrackets: Bool = true

    /// The same for `'`.
    var autoPairQuotes: Bool = true

    /// A wash behind the line holding the caret.
    var highlightCurrentLine: Bool = true {
        didSet { if highlightCurrentLine != oldValue { needsDisplay = true } }
    }

    /// Folding at all. Turning it off unfolds everything that is folded —
    /// text hidden by a setting the user has just switched off would be text
    /// they cannot reach.
    var codeFoldingEnabled: Bool = true {
        didSet {
            guard !codeFoldingEnabled, codeFoldingEnabled != oldValue else { return }
            unfoldAll()
        }
    }

    /// When the completion list opens on its own. Ctrl+Space ignores this.
    var completionTrigger: CompletionTrigger = .afterDot

    /// Identifier characters needed before the identifier trigger fires.
    var completionMinimumCharacters: Int = 1

    /// Whether a paste that looks like a bare value list offers the
    /// "Format as SQL list" chip.
    var offersSqlListChip: Bool = true

    /// How that formatter quotes a value.
    var sqlListQuoteStyle: SqlListQuoteStyle = .single

    /// One indent level, as the text Tab actually writes.
    private var indentUnit: String {
        insertSpacesForTab ? String(repeating: " ", count: tabSize) : "\t"
    }

    /// The opener → closer pairs auto-pairing is ON for right now. Empty when
    /// both switches are off, which turns every auto-pair path into the plain
    /// insert `NSTextView` would have done.
    private var activeAutoClosePairs: [String: String] {
        var pairs: [String: String] = [:]
        if autoPairBrackets {
            pairs["("] = ")"
            pairs["["] = "]"
        }
        if autoPairQuotes {
            pairs["'"] = "'"
        }
        return pairs
    }

    /// The closers skip-over applies to — the same set, seen from the other
    /// end.
    private var activeCloseChars: Set<String> {
        Set(activeAutoClosePairs.values)
    }

    /// Names (without braces) of variables defined for the active tab. Drives
    /// defined-vs-undefined coloring of `{{name}}` tokens. Re-highlights on change.
    var variableNames: Set<String> = [] {
        didSet {
            guard variableNames != oldValue else { return }
            highlightSyntax()
        }
    }

    /// Called whenever the text changes (after highlighting).
    var onTextChange: ((String) -> Void)?

    /// Called when fold state changes (fold or unfold) so the host VC can re-sync gutter.
    var onFoldStateChanged: (() -> Void)?

    /// Called when user clicks a fold placeholder to request unfold. Parameter is the fold entry UUID.
    var onPlaceholderClicked: ((UUID) -> Void)?

    // MARK: Format-as-SQL-list paste offer

    /// Called after a paste whose content looks like a bare value list
    /// (see SQLListFormatter.looksLikeBareList).
    var onListPasteDetected: (() -> Void)?

    /// Called when a pending list-paste offer is invalidated (any edit,
    /// selection move away from the paste end, or Esc).
    var onListPasteOfferInvalidated: (() -> Void)?

    /// Range of the last paste that qualified for the SQL-list offer.
    /// Deliberately NOT cleared on focus loss: invalidating in
    /// resignFirstResponder would race with clicking the toolbar apply
    /// button. Safe because any edit invalidates, so the range can't go stale.
    private var pendingListPasteRange: NSRange?

    /// Suppresses offer invalidation for the text/selection changes that
    /// applyPendingSQLize itself performs.
    private var isApplyingSQLize = false

    var hasListPasteOffer: Bool { pendingListPasteRange != nil }

    /// Fold state — tracks collapsed regions separately from text storage.
    /// Text storage always contains the full, unfolded SQL.
    /// Owned by the FoldingLayoutManager; accessed here for convenience.
    var foldState: FoldState {
        (layoutManager as! FoldingLayoutManager).foldState
    }

    /// Monotonically increasing generation tag for highlight passes. The
    /// off-main computation captures the current value; on completion the
    /// apply step bails if a newer pass has been scheduled (i.e. the user
    /// kept typing while a large document was being lexed off-main).
    private var highlightGeneration: UInt64 = 0

    /// Pending debounced highlightSyntax task, replaced on each keystroke.
    /// Full-document syntax passes are expensive on large docs (multi-KB
    /// WITH clauses, query results pasted in, etc.), so the visible-color
    /// refresh is deferred 150 ms after typing stops to keep input snappy.
    private var highlightDebounceTask: Task<Void, Never>?

    /// One undo stack per editor. Without this, NSResponder hands back the
    /// WINDOW's undo manager, shared by every text view and field in it, so
    /// ⌘Z in one pane could undo an edit made in the other. `setSQL` clears
    /// this stack on a tab switch, and that must not touch anyone else's history.
    private let editorUndoManager = UndoManager()
    override var undoManager: UndoManager? { editorUndoManager }

    /// Edit ▸ Undo and Redo are `undo:` / `redo:` sent down the responder
    /// chain, and `NSTextView` does not answer them: the first class that does
    /// is `NSWindow`, which undoes on the WINDOW's manager. With a per-editor
    /// manager that stack is always empty, so ⌘Z did nothing anywhere in the
    /// editor from 2026-09-04 until this override (measured with a probe: a
    /// stock text view undoes through the window, one with its own manager
    /// does not). Answering here keeps the action on this editor's stack.
    @objc func undo(_ sender: Any?) { editorUndoManager.undo() }
    @objc func redo(_ sender: Any?) { editorUndoManager.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(SQLTextView.undo(_:)) { return editorUndoManager.canUndo }
        if item.action == #selector(SQLTextView.redo(_:)) { return editorUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// Convenience initializer — creates the full text system with FoldingLayoutManager.
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = FoldingLayoutManager(foldState: FoldState())
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    private func commonInit() {
        isEditable = true
        isSelectable = true
        allowsUndo = true
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        // Smart insert/delete adds and strips spaces around a cut or pasted
        // word — wrong for code. The system word completion is a second
        // completion UI that would compete with SQLCompletionProvider.
        smartInsertDeleteEnabled = false
        isAutomaticTextCompletionEnabled = false
        writingToolsBehavior = .none
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = .labelColor
        backgroundColor = .textBackgroundColor
        insertionPointColor = .labelColor

        textContainerInset = NSSize(width: 4, height: 8)

        // Use temporary attributes for highlighting (doesn't interfere with undo)
        layoutManager?.allowsNonContiguousLayout = true

        // Added to what NSTextView already accepts, never replacing it: the
        // plain-text drop that inserts the dragged string must keep working.
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
    }

    // MARK: - File Drop

    /// A `.sql` (or any text) file dropped on the editor opens as a TAB of its
    /// own rather than being inserted into the query under the cursor —
    /// the same result as File > Open… or a drop on the Dock icon, which is
    /// what an editor drop means everywhere else on the system.
    ///
    /// The files are handed to the app delegate's `application(_:open:)`, the
    /// one entry point that already turns a URL into a tab, so this view needs
    /// no reference to `AppStateManager` (and keeps compiling on its own in
    /// scripts/test-completion-accessibility.sh).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropOperation(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropOperation(sender) ?? super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.textFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            // Not a file drag at all — a dragged string, say — keeps the
            // editor's own insert-the-text behaviour.
            guard Self.fileURLs(from: sender.draggingPasteboard).isEmpty else { return false }
            return super.performDragOperation(sender)
        }
        NSApp.delegate?.application?(NSApp, open: urls)
        return true
    }

    /// How this view answers a FILE drag: `.copy` for text files, refused for
    /// any other file, and nil for a drag that carries no file at all (the
    /// caller then defers to NSTextView).
    ///
    /// A file the editor cannot open must be refused HERE, not just at the
    /// drop: NSTextView's own answer is `.copy` — it would insert the file's
    /// name as text — so the cursor would promise a drop that
    /// `performDragOperation` then silently refuses.
    private func fileDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation? {
        if !Self.textFileURLs(from: sender.draggingPasteboard).isEmpty { return .copy }
        if !Self.fileURLs(from: sender.draggingPasteboard).isEmpty { return [] }
        return nil
    }

    /// Every file URL on `pasteboard`, in drag order.
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    /// The dropped files this editor can open: anything whose content type
    /// conforms to `public.text`.
    ///
    /// Mirrors the rule in `AppDelegate.application(_:open:)`, extension
    /// fallback included, because the drop has to decide whether to show the
    /// copy cursor BEFORE the delegate ever sees the URLs.
    static func textFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        fileURLs(from: pasteboard).filter { url in
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return type.conforms(to: .text)
            }
            return ["sql", "txt", "md"].contains(url.pathExtension.lowercased())
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        cancelPendingCompletionOffer()
        completionDelegate?.dismissCompletion()

        // Check if click lands on a fold pill — if so, unfold it
        if !foldState.entries.isEmpty, let foldingLM = layoutManager as? FoldingLayoutManager, let textContainer {
            let localPoint = convert(event.locationInWindow, from: nil)
            let textOrigin = textContainerOrigin
            let pointInText = NSPoint(x: localPoint.x - textOrigin.x, y: localPoint.y - textOrigin.y)

            if let entry = foldingLM.foldEntry(at: pointInText, in: textContainer) {
                onPlaceholderClicked?(entry.id)
                return
            }
        }

        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Show pointing hand cursor over fold pills
        guard !foldState.entries.isEmpty,
              let foldingLM = layoutManager as? FoldingLayoutManager,
              let textContainer else { return }
        let textOrigin = textContainerOrigin
        for entry in foldState.entries {
            guard let rect = foldingLM.pillRect(for: entry, in: textContainer) else { continue }
            let adjustedRect = rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
            addCursorRect(adjustedRect, cursor: .pointingHand)
        }
    }

    // MARK: - Text Changes

    /// Tracks the range being edited so foldState can adjust on didChangeText.
    private var pendingEditRange: NSRange?
    private var pendingReplacementLength: Int?

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        pendingEditRange = affectedCharRange
        pendingReplacementLength = (replacementString as NSString?)?.length
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()

        // Adjust fold state for the edit — removes folds that overlap the edit, shifts others
        if let editRange = pendingEditRange {
            let changeInLength = (pendingReplacementLength ?? 0) - editRange.length
            let hadFolds = !foldState.entries.isEmpty
            let removed = foldState.adjustForEdit(editedRange: editRange, changeInLength: changeInLength)
            if hadFolds {
                // A removed fold's range is in pre-edit coordinates. Text after
                // the edit moved by `changeInLength`, so widen each range by any
                // growth; `invalidateFoldLayout` clamps to the new length.
                let shifted = removed.map {
                    NSRange(location: $0.location, length: $0.length + max(0, changeInLength))
                }
                invalidateFoldLayout(revealing: shifted)
            }
        }
        pendingEditRange = nil
        pendingReplacementLength = nil

        // The text changed under any in-flight highlight pass: its spans were
        // computed for the OLD text and can now reach past the end of the new
        // one. Bumping the generation here makes that pass discard itself.
        highlightGeneration &+= 1
        scheduleDebouncedHighlight()
        onTextChange?(string)

        // Any edit invalidates a pending list-paste offer (except the
        // SQL-ize application itself).
        if !isApplyingSQLize {
            invalidateListPasteOffer()
        }

        // Completion triggers after text change
        refreshCompletion()
    }

    // MARK: - Completion Offer

    /// Follow the text: refilter a list that is open, or ask whether one
    /// should open.
    private func refreshCompletion() {
        if completionDelegate?.isCompletionShown == true {
            completionDelegate?.updateCompletion()
        } else {
            offerCompletionIfAppropriate()
        }
    }

    /// NSTextView's own completion action — ⌥Esc and F5 by default. It opens
    /// OUR list, not the system word list. With plain Esc (see `keyDown`)
    /// these are the ways in that need no Control key: Ctrl+Space with a
    /// trackpad touch is a Control-click, which opens the context menu instead.
    override func complete(_ sender: Any?) {
        cancelPendingCompletionOffer()
        completionDelegate?.triggerCompletion()
    }

    /// Pending debounced identifier-trigger offer, replaced on each keystroke.
    private var completionOfferTask: Task<Void, Never>?

    /// How long typing must stop before the IDENTIFIER trigger opens the list.
    /// The dot trigger is not debounced: it is unambiguous, and the analyst is
    /// waiting on it.
    private static let completionDebounceNanoseconds: UInt64 = 120_000_000  // 120 ms

    /// Drop any offer that has not fired yet.
    func cancelPendingCompletionOffer() {
        completionOfferTask?.cancel()
        completionOfferTask = nil
    }

    /// Ask `CompletionTriggerPolicy` whether the caret earns a completion
    /// list, and open one if it does.
    private func offerCompletionIfAppropriate() {
        cancelPendingCompletionOffer()

        let text = string as NSString
        let cursor = min(selectedRange().location, text.length)

        // In a `{{` token the variable list opens at once — no debounce, as
        // `{{` is as unambiguous as a dot — and the SQL list never does. It
        // opens in a string literal too: a token there is substituted all the
        // same (`'{{day}}'`).
        if VariableCompletion.context(in: text, caret: cursor) != nil {
            if completionTrigger != .off {
                completionDelegate?.triggerCompletion()
            }
            return
        }

        var preceding: Character?
        if cursor > 0, let scalar = UnicodeScalar(text.character(at: cursor - 1)) {
            preceding = Character(scalar)
        }

        guard CompletionTriggerPolicy.shouldOffer(
            trigger: completionTrigger,
            minimumCharacters: completionMinimumCharacters,
            prefix: identifierPrefix(before: cursor, in: text),
            precedingCharacter: preceding,
            isInStringOrComment: isInStringOrComment(atCaret: cursor)
        ) else { return }

        if preceding == "." {
            completionDelegate?.triggerCompletion()
            return
        }

        completionOfferTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.completionDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.completionOfferTask = nil
            self.completionDelegate?.triggerCompletion()
        }
    }

    /// The identifier characters already typed immediately before `cursor`.
    private func identifierPrefix(before cursor: Int, in text: NSString) -> String {
        var start = cursor
        while start > 0 {
            guard let scalar = UnicodeScalar(text.character(at: start - 1)) else { break }
            guard CharacterSet.alphanumerics.contains(scalar) || scalar == UnicodeScalar("_") else { break }
            start -= 1
        }
        guard start < cursor else { return "" }
        return text.substring(with: NSRange(location: start, length: cursor - start))
    }

    /// Whether a caret at `cursor` sits inside a string literal or a comment.
    ///
    /// Read from the shared `SQLLexSnapshot` state map — the same lex the
    /// highlighter and both parsers use — rather than from the temporary
    /// colour attributes, which lag the text by the 150 ms highlight debounce
    /// and would therefore answer for the PREVIOUS keystroke.
    ///
    /// The caret sits between two characters; the state that governs it is the
    /// one of the character to its left.
    private func isInStringOrComment(atCaret cursor: Int) -> Bool {
        let snapshot = SQLLexSnapshot.shared(for: string)
        guard snapshot.length > 0, cursor > 0 else { return false }
        let index = min(cursor - 1, snapshot.length - 1)
        switch snapshot.stateMap[index] {
        case .singleQuote, .dollarQuote, .lineComment, .blockComment:
            return true
        case .normal, .doubleQuote:
            // A double-quoted token is an IDENTIFIER in Postgres, not a
            // string: completing a column name inside one is exactly right.
            return false
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Moving the caret away from the paste end abandons the offer.
        if let pending = pendingListPasteRange, !isApplyingSQLize {
            let expected = NSRange(location: pending.location + pending.length, length: 0)
            if selectedRange() != expected {
                invalidateListPasteOffer()
            }
        }
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl+Space → explicit trigger
        if event.charactersIgnoringModifiers == " " && flags.contains(.control) {
            completionDelegate?.triggerCompletion()
            return
        }

        // Escape → dismiss completion if shown, else a pending list-paste
        // offer, else open the completion list (Xcode's completion key; the
        // editor has no other use for a bare Escape).
        if event.keyCode == 53, flags.isDisjoint(with: [.command, .option, .control, .shift]) {
            cancelPendingCompletionOffer()
            if completionDelegate?.isCompletionShown == true {
                completionDelegate?.dismissCompletion()
                return
            }
            if hasListPasteOffer {
                invalidateListPasteOffer()
                return
            }
            completionDelegate?.triggerCompletion()
            return
        }

        // Up/Down while completion shown → navigate
        if event.keyCode == 126, completionDelegate?.completionMoveUp() == true { return }
        if event.keyCode == 125, completionDelegate?.completionMoveDown() == true { return }

        // Return or Tab while completion shown → accept
        if event.keyCode == 36 || event.keyCode == 48 {
            if completionDelegate?.acceptCompletion() == true { return }
        }

        // Tab while a "Format as SQL list" offer is pending → apply it
        // (Shift+Tab means dedent — let it fall through)
        if event.keyCode == 48, !flags.contains(.shift), hasListPasteOffer {
            applyPendingSQLize()
            return
        }

        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if selectedRange().length > 0 {
            let item = NSMenuItem(
                title: "Format as SQL list",
                action: #selector(formatSelectionAsSQLList(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu?.insertItem(.separator(), at: 0)
            menu?.insertItem(item, at: 0)
        }
        return menu
    }

    // MARK: - Auto-Close Brackets

    /// Auto-close only fires when the character following the insertion point
    /// is end-of-document, whitespace, or a closing delimiter. Typing `(`
    /// directly before existing text inserts just the `(`.
    private static let autoCloseFollowers = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ")],;"))

    private static func allowsAutoClose(after position: Int, in text: NSString) -> Bool {
        guard position < text.length else { return true }
        guard let scalar = UnicodeScalar(text.character(at: position)) else { return false }
        return autoCloseFollowers.contains(scalar)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String, str.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let cursor = selectedRange().location
        let text = self.string as NSString
        let autoClosePairs = activeAutoClosePairs

        // `{{` → `{{|}}`, and `}` steps over the pair's own braces. The
        // brackets setting governs these like `(` and `[`.
        if autoPairBrackets, selectedRange().length == 0 {
            if str == "{", VariableCompletion.shouldAutoClose(in: text, at: cursor) {
                super.insertText("{}}", replacementRange: replacementRange)
                setSelectedRange(NSRange(location: selectedRange().location - 2, length: 0))
                // The edit reported the caret AFTER `}}`, outside the token;
                // now that it is inside, give the variable list its chance.
                refreshCompletion()
                return
            }
            if str == "}", VariableCompletion.shouldStepOver(in: text, at: cursor) {
                setSelectedRange(NSRange(location: cursor + 1, length: 0))
                // No edit happened, so nothing else closes the variable list
                // the caret just stepped out of.
                refreshCompletion()
                return
            }
        }

        // Wrap selection: typing an opener with a non-empty selection wraps
        // it instead of replacing it, with the caret placed after the closing
        // character so typing can continue (e.g. a comma after 'value').
        let sel = selectedRange()
        if sel.length > 0, let closeChar = autoClosePairs[str] {
            let selected = text.substring(with: sel)
            super.insertText(str + selected + closeChar, replacementRange: sel)
            return
        }

        // Skip-over: typing a closing char that's already the next character
        if activeCloseChars.contains(str), cursor < text.length {
            guard let nextScalar = UnicodeScalar(text.character(at: cursor)) else {
                super.insertText(string, replacementRange: replacementRange)
                return
            }
            let nextChar = String(Character(nextScalar))
            if nextChar == str {
                // For quote, only skip if we're inside a matching pair
                if str == "'" {
                    if cursor > 0, let prevScalar = UnicodeScalar(text.character(at: cursor - 1)) {
                        let prevChar = Character(prevScalar)
                        // Don't skip if previous char is also a quote (empty string case handled)
                        if prevChar != "'" {
                            setSelectedRange(NSRange(location: cursor + 1, length: 0))
                            return
                        }
                    }
                } else {
                    setSelectedRange(NSRange(location: cursor + 1, length: 0))
                    return
                }
            }
        }

        // Auto-close: insert matching pair
        if let closeChar = autoClosePairs[str] {
            // For quotes, don't auto-close if previous char is alphanumeric (e.g., it's an apostrophe)
            if str == "'" && cursor > 0 {
                let prevScalar = UnicodeScalar(text.character(at: cursor - 1))
                if let s = prevScalar, CharacterSet.alphanumerics.contains(s) {
                    super.insertText(string, replacementRange: replacementRange)
                    return
                }
            }
            // Don't auto-close when text sits immediately to the right of the
            // insertion point. (Selection is always empty here — a non-empty
            // selection took the wrap branch above.)
            if !Self.allowsAutoClose(after: cursor, in: text) {
                super.insertText(string, replacementRange: replacementRange)
                return
            }
            super.insertText(str + closeChar, replacementRange: replacementRange)
            // Move cursor back between the pair
            setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0))
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: - Indent-Aware Paste

    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }

        let lines = pasted.components(separatedBy: "\n")
        guard lines.count > 1 else {
            super.paste(sender)
            return
        }

        // Determine indentation at the cursor position
        let text = self.string as NSString
        let cursor = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
        let colInLine = cursor - lineRange.location
        let currentLine = text.substring(with: NSRange(location: lineRange.location, length: colInLine))
        let cursorIndent = String(currentLine.prefix(while: { $0 == " " || $0 == "\t" }))
        // Only use cursor indent if cursor is at or within the leading whitespace
        let effectiveIndent = colInLine <= cursorIndent.count ? cursorIndent : String(repeating: " ", count: colInLine)

        // Find the base indentation of the pasted block (min indent of lines 2+, ignoring empty lines)
        let tailLines = lines.dropFirst()
        let baseIndent: String = tailLines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in String(line.prefix(while: { $0 == " " || $0 == "\t" })) }
            .min(by: { $0.count < $1.count }) ?? ""

        // Re-indent: first line stays as-is, subsequent lines get rebased
        var result = lines[0]
        for line in tailLines {
            result += "\n"
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result += line
            } else {
                let stripped = line.hasPrefix(baseIndent) ? String(line.dropFirst(baseIndent.count)) : line
                result += effectiveIndent + stripped
            }
        }

        let insertionStart = selectedRange().location
        insertText(result, replacementRange: selectedRange())

        // Offer SQL-list formatting AFTER the verbatim paste lands. Setting
        // the pending range after insertText keeps the paste's own
        // didChangeText/selection updates from invalidating the fresh offer.
        if offersSqlListChip, SQLListFormatter.looksLikeBareList(result) {
            pendingListPasteRange = NSRange(location: insertionStart, length: (result as NSString).length)
            onListPasteDetected?()
        }
    }

    // MARK: - Format as SQL List

    /// Rewrite the most recent qualifying paste as a quoted, comma-separated
    /// SQL list. One discrete edit: Cmd+Z restores the raw paste, a second
    /// Cmd+Z removes the paste.
    func applyPendingSQLize() {
        guard let range = pendingListPasteRange else { return }
        let text = self.string as NSString
        guard NSMaxRange(range) <= text.length else {
            invalidateListPasteOffer()
            return
        }
        let formatted = SQLListFormatter.sqlize(text.substring(with: range), quoteStyle: sqlListQuoteStyle)
        isApplyingSQLize = true
        if shouldChangeText(in: range, replacementString: formatted) {
            insertText(formatted, replacementRange: range)
        }
        isApplyingSQLize = false
        invalidateListPasteOffer()
    }

    /// Also called by the host when it replaces the text programmatically
    /// (setSQL bypasses didChangeText).
    func invalidateListPasteOffer() {
        guard pendingListPasteRange != nil else { return }
        pendingListPasteRange = nil
        onListPasteOfferInvalidated?()
    }

    /// Context-menu action: SQL-ize the selected lines. No detection gate —
    /// explicit user intent. The selection is widened to whole lines first.
    @objc func formatSelectionAsSQLList(_ sender: Any?) {
        let text = self.string as NSString
        var range = text.lineRange(for: selectedRange())
        // lineRange includes the final line's trailing newline; keep it out
        // of the transform so the line break after the list survives.
        while range.length > 0 {
            let last = text.character(at: range.location + range.length - 1)
            if last == 0x0A || last == 0x0D { range.length -= 1 } else { break }
        }
        guard range.length > 0 else { return }
        let formatted = SQLListFormatter.sqlize(text.substring(with: range), quoteStyle: sqlListQuoteStyle)
        if shouldChangeText(in: range, replacementString: formatted) {
            insertText(formatted, replacementRange: range)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let cursor = selectedRange().location
        let text = self.string as NSString

        // An empty `{{|}}` goes whole, as `(|)` does.
        if autoPairBrackets, selectedRange().length == 0,
           let pair = VariableCompletion.emptyPairRange(in: text, at: cursor) {
            super.insertText("", replacementRange: pair)
            return
        }

        // If deleting an open bracket and the next char is its matching close, delete both.
        // Only with a caret — with a selection, Backspace deletes the selection.
        if selectedRange().length == 0, cursor > 0, cursor < text.length,
           let prevScalar = UnicodeScalar(text.character(at: cursor - 1)),
           let nextScalar = UnicodeScalar(text.character(at: cursor)) {
            let prevChar = String(Character(prevScalar))
            if let closeChar = activeAutoClosePairs[prevChar] {
                let nextChar = String(Character(nextScalar))
                if nextChar == closeChar {
                    setSelectedRange(NSRange(location: cursor - 1, length: 2))
                    super.insertText("", replacementRange: selectedRange())
                    return
                }
            }
        }

        // Indent-level-aware backspace: if the cursor sits at an indent boundary
        // (only spaces to its left on the current line), delete one full indent level.
        // Only meaningful while Tab writes spaces — with real tabs, one
        // Backspace already removes one whole indent level.
        if insertSpacesForTab, cursor >= tabSize, selectedRange().length == 0 {
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            let offsetInLine = cursor - lineRange.location
            if offsetInLine >= tabSize, offsetInLine % tabSize == 0 {
                let leadingRange = NSRange(location: lineRange.location, length: offsetInLine)
                let leading = text.substring(with: leadingRange)
                if leading.allSatisfy({ $0 == " " }) {
                    setSelectedRange(NSRange(location: cursor - tabSize, length: tabSize))
                    super.insertText("", replacementRange: selectedRange())
                    return
                }
            }
        }

        super.deleteBackward(sender)
    }

    override func insertTab(_ sender: Any?) {
        let text = self.string as NSString
        let sel = selectedRange()

        // Check if selection spans multiple lines
        if sel.length > 0 {
            let selString = text.substring(with: sel)
            if selString.contains("\n") {
                // Multi-line indent: prepend tabSize spaces to each selected line
                let blockRange = text.lineRange(for: sel)
                let block = text.substring(with: blockRange)
                let indent = indentUnit
                let lines = block.components(separatedBy: "\n")

                // Don't indent trailing empty component from a trailing newline
                var indented: [String] = []
                for (i, line) in lines.enumerated() {
                    if i == lines.count - 1 && line.isEmpty {
                        indented.append(line)
                    } else {
                        indented.append(indent + line)
                    }
                }
                let result = indented.joined(separator: "\n")

                insertText(result, replacementRange: blockRange)

                // Re-select the indented block (adjust for added spaces)
                let nonEmptyCount = lines.count - (lines.last?.isEmpty == true ? 1 : 0)
                let newLength = blockRange.length + nonEmptyCount * (indent as NSString).length
                setSelectedRange(NSRange(location: blockRange.location, length: newLength))
                return
            }
        }

        // Single-line / no selection: insert one indent level
        super.insertText(indentUnit, replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) {
        let text = self.string as NSString
        let sel = selectedRange()
        let blockRange = text.lineRange(for: sel)
        let block = text.substring(with: blockRange)
        let lines = block.components(separatedBy: "\n")

        var dedented: [String] = []
        var totalRemoved = 0
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1 && line.isEmpty {
                dedented.append(line)
            } else {
                // One tab character IS one indent level; otherwise take back
                // up to one level's worth of spaces.
                let removeCount = line.hasPrefix("\t")
                    ? 1
                    : min(tabSize, line.prefix(while: { $0 == " " }).count)
                dedented.append(String(line.dropFirst(removeCount)))
                totalRemoved += removeCount
            }
        }
        let result = dedented.joined(separator: "\n")

        insertText(result, replacementRange: blockRange)

        // Re-select the dedented block
        let newLength = max(0, blockRange.length - totalRemoved)
        setSelectedRange(NSRange(location: blockRange.location, length: newLength))
    }

    override func insertNewline(_ sender: Any?) {
        guard autoIndentEnabled else {
            super.insertNewline(sender)
            return
        }
        // Auto-indent: match leading whitespace of current line
        let text = string as NSString
        let cursorLocation = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let currentLine = text.substring(with: lineRange)
        let indent = currentLine.prefix(while: { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(String(indent), replacementRange: selectedRange())
        }
    }

    // MARK: - Code Folding (Display-Layer)

    /// Fold a character range. Text storage is NOT modified — the FoldingLayoutManager
    /// hides the glyphs and draws a placeholder pill.
    /// Returns nil, folding nothing, while `codeFoldingEnabled` is off.
    @discardableResult
    func fold(range: NSRange, placeholder: String) -> FoldEntry? {
        guard codeFoldingEnabled else { return nil }
        let entry = foldState.add(range: range, placeholder: placeholder)
        invalidateFoldLayout()
        return entry
    }

    /// Unfold a specific fold by its UUID.
    func unfold(id: UUID) {
        guard let removed = foldState.remove(id: id) else { return }
        invalidateFoldLayout(revealing: [removed.range])
    }

    /// Unfold all folded regions.
    func unfoldAll() {
        guard !foldState.entries.isEmpty else { return }
        let removed = foldState.foldedCharacterRanges
        foldState.removeAll()
        invalidateFoldLayout(revealing: removed)
    }

    /// Invalidate layout for fold-affected ranges so the layout manager recomputes glyphs.
    /// Only invalidates the specific fold ranges instead of the entire document to avoid
    /// layout thrashing that causes visible text jumping.
    ///
    /// `revealing` carries the ranges of folds that were JUST removed. Their
    /// glyphs are still suppressed, and they are no longer in `foldState`, so
    /// the caller has to hand them over — with two or more folds active, the
    /// live ranges alone would leave the unfolded text hidden until a full
    /// relayout (a window resize) happened to come along.
    private func invalidateFoldLayout(revealing removed: [NSRange] = []) {
        guard let layoutManager else { return }
        let textLength = (string as NSString).length
        guard textLength > 0 else { return }

        // Invalidate each fold's range individually instead of the entire document.
        // This is what triggers FoldingLayoutManager.setGlyphs() to re-evaluate
        // which glyphs should be suppressed, but only for affected regions.
        for range in foldState.foldedCharacterRanges + removed {
            let location = min(range.location, textLength)
            let safeRange = NSRange(location: location, length: min(range.length, textLength - location))
            guard safeRange.length > 0 else { continue }
            layoutManager.invalidateGlyphs(forCharacterRange: safeRange, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: safeRange, actualCharacterRange: nil)
        }

        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onFoldStateChanged?()
    }

    // MARK: - Error Underlines

    /// Add a red underline to the given character range (for execution errors).
    /// Uses temporary attributes so it doesn't affect undo or stored text.
    func addErrorUnderline(range: NSRange) {
        guard let layoutManager else { return }
        layoutManager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.underlineColor, value: NSColor.systemRed, forCharacterRange: range)
    }

    /// Remove all error underlines from the text.
    func clearErrorUnderlines() {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
    }

    // MARK: - Drafted SQL

    /// The range holding the statement a model draft just put in, while it is
    /// still marked. Nil once the analyst has edited anything.
    private(set) var draftRange: NSRange?

    /// Observes the first edit after an insert, which is what takes the mark
    /// away. Removed as soon as it fires, so only ONE edit is ever watched.
    private var draftEditObserver: NSObjectProtocol?

    /// A wash of the accent colour — enough to say "this text is new and came
    /// from the model", not enough to be read as a selection or an error.
    private static var draftHighlightColor: NSColor {
        .controlAccentColor.withAlphaComponent(0.15)
    }

    /// Put a drafted statement in over the current selection, as ONE undoable
    /// edit named "Insert Draft", then select it and mark it.
    ///
    /// Returns the inserted range, or nil when there was nothing to insert or
    /// the text system refused the edit.
    ///
    /// Nothing runs. This is an edit like any other; ⌘Z takes it back out in
    /// a single step, which is why the grouping is explicit and why the
    /// coalescing is broken on both sides — without that, the analyst's next
    /// keystrokes would join the group and one undo would remove them too.
    @discardableResult
    func insertDraft(_ sql: String) -> NSRange? {
        guard !sql.isEmpty, isEditable else { return nil }
        let target = selectedRange()

        // `insertText` runs its own `shouldChangeText`/`didChangeText` pair and
        // registers the undo itself. Calling `shouldChangeText` here as well —
        // the shape `applyPendingSQLize` uses — leaves a registration with no
        // matching `didChangeText`, and the stack then raises
        // `NSRangeException` when it is unwound ("Range {0, 16} out of bounds;
        // string length 7", measured). Breaking the coalescing on both sides is
        // what makes this one undo step: without it the analyst's next
        // keystrokes join the group and one ⌘Z would take them out too.
        breakUndoCoalescing()
        insertText(sql, replacementRange: target)
        breakUndoCoalescing()
        // After, not before: `insertText` sets the name to "Typing" on its way
        // through, so a name set first is the one that loses.
        undoManager?.setActionName(String(localized: "Insert Draft"))

        let inserted = NSRange(location: target.location, length: (sql as NSString).length)
        setSelectedRange(inserted)
        markDraft(inserted)
        return inserted
    }

    /// Mark `range` and arrange for the next edit anywhere to clear it.
    ///
    /// Registered AFTER the insert, so the insert's own change notification
    /// cannot be the edit that clears the mark it has just made.
    private func markDraft(_ range: NSRange) {
        removeDraftObserver()
        draftRange = range
        applyDraftHighlight()

        draftEditObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearDraftHighlight() }
        }
    }

    /// Take the mark away. Safe to call when there is none.
    func clearDraftHighlight() {
        removeDraftObserver()
        guard let range = draftRange, let layoutManager else {
            draftRange = nil
            return
        }
        draftRange = nil
        if let safe = clamped(range) {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe)
        }
    }

    /// (Re-)paint the mark.
    ///
    /// `updateBracketHighlight` clears `.backgroundColor` across the whole
    /// document on every caret move, so the mark has to be laid on again
    /// after it — otherwise it would vanish on the first arrow key rather
    /// than on the first edit.
    private func applyDraftHighlight() {
        guard let layoutManager, let range = draftRange, let safe = clamped(range) else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor, value: Self.draftHighlightColor, forCharacterRange: safe)
    }

    /// `range` trimmed to the document, or nil when it no longer fits at all.
    private func clamped(_ range: NSRange) -> NSRange? {
        let length = (string as NSString).length
        guard range.location < length else { return nil }
        let clamped = NSRange(
            location: range.location, length: min(range.length, length - range.location))
        return clamped.length > 0 ? clamped : nil
    }

    private func removeDraftObserver() {
        if let draftEditObserver {
            NotificationCenter.default.removeObserver(draftEditObserver)
        }
        draftEditObserver = nil
    }

    // MARK: - Syntax Highlighting

    /// Schedule a debounced full-document highlight pass. Cancels any
    /// pending pass so rapid typing only triggers one repaint after the
    /// user pauses.
    private func scheduleDebouncedHighlight() {
        highlightDebounceTask?.cancel()
        highlightDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms
            guard !Task.isCancelled, let self else { return }
            self.highlightSyntax()
        }
    }

    func highlightSyntax() {
        guard let layoutManager else { return }

        let text = string
        guard !text.isEmpty else { return }

        // Bump generation; any in-flight off-main pass will discard its result
        // when it returns. Snapshot the theme so we don't read it off-main.
        highlightGeneration &+= 1
        let generation = highlightGeneration
        let themeSnapshot = theme
        let variableNamesSnapshot = variableNames

        Task.detached(priority: .userInitiated) { [weak self] in
            // ---- Off-main computation ----
            let attrs = SQLSyntaxHighlighter.spans(
                for: text,
                theme: themeSnapshot,
                variableNames: variableNamesSnapshot
            )

            // ---- On-main application ----
            // Its OWN `[weak self]`: without one this closure reads the weak
            // `self` variable captured by the enclosing detached task, which is
            // a reference to a captured var from concurrently-executing code.
            await MainActor.run { [weak self] in
                guard let self, generation == self.highlightGeneration else { return }
                self.applyHighlightAttributes(attrs, layoutManager: layoutManager)
            }
        }
    }

    /// Apply a batch of pre-computed highlight attributes. Wrapped in a
    /// CATransaction with implicit animations disabled so the layout manager
    /// doesn't animate temporary-attribute changes during the bulk update.
    private func applyHighlightAttributes(_ attrs: [SQLSyntaxHighlighter.Span], layoutManager: NSLayoutManager) {
        // Clamp every span to the live text. The generation check catches a
        // pass that started before an edit; this catches anything else that
        // could hand a range past the end to the layout manager, which raises
        // NSRangeException rather than ignoring it.
        let length = (string as NSString).length
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for attr in attrs {
            guard attr.range.location < length else { continue }
            let range = NSRange(location: attr.range.location,
                                length: min(attr.range.length, length - attr.range.location))
            guard range.length > 0 else { continue }
            if let color = attr.color {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
            } else {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
        }
        CATransaction.commit()
    }

    // MARK: - Bracket Matching

    private static let openBrackets = Set<Character>(["(", "[", "{"])
    private static let closeBrackets = Set<Character>([")", "]", "}"])
    private static let matchingBracket: [Character: Character] = [
        "(": ")", ")": "(",
        "[": "]", "]": "[",
        "{": "}", "}": "{",
    ]

    private func updateBracketHighlight() {
        guard let layoutManager else { return }
        let text = string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Clear previous bracket highlights
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        // …which also wipes a drafted statement's mark, since both are drawn
        // with the same temporary attribute. Lay it on again: the mark
        // belongs to the text, not to where the caret happens to be.
        applyDraftHighlight()

        let cursor = selectedRange().location
        guard cursor > 0, cursor <= nsText.length else { return }

        // Check the character before the cursor
        let charIndex = cursor - 1
        guard let scalar = UnicodeScalar(nsText.character(at: charIndex)) else { return }
        let char = Character(scalar)

        guard Self.openBrackets.contains(char) || Self.closeBrackets.contains(char) else { return }

        // Skip if inside a string or comment
        if isInsideStringOrComment(at: charIndex, layoutManager: layoutManager) { return }

        let isOpen = Self.openBrackets.contains(char)
        guard let target = Self.matchingBracket[char] else { return }

        // Scan for the matching bracket
        if let matchIndex = findMatchingBracket(
            from: charIndex, char: char, target: target, isOpen: isOpen,
            text: nsText, layoutManager: layoutManager
        ) {
            let highlightColor = NSColor.systemYellow.withAlphaComponent(0.25)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: highlightColor,
                forCharacterRange: NSRange(location: charIndex, length: 1))
            layoutManager.addTemporaryAttribute(.backgroundColor, value: highlightColor,
                forCharacterRange: NSRange(location: matchIndex, length: 1))
        }
    }

    private func findMatchingBracket(
        from index: Int, char: Character, target: Character, isOpen: Bool,
        text: NSString, layoutManager: NSLayoutManager
    ) -> Int? {
        var depth = 1
        let length = text.length

        if isOpen {
            // Scan forward
            var i = index + 1
            while i < length {
                guard let s = UnicodeScalar(text.character(at: i)) else { i += 1; continue }
                let c = Character(s)
                if !isInsideStringOrComment(at: i, layoutManager: layoutManager) {
                    if c == char { depth += 1 }
                    else if c == target { depth -= 1; if depth == 0 { return i } }
                }
                i += 1
            }
        } else {
            // Scan backward
            var i = index - 1
            while i >= 0 {
                guard let s = UnicodeScalar(text.character(at: i)) else { i -= 1; continue }
                let c = Character(s)
                if !isInsideStringOrComment(at: i, layoutManager: layoutManager) {
                    if c == char { depth += 1 }
                    else if c == target { depth -= 1; if depth == 0 { return i } }
                }
                i -= 1
            }
        }
        return nil
    }

    private func isInsideStringOrComment(at index: Int, layoutManager: NSLayoutManager) -> Bool {
        guard let color = layoutManager.temporaryAttribute(
            .foregroundColor, atCharacterIndex: index, effectiveRange: nil
        ) as? NSColor else { return false }
        return color == theme.comment || color == theme.string
    }

    // MARK: - Current Line Highlight

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        updateBracketHighlight()
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // `textContainer` is checked, not bound: the body below uses
        // `textContainerInset` and `textContainerOrigin`, which are different
        // symbols on the text view itself.
        guard highlightCurrentLine, let layoutManager, textContainer != nil else { return }

        // Highlight current line
        let cursorRange = selectedRange()
        if cursorRange.length == 0 {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: cursorRange, actualCharacterRange: nil)
            let glyphCount = layoutManager.numberOfGlyphs
            var lineRect: NSRect
            if glyphRange.location < glyphCount {
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            } else if !layoutManager.extraLineFragmentRect.isEmpty {
                // Caret on the trailing line: an empty document, or text that
                // ends in a newline. There is no glyph to ask about — asking
                // logged "invalid glyph index" on every empty editor.
                lineRect = layoutManager.extraLineFragmentRect
            } else if glyphCount > 0 {
                // Caret after the last character of a document with no final
                // newline: that character's line is the current line.
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
            } else {
                return
            }
            lineRect.origin.x = 0
            lineRect.size.width = bounds.width
            lineRect.origin.y += textContainerInset.height
            lineRect.origin.x += textContainerOrigin.x

            // The wash must stay barely there: the caret line still carries
            // syntax colors, and a band any darker drops the contrast of the
            // string green below what a user can read. `withAlphaComponent`
            // REPLACES a color's alpha, it does not scale it, so
            // `quaternaryLabelColor.withAlphaComponent(0.35)` was opaque black
            // at 0.35 — a mid-gray band — not 0.35 of a faint gray. Set the
            // alpha on `labelColor`, whose own alpha is 1, so the number here
            // is the alpha that reaches the screen. The rect comes from the
            // LAYOUT MANAGER, never from the font metrics, so a collapsed fold
            // above the caret cannot put the band on the wrong line.
            let highlightColor = NSColor.labelColor.withAlphaComponent(0.04)
            highlightColor.setFill()
            lineRect.fill()
        }
    }
}
