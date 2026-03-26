import Foundation

// MARK: - Lex State

/// State of the SQL lexer at any character position.
enum SQLLexState: Equatable {
    case normal
    case singleQuote
    case doubleQuote           // quoted identifier: "First Seen"
    case dollarQuote(String)   // stores the full $tag$ delimiter
    case lineComment
    case blockComment(Int)     // nesting depth

    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }
}

// MARK: - SQLLexer

/// Shared SQL lexer that produces a per-character state map.
/// Used by syntax highlighting, segment parsing, and code folding.
struct SQLLexer {

    /// Build a state map marking the lex state at every UTF-16 character position.
    /// This is the single source of truth for what's inside strings, comments, etc.
    static func buildStateMap(chars: [unichar], length: Int) -> [SQLLexState] {
        var stateMap = [SQLLexState](repeating: .normal, count: length)
        var state: SQLLexState = .normal
        var i = 0

        while i < length {
            let ch = chars[i]

            switch state {
            case .normal:
                if ch == Self.uc("'") {
                    state = .singleQuote
                    stateMap[i] = .singleQuote
                } else if ch == Self.uc("\"") {
                    state = .doubleQuote
                    stateMap[i] = .doubleQuote
                } else if ch == Self.uc("-"), i + 1 < length, chars[i + 1] == Self.uc("-") {
                    state = .lineComment
                    stateMap[i] = .lineComment
                    i += 1
                    if i < length { stateMap[i] = .lineComment }
                } else if ch == Self.uc("/"), i + 1 < length, chars[i + 1] == Self.uc("*") {
                    state = .blockComment(1)
                    stateMap[i] = .blockComment(1)
                    i += 1
                    if i < length { stateMap[i] = .blockComment(1) }
                } else if ch == Self.uc("$") {
                    if let tag = scanDollarTag(chars: chars, from: i, length: length) {
                        let tagLen = tag.utf16.count
                        state = .dollarQuote(tag)
                        for j in i..<min(i + tagLen, length) {
                            stateMap[j] = .dollarQuote(tag)
                        }
                        i += tagLen - 1
                    }
                }

            case .singleQuote:
                stateMap[i] = .singleQuote
                if ch == Self.uc("'") {
                    if i + 1 < length, chars[i + 1] == Self.uc("'") {
                        i += 1
                        if i < length { stateMap[i] = .singleQuote }
                    } else {
                        state = .normal
                    }
                }

            case .doubleQuote:
                stateMap[i] = .doubleQuote
                if ch == Self.uc("\"") {
                    // Handle "" escape inside quoted identifiers
                    if i + 1 < length, chars[i + 1] == Self.uc("\"") {
                        i += 1
                        if i < length { stateMap[i] = .doubleQuote }
                    } else {
                        state = .normal
                    }
                }

            case .dollarQuote(let tag):
                stateMap[i] = .dollarQuote(tag)
                if ch == Self.uc("$") {
                    let tagUTF16 = Array(tag.utf16)
                    if matchesAt(chars: chars, offset: i, pattern: tagUTF16, length: length) {
                        for j in i..<min(i + tagUTF16.count, length) {
                            stateMap[j] = .dollarQuote(tag)
                        }
                        i += tagUTF16.count - 1
                        state = .normal
                    }
                }

            case .lineComment:
                stateMap[i] = .lineComment
                if ch == 0x0A {
                    state = .normal
                }

            case .blockComment(let depth):
                stateMap[i] = .blockComment(depth)
                if ch == Self.uc("/"), i + 1 < length, chars[i + 1] == Self.uc("*") {
                    let newDepth = depth + 1
                    state = .blockComment(newDepth)
                    stateMap[i] = .blockComment(newDepth)
                    i += 1
                    if i < length { stateMap[i] = .blockComment(newDepth) }
                } else if ch == Self.uc("*"), i + 1 < length, chars[i + 1] == Self.uc("/") {
                    if depth <= 1 {
                        stateMap[i] = .blockComment(depth)
                        i += 1
                        if i < length { stateMap[i] = .blockComment(0) }
                        state = .normal
                    } else {
                        let newDepth = depth - 1
                        state = .blockComment(newDepth)
                        stateMap[i] = .blockComment(depth)
                        i += 1
                        if i < length { stateMap[i] = .blockComment(newDepth) }
                    }
                }
            }

            i += 1
        }

        return stateMap
    }

