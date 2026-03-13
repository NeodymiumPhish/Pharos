import Foundation

/// Kind of foldable SQL region.
enum FoldKind {
    case cte          // WITH ... AS ( ... )
    case subquery     // ( SELECT ... )
    case caseBlock    // CASE ... END
    case beginEnd     // BEGIN ... END
    case createBody   // CREATE ... AS $$ ... $$ or CREATE ... ( ... )
    case parenBlock   // Multi-line parenthesized lists (VALUES, IN, column defs) -- only when spanning 3+ lines
}

/// A foldable region in SQL text.
struct SQLFoldRegion {
    /// 1-based line of the fold trigger keyword.
    let startLine: Int
    /// 1-based closing line (END, closing paren, etc.).
    let endLine: Int
    /// 0-based character offset of the first char on the line AFTER startLine.
    let startCharIndex: Int
    /// 0-based character offset of the last char on endLine (before newline).
    let endCharIndex: Int
    /// 0-based character offset of the closing delimiter (`)` for paren-based, same as endCharIndex for keyword-based).
    let closeCharIndex: Int
    /// What kind of fold this is.
    let kind: FoldKind
    /// Whether the region is currently collapsed.
    var isCollapsed: Bool = false
    /// UUID of the FoldEntry in FoldState when collapsed (set by QueryEditorVC on rebuild).
    var foldEntryId: UUID? = nil
}

/// Parses SQL text to find foldable regions for code folding.
struct SQLFoldingParser {

    // MARK: - Parse State

    private enum LexState {
        case normal
        case singleQuote
        case dollarQuote(String)
        case lineComment
        case blockComment(Int) // depth
    }

