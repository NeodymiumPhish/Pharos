import AppKit

// MARK: - SQL Syntax Highlighting Colors

struct SQLTheme {
    let keyword: NSColor
    let function: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let type: NSColor

    static let `default` = SQLTheme(
        keyword: .systemBlue,
        function: .systemTeal,
        string: .systemGreen,
        number: .systemOrange,
        comment: .systemGray,
        type: .systemPurple
    )
}

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
    /// refresh is deferred ~100 ms after typing stops to keep input snappy.
    private var highlightDebounceTask: Task<Void, Never>?

    // Cached regex objects (compiled once, reused per highlight call)
    private static let numberRegex = try! NSRegularExpression(pattern: "(?<![\\w.])\\d+\\.?\\d*(?![\\w.])")
    private static let keywordRegex: NSRegularExpression = {
        let keywords = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE",
            "BETWEEN", "IS", "NULL", "TRUE", "FALSE",
            "ORDER", "BY", "ASC", "DESC", "NULLS", "FIRST", "LAST",
            "GROUP", "HAVING", "LIMIT", "OFFSET",
            "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON",
            "UNION", "ALL", "INTERSECT", "EXCEPT",
            "INSERT", "INTO", "VALUES", "DEFAULT",
            "UPDATE", "SET",
            "DELETE",
            "CREATE", "TABLE", "INDEX", "VIEW", "SCHEMA", "DATABASE",
            "ALTER", "ADD", "DROP", "COLUMN", "CONSTRAINT",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK",
            "CASCADE", "RESTRICT",
            "AS", "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END",
            "COALESCE", "NULLIF", "CAST",
            "EXISTS", "ANY", "SOME",
            "WITH", "RECURSIVE",
            "RETURNING", "IF", "REPLACE", "TEMP", "TEMPORARY",
            "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
            "EXPLAIN", "ANALYZE", "VERBOSE", "COSTS", "BUFFERS", "FORMAT",
            "GRANT", "REVOKE", "TRUNCATE",
            "OVER", "PARTITION", "WINDOW", "ROWS", "RANGE",
            "LATERAL", "FETCH", "NEXT", "ONLY", "FOR",
        ]
        return try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
    }()
    private static let functionRegex: NSRegularExpression = {
        let builtins = [
            "count", "sum", "avg", "min", "max", "array_agg", "string_agg", "bool_and", "bool_or",
            "length", "lower", "upper", "trim", "ltrim", "rtrim", "substring", "concat", "replace",
            "split_part", "regexp_replace", "regexp_matches", "position", "strpos",
            "now", "current_date", "current_time", "current_timestamp", "date_trunc", "extract",
            "age", "date_part", "to_char", "to_date", "to_timestamp",
            "abs", "ceil", "floor", "round", "trunc", "mod", "power", "sqrt", "random",
            "json_build_object", "json_agg", "jsonb_build_object", "jsonb_agg",
            "json_extract_path", "jsonb_extract_path", "json_array_elements", "jsonb_array_elements",
            "array_length", "unnest", "array_append", "array_prepend", "array_cat",
            "greatest", "least", "generate_series",
            "row_number", "rank", "dense_rank", "ntile", "lag", "lead", "first_value", "last_value",
        ]
        return try! NSRegularExpression(pattern: "\\b(" + builtins.joined(separator: "|") + ")\\s*(?=\\()", options: [.caseInsensitive])
    }()
    private static let typeRegex: NSRegularExpression = {
        let types = [
            "INTEGER", "INT", "BIGINT", "SMALLINT", "SERIAL", "BIGSERIAL",
            "TEXT", "VARCHAR", "CHAR", "CHARACTER", "VARYING",
            "BOOLEAN", "BOOL",
            "TIMESTAMP", "TIMESTAMPTZ", "DATE", "TIME", "TIMETZ", "INTERVAL",
            "NUMERIC", "DECIMAL", "REAL", "DOUBLE", "PRECISION", "FLOAT",
            "UUID", "JSON", "JSONB", "BYTEA", "INET", "CIDR", "MACADDR",
            "ARRAY", "RECORD", "VOID", "OID", "REGCLASS",
        ]
        return try! NSRegularExpression(pattern: "\\b(" + types.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
    }()

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
        usesFindBar = true

        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = .labelColor
        backgroundColor = .textBackgroundColor
        insertionPointColor = .labelColor

        textContainerInset = NSSize(width: 4, height: 8)

        // Use temporary attributes for highlighting (doesn't interfere with undo)
        layoutManager?.allowsNonContiguousLayout = true
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
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
            foldState.adjustForEdit(editedRange: editRange, changeInLength: changeInLength)
            if hadFolds {
                invalidateFoldLayout()
            }
        }
        pendingEditRange = nil
        pendingReplacementLength = nil

        scheduleDebouncedHighlight()
        onTextChange?(string)

        // Any edit invalidates a pending list-paste offer (except the
        // SQL-ize application itself).
        if !isApplyingSQLize {
            invalidateListPasteOffer()
        }

        // Completion triggers after text change
        if completionDelegate?.isCompletionShown == true {
            completionDelegate?.updateCompletion()
        } else {
            // Auto-trigger on dot
            let cursor = selectedRange().location
            if cursor > 0 {
                let ch = (string as NSString).character(at: cursor - 1)
                if ch == UInt16(UnicodeScalar(".").value) {
                    completionDelegate?.triggerCompletion()
                }
            }
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

        // Escape → dismiss completion if shown, else a pending list-paste offer
        if event.keyCode == 53 {
            if completionDelegate?.isCompletionShown == true {
                completionDelegate?.dismissCompletion()
                return
            }
            if hasListPasteOffer {
                invalidateListPasteOffer()
                return
            }
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

    private static let autoClosePairs: [String: String] = ["(": ")", "[": "]", "'": "'"]
    private static let closeChars: Set<String> = [")", "]", "'"]

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

        // Skip-over: typing a closing char that's already the next character
        if Self.closeChars.contains(str), cursor < text.length {
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
        if let closeChar = Self.autoClosePairs[str] {
            // For quotes, don't auto-close if previous char is alphanumeric (e.g., it's an apostrophe)
            if str == "'" && cursor > 0 {
                let prevScalar = UnicodeScalar(text.character(at: cursor - 1))
                if let s = prevScalar, CharacterSet.alphanumerics.contains(s) {
                    super.insertText(string, replacementRange: replacementRange)
                    return
                }
            }
            // Don't auto-close when text sits immediately to the right of the
            // insertion point. With a non-empty selection the typed character
            // replaces it, so the relevant character is the one after the
            // selection end.
            let sel = selectedRange()
            if !Self.allowsAutoClose(after: sel.location + sel.length, in: text) {
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
        if SQLListFormatter.looksLikeBareList(result) {
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
        let formatted = SQLListFormatter.sqlize(text.substring(with: range))
        isApplyingSQLize = true
        if shouldChangeText(in: range, replacementString: formatted) {
            insertText(formatted, replacementRange: range)
        }
        isApplyingSQLize = false
        invalidateListPasteOffer()
    }

    private func invalidateListPasteOffer() {
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
        let formatted = SQLListFormatter.sqlize(text.substring(with: range))
        if shouldChangeText(in: range, replacementString: formatted) {
            insertText(formatted, replacementRange: range)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let cursor = selectedRange().location
        let text = self.string as NSString

        // If deleting an open bracket and the next char is its matching close, delete both
        if cursor > 0, cursor < text.length,
           let prevScalar = UnicodeScalar(text.character(at: cursor - 1)),
           let nextScalar = UnicodeScalar(text.character(at: cursor)) {
            let prevChar = String(Character(prevScalar))
            if let closeChar = Self.autoClosePairs[prevChar] {
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
        if cursor >= tabSize, selectedRange().length == 0 {
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
                let indent = String(repeating: " ", count: tabSize)
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
                let newLength = blockRange.length + nonEmptyCount * tabSize
                setSelectedRange(NSRange(location: blockRange.location, length: newLength))
                return
            }
        }

        // Single-line / no selection: insert spaces
        let spaces = String(repeating: " ", count: tabSize)
        super.insertText(spaces, replacementRange: sel)
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
                let leading = line.prefix(while: { $0 == " " })
                let removeCount = min(tabSize, leading.count)
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
    @discardableResult
    func fold(range: NSRange, placeholder: String) -> FoldEntry {
        let entry = foldState.add(range: range, placeholder: placeholder)
        invalidateFoldLayout()
        return entry
    }

    /// Unfold a specific fold by its UUID.
    func unfold(id: UUID) {
        guard foldState.remove(id: id) != nil else { return }
        invalidateFoldLayout()
    }

    /// Unfold all folded regions.
    func unfoldAll() {
        guard !foldState.entries.isEmpty else { return }
        foldState.removeAll()
        invalidateFoldLayout()
    }

    /// Invalidate layout for fold-affected ranges so the layout manager recomputes glyphs.
    /// Only invalidates the specific fold ranges instead of the entire document to avoid
    /// layout thrashing that causes visible text jumping.
    private func invalidateFoldLayout() {
        guard let layoutManager else { return }
        let textLength = (string as NSString).length
        guard textLength > 0 else { return }

        // Invalidate each fold's range individually instead of the entire document.
        // This is what triggers FoldingLayoutManager.setGlyphs() to re-evaluate
        // which glyphs should be suppressed, but only for affected regions.
        let foldRanges = foldState.foldedCharacterRanges
        if foldRanges.isEmpty {
            // No folds remain — still need one invalidation pass so previously
            // suppressed glyphs become visible again. Use a targeted range
            // covering from the first fold start to the end of the document
            // (we don't know exact old ranges, but the layout manager will
            // quickly no-op for non-folded regions in setGlyphs).
            let fullRange = NSRange(location: 0, length: textLength)
            layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        } else {
            for range in foldRanges {
                let safeRange = NSRange(location: range.location, length: min(range.length, textLength - range.location))
                guard safeRange.length > 0 else { continue }
                layoutManager.invalidateGlyphs(forCharacterRange: safeRange, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: safeRange, actualCharacterRange: nil)
            }
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

    // MARK: - Syntax Highlighting

    /// Schedule a debounced full-document highlight pass. Cancels any
    /// pending pass so rapid typing only triggers one repaint after the
    /// user pauses.
    private func scheduleDebouncedHighlight() {
        highlightDebounceTask?.cancel()
        highlightDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)  // 750 ms
            guard !Task.isCancelled, let self else { return }
            self.highlightSyntax()
        }
    }

    /// One attribute the highlighter wants applied. `color == nil` means
    /// remove the foreground attribute over `range` (used to clear stale
    /// highlighting on normal code or quoted identifiers).
    private struct HighlightAttribute {
        let range: NSRange
        let color: NSColor?
    }

    func highlightSyntax() {
        guard let layoutManager else { return }

        let text = string
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard nsText.length > 0 else { return }

        // Bump generation; any in-flight off-main pass will discard its result
        // when it returns. Snapshot the theme so we don't read it off-main.
        highlightGeneration &+= 1
        let generation = highlightGeneration
        let themeSnapshot = theme

        Task.detached(priority: .userInitiated) { [weak self] in
            // ---- Off-main computation ----
            let chars = Array(text.utf16)
            let length = chars.count
            let stateMap = SQLLexer.buildStateMap(chars: chars, length: length)

            var attrs: [HighlightAttribute] = []
            attrs.reserveCapacity(64)

            // Phase 1: state-machine spans (comments, strings, normal/quoted clears).
            var rangeStart = 0
            var currentState: SQLLexState = stateMap[0]
            for i in 1...length {
                let nextState: SQLLexState = (i < length) ? stateMap[i] : .normal
                if nextState != currentState || i == length {
                    let range = NSRange(location: rangeStart, length: i - rangeStart)
                    if currentState.isNormal || currentState == .doubleQuote {
                        attrs.append(.init(range: range, color: nil))
                    } else {
                        let color: NSColor
                        switch currentState {
                        case .lineComment, .blockComment: color = themeSnapshot.comment
                        case .singleQuote, .dollarQuote: color = themeSnapshot.string
                        default: color = themeSnapshot.comment
                        }
                        attrs.append(.init(range: range, color: color))
                    }
                    rangeStart = i
                    currentState = nextState
                }
            }

            // Phase 2: regex passes (keyword/function/type/number) — only on
            // ranges currently in `.normal` state.
            let regexPasses: [(NSRegularExpression, NSColor)] = [
                (Self.keywordRegex, themeSnapshot.keyword),
                (Self.functionRegex, themeSnapshot.function),
                (Self.typeRegex, themeSnapshot.type),
                (Self.numberRegex, themeSnapshot.number),
            ]
            for (regex, color) in regexPasses {
                regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                    guard let range = match?.range else { return }
                    if range.location < stateMap.count && stateMap[range.location].isNormal {
                        attrs.append(.init(range: range, color: color))
                    }
                }
            }

            // ---- On-main application ----
            await MainActor.run {
                guard let self, generation == self.highlightGeneration else { return }
                self.applyHighlightAttributes(attrs, layoutManager: layoutManager)
            }
        }
    }

    /// Apply a batch of pre-computed highlight attributes. Wrapped in a
    /// CATransaction with implicit animations disabled so the layout manager
    /// doesn't animate temporary-attribute changes during the bulk update.
    private func applyHighlightAttributes(_ attrs: [HighlightAttribute], layoutManager: NSLayoutManager) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for attr in attrs {
            if let color = attr.color {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: attr.range)
            } else {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: attr.range)
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
        guard let layoutManager, let textContainer else { return }

        // Highlight current line
        let cursorRange = selectedRange()
        if cursorRange.length == 0 {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: cursorRange, actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            lineRect.origin.x = 0
            lineRect.size.width = bounds.width
            lineRect.origin.y += textContainerInset.height
            lineRect.origin.x += textContainerOrigin.x

            let highlightColor = NSColor.labelColor.withAlphaComponent(0.04)
            highlightColor.setFill()
            lineRect.fill()
        }
    }
}
