// Standalone test runner for TagFunnel. Compiled by scripts/test-tag-funnel.sh.
import Foundation

var failures = 0

func expect(_ ok: Bool, _ name: String) {
    if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    let red = "label-red"

    expect(TagFunnel.passes(labelId: red, allowed: [red]),
           "a row with an allowed label passes")
    expect(!TagFunnel.passes(labelId: "label-blue", allowed: [red]),
           "a row with another label is hidden")
    expect(!TagFunnel.passes(labelId: nil, allowed: [red]),
           "an untagged row is hidden when only labels are allowed")
    expect(TagFunnel.passes(labelId: nil, allowed: [TagFunnel.untaggedValue]),
           "Untagged admits the untagged row")
    expect(!TagFunnel.passes(labelId: red, allowed: [TagFunnel.untaggedValue]),
           "Untagged alone hides every tagged row — even with force-show on, by design")
    expect(TagFunnel.passes(labelId: red, allowed: [red, TagFunnel.untaggedValue]),
           "a mixed selection admits both")

    expect(TagFunnel.isTagFilter(columnId: "__rownum__"), "the reserved id is recognised")
    expect(!TagFunnel.isTagFilter(columnId: "col_0"), "a data column is not")

    // The sentinel is the shared blanks sentinel, so the popover layer never
    // needs a second special value.
    expect(TagFunnel.untaggedValue == ColumnFilter.blanksSentinel,
           "Untagged rides the existing blanks sentinel")

    if failures == 0 { print("\nAll TagFunnel tests passed.") }
    else { print("\n\(failures) failure(s)."); exit(1) }
}
