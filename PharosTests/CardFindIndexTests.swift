// Standalone test for CardFindIndex (find across cards). Compiled by
// scripts/test-card-find-index.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

func runTests() {
    let index = CardFindIndex(cards: [("a", "SELECT 1"), ("b", "café"), ("c", "")])
    expect(index.text == "SELECT 1\ncafé\n", "text: cards joined by a newline", index.text)
    expect(index.segments.map(\.range) == [NSRange(location: 0, length: 8), NSRange(location: 9, length: 4), NSRange(location: 14, length: 0)],
           "segments: UTF-16 ranges, one separator between", "\(index.segments)")
    expect(index.segment(at: 8)?.cardId == "a", "segment: the separator belongs to the card before")
    expect(index.segment(at: 9)?.cardId == "b", "segment: a card's first character")
    expect(index.segment(at: 14)?.cardId == "c" && index.segment(at: 99)?.cardId == "c", "segment: the end belongs to the last card")
    let local = index.local(NSRange(location: 10, length: 2))
    expect(local?.cardId == "b" && local?.range == NSRange(location: 1, length: 2), "local: a match in card b")
    expect(index.local(NSRange(location: 6, length: 5)) == nil, "local: a range across cards is refused")
    expect(index.global(cardId: "b", NSRange(location: 1, length: 2)) == NSRange(location: 10, length: 2), "global: back again")
    expect(index.global(cardId: "b", NSRange(location: 3, length: 9)) == NSRange(location: 12, length: 1), "global: clamped to the card")
    expect(index.global(cardId: "z", NSRange(location: 0, length: 0)) == nil, "global: unknown card")
    let empty = CardFindIndex(cards: [])
    expect(empty.text.isEmpty && empty.segment(at: 0) == nil, "empty: no cards, no segments")
    // "SELECT" occurs in both cards: a search over `text` finds both, each inside one card.
    let two = CardFindIndex(cards: [("a", "SELECT x"), ("b", "select y")])
    var ranges: [NSRange] = []
    var from = 0
    let ns = two.text as NSString
    while true {
        let r = ns.range(of: "select", options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
        if r.location == NSNotFound { break }
        ranges.append(r); from = NSMaxRange(r)
    }
    expect(ranges.compactMap { two.local($0)?.cardId } == ["a", "b"], "search: one match per card, each local")
    if failures == 0 { print("\nAll card find index tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
