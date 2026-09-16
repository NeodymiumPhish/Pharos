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

/// A form the size a real pane's grid is: narrower than the 540 pt floor.
private func makeContent(width: CGFloat = 300, height: CGFloat = 120) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        v.widthAnchor.constraint(equalToConstant: width),
        v.heightAnchor.constraint(equalToConstant: height),
    ])
    return v
}

private func testNaturalSize() {
    let content = makeContent()
    let wrapper = SettingsForm.wrap(content)
    let fitting = wrapper.fittingSize
    // The window's width for a tab comes from this, so the breakable side
    // insets must still hold at the natural size.
    expectClose(fitting.width, 300 + 40, "fittingSize is the content plus both insets")
    expectClose(fitting.height, 120 + 40, "fittingSize height is the content plus both insets")
}

private func testCentredWhenStretched() {
    let content = makeContent()
    let wrapper = SettingsForm.wrap(content)
    // What the window actually does: floor the pane at the minimum width.
    let paneWidth = SettingsForm.minimumPaneWidth
    wrapper.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 200)
    wrapper.layoutSubtreeIfNeeded()

    let leftGap = content.frame.minX
    let rightGap = paneWidth - content.frame.maxX
    expectClose(content.frame.width, 300, "the content keeps its natural width")
    expectClose(leftGap, rightGap, "the slack is split evenly, not dumped on one side")
    // The regression itself: all the slack on the left is the right-shifted form.
    expectTrue(leftGap > 20, "the content is not jammed against the leading inset")
    expectClose(content.frame.midX, paneWidth / 2, "the content is centred in the pane")
}

private func testInsetIsAMinimum() {
    let content = makeContent(width: 300)
    let wrapper = SettingsForm.wrap(content)
    // Narrower than the content wants: the inset must not collapse to nothing.
    wrapper.frame = NSRect(x: 0, y: 0, width: 300 + 40, height: 200)
    wrapper.layoutSubtreeIfNeeded()
    expectTrue(content.frame.minX >= 19.5, "the leading inset holds at the natural width")
    expectTrue(wrapper.frame.width - content.frame.maxX >= 19.5,
               "the trailing inset holds at the natural width")
}

private func testGridLabelColumnTrailing() {
    // The property that makes the stretch visible, and the one a future edit
    // is most likely to "tidy away".
    let grid = NSGridView(views: [[NSTextField(labelWithString: "Font"), NSPopUpButton()]])
    SettingsForm.configureGrid(grid)
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
