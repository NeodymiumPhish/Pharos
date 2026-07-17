import AppKit

// MARK: - SQL Syntax Highlighting Colors

struct SQLTheme {
    let keyword: NSColor
    let function: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let type: NSColor
    let variable: NSColor           // defined {{name}}
    let variableUnresolved: NSColor // {{name}} with no definition

    static let `default` = SQLTheme(
        keyword: .systemBlue,
        function: .systemTeal,
        string: .systemGreen,
        number: .systemOrange,
        comment: .systemGray,
        type: .systemPurple,
        variable: .systemIndigo,
        variableUnresolved: .systemRed
    )
}

// MARK: - SQLSyntaxHighlighter

/// View-independent SQL colorizer. The single source of truth for which token
/// maps to which color, built on the shared `SQLLexer` state map. Used both by
/// `SQLTextView` (which applies the spans as layout-manager temporary
/// attributes) and by static read-only displays such as the Inspector's query
/// preview (which bakes the spans into an `NSAttributedString`).
enum SQLSyntaxHighlighter {

    /// One highlight span. `color == nil` means "no color" — for the editor's
    /// incremental temporary-attribute model this clears any stale foreground
    /// over `range`; for a freshly built attributed string it is simply ignored
    /// (the base color already applies).
    struct Span {
        let range: NSRange
        let color: NSColor?
    }

    // Cached regex objects (compiled once, reused per highlight call)
    static let numberRegex = try! NSRegularExpression(pattern: "(?<![\\w.])\\d+\\.?\\d*(?![\\w.])")
    static let variableTokenRegex = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#
    )
    static let keywordRegex: NSRegularExpression = {
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
    static let functionRegex: NSRegularExpression = {
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
    static let typeRegex: NSRegularExpression = {
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

    /// Compute highlight spans for `text`. Pure and view-free, so it is safe to
    /// call off the main actor. Mirrors the editor's three-phase model:
    /// state-machine spans (comments/strings), regex passes on normal code, and
    /// `{{name}}` variable tokens (appended last so they win overlaps).
    static func spans(for text: String, theme: SQLTheme = .default, variableNames: Set<String> = []) -> [Span] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard nsText.length > 0 else { return [] }

        let chars = Array(text.utf16)
        let length = chars.count
        let stateMap = SQLLexer.buildStateMap(chars: chars, length: length)

        var attrs: [Span] = []
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
                    case .lineComment, .blockComment: color = theme.comment
                    case .singleQuote, .dollarQuote: color = theme.string
                    default: color = theme.comment
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
            (keywordRegex, theme.keyword),
            (functionRegex, theme.function),
            (typeRegex, theme.type),
            (numberRegex, theme.number),
        ]
        for (regex, color) in regexPasses {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                if range.location < stateMap.count && stateMap[range.location].isNormal {
                    attrs.append(.init(range: range, color: color))
                }
            }
        }

        // Phase 3: variable tokens `{{name}}`. Appended last so they win over
        // keyword/number coloring on overlap. Colored regardless of lex state
        // (variables are commonly written inside quotes, e.g. '{{ip}}').
        variableTokenRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            let name = nsText.substring(with: match.range(at: 1))
            let color = variableNames.contains(name)
                ? theme.variable
                : theme.variableUnresolved
            attrs.append(.init(range: match.range, color: color))
        }

        return attrs
    }

    /// Build an attributed string with editor-style SQL coloring baked in.
    /// Used for read-only displays (e.g. the Inspector query preview). Text
    /// starts in `baseColor` with `font`; colored spans are layered on top.
    static func attributedString(
        for text: String,
        font: NSFont,
        baseColor: NSColor,
        theme: SQLTheme = .default,
        variableNames: Set<String> = []
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: paragraph,
            ]
        )
        for span in spans(for: text, theme: theme, variableNames: variableNames) {
            if let color = span.color {
                result.addAttribute(.foregroundColor, value: color, range: span.range)
            }
        }
        return result
    }
}
