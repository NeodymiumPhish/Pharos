import Foundation

/// The pure half of the editor's `{{` variable completion: where a token is
/// being typed, which rows the list shows, and the brace-pairing decisions.
/// No AppKit, so `scripts/test-editor-completion.sh` checks it directly.
///
/// A token is `{{`, optional spaces or tabs, then a name of `[A-Za-z0-9_]` —
/// the same shape `VariableSubstitutor` resolves. The caret is "in a token"
/// while it sits in or right after that name, before anything else is typed.
enum VariableCompletion {

    /// A token being typed at the caret.
    struct Context: Equatable {
        /// The part of the name before the caret — what the list filters by.
        let typed: String
        /// What accepting a row replaces: the whole name around the caret, and
        /// the closing `}}` when it is already there (spaces before it too).
        /// Accepting writes `name}}` over this range.
        let replaceRange: NSRange
    }

    /// One row of the list.
    struct Item: Equatable {
        let name: String
        /// True for the "new variable" row: no variable has this name yet.
        let isNew: Bool
    }

    // MARK: - Context

    /// The token being typed at `caret`, or nil when the caret is not in one.
    static func context(in text: NSString, caret: Int) -> Context? {
        guard caret >= 0, caret <= text.length,
              let nameStart = nameStart(ofTokenEndingAt: caret, in: text) else { return nil }

        var nameEnd = caret
        while nameEnd < text.length, isNameCharacter(text.character(at: nameEnd)) {
            nameEnd += 1
        }
        var closeStart = nameEnd
        while closeStart < text.length, isInlineSpace(text.character(at: closeStart)) {
            closeStart += 1
        }
        let replaceEnd = hasClosingPair(in: text, at: closeStart) ? closeStart + 2 : nameEnd

        return Context(
            typed: text.substring(with: NSRange(location: nameStart, length: caret - nameStart)),
            replaceRange: NSRange(location: nameStart, length: replaceEnd - nameStart)
        )
    }

    // MARK: - Rows

    /// The rows for `typed`, against the variable names in list order.
    ///
    /// An exact (case-sensitive) match first, then names that start with
    /// `typed`, then names that contain it — both case-insensitive. Last, when
    /// `typed` is a usable name that no variable has exactly, a row that
    /// creates it. With nothing typed, every name and no "new" row.
    static func items(names: [String], typed: String) -> [Item] {
        var seen = Set<String>()
        let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }

        guard !typed.isEmpty else {
            return unique.map { Item(name: $0, isNew: false) }
        }

        let lower = typed.lowercased()
        var exact: [String] = []
        var prefix: [String] = []
        var contains: [String] = []
        for name in unique {
            let lowerName = name.lowercased()
            if name == typed {
                exact.append(name)
            } else if lowerName.hasPrefix(lower) {
                prefix.append(name)
            } else if lowerName.contains(lower) {
                contains.append(name)
            }
        }

        var result = (exact + prefix + contains).map { Item(name: $0, isNew: false) }
        if exact.isEmpty, VariableSubstitutor.isValidName(typed) {
            result.append(Item(name: typed, isNew: true))
        }
        return result
    }

    // MARK: - Brace pairing

    /// Characters that may follow the caret for `{{` to get its `}}`. The same
    /// set `(` and `[` use, plus `'`, so `'{{` inside a string literal pairs.
    private static let autoCloseFollowers = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ")],;'"))

    /// Whether typing `{` at `caret` completes a `{{` that should get `}}`.
    /// Not for a third brace (`{{{`), and not with text right after the caret.
    static func shouldAutoClose(in text: NSString, at caret: Int) -> Bool {
        guard caret >= 1, caret <= text.length, text.character(at: caret - 1) == openBrace else {
            return false
        }
        if caret >= 2, text.character(at: caret - 2) == openBrace { return false }
        guard caret < text.length else { return true }
        guard let scalar = UnicodeScalar(text.character(at: caret)) else { return false }
        return autoCloseFollowers.contains(scalar)
    }

    /// Whether typing `}` at `caret` should step over a `}` of a token's
    /// closing pair instead of adding a third brace: `{{name|}}` and
    /// `{{name}|}`.
    static func shouldStepOver(in text: NSString, at caret: Int) -> Bool {
        guard caret >= 0, caret < text.length, text.character(at: caret) == closeBrace else {
            return false
        }
        if hasClosingPair(in: text, at: caret), nameStart(ofTokenEndingAt: caret, in: text) != nil {
            return true
        }
        return caret >= 1
            && text.character(at: caret - 1) == closeBrace
            && nameStart(ofTokenEndingAt: caret - 1, in: text) != nil
    }

    /// The range of an empty `{{}}` around `caret` (`{{|}}`), which one
    /// Backspace removes whole.
    static func emptyPairRange(in text: NSString, at caret: Int) -> NSRange? {
        guard caret >= 2, caret + 2 <= text.length,
              text.character(at: caret - 2) == openBrace,
              text.character(at: caret - 1) == openBrace,
              hasClosingPair(in: text, at: caret) else { return nil }
        return NSRange(location: caret - 2, length: 4)
    }

    // MARK: - Scanning

    private static let openBrace = unichar(UInt8(ascii: "{"))
    private static let closeBrace = unichar(UInt8(ascii: "}"))

    /// Where the name starts when `{{`, spaces, and name characters end
    /// exactly at `end`; nil when they do not.
    private static func nameStart(ofTokenEndingAt end: Int, in text: NSString) -> Int? {
        var nameStart = end
        while nameStart > 0, isNameCharacter(text.character(at: nameStart - 1)) {
            nameStart -= 1
        }
        var open = nameStart
        while open > 0, isInlineSpace(text.character(at: open - 1)) {
            open -= 1
        }
        guard open >= 2,
              text.character(at: open - 2) == openBrace,
              text.character(at: open - 1) == openBrace else { return nil }
        return nameStart
    }

    private static func hasClosingPair(in text: NSString, at index: Int) -> Bool {
        index + 2 <= text.length
            && text.character(at: index) == closeBrace
            && text.character(at: index + 1) == closeBrace
    }

    /// `[A-Za-z0-9_]` — ASCII only, like the token regex.
    private static func isNameCharacter(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    private static func isInlineSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09
    }
}
