// Standalone test for CardKeyedStore and CardResultEviction.
// Compiled by scripts/test-card-result-store.sh.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func testStore() {
    var s = CardKeyedStore<String>()
    s.deposit("a1", cardId: "a", tabId: "t1")
    s.deposit("b1", cardId: "b", tabId: "t1")
    s.deposit("x1", cardId: "x", tabId: "t2")
    expect(s.value(for: "a") == "a1" && s.value(for: "x") == "x1", "store: values by card")
    expect(s.cardIds(inTab: "t1") == ["a", "b"], "store: a tab's cards, oldest result first")
    s.deposit("a2", cardId: "a", tabId: "t1")
    expect(s.value(for: "a") == "a2", "store: a new result replaces the card's old one")
    expect(s.cardIds(inTab: "t1") == ["b", "a"], "store: and counts as the newest", "got \(s.cardIds(inTab: "t1"))")
    s.update(cardId: "b") { $0 += "!" }
    expect(s.value(for: "b") == "b1!", "store: update in place")
    s.update(cardId: "missing") { $0 = "never" }
    expect(s.value(for: "missing") == nil, "store: updating a missing card adds nothing")
    expect(s.remove(cardId: "b") == "b1!" && s.value(for: "b") == nil, "store: remove returns the value")
    s.prune(keepingTabs: ["t1"])
    expect(s.value(for: "x") == nil && s.value(for: "a") == "a2", "store: prune drops closed tabs' results")
    expect(s.tabId(of: "a") == "t1", "store: the owning tab of a card")
}

private func held(_ id: String, _ order: Int, viewed: Bool = false, displayed: Bool = false, pinned: Bool = false) -> CardResultEviction.Candidate {
    .init(cardId: id, order: order, hasBeenViewed: viewed, isDisplayed: displayed, isPinned: pinned)
}

private func testEviction() {
    let three = [held("a", 0), held("b", 1), held("c", 2)]
    expect(CardResultEviction.toEvict(three, limit: 0).isEmpty, "evict: 0 means no limit")
    expect(CardResultEviction.toEvict(three, limit: 3).isEmpty, "evict: at the limit nothing goes")
    expect(CardResultEviction.toEvict(three, limit: 2) == ["a"], "evict: over the limit the oldest goes")
    expect(CardResultEviction.toEvict(three, limit: 1) == ["a", "b"], "evict: as many as needed, oldest first")
    let guarded = [held("a", 0, viewed: true), held("b", 1, displayed: true), held("c", 2, pinned: true), held("d", 3)]
    expect(CardResultEviction.toEvict(guarded, limit: 2) == ["d"], "evict: viewed, displayed and pinned results are kept")
    let allViewed = [held("a", 0, viewed: true), held("b", 1, viewed: true)]
    expect(CardResultEviction.toEvict(allViewed, limit: 1).isEmpty, "evict: when only viewed results are left, the tab goes over the limit")
    let unordered = [held("c", 9), held("a", 2), held("b", 5)]
    expect(CardResultEviction.toEvict(unordered, limit: 1) == ["a", "b"], "evict: order is by result age, not array order")
}

func runTests() {
    testStore()
    testEviction()
    if failures == 0 { print("\nAll CardResultStore tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
