// Standalone test runner for FoldState. Not part of the app target —
// compiled together with the implementation by scripts/test-fold-state.sh.
//
// The one behaviour worth pinning: `adjustForEdit` REPORTS the ranges of the
// folds it removes. `SQLTextView.invalidateFoldLayout(revealing:)` needs them
// to un-suppress those glyphs; before it had them, unfolding one of two folds
// left the unfolded text hidden until a full relayout.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

func runTests() {
    // Two folds: [10, 20) and [40, 50).
    let state = FoldState()
    let first = state.add(range: NSRange(location: 10, length: 10), placeholder: "a")
    let second = state.add(range: NSRange(location: 40, length: 10), placeholder: "b")

    // Removing by id returns the entry, and the other fold stays.
    let removed = state.remove(id: first.id)
    expect(removed?.range == NSRange(location: 10, length: 10), "remove(id:) returns the removed entry")
    expect(state.foldedCharacterRanges == [NSRange(location: 40, length: 10)],
           "remove(id:) leaves the other fold in place")

    // An edit that does not touch a fold removes nothing and shifts later folds.
    var reported = state.adjustForEdit(editedRange: NSRange(location: 0, length: 0), changeInLength: 5)
    expect(reported.isEmpty, "an edit before every fold removes none", "reported \(reported)")
    expect(state.foldedCharacterRanges == [NSRange(location: 45, length: 10)],
           "an insertion before a fold shifts it by the change in length",
           "got \(state.foldedCharacterRanges)")

    // An edit inside a fold removes it and REPORTS its (pre-edit) range.
    reported = state.adjustForEdit(editedRange: NSRange(location: 47, length: 1), changeInLength: -1)
    expect(reported == [NSRange(location: 45, length: 10)],
           "an edit inside a fold reports the removed fold's range", "reported \(reported)")
    expect(state.entries.isEmpty, "the edited fold is gone")

    // An edit spanning two folds reports both.
    let s2 = FoldState()
    s2.add(range: NSRange(location: 10, length: 10), placeholder: "a")
    s2.add(range: NSRange(location: 40, length: 10), placeholder: "b")
    s2.add(range: NSRange(location: 80, length: 10), placeholder: "c")
    reported = s2.adjustForEdit(editedRange: NSRange(location: 15, length: 30), changeInLength: -30)
    expect(Set(reported.map(\.location)) == Set([10, 40]),
           "an edit spanning two folds reports both", "reported \(reported)")
    expect(s2.foldedCharacterRanges == [NSRange(location: 50, length: 10)],
           "the fold after the edit shifts back by the removed length", "got \(s2.foldedCharacterRanges)")

    // A fold that merely touches the edit boundary is NOT removed.
    let s3 = FoldState()
    s3.add(range: NSRange(location: 10, length: 10), placeholder: "a")
    reported = s3.adjustForEdit(editedRange: NSRange(location: 20, length: 0), changeInLength: 3)
    expect(reported.isEmpty && s3.foldedCharacterRanges == [NSRange(location: 10, length: 10)],
           "an insertion at a fold's end leaves the fold untouched", "reported \(reported), got \(s3.foldedCharacterRanges)")

    _ = second
    if failures == 0 { print("\nAll FoldState tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
