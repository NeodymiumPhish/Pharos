import Foundation

/// The rule the card editor's Find field matches text by, and the edits that
/// Replace, Replace All and Change Variable make to the cards.
///
/// The same three modes as the results Find (`FindMode`, Settings ▸ Results ▸
/// Find), but over the text of a card, so it answers with character ranges
/// rather than yes or no. Every mode compiles to one regular expression, so
/// the ranges, the replacements and the count cannot disagree.
///
/// Ranges are UTF-16 (`NSRange`), as `NSTextView` and `NSLayoutManager` count.
/// Foundation only, so `scripts/test-card-text-search.sh` compiles it
/// standalone.
struct CardTextMatcher {

    let pattern: String
    let mode: FindMode
    let matchCase: Bool

    /// False only for a regular expression that does not compile. An invalid
    /// matcher matches nothing.
    let isValid: Bool

    private let regex: NSRegularExpression?

    init(pattern: String, mode: FindMode, matchCase: Bool) {
        self.pattern = pattern
        self.mode = mode
        self.matchCase = matchCase
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        guard !pattern.isEmpty else {
            regex = nil
            isValid = true
            return
        }
        let source: String
        switch mode {
        case .contains:
            source = NSRegularExpression.escapedPattern(for: pattern)
        case .wholeWord:
            // Literal text between word boundaries: `a.b` is not a wildcard.
            source = "\\b\(NSRegularExpression.escapedPattern(for: pattern))\\b"
        case .regularExpression:
            source = pattern
        }
        regex = try? NSRegularExpression(pattern: source, options: options)
        isValid = regex != nil
    }

    /// Every match in `text`, in order. An empty pattern matches nothing (no
    /// search yet), and so does an empty match (`a*`, `^`): there is nothing
    /// to show or to replace.
    func ranges(in text: String) -> [NSRange] {
        results(in: text).map(\.range)
    }

    /// The edit for every match in `text`. A regular expression expands
    /// `$1`-style templates; the other modes put `template` in as typed.
    func edits(in text: String, template: String) -> [TextEdit] {
        guard let regex else { return [] }
        let literal = mode != .regularExpression
        return results(in: text).map { result in
            let replacement = literal
                ? template
                : regex.replacementString(for: result, in: text, offset: 0, template: template)
            return TextEdit(range: result.range, replacement: replacement)
        }
    }

    private func results(in text: String) -> [NSTextCheckingResult] {
        guard let regex else { return [] }
        let all = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: all).filter { $0.range.length > 0 }
    }
}

/// One change to a text: put `replacement` where `range` is.
struct TextEdit: Equatable {
    let range: NSRange
    let replacement: String
}

/// What an edit sees of a card.
struct EditableCardText: Equatable {
    let id: String
    let sql: String
    /// A locked version keeps the SQL its results came from
    /// (`CardDocument.updateSQL` refuses it).
    let isLocked: Bool
}

/// The changes to one card, and its text before and after.
struct CardEdit: Equatable {
    let cardId: String
    let edits: [TextEdit]
    let oldSQL: String
    let newSQL: String
}

/// The changes one Replace All or Change Variable makes across cards.
struct CardEditPlan: Equatable {
    var cards: [CardEdit] = []
    /// Locked versions that hold a match and are left as they are.
    var lockedCardsSkipped = 0

    var editCount: Int { cards.reduce(0) { $0 + $1.edits.count } }
    var isEmpty: Bool { cards.isEmpty }
}

enum CardTextEdits {

    /// `text` with `edits` made. The edits must not overlap; they are made
    /// from the last to the first, so each range still names the original
    /// text when its turn comes.
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    /// The edit that puts `edit.oldSQL` back: each replacement, where it
    /// landed in the new text, changed back to what it replaced. For undo,
    /// so the caret and the folds outside the changes stay where they were.
    static func inverse(of edit: CardEdit) -> CardEdit {
        let old = edit.oldSQL as NSString
        var shift = 0
        var back: [TextEdit] = []
        for e in edit.edits.sorted(by: { $0.range.location < $1.range.location }) {
            let length = (e.replacement as NSString).length
            back.append(TextEdit(range: NSRange(location: e.range.location + shift, length: length),
                                 replacement: old.substring(with: e.range)))
            shift += length - e.range.length
        }
        return CardEdit(cardId: edit.cardId, edits: back, oldSQL: edit.newSQL, newSQL: edit.oldSQL)
    }

    /// Replace every match in `cards`.
    static func replaceAll(in cards: [EditableCardText], matcher: CardTextMatcher, template: String) -> CardEditPlan {
        plan(cards) { matcher.edits(in: $0, template: template) }
    }

    /// The one match at `range` in a card, replaced. Nil when no match starts
    /// and ends there now (the text changed since the match was found).
    static func replace(_ range: NSRange, in card: EditableCardText,
                        matcher: CardTextMatcher, template: String) -> CardEdit? {
        guard !card.isLocked,
              let edit = matcher.edits(in: card.sql, template: template).first(where: { $0.range == range }) else { return nil }
        return CardEdit(cardId: card.id, edits: [edit], oldSQL: card.sql, newSQL: apply([edit], to: card.sql))
    }

    /// Every `{{from}}` token in `cards` written as `{{to}}`. Tokens are found
    /// by `VariableSubstitutor.tokens`, the scan `render` substitutes with, so
    /// `{{ from }}` is changed and `{{from_x}}` is not.
    static func changeVariable(in cards: [EditableCardText], from: String, to: String) -> CardEditPlan {
        guard from != to, VariableSubstitutor.isValidName(to) else { return CardEditPlan() }
        return plan(cards) { sql in
            VariableSubstitutor.tokens(in: sql)
                .filter { $0.name == from }
                .map { TextEdit(range: $0.range, replacement: "{{\(to)}}") }
        }
    }

    private static func plan(_ cards: [EditableCardText], edits: (String) -> [TextEdit]) -> CardEditPlan {
        var plan = CardEditPlan()
        for card in cards {
            let found = edits(card.sql)
            guard !found.isEmpty else { continue }
            if card.isLocked {
                plan.lockedCardsSkipped += 1
                continue
            }
            let newSQL = apply(found, to: card.sql)
            guard newSQL != card.sql else { continue }
            plan.cards.append(CardEdit(cardId: card.id, edits: found, oldSQL: card.sql, newSQL: newSQL))
        }
        return plan
    }
}
