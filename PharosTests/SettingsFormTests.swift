// Standalone tests for SettingsForm — the layout furniture every Settings pane
// is built from. Compiled by scripts/test-settings-form.sh.
//
// What this suite is FOR. `SettingsWindowController.paneSize(for:)` floors every
// pane at `minimumPaneWidth` so the window does not change width between tabs.
// A pane whose form is narrower than that floor is therefore STRETCHED — and
// the grid's label column is `.trailing`, so every point of slack that reaches
// the grid lands in that column and slides the whole form to the right-hand
// edge of the window. That is what the Editor pane looked like, and no
// compiler, and no assertion about colours or titles, can see it. It is only
// visible in laid-out frames, which is what these measure.
import AppKit

private var failures = 0

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String,
                         tolerance: CGFloat = 0.5) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

/// A REAL pane grid, built exactly as the panes build theirs.
///
/// This must not be a view with a fixed width constraint. The first version of
/// this suite used one, it passed, and the Editor pane was still skewed:
/// `NSGridView` hugs horizontally at 249, so it will happily stretch to satisfy
/// any constraint of priority 250 or more, while a required width constraint
/// cannot stretch at all. A fixed-width stand-in tests the wrapper against
/// content that does not behave like the content it actually wraps.
private func makeGrid() -> NSGridView {
    let grid = NSGridView(views: [
        [NSTextField(labelWithString: "Font:"), NSPopUpButton()],
        [NSTextField(labelWithString: "Font Size:"), NSTextField(string: "12")],
        [NSTextField(labelWithString: "Tab Size:"), NSPopUpButton()],
    ])
    SettingsForm.configureGrid(grid)
    return grid
}

private func testNaturalSize() {
    let grid = makeGrid()
    let natural = grid.fittingSize
    let wrapper = SettingsForm.wrap(grid)
    let fitting = wrapper.fittingSize
    // The window's width for a tab comes from this.
    expectClose(fitting.width, natural.width + 40, "fittingSize is the grid plus both insets")
    expectClose(fitting.height, natural.height + 40, "fittingSize height is the grid plus both insets")
}

private func testCentredWhenStretched() {
    let grid = makeGrid()
    let natural = grid.fittingSize.width
    let wrapper = SettingsForm.wrap(grid)
    // What the window actually does: floor the pane at the minimum width.
    let paneWidth = SettingsForm.minimumPaneWidth
    wrapper.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 220)
    wrapper.layoutSubtreeIfNeeded()

    expectTrue(natural < paneWidth - 40, "the fixture really is narrower than the pane floor")
    // THE regression: the grid stretching to fill is what pushed every label
    // into the right-hand side of the window, because column 0 is `.trailing`
    // and took all of the slack.
    expectClose(grid.frame.width, natural, "the grid keeps its natural width, it does not stretch")

    let leftGap = grid.frame.minX
    let rightGap = paneWidth - grid.frame.maxX
    expectClose(leftGap, rightGap, "the slack is split evenly, not dumped on one side")
    expectTrue(leftGap > 20, "the grid is not jammed against the leading inset")
    expectClose(grid.frame.midX, paneWidth / 2, "the grid is centred in the pane")
}

private func testInsetIsAMinimum() {
    let grid = makeGrid()
    let natural = grid.fittingSize.width
    let wrapper = SettingsForm.wrap(grid)
    // Exactly the natural width: the inset must not collapse to nothing.
    wrapper.frame = NSRect(x: 0, y: 0, width: natural + 40, height: 220)
    wrapper.layoutSubtreeIfNeeded()
    expectTrue(grid.frame.minX >= 19.5, "the leading inset holds at the natural width")
    expectTrue(wrapper.frame.width - grid.frame.maxX >= 19.5,
               "the trailing inset holds at the natural width")
}

private func testGridLabelColumnTrailing() {
    // The property that makes the stretch visible, and the one a future edit
    // is most likely to "tidy away".
    let grid = makeGrid()
    expectTrue(grid.column(at: 0).xPlacement == .trailing, "labels are trailing-aligned")
    expectClose(grid.rowSpacing, 8, "row spacing")
    expectClose(grid.columnSpacing, 8, "column spacing")
}

func runTests() {
    testNaturalSize()
    testCentredWhenStretched()
    testInsetIsAMinimum()
    testGridLabelColumnTrailing()

    if failures == 0 { print("\nAll settings form tests passed.") }
    else { print("\n\(failures) failure(s).") ; exit(1) }
}
