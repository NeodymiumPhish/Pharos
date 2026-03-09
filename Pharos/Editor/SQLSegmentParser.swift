import Foundation

/// Represents a single SQL statement parsed from the editor text.
struct SQLSegment {
    /// 0-based ordinal index among all segments in the editor.
    let index: Int
    /// The trimmed SQL text of this segment (without trailing semicolon).
    let sql: String
    /// Character range in the full editor text (includes leading/trailing whitespace and semicolon).
    let range: NSRange
    /// 1-based starting line number.
    let startLine: Int
    /// 1-based ending line number (inclusive).
    let endLine: Int
}

/// Parses SQL editor text into individual statement segments, respecting
/// string literals, comments, and dollar-quoted strings.
struct SQLSegmentParser {

    // MARK: - Parse State

    private enum State {
        case normal
        case singleQuote        // Inside '...'
        case dollarQuote(String) // Inside $tag$...$tag$
        case lineComment        // Inside -- ...\n
        case blockComment       // Inside /* ... */
    }

    /// Parse editor text into segments split on semicolons.
    ///
    /// Rules:
    /// - Semicolons inside single-quoted strings, dollar-quoted strings,
    ///   line comments, and block comments are ignored.
    /// - Empty segments (whitespace-only between semicolons) are skipped.
    /// - The last segment may lack a trailing semicolon.
    static func parse(_ text: String) -> [SQLSegment] {
        guard !text.isEmpty else { return [] }

        let chars = Array(text.utf16)
        let length = chars.count
        var state: State = .normal
        var segments: [SQLSegment] = []
        var segmentStart = 0  // UTF-16 offset of current segment start
        var i = 0
        var blockCommentDepth = 0

        while i < length {
            let ch = chars[i]

            switch state {
            case .normal:
                if ch == unichar(";") {
                    // End of statement — emit segment
                    let segRange = NSRange(location: segmentStart, length: i - segmentStart + 1)
                    emitSegment(text: text, range: segRange, index: segments.count, into: &segments)
                    segmentStart = i + 1

                } else if ch == unichar("'") {
                    state = .singleQuote

                } else if ch == unichar("-"), i + 1 < length, chars[i + 1] == unichar("-") {
                    state = .lineComment
                    i += 1 // skip second '-'

                } else if ch == unichar("/"), i + 1 < length, chars[i + 1] == unichar("*") {
                    state = .blockComment
                    blockCommentDepth = 1
                    i += 1 // skip '*'

                } else if ch == unichar("$") {
                    // Potential dollar-quote: scan for closing '$'
                    if let tag = scanDollarTag(chars: chars, from: i, length: length) {
                        state = .dollarQuote(tag)
                        i += tag.utf16.count - 1 // advance past the full $tag$ (minus 1 because loop increments)
                    }
                }

            case .singleQuote:
                if ch == unichar("'") {
                    // Check for escaped quote ''
                    if i + 1 < length, chars[i + 1] == unichar("'") {
                        i += 1 // skip the second quote
                    } else {
                        state = .normal
                    }
                }

            case .dollarQuote(let tag):
                if ch == unichar("$") {
                    // Check if we see the closing $tag$
                    let tagUTF16 = Array(tag.utf16)
                    if matchesAt(chars: chars, offset: i, pattern: tagUTF16, length: length) {
                        state = .normal
                        i += tagUTF16.count - 1
                    }
                }

            case .lineComment:
                if ch == unichar("\n") {
                    state = .normal
                }

            case .blockComment:
                if ch == unichar("/"), i + 1 < length, chars[i + 1] == unichar("*") {
                    blockCommentDepth += 1
                    i += 1
                } else if ch == unichar("*"), i + 1 < length, chars[i + 1] == unichar("/") {
                    blockCommentDepth -= 1
                    i += 1
                    if blockCommentDepth <= 0 {
                        state = .normal
                        blockCommentDepth = 0
                    }
                }
            }

            i += 1
        }

        // Handle trailing segment (no semicolon at end)
        if segmentStart < length {
            let segRange = NSRange(location: segmentStart, length: length - segmentStart)
            emitSegment(text: text, range: segRange, index: segments.count, into: &segments)
        }

        return segments
    }

