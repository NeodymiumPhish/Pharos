import AppKit

// MARK: - SQL Syntax Highlighting Colors

struct SQLTheme {
    let keyword: NSColor
    let function: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let type: NSColor
    let identifier: NSColor

    static let `default` = SQLTheme(
        keyword: .systemBlue,
        function: .systemTeal,
        string: .systemGreen,
        number: .systemOrange,
        comment: .systemGray,
        type: .systemPurple,
        identifier: .labelColor
    )
}

// MARK: - SQLTextView

/// NSTextView subclass with SQL syntax highlighting via regex patterns.
class SQLTextView: NSTextView {

    var theme = SQLTheme.default {
        didSet { highlightSyntax() }
    }

    /// Called whenever the text changes (after highlighting).
    var onTextChange: ((String) -> Void)?

    private var isHighlighting = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// Convenience initializer — creates the full text system (storage → layout → container → view).
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
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
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // MARK: - Text Changes

    override func didChangeText() {
        super.didChangeText()
        highlightSyntax()
        onTextChange?(string)
    }

    // MARK: - Key Handling

    override func insertTab(_ sender: Any?) {
        // Insert spaces instead of tab
        let spaces = String(repeating: " ", count: 2)
        insertText(spaces, replacementRange: selectedRange())
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

    // MARK: - Syntax Highlighting

    func highlightSyntax() {
        guard !isHighlighting, let layoutManager, let textStorage else { return }
        isHighlighting = true
        defer { isHighlighting = false }

        let text = string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // Reset all temporary attributes
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

        guard !text.isEmpty else { return }

        // Apply highlighting via temporary attributes (doesn't affect undo stack)
        highlightComments(text, layoutManager: layoutManager)
        highlightStrings(text, layoutManager: layoutManager)
        highlightKeywords(text, layoutManager: layoutManager)
        highlightFunctions(text, layoutManager: layoutManager)
        highlightTypes(text, layoutManager: layoutManager)
        highlightNumbers(text, layoutManager: layoutManager)
    }

    // MARK: - Pattern Matching

    private func highlightComments(_ text: String, layoutManager: NSLayoutManager) {
        // Single-line comments: -- to end of line
        applyPattern("--[^\n]*", color: theme.comment, in: text, layoutManager: layoutManager)
        // Block comments: /* ... */
        applyPattern("/\\*[\\s\\S]*?\\*/", color: theme.comment, in: text, layoutManager: layoutManager)
    }

    private func highlightStrings(_ text: String, layoutManager: NSLayoutManager) {
        // Single-quoted strings (with escaped quotes)
        applyPattern("'(?:[^'\\\\]|\\\\.)*'", color: theme.string, in: text, layoutManager: layoutManager)
        // Dollar-quoted strings: $$...$$
        applyPattern("\\$\\$[\\s\\S]*?\\$\\$", color: theme.string, in: text, layoutManager: layoutManager)
    }

    private func highlightKeywords(_ text: String, layoutManager: NSLayoutManager) {
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
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        applyPattern(pattern, color: theme.keyword, in: text, layoutManager: layoutManager, options: [.caseInsensitive])
    }

    private func highlightFunctions(_ text: String, layoutManager: NSLayoutManager) {
        // Match word followed by ( — common SQL function call pattern
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
        let pattern = "\\b(" + builtins.joined(separator: "|") + ")\\s*(?=\\()"
        applyPattern(pattern, color: theme.function, in: text, layoutManager: layoutManager, options: [.caseInsensitive])
    }

    private func highlightTypes(_ text: String, layoutManager: NSLayoutManager) {
        let types = [
            "INTEGER", "INT", "BIGINT", "SMALLINT", "SERIAL", "BIGSERIAL",
            "TEXT", "VARCHAR", "CHAR", "CHARACTER", "VARYING",
            "BOOLEAN", "BOOL",
            "TIMESTAMP", "TIMESTAMPTZ", "DATE", "TIME", "TIMETZ", "INTERVAL",
            "NUMERIC", "DECIMAL", "REAL", "DOUBLE", "PRECISION", "FLOAT",
            "UUID", "JSON", "JSONB", "BYTEA", "INET", "CIDR", "MACADDR",
            "ARRAY", "RECORD", "VOID", "OID", "REGCLASS",
        ]
        let pattern = "\\b(" + types.joined(separator: "|") + ")\\b"
        applyPattern(pattern, color: theme.type, in: text, layoutManager: layoutManager, options: [.caseInsensitive])
    }

    private func highlightNumbers(_ text: String, layoutManager: NSLayoutManager) {
        // Integers and decimals, but not part of identifiers
        applyPattern("(?<![\\w.])\\d+\\.?\\d*(?![\\w.])", color: theme.number, in: text, layoutManager: layoutManager)
    }

    private func applyPattern(
        _ pattern: String,
        color: NSColor,
        in text: String,
        layoutManager: NSLayoutManager,
        options: NSRegularExpression.Options = []
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            // Don't overwrite comments or strings (they're applied first and take priority)
            if let existing = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor {
                if existing == theme.comment || existing == theme.string {
                    return
                }
            }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        }
    }

    // MARK: - Current Line Highlight

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
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
