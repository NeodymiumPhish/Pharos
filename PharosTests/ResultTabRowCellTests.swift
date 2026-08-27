// Standalone test runner for ResultTabRowCell + ResultTabRowText. Compiled by
// scripts/test-result-tab-row-cell.sh together with DisplayEscape and
// HistoryRowText (both pure — no FFI).
import AppKit

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

/// A cell whose pointer probe answers a value the test controls. A test cannot
/// move the real pointer, and an unhosted cell has no window, so without this
/// the positive case — pointer genuinely over the row through a reload — has no
/// coverage, and reverting the fix to a blind `isHovered = false` would pass.
private final class PointerStubCell: ResultTabRowCell {
    var pointerIsInside = false
    override var isPointerInside: Bool { pointerIsInside }
}

private func makeModel(
    label: String = "L60-81: tcp_udp_sessions",
    counts: String = "46×240",
    isStale: Bool = false
) -> ResultTabRowModel {
    ResultTabRowModel(id: "rt1", label: label, color: .systemBlue, countsText: counts, isStale: isStale)
}

func runTests() {
    // Every AppKit suite in this repo bootstraps the app object first — symbol
    // images and resolved colours need it. Activation is prohibited so the
    // binary stays headless and never steals focus.
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // --- ResultTabRowText ---
    expectEqual(ResultTabRowText.countsText(columnCount: 46, rowCount: 240), "46×240",
                "counts text is cols×rows")
    expectEqual(ResultTabRowText.countsText(columnCount: 3, rowCount: 1200), "3×1,200",
                "row count gets thousands grouping")
    expectEqual(ResultTabRowText.affectedText(rowsAffected: 1), "1 row",
                "one affected row is singular")
    expectEqual(ResultTabRowText.affectedText(rowsAffected: 2500), "2,500 rows",
                "affected rows are grouped and plural")

    // --- ResultTabRowCell ---
    let cell = ResultTabRowCell(frame: NSRect(x: 0, y: 0, width: 220, height: 24))

    // Fresh row.
    cell.configure(model: makeModel(), isActive: false)
    expectEqual(cell.primaryLabel.stringValue, "L60-81: tcp_udp_sessions", "label shown")
    expectEqual(cell.secondaryLabel.stringValue, "46×240", "counts shown")
    expectTrue(cell.closeButton.isHidden, "close hidden when inactive and not hovered")
    expectTrue(cell.primaryLabel.textColor == .labelColor, "fresh label uses labelColor")

    // Active row shows the close button.
    cell.configure(model: makeModel(), isActive: true)
    expectFalse(cell.closeButton.isHidden, "close visible on the active row")

    // Stale row dims label and counts.
    cell.configure(model: makeModel(isStale: true), isActive: false)
    expectTrue(cell.primaryLabel.textColor == .tertiaryLabelColor, "stale label dims")
    expectTrue(cell.secondaryLabel.textColor == .tertiaryLabelColor, "stale counts dim")
    expectEqual(cell.accessibilityLabel() ?? "", "L60-81: tcp_udp_sessions, stale, 46×240",
                "stale state is announced")

    // Recycling: a stale configure followed by a fresh one restores every state.
    cell.configure(model: makeModel(), isActive: false)
    expectTrue(cell.primaryLabel.textColor == .labelColor, "recycled cell restores label color")
    expectEqual(cell.accessibilityLabel() ?? "", "L60-81: tcp_udp_sessions, 46×240",
                "recycled cell drops the stale announcement")

    // `ResultTab.rowModel` yields empty counts for a tab holding neither a
    // query result nor an execute result. The announcement has to end at the
    // label — without the emptiness guard it trails a bare ", ".
    cell.configure(model: makeModel(counts: ""), isActive: false)
    expectEqual(cell.accessibilityLabel() ?? "", "L60-81: tcp_udp_sessions",
                "empty counts are not announced as a trailing comma")

    // The dot colour, asserted on ONE RECYCLED cell so that deleting the
    // assignment cannot pass. WorkspaceHistoryMatchTests.swift:216 records why
    // this shape is required: nothing there read the dot colour, so removing
    // the assignment outright passed the whole suite. Compare two configures
    // and pin both expected values.
    let dotCell = ResultTabRowCell(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    dotCell.configure(model: makeModel(), isActive: false)
    let freshDot = dotCell.dot.layer?.backgroundColor
    dotCell.configure(model: makeModel(isStale: true), isActive: false)
    let staleDot = dotCell.dot.layer?.backgroundColor
    expectTrue(freshDot != nil && staleDot != nil, "the dot is filled on both configures")
    expectTrue(freshDot != staleDot, "the recycled dot changes when the row goes stale")
    expectTrue(freshDot == NSColor.systemBlue.cgColor, "a fresh dot is the row colour at full strength")
    expectTrue(staleDot == NSColor.systemBlue.withAlphaComponent(0.4).cgColor,
               "a stale dot is the row colour at 40%")

    // Close button reports the row it currently shows, not the row it was
    // first configured with — the cell is recycled, so a captured id would
    // close the wrong result.
    var closed: [String] = []
    let closeCell = ResultTabRowCell(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    closeCell.onClose = { closed.append($0) }
    closeCell.configure(model: ResultTabRowModel(id: "first", label: "a", color: .systemBlue, countsText: "", isStale: false), isActive: true)
    closeCell.configure(model: ResultTabRowModel(id: "second", label: "b", color: .systemBlue, countsText: "", isStale: false), isActive: true)
    closeCell.closeButton.performClick(nil)
    expectEqual(closed.joined(separator: ","), "second", "close reports the recycled row's id")

    // Hover must not survive recycling. Drive the real entry point, then hand
    // the cell a different, inactive row — the close button has to go away.
    // `hoverChanged` stands in for `mouseEntered(with:)` because `NSEvent` has
    // no public plain initialiser this test could construct.
    let hoverCell = ResultTabRowCell(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    hoverCell.configure(model: makeModel(), isActive: false)
    hoverCell.hoverChanged(true)
    expectFalse(hoverCell.closeButton.isHidden, "hovering shows the close button")
    hoverCell.configure(model: makeModel(label: "another row"), isActive: false)
    expectTrue(hoverCell.closeButton.isHidden,
               "a recycled row does not inherit the previous row's hover")

    // The positive case the fix exists for: the pointer is genuinely over this
    // row, and a reload reconfigures it. Hover must be re-derived as true, not
    // blindly cleared — a blind clear would hide the close button until the
    // user moved the mouse.
    let stub = PointerStubCell(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    stub.pointerIsInside = true
    stub.configure(model: makeModel(), isActive: false)
    expectFalse(stub.closeButton.isHidden,
                "a reload under a stationary pointer keeps the close button")
    stub.pointerIsInside = false
    stub.configure(model: makeModel(), isActive: false)
    expectTrue(stub.closeButton.isHidden,
               "a reload with the pointer elsewhere clears the close button")

    // Hostile label: escaped exactly once, for display and accessibility both.
    let hostile = "evil\u{202E}label"
    cell.configure(model: makeModel(label: hostile), isActive: false)
    expectEqual(cell.primaryLabel.stringValue, DisplayEscape.escaped(hostile),
                "label is display-escaped")
    expectFalse(cell.primaryLabel.stringValue.contains("\u{202E}"),
                "bidi override does not reach the label")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
