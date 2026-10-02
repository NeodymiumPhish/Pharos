// Standalone test for CardResultEviction.
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
    testEviction()
    if failures == 0 { print("\nAll CardResultStore tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
