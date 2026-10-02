// Standalone test for CardStackLayout. Compiled by scripts/test-card-stack-layout.sh.
import CoreGraphics
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func card(_ id: String, lineage: String? = nil, version: Int = 1, locked: Bool = false,
                  name: String? = nil, sql: String = "SELECT 1") -> QueryCard {
    var c = QueryCard(id: id, lineageId: lineage, version: version, name: name, sql: sql)
    c.isLocked = locked
    return c
}

/// v1, v2 locked, v3 live of one query, then another card.
private func versioned() -> CardDocument {
    var d = CardDocument(cards: [
        card("a1", lineage: "a", locked: true, name: "Active users"),
        card("a2", lineage: "a", version: 2, locked: true, name: "Active users"),
        card("a3", lineage: "a", version: 3, name: "Active users"),
        card("b", sql: "SELECT * FROM plans"),
    ])
    d.focusedCardId = "b"
    return d
}

private func testItems() {
    let plain = CardDocument(cards: [card("x"), card("y")])
    expect(CardStackLayout.items(plain) == [.card("x"), .card("y"), .addCard], "items: cards then the add button")

    let d = versioned()
    expect(CardStackLayout.items(d) == [.versionGroup(lineageId: "a", cardIds: ["a1", "a2"]), .card("a3"), .card("b"), .addCard],
           "items: older locked versions fold into one row above the live version", "got \(CardStackLayout.items(d))")

    var expanded = d
    expanded.expandedLineages = ["a"]
    expect(CardStackLayout.items(expanded) == [.card("a1"), .card("a2"), .card("a3"), .card("b"), .addCard],
           "items: an expanded query shows every version")

    var shown = d
    shown.displayedCardId = "a1"
    expect(CardStackLayout.items(shown) == [.card("a1"), .versionGroup(lineageId: "a", cardIds: ["a2"]), .card("a3"), .card("b"), .addCard],
           "items: the card whose results are shown never folds", "got \(CardStackLayout.items(shown))")

    // The latest version folds never, even when locked (no live copy yet).
    var lockedLast = CardDocument(cards: [card("p1", lineage: "p", locked: true), card("p2", lineage: "p", version: 2, locked: true)])
    lockedLast.focusedCardId = "p2"
    expect(CardStackLayout.items(lockedLast) == [.versionGroup(lineageId: "p", cardIds: ["p1"]), .card("p2"), .addCard],
           "items: the last version stays open")

    expect(CardStackLayout.items(d, filter: "plans") == [.card("b")], "filter: matches the SQL, no add button")
    expect(CardStackLayout.items(d, filter: "active USERS") == [.card("a1"), .card("a2"), .card("a3")],
           "filter: matches the name, case-insensitive, folded versions included")
    expect(CardStackLayout.items(d, filter: "   ") == CardStackLayout.items(d), "filter: blank is no filter")
}

private func testFrames() {
    let items: [CardStackItem] = [.card("x"), .card("y"), .addCard]
    let heights: [CardStackItem: CGFloat] = [.card("x"): 100, .card("y"): 50, .addCard: 30]
    let frames = CardStackLayout.frames(items, height: { heights[$0]! }, width: 400, spacing: 10, inset: 12)
    expect(frames == [CGRect(x: 12, y: 12, width: 376, height: 100),
                      CGRect(x: 12, y: 122, width: 376, height: 50),
                      CGRect(x: 12, y: 182, width: 376, height: 30)],
           "frames: stacked top down with spacing and insets", "got \(frames)")
    expect(CardStackLayout.contentHeight(frames, inset: 12) == 224, "frames: content height includes the bottom inset")
    expect(CardStackLayout.contentHeight([], inset: 12) == 24, "frames: an empty stack is just the insets")

    expect(CardStackLayout.visibleIndices(frames, visible: CGRect(x: 0, y: 115, width: 400, height: 10)) == 1..<2,
           "visible: only the card in view")
    expect(CardStackLayout.visibleIndices(frames, visible: CGRect(x: 0, y: 0, width: 400, height: 1000)) == 0..<3,
           "visible: everything")
    expect(CardStackLayout.visibleIndices(frames, visible: CGRect(x: 0, y: 500, width: 400, height: 10)).isEmpty,
           "visible: nothing below the end")
}

private func testAnchoredOffset() {
    // A locked v1 appears above the focused card: the focused card must stay
    // where it was on screen.
    let oldItems: [CardStackItem] = [.card("a"), .card("b")]
    let oldFrames = [CGRect(x: 0, y: 0, width: 10, height: 100), CGRect(x: 0, y: 110, width: 10, height: 100)]
    let newItems: [CardStackItem] = [.card("a"), .card("a2"), .card("b")]
    let newFrames = [CGRect(x: 0, y: 0, width: 10, height: 100), CGRect(x: 0, y: 110, width: 10, height: 60),
                     CGRect(x: 0, y: 180, width: 10, height: 100)]
    expect(CardStackLayout.anchoredOffset(oldItems: oldItems, oldFrames: oldFrames, newItems: newItems,
                                          newFrames: newFrames, anchor: .card("b"), oldOffset: 50) == 120,
           "anchor: the offset moves by how far the anchor moved")
    expect(CardStackLayout.anchoredOffset(oldItems: oldItems, oldFrames: oldFrames, newItems: newItems,
                                          newFrames: newFrames, anchor: .card("gone"), oldOffset: 50) == 50,
           "anchor: a missing anchor keeps the offset")
    expect(CardStackLayout.anchoredOffset(oldItems: newItems, oldFrames: newFrames, newItems: oldItems,
                                          newFrames: oldFrames, anchor: .card("b"), oldOffset: 20) == 0,
           "anchor: never scrolls above the top")
}

func runTests() {
    testItems()
    testFrames()
    testAnchoredOffset()
    if failures == 0 { print("\nAll CardStackLayout tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
