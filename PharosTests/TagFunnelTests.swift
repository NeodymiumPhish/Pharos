// Standalone test runner for TagFunnel. Compiled by scripts/test-tag-funnel.sh.
import Foundation

var failures = 0

func expect(_ ok: Bool, _ name: String) {
    if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    let red = "tag-red"

    expect(TagFunnel.passes(tagIds: [red], allowed: [red]),
           "a row with an allowed tag passes")
    expect(!TagFunnel.passes(tagIds: ["tag-blue"], allowed: [red]),
           "a row with another tag is hidden")
    expect(!TagFunnel.passes(tagIds: [], allowed: [red]),
           "an untagged row is hidden when only tags are allowed")
    expect(TagFunnel.passes(tagIds: [], allowed: [TagFunnel.untaggedValue]),
           "Untagged admits the untagged row")
    expect(!TagFunnel.passes(tagIds: [red], allowed: [TagFunnel.untaggedValue]),
           "Untagged alone hides every tagged row — even with force-show on, by design")
    expect(TagFunnel.passes(tagIds: [red], allowed: [red, TagFunnel.untaggedValue]),
           "a mixed selection admits both")

    // A row belongs to two cases. ANY checked tag shows it, because the funnel
    // answers "show me this case", and this row is in both.
    expect(TagFunnel.passes(tagIds: ["a", "b"], allowed: ["b"]),
           "the second tag alone admits the row")
    expect(!TagFunnel.passes(tagIds: ["a", "b"], allowed: ["c"]),
           "no checked tag, no row")
    expect(!TagFunnel.passes(tagIds: ["a", "b"], allowed: [TagFunnel.untaggedValue]),
           "a tagged row is not Untagged, whatever it carries")
    expect(TagFunnel.passes(tagIds: [], allowed: [TagFunnel.untaggedValue]),
           "no tag at any state means Untagged")

    expect(TagFunnel.isTagFilter(columnId: "__rownum__"), "the reserved id is recognised")
    expect(!TagFunnel.isTagFilter(columnId: "col_0"), "a data column is not")

    // The sentinel is the shared blanks sentinel, so the popover layer never
    // needs a second special value.
    expect(TagFunnel.untaggedValue == ColumnFilter.blanksSentinel,
           "Untagged rides the existing blanks sentinel")

    if failures == 0 { print("\nAll TagFunnel tests passed.") }
    else { print("\n\(failures) failure(s)."); exit(1) }
}
