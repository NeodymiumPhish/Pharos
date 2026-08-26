import Foundation

// MARK: - TagGlob

/// `*` and `?` matching for a text condition.
///
/// Hand-written, and deliberately NOT `NSRegularExpression`. A glob translated
/// to a regex inherits catastrophic backtracking, and `NSRegularExpression`
/// offers no timeout — a pasted pattern could freeze the grid with no recovery.
/// This walk is O(pattern x text) in the worst case and cannot run away.
///
/// The match is ANCHORED at both ends: a glob describes a whole value, never a
/// substring. `evil` does not match `evil.com`, and an analyst who wants a
/// substring writes `*evil*`. Anchoring is the safer default because it cannot
/// silently widen a condition.
///
/// Pure Foundation, so the harness compiles this file on its own.
enum TagGlob {

    enum Token: Equatable {
        case literal(Character)
        case anyOne     // ?
        case anyRun     // *
    }

    /// Tokens for `pattern`, or nil when it cannot be one.
    ///
    /// A run of stars collapses to a single `anyRun`: `**` says exactly what
    /// `*` says, and collapsing it here keeps the matcher's backtracking state
    /// to one saved position instead of one per star.
    ///
    /// Returns nil for an empty pattern (it would match only empty text, which
    /// an `exact` condition already says better) and for a trailing lone
    /// backslash (there is nothing to escape, and guessing would let a typo
    /// match text the analyst never wrote).
    static func compile(_ pattern: String) -> [Token]? {
        guard !pattern.isEmpty else { return nil }
        var tokens: [Token] = []
        var iterator = pattern.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\\":
                guard let escaped = iterator.next() else { return nil }
                tokens.append(.literal(escaped))
            case "*":
                if tokens.last != .anyRun { tokens.append(.anyRun) }
            case "?":
                tokens.append(.anyOne)
            default:
                tokens.append(.literal(character))
            }
        }
        return tokens
    }

    /// Does `text` match `tokens`, end to end?
    ///
    /// One saved backtrack position rather than recursion: on a mismatch the
    /// walk returns to the most recent `anyRun` and lets it swallow one more
    /// character. That is enough for a total order of stars, and it cannot
    /// overflow the stack on a long value.
    ///
    /// `Array(text)` and not `text.unicodeScalars`: `?` must match one thing
    /// the analyst can SEE, and an accented letter is often two scalars and one
    /// Character.
    static func matches(_ tokens: [Token], _ text: String) -> Bool {
        let characters = Array(text)
        var token = 0
        var index = 0
        var runToken = -1
        var runIndex = 0

        while index < characters.count {
            if token < tokens.count {
                switch tokens[token] {
                case .literal(let expected) where expected == characters[index]:
                    token += 1
                    index += 1
                    continue
                case .anyOne:
                    token += 1
                    index += 1
                    continue
                case .anyRun:
                    // Remember where the run started, then try to match the
                    // REST of the pattern from here. If that fails, the run
                    // swallows one more character and we try again.
                    runToken = token
                    runIndex = index
                    token += 1
                    continue
                case .literal:
                    break
                }
            }
            guard runToken >= 0 else { return false }
            runIndex += 1
            index = runIndex
            token = runToken + 1
        }

        // Text is spent. Any trailing runs may match nothing at all.
        var tail = token
        while tail < tokens.count, tokens[tail] == .anyRun { tail += 1 }
        return tail == tokens.count
    }
}
