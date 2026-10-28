// Standalone test for CardTextMatcher / CardTextEdits (the card editor's
// Find and Replace, and Change Variable). Compiled by
// scripts/test-card-text-search.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func r(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

func runTests() {
    // Matching
    let contains = CardTextMatcher(pattern: "sel", mode: .contains, matchCase: false)
    expect(contains.ranges(in: "SELECT x; select y") == [r(0, 3), r(10, 3)], "contains: case-insensitive, every match",
           "\(contains.ranges(in: "SELECT x; select y"))")
    let cased = CardTextMatcher(pattern: "sel", mode: .contains, matchCase: true)
    expect(cased.ranges(in: "SELECT x; select y") == [r(10, 3)], "contains: Match Case")
    let dot = CardTextMatcher(pattern: "a.b", mode: .contains, matchCase: false)
    expect(dot.ranges(in: "axb a.b") == [r(4, 3)], "contains: the pattern is literal")
    let word = CardTextMatcher(pattern: "id", mode: .wholeWord, matchCase: false)
    expect(word.ranges(in: "id, uid, id_x, (id)") == [r(0, 2), r(16, 2)], "whole word: not inside other words",
           "\(word.ranges(in: "id, uid, id_x, (id)"))")
    let regex = CardTextMatcher(pattern: #"\d+"#, mode: .regularExpression, matchCase: false)
    expect(regex.ranges(in: "a 12 b 3") == [r(2, 2), r(7, 1)], "regex: matches")
    let bad = CardTextMatcher(pattern: "(", mode: .regularExpression, matchCase: false)
    expect(!bad.isValid && bad.ranges(in: "((") .isEmpty, "regex: invalid matches nothing")
    let empty = CardTextMatcher(pattern: "", mode: .contains, matchCase: false)
    expect(empty.isValid && empty.ranges(in: "abc").isEmpty, "empty pattern: no matches")
    let star = CardTextMatcher(pattern: "x*", mode: .regularExpression, matchCase: false)
    expect(star.ranges(in: "ab") .isEmpty, "regex: empty matches are dropped")
    let emoji = CardTextMatcher(pattern: "ip", mode: .contains, matchCase: false)
    expect(emoji.ranges(in: "🛰️ ip") == [r(4, 2)], "UTF-16 ranges after an emoji", "\(emoji.ranges(in: "🛰️ ip"))")

    // Replacement text
    let literal = CardTextMatcher(pattern: "a", mode: .contains, matchCase: false)
    expect(literal.edits(in: "a", template: "$1\\x").first?.replacement == "$1\\x", "contains: template is literal")
    let groups = CardTextMatcher(pattern: #"(\w+)@(\w+)"#, mode: .regularExpression, matchCase: false)
    expect(CardTextEdits.apply(groups.edits(in: "x a@b y", template: "$2.$1"), to: "x a@b y") == "x b.a y", "regex: $n templates")

    // Replace All across cards
    let cards = [
        EditableCardText(id: "1", sql: "SELECT {{router}} -- router", isLocked: false),
        EditableCardText(id: "2", sql: "SELECT 1", isLocked: false),
        EditableCardText(id: "3", sql: "router router", isLocked: true),
        EditableCardText(id: "4", sql: "WHERE ip = router", isLocked: false),
    ]
    let all = CardTextEdits.replaceAll(in: cards, matcher: CardTextMatcher(pattern: "router", mode: .wholeWord, matchCase: false),
                                       template: "coda_dlink")
    expect(all.cards.map(\.cardId) == ["1", "4"], "replace all: only cards with a match", "\(all.cards.map(\.cardId))")
    expect(all.cards.first?.newSQL == "SELECT {{coda_dlink}} -- coda_dlink", "replace all: every match in a card")
    expect(all.cards.first?.oldSQL == "SELECT {{router}} -- router", "replace all: keeps the old text for undo")
    expect(all.lockedCardsSkipped == 1 && all.editCount == 3, "replace all: locked card skipped and counted",
           "\(all.lockedCardsSkipped) \(all.editCount)")
    let lengthChange = CardTextEdits.replaceAll(in: [EditableCardText(id: "a", sql: "x x x", isLocked: false)],
                                                matcher: CardTextMatcher(pattern: "x", mode: .contains, matchCase: false),
                                                template: "long")
    expect(lengthChange.cards.first?.newSQL == "long long long", "replace all: longer replacement keeps offsets right")

    // Undo: the inverse edit puts the old text back, and applies to the new text
    for edit in all.cards + lengthChange.cards {
        let back = CardTextEdits.inverse(of: edit)
        expect(CardTextEdits.apply(back.edits, to: edit.newSQL) == edit.oldSQL && back.newSQL == edit.oldSQL,
               "inverse: restores card \(edit.cardId)", CardTextEdits.apply(back.edits, to: edit.newSQL))
    }
    let shrink = CardTextEdits.replaceAll(in: [EditableCardText(id: "s", sql: "abc 🛰️ abc abc", isLocked: false)],
                                          matcher: CardTextMatcher(pattern: "abc", mode: .contains, matchCase: false),
                                          template: "")
    if let edit = shrink.cards.first {
        expect(CardTextEdits.apply(CardTextEdits.inverse(of: edit).edits, to: edit.newSQL) == edit.oldSQL,
               "inverse: empty replacement and an emoji")
    } else { expect(false, "inverse: empty replacement planned") }

    // Replace one
    let one = EditableCardText(id: "1", sql: "a b a", isLocked: false)
    let m = CardTextMatcher(pattern: "a", mode: .contains, matchCase: false)
    expect(CardTextEdits.replace(r(4, 1), in: one, matcher: m, template: "z")?.newSQL == "a b z", "replace: the one match")
    expect(CardTextEdits.replace(r(2, 1), in: one, matcher: m, template: "z") == nil, "replace: not a match now")
    expect(CardTextEdits.replace(r(0, 1), in: EditableCardText(id: "1", sql: "a", isLocked: true), matcher: m, template: "z") == nil,
           "replace: locked card refused")

    // Change Variable
    let vars = [
        EditableCardText(id: "1", sql: "WHERE h = {{router}} AND x = {{ router }}", isLocked: false),
        EditableCardText(id: "2", sql: "WHERE {{router_x}} -- router", isLocked: false),
        EditableCardText(id: "3", sql: "{{router}}", isLocked: true),
    ]
    let change = CardTextEdits.changeVariable(in: vars, from: "router", to: "coda_dlink")
    expect(change.cards.map(\.cardId) == ["1"], "change variable: only tokens named router", "\(change.cards.map(\.cardId))")
    expect(change.cards.first?.newSQL == "WHERE h = {{coda_dlink}} AND x = {{coda_dlink}}", "change variable: spaced token too",
           change.cards.first?.newSQL ?? "nil")
    expect(change.lockedCardsSkipped == 1, "change variable: locked version counted")
    expect(CardTextEdits.changeVariable(in: vars, from: "router", to: "router").isEmpty, "change variable: same name is no change")
    expect(CardTextEdits.changeVariable(in: vars, from: "router", to: "bad name").isEmpty, "change variable: invalid name refused")

    if failures > 0 {
        print("\(failures) FAILED")
        exit(1)
    }
    print("ALL PASS")
}