    /// Find which segment the cursor is in (by character offset, 0-based).
    /// Returns nil if the cursor is outside all segments.
    static func segmentIndex(forCursorAt offset: Int, in segments: [SQLSegment]) -> Int? {
        for segment in segments {
            if offset >= segment.range.location &&
                offset <= segment.range.location + segment.range.length {
                return segment.index
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Emit a segment if it contains non-whitespace SQL.
    private static func emitSegment(
        text: String,
        range: NSRange,
        index: Int,
        into segments: inout [SQLSegment]
    ) {
        let nsText = text as NSString
        let raw = nsText.substring(with: range)

        // Strip the trailing semicolon for the SQL content
        var sql = raw
        if sql.hasSuffix(";") {
            sql = String(sql.dropLast())
        }
        sql = sql.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip empty segments
        guard !sql.isEmpty else { return }

        // Compute line numbers by counting newlines directly (avoids allocating substring arrays)
        var rawStartLine = 1
        for j in 0..<range.location {
            if nsText.character(at: j) == 0x0A { rawStartLine += 1 }
        }
        let segmentText = nsText.substring(with: range)
        let lines = segmentText.components(separatedBy: "\n")
        let rawEndLine = rawStartLine + lines.count - 1

        // Trim startLine to skip leading empty/whitespace-only lines.
        var startLine = rawStartLine
        for lineIdx in 0..<lines.count {
            let stripped = lines[lineIdx].trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                startLine = rawStartLine + lineIdx + 1
            } else {
                break
            }
        }

        // Trim endLine to exclude trailing lines that only contain `;` and/or whitespace.
        // This creates a visual gap between segments in the gutter.
        var endLine = rawEndLine
        for lineIdx in stride(from: lines.count - 1, through: 0, by: -1) {
            let stripped = lines[lineIdx].trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped == ";" {
                endLine = rawStartLine + lineIdx - 1
            } else {
                break
            }
        }

        // Ensure valid range (startLine <= endLine, and both within bounds)
        startLine = min(startLine, rawEndLine)
        endLine = max(endLine, startLine)

        segments.append(SQLSegment(
            index: segments.count,
            sql: sql,
            range: range,
            startLine: startLine,
            endLine: endLine
        ))
    }

    /// Scan for a dollar-quote tag starting at position `from`.
    /// A dollar tag is: `$` followed by optional identifier chars, then `$`.
    /// Returns the full tag including both `$` delimiters (e.g., `$$` or `$tag$`).
    private static func scanDollarTag(chars: [unichar], from: Int, length: Int) -> String? {
        guard from < length, chars[from] == unichar("$") else { return nil }

        var j = from + 1
        // Scan optional identifier: [A-Za-z0-9_]
        while j < length {
            let c = chars[j]
            let isIdent = (c >= unichar("A") && c <= unichar("Z"))
                || (c >= unichar("a") && c <= unichar("z"))
                || (c >= unichar("0") && c <= unichar("9"))
                || c == unichar("_")
            if !isIdent { break }
            j += 1
        }

        // Must end with another '$'
        guard j < length, chars[j] == unichar("$") else { return nil }

        // Build the tag string (includes both $ delimiters)
        let tagChars = chars[from...j]
        return String(utf16CodeUnits: Array(tagChars), count: tagChars.count)
    }

    /// Check if `pattern` matches at `offset` in `chars`.
    private static func matchesAt(chars: [unichar], offset: Int, pattern: [unichar], length: Int) -> Bool {
        guard offset + pattern.count <= length else { return false }
        for k in 0..<pattern.count {
            if chars[offset + k] != pattern[k] { return false }
        }
        return true
    }

    private static func unichar(_ c: Character) -> unichar {
        return c.utf16.first!
    }
}