    // MARK: - Shared Helpers

    /// Convert a Character to its UTF-16 code unit.
    static func uc(_ c: Character) -> unichar {
        c.utf16.first!
    }

    /// Scan for a dollar-quote tag starting at position `from`.
    /// Returns the full tag including both `$` delimiters (e.g., `$$` or `$tag$`).
    static func scanDollarTag(chars: [unichar], from: Int, length: Int) -> String? {
        guard from < length, chars[from] == uc("$") else { return nil }
        var j = from + 1
        while j < length {
            let c = chars[j]
            if !isIdentChar(c) { break }
            j += 1
        }
        guard j < length, chars[j] == uc("$") else { return nil }
        let tagChars = chars[from...j]
        return String(utf16CodeUnits: Array(tagChars), count: tagChars.count)
    }

    /// Check if `pattern` matches at `offset` in `chars`.
    static func matchesAt(chars: [unichar], offset: Int, pattern: [unichar], length: Int) -> Bool {
        guard offset + pattern.count <= length else { return false }
        for k in 0..<pattern.count {
            if chars[offset + k] != pattern[k] { return false }
        }
        return true
    }

    /// Check if a character is an identifier character [A-Za-z0-9_].
    static func isIdentChar(_ c: unichar) -> Bool {
        (c >= uc("A") && c <= uc("Z"))
            || (c >= uc("a") && c <= uc("z"))
            || (c >= uc("0") && c <= uc("9"))
            || c == uc("_")
    }

    /// Check if position `i` is at the start of a word.
    static func isWordStart(chars: [unichar], at i: Int) -> Bool {
        if i == 0 { return true }
        return !isIdentChar(chars[i - 1])
    }

    /// Case-insensitive keyword match with word boundary after.
    static func matchesKeyword(_ keyword: String, chars: [unichar], at pos: Int, length: Int) -> Bool {
        let kwChars = Array(keyword.uppercased().utf16)
        guard pos + kwChars.count <= length else { return false }
        for k in 0..<kwChars.count {
            let c = chars[pos + k]
            let upper: unichar = (c >= uc("a") && c <= uc("z")) ? c - 32 : c
            if upper != kwChars[k] { return false }
        }
        let afterPos = pos + kwChars.count
        if afterPos < length && isIdentChar(chars[afterPos]) { return false }
        return true
    }

    /// Case-insensitive backward keyword match.
    static func matchesKeywordBackward(_ keyword: String, chars: [unichar], endingAt pos: Int, length: Int) -> Bool {
        let kwChars = Array(keyword.uppercased().utf16)
        let startPos = pos - kwChars.count + 1
        guard startPos >= 0 else { return false }
        if startPos > 0 && isIdentChar(chars[startPos - 1]) { return false }
        for k in 0..<kwChars.count {
            let c = chars[startPos + k]
            let upper: unichar = (c >= uc("a") && c <= uc("z")) ? c - 32 : c
            if upper != kwChars[k] { return false }
        }
        return true
    }

    /// Skip whitespace forward, returning the next non-whitespace position.
    static func skipWhitespace(chars: [unichar], from: Int, length: Int) -> Int {
        var j = from
        while j < length {
            let c = chars[j]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                j += 1
            } else {
                break
            }
        }
        return j
    }

    /// Skip whitespace backward, returning the position of the last non-whitespace char.
    static func skipWhitespaceBackward(chars: [unichar], from: Int) -> Int {
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