    /// Parse SQL text and return foldable regions (each spanning 3+ lines).
    static func parse(_ text: String) -> [SQLFoldRegion] {
        guard !text.isEmpty else { return [] }

        let nsText = text as NSString
        let chars = Array(text.utf16)
        let length = chars.count

        // Build line start offsets (0-based char index for each 1-based line)
        var lineStarts: [Int] = [0] // line 1 starts at char 0
        for i in 0..<length {
            if chars[i] == 0x0A { // newline
                lineStarts.append(i + 1)
            }
        }
        let totalLines = lineStarts.count

        // Helper: get 1-based line number for a 0-based char index
        func lineFor(_ charIndex: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= charIndex {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return lo + 1 // 1-based
        }

        // Helper: get the char index of end of content on a given line (before newline)
        func endOfLine(_ line: Int) -> Int {
            let lineIdx = line - 1
            guard lineIdx >= 0, lineIdx < lineStarts.count else { return length - 1 }
            let start = lineStarts[lineIdx]
            // Find the newline or end of text
            if line < totalLines {
                let nextStart = lineStarts[line]
                // nextStart - 1 is the newline, so content ends at nextStart - 2
                return max(start, nextStart - 2)
            } else {
                return max(start, length - 1)
            }
        }

        // First pass: build a lex-state map so we know what's in strings/comments
        var stateMap = [LexState](repeating: .normal, count: length)
        var lexState: LexState = .normal
        var i = 0
        while i < length {
            let ch = chars[i]
            switch lexState {
            case .normal:
                if ch == uc("'") {
                    lexState = .singleQuote
                    stateMap[i] = .singleQuote
                } else if ch == uc("-"), i + 1 < length, chars[i + 1] == uc("-") {
                    lexState = .lineComment
                    stateMap[i] = .lineComment
                    i += 1
                    if i < length { stateMap[i] = .lineComment }
                } else if ch == uc("/"), i + 1 < length, chars[i + 1] == uc("*") {
                    lexState = .blockComment(1)
                    stateMap[i] = .blockComment(1)
                    i += 1
                    if i < length { stateMap[i] = .blockComment(1) }
                } else if ch == uc("$") {
                    if let tag = scanDollarTag(chars: chars, from: i, length: length) {
                        let tagLen = tag.utf16.count
                        lexState = .dollarQuote(tag)
                        for j in i..<min(i + tagLen, length) {
                            stateMap[j] = .dollarQuote(tag)
                        }
                        i += tagLen - 1
                    }
                }
            case .singleQuote:
                stateMap[i] = .singleQuote
                if ch == uc("'") {
                    if i + 1 < length, chars[i + 1] == uc("'") {
                        i += 1
                        if i < length { stateMap[i] = .singleQuote }
                    } else {
                        lexState = .normal
                    }
                }
            case .dollarQuote(let tag):
                stateMap[i] = .dollarQuote(tag)
                if ch == uc("$") {
                    let tagUTF16 = Array(tag.utf16)
                    if matchesAt(chars: chars, offset: i, pattern: tagUTF16, length: length) {
                        for j in i..<min(i + tagUTF16.count, length) {
                            stateMap[j] = .dollarQuote(tag)
                        }
                        i += tagUTF16.count - 1
                        lexState = .normal
                    }
                }
            case .lineComment:
                stateMap[i] = .lineComment
                if ch == 0x0A {
                    lexState = .normal
                }
            case .blockComment(let depth):
                stateMap[i] = .blockComment(depth)
                if ch == uc("/"), i + 1 < length, chars[i + 1] == uc("*") {
                    let newDepth = depth + 1
                    lexState = .blockComment(newDepth)
                    stateMap[i] = .blockComment(newDepth)
                    i += 1
                    if i < length { stateMap[i] = .blockComment(newDepth) }
                } else if ch == uc("*"), i + 1 < length, chars[i + 1] == uc("/") {
                    if depth <= 1 {
                        stateMap[i] = .blockComment(depth)
                        i += 1
                        if i < length { stateMap[i] = .blockComment(0) }
                        lexState = .normal
                    } else {
                        let newDepth = depth - 1
                        lexState = .blockComment(newDepth)
                        stateMap[i] = .blockComment(depth)
                        i += 1
                        if i < length { stateMap[i] = .blockComment(newDepth) }
                    }
                }
            }
            i += 1
        }

        // Helper: check if a char index is in normal code (not string/comment)
        func isNormal(_ idx: Int) -> Bool {
            guard idx >= 0, idx < length else { return false }
            switch stateMap[idx] {
            case .normal: return true
            default: return false
            }
        }

        // Second pass: find foldable regions
        var regions: [SQLFoldRegion] = []

        // Track parenthesis pairs for paren-based folds
        var parenStack: [(charIndex: Int, line: Int)] = []

        // Track keyword-based folds
        var caseStack: [Int] = []  // char indices of CASE keywords
        var beginStack: [Int] = [] // char indices of BEGIN keywords

        i = 0
        while i < length {
            guard isNormal(i) else { i += 1; continue }
            let ch = chars[i]

            // Parenthesis matching
            if ch == uc("(") {
                parenStack.append((charIndex: i, line: lineFor(i)))
                i += 1
                continue
            }

            if ch == uc(")") {
                if let open = parenStack.popLast() {
                    let openLine = open.line
                    let closeLine = lineFor(i)
                    if closeLine - openLine + 1 >= 3 {
                        // Determine kind: check if SELECT follows the open paren
                        let kind: FoldKind
                        let afterOpen = skipWhitespace(chars: chars, from: open.charIndex + 1, length: length, stateMap: stateMap)
                        if matchesKeyword("SELECT", chars: chars, at: afterOpen, length: length) && isNormal(afterOpen) {
                            kind = .subquery
                        } else {
                            // Check if this is a CTE: look backward from open paren for "AS"
                            let beforeOpen = skipWhitespaceBackward(chars: chars, from: open.charIndex - 1, stateMap: stateMap)
                            if beforeOpen >= 1 && matchesKeywordBackward("AS", chars: chars, endingAt: beforeOpen, length: length) && isNormal(beforeOpen) {
                                kind = .cte
                            } else {
                                kind = .parenBlock
                            }
                        }

                        // startCharIndex: char right after the opening '('
                        let startCharIdx = open.charIndex + 1
                        let endCharIdx = endOfLine(closeLine)

                        regions.append(SQLFoldRegion(
                            startLine: openLine,
                            endLine: closeLine,
                            startCharIndex: startCharIdx,
                            endCharIndex: endCharIdx,
                            closeCharIndex: i, // position of the closing ')'
                            kind: kind
                        ))
                    }
                }
                i += 1
                continue
            }

            // Keyword matching (only at word boundaries)
            if isWordStart(chars: chars, at: i) {
                // CASE ... END
                if matchesKeyword("CASE", chars: chars, at: i, length: length) {
                    caseStack.append(i)
                    i += 4
                    continue
                }

                // BEGIN ... END
                if matchesKeyword("BEGIN", chars: chars, at: i, length: length) {
                    beginStack.append(i)
                    i += 5
                    continue
                }

                // CREATE ... AS $$ ... $$ (dollar-quoted function/procedure body)
                if matchesKeyword("CREATE", chars: chars, at: i, length: length) {
                    // Scan forward from CREATE to find AS followed by a dollar-quote opening
                    let createPos = i
                    var scan = i + 6 // skip past "CREATE"
                    // Scan forward looking for "AS" keyword followed by a dollar-quote
                    // Limit scan to avoid running forever (max ~2000 chars from CREATE)
                    let scanLimit = min(scan + 2000, length)
                    var foundCreateBody = false
                    while scan < scanLimit {
                        guard isNormal(scan) else { scan += 1; continue }
                        if isWordStart(chars: chars, at: scan) && matchesKeyword("AS", chars: chars, at: scan, length: length) {
                            // Found AS — check if followed by a dollar-quote
                            let afterAS = skipWhitespace(chars: chars, from: scan + 2, length: length, stateMap: stateMap)
                            if afterAS < length, chars[afterAS] == uc("$") {
                                // This should be the start of a dollar-quote — the stateMap marks it
                                if case .dollarQuote(let tag) = stateMap[afterAS] {
                                    let tagLen = tag.utf16.count
                                    let bodyStart = afterAS + tagLen // first char after opening $$
                                    // Scan forward to find where this dollar-quote ends
                                    // (the lex state transitions back to .normal after the closing tag)
                                    var endPos = bodyStart
                                    while endPos < length {
                                        if case .dollarQuote(let t) = stateMap[endPos], t == tag {
                                            // Check if this is the closing tag (next char after tag is normal or end)
                                            let tagEnd = endPos + tagLen
                                            if tagEnd <= length {
                                                let afterTag = tagEnd < length ? stateMap[tagEnd] : .normal
                                                let isClosing: Bool
                                                switch afterTag {
                                                case .normal: isClosing = true
                                                case .dollarQuote: isClosing = false
                                                default: isClosing = true
                                                }
                                                if isClosing && endPos > bodyStart {
                                                    // Found closing dollar-quote at endPos..endPos+tagLen-1
                                                    let foldEndCharIdx = min(endPos + tagLen - 1, length - 1)
                                                    let startLine = lineFor(createPos)
                                                    let endLine = lineFor(foldEndCharIdx)
                                                    if endLine - startLine + 1 >= 3 {
                                                        let startCharIdx: Int
                                                        if startLine < totalLines {
                                                            startCharIdx = lineStarts[startLine]
                                                        } else {
                                                            startCharIdx = afterAS + tagLen
                                                        }
                                                        let endCharIdx2 = endOfLine(endLine)
                                                        regions.append(SQLFoldRegion(
                                                            startLine: startLine,
                                                            endLine: endLine,
                                                            startCharIndex: startCharIdx,
                                                            endCharIndex: endCharIdx2,
                                                            closeCharIndex: endCharIdx2,
                                                            kind: .createBody
                                                        ))
                                                        foundCreateBody = true
                                                    }
                                                    break
                                                }
                                            }
                                        }
                                        endPos += 1
                                    }
                                    break // Done scanning for AS $$ from this CREATE
                                }
                            }
                            break // Found AS but no dollar-quote follows; stop scanning
                        }
                        // Also stop if we hit a semicolon (end of statement) before finding AS
                        if chars[scan] == uc(";") { break }
                        scan += 1
                    }
                    // Don't skip past CREATE — let paren matching still work for CREATE TABLE (...)
                    if !foundCreateBody {
                        i += 6
                        continue
                    } else {
                        i += 6
                        continue
                    }
                }

                // END — close CASE or BEGIN
                if matchesKeyword("END", chars: chars, at: i, length: length) {
                    let endLine = lineFor(i)
                    let endCharIdx = endOfLine(endLine)

                    // Try CASE first (innermost)
                    if let caseStart = caseStack.popLast() {
                        let startLine = lineFor(caseStart)
                        if endLine - startLine + 1 >= 3 {
                            let startCharIdx: Int
                            if startLine < totalLines {
                                startCharIdx = lineStarts[startLine]
                            } else {
                                startCharIdx = caseStart + 4
                            }
                            regions.append(SQLFoldRegion(
                                startLine: startLine,
                                endLine: endLine,
                                startCharIndex: startCharIdx,
                                endCharIndex: endCharIdx,
                                closeCharIndex: endCharIdx,
                                kind: .caseBlock
                            ))
                        }
                    } else if let beginStart = beginStack.popLast() {
                        let startLine = lineFor(beginStart)
                        if endLine - startLine + 1 >= 3 {
                            let startCharIdx: Int
                            if startLine < totalLines {
                                startCharIdx = lineStarts[startLine]
                            } else {
                                startCharIdx = beginStart + 5
                            }
                            regions.append(SQLFoldRegion(
                                startLine: startLine,
                                endLine: endLine,
                                startCharIndex: startCharIdx,
                                endCharIndex: endCharIdx,
                                closeCharIndex: endCharIdx,
                                kind: .beginEnd
                            ))
                        }
                    }
                    i += 3
                    continue
                }
            }

            i += 1
        }

        // Sort by startLine, then by startCharIndex for stable ordering
        regions.sort { a, b in
            if a.startLine != b.startLine { return a.startLine < b.startLine }
            return a.startCharIndex < b.startCharIndex
        }

        return regions
    }

    // MARK: - Helpers

    private static func uc(_ c: Character) -> unichar {
        return c.utf16.first!
    }

    private static func scanDollarTag(chars: [unichar], from: Int, length: Int) -> String? {
        guard from < length, chars[from] == uc("$") else { return nil }
        var j = from + 1
        while j < length {
            let c = chars[j]
            let isIdent = (c >= uc("A") && c <= uc("Z"))
                || (c >= uc("a") && c <= uc("z"))
                || (c >= uc("0") && c <= uc("9"))
                || c == uc("_")
            if !isIdent { break }
            j += 1
        }
        guard j < length, chars[j] == uc("$") else { return nil }
        let tagChars = chars[from...j]
        return String(utf16CodeUnits: Array(tagChars), count: tagChars.count)
    }

    private static func matchesAt(chars: [unichar], offset: Int, pattern: [unichar], length: Int) -> Bool {
        guard offset + pattern.count <= length else { return false }
        for k in 0..<pattern.count {
            if chars[offset + k] != pattern[k] { return false }
        }
        return true
    }

    /// Check if position `i` is at the start of a word (no preceding alphanumeric/underscore).
    private static func isWordStart(chars: [unichar], at i: Int) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1]
        return !isIdentChar(prev)
    }

    /// Check if a character is an identifier character [A-Za-z0-9_].
    private static func isIdentChar(_ c: unichar) -> Bool {
        return (c >= uc("A") && c <= uc("Z"))
            || (c >= uc("a") && c <= uc("z"))
            || (c >= uc("0") && c <= uc("9"))
            || c == uc("_")
    }

    /// Check if keyword matches at position (case-insensitive) with word boundary after.
    private static func matchesKeyword(_ keyword: String, chars: [unichar], at pos: Int, length: Int) -> Bool {
        let kwChars = Array(keyword.uppercased().utf16)
        guard pos + kwChars.count <= length else { return false }
        for k in 0..<kwChars.count {
            let c = chars[pos + k]
            // Uppercase the char for comparison
            let upper: unichar
            if c >= uc("a") && c <= uc("z") {
                upper = c - 32
            } else {
                upper = c
            }
            if upper != kwChars[k] { return false }
        }
        // Check word boundary after
        let afterPos = pos + kwChars.count
        if afterPos < length && isIdentChar(chars[afterPos]) { return false }
        return true
    }

    /// Check if keyword ends at position (scanning backward), case-insensitive.
    private static func matchesKeywordBackward(_ keyword: String, chars: [unichar], endingAt pos: Int, length: Int) -> Bool {
        let kwChars = Array(keyword.uppercased().utf16)
        let startPos = pos - kwChars.count + 1
        guard startPos >= 0 else { return false }
        // Check word boundary before
        if startPos > 0 && isIdentChar(chars[startPos - 1]) { return false }
        for k in 0..<kwChars.count {
            let c = chars[startPos + k]
            let upper: unichar
            if c >= uc("a") && c <= uc("z") {
                upper = c - 32
            } else {
                upper = c
            }
            if upper != kwChars[k] { return false }
        }
        return true
    }

    /// Skip whitespace forward, returning the next non-whitespace position.
    private static func skipWhitespace(chars: [unichar], from: Int, length: Int, stateMap: [LexState]) -> Int {
        var j = from
        while j < length {
            let c = chars[j]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { // space, tab, newline, CR
                j += 1
            } else {
                break
            }
        }
        return j
    }

    /// Skip whitespace backward, returning the position of the last non-whitespace char.
    private static func skipWhitespaceBackward(chars: [unichar], from: Int, stateMap: [LexState]) -> Int {
        var j = from
        while j >= 0 {
            let c = chars[j]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                j -= 1
            } else {
                break
            }
        }
        return j
    }
}
