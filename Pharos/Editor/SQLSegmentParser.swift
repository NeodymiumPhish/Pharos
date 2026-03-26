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
        let stateMap = SQLLexer.buildStateMap(chars: chars, length: length)

        var segments: [SQLSegment] = []
        var segmentStart = 0
        var currentLine = 1
        var segmentStartLine = 1

        for i in 0..<length {
            let ch = chars[i]

            // Only split on semicolons in normal (non-string/comment) state
            if ch == SQLLexer.uc(";") && stateMap[i].isNormal {
                let segRange = NSRange(location: segmentStart, length: i - segmentStart + 1)
                emitSegment(text: text, range: segRange, index: segments.count, startLine: segmentStartLine, into: &segments)
                segmentStart = i + 1
                segmentStartLine = currentLine
            }

            if ch == 0x0A {
                currentLine += 1
            }
        }

        // Handle trailing segment (no semicolon at end)
        if segmentStart < length {
            let segRange = NSRange(location: segmentStart, length: length - segmentStart)
            emitSegment(text: text, range: segRange, index: segments.count, startLine: segmentStartLine, into: &segments)
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
    /// `startLine` is the 1-based line number at the start of this segment's range (passed from the running count).
    private static func emitSegment(
        text: String,
        range: NSRange,
        index: Int,
        startLine: Int,
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

        // Use the running line count passed from parse() instead of re-scanning from start
        let rawStartLine = startLine
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

}
