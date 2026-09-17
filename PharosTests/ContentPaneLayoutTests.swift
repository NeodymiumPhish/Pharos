// Standalone test runner for ContentPaneLayout — the Editor / Results toggles.
import Foundation

var failures = 0
func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

func runTests() {
    let both = ContentPaneLayout.both
    expectTrue(both.editorVisible && both.resultsVisible, "the default shows both areas")
    expectEqual(both.expandState, .normal, "both visible is the normal split")
    expectTrue(both.editorToggleEnabled && both.resultsToggleEnabled, "with both showing, either can be hidden")
    expectEqual(both.editorTooltip, "Hide Editor", "a lit editor toggle offers to hide")
    expectEqual(both.resultsTooltip, "Hide Results", "a lit results toggle offers to hide")

    // Deselect Results → editor fills the pane.
    let editorOnly = both.togglingResults()
    expectEqual(editorOnly, ContentPaneLayout(editorVisible: true, resultsVisible: false), "hiding the results leaves the editor")
    expectEqual(editorOnly.expandState, .editorExpanded, "…which is the editor-expanded split")
    expectTrue(!editorOnly.editorToggleEnabled, "the editor, now the only area, cannot be hidden")
    expectTrue(editorOnly.resultsToggleEnabled, "the results can be brought back")
    expectEqual(editorOnly.resultsTooltip, "Show Results", "an unlit results toggle offers to show")
    expectEqual(editorOnly.togglingEditor(), editorOnly, "pressing the disabled editor toggle changes nothing")
    expectEqual(editorOnly.togglingResults(), both, "pressing Results again restores both")

    // Deselect Editor → results fill the pane.
    let resultsOnly = both.togglingEditor()
    expectEqual(resultsOnly.expandState, .resultsExpanded, "hiding the editor is the results-expanded split")
    expectTrue(!resultsOnly.resultsToggleEnabled, "the results, now the only area, cannot be hidden")
    expectEqual(resultsOnly.togglingResults(), resultsOnly, "pressing the disabled results toggle changes nothing")
    expectEqual(resultsOnly.togglingEditor(), both, "pressing Editor again restores both")
    expectEqual(resultsOnly.editorTooltip, "Show Editor", "an unlit editor toggle offers to show")

    // Round trip with the split state, and the impossible state is clamped.
    for state in [ContentExpandState.normal, .editorExpanded, .resultsExpanded] {
        expectEqual(ContentPaneLayout(state).expandState, state, "\(state) round-trips through the layout")
    }
    expectEqual(ContentPaneLayout(editorVisible: false, resultsVisible: false), both, "both hidden is clamped to both shown")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
