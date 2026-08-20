// Standalone test runner for ColumnFilterPopoverVC's main stack geometry. Uses
// real AppKit: the popover's view is hosted in a headless, never-shown NSWindow
// so Auto Layout runs. Compiled by scripts/test-filter-popover-layout.sh.
//
// Separate from scripts/test-filter-popover-sizing.sh, which exercises the pure
// `FilterPopoverSizing` clamps and compiles nothing else — only one `runTests()`
// can exist per binary.
//
// What this suite is FOR: the popover asked for `alignment = .width`, which
// NSStackView rejects, and the partial-data footer — the only row here narrow
// enough to give it away — sat three-quarters of the way across the popover
// instead of at the leading edge with everything else. The rest of the rows
// stretch on their own, so nothing else looked wrong.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

/// The popover's main vertical stack — the one holding all seven rows.
/// `loadView` keeps it to itself, so it is found by shape rather than exposed.
private func mainStack(in view: NSView) -> NSStackView? {
    func walk(_ v: NSView) -> NSStackView? {
        for sub in v.subviews {
            if let stack = sub as? NSStackView, stack.orientation == .vertical,
               stack.arrangedSubviews.count == 7 {
                return stack
            }
            if let found = walk(sub) { return found }
        }
        return nil
    }
    return walk(view)
}

private func popover(hasMore: Bool, existing: ColumnFilter?) -> ColumnFilterPopoverVC {
    let vc = ColumnFilterPopoverVC(
        columnName: "name", displayName: "name", category: .string, dataType: "text",
        existingFilter: existing, distinctValues: ["alpha", "beta", "gamma"], hasBlanks: true,
        referenceSize: CGSize(width: 900, height: 600),
        counts: [:], loadedRowCount: 1234, hasMore: hasMore)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = vc.view
    vc.view.layoutSubtreeIfNeeded()
    return vc
}

/// The 12pt side padding the stack carries as `edgeInsets`. Every row starts
/// here, and no row may be wider than the popover minus both sides.
private let sideInset: CGFloat = 12

func runTests() {
    // MARK: the partial-data footer, which is the row that drifted

    let vc = popover(hasMore: true, existing: nil)
    guard let stack = mainStack(in: vc.view) else {
        print("FAIL the popover's main stack is reachable from its view")
        print("\n1 FAILURE(S)")
        exit(1)
    }

    expectTrue(stack.alignment == .leading,
               "the main stack asks for an alignment NSStackView accepts")
    expectTrue(stack.arrangedSubviews.count == 7,
               "the main stack holds the seven rows the span reached")

    // Measured on alignment rects, not frames: an NSTextField label's frame
    // overhangs its alignment rect by 2pt each side.
    let visible = stack.arrangedSubviews.filter { !$0.isHidden }
    let rects = visible.map { $0.alignmentRect(forFrame: $0.frame) }
    expectTrue(rects.allSatisfy { abs($0.minX - sideInset) < 0.5 },
               "every visible row starts at the padded leading edge (\(rects.map { Int($0.minX) }))")

    let rowWidth = stack.frame.width - sideInset * 2
    expectTrue(rects.allSatisfy { abs($0.width - rowWidth) < 0.5 },
               "and every visible row spans that width, not the stack's (\(rects.map { Int($0.width) }) of \(Int(rowWidth)))")

    // The padding is the half of this that a naive full-width pin destroys:
    // pinned to the stack's own width instead, each row would run to x=0 and
    // the popover's content would touch its edges.
    expectTrue(rects.allSatisfy { $0.minX > 0 },
               "the stack's own side padding survives the span")

    // The footer specifically — it is the only row narrow enough on its own to
    // have shown the drift, so name it rather than trusting the sweep above.
    let footer = stack.arrangedSubviews[3]
    expectTrue(!footer.isHidden, "the partial-data footer shows when rows are unfetched")
    expectTrue(abs(footer.alignmentRect(forFrame: footer.frame).minX - sideInset) < 0.5,
               "the partial-data footer starts at the leading edge, not part-way across")

    // MARK: the advanced area, which is hidden until the disclosure opens

    let expanded = popover(hasMore: false,
                           existing: ColumnFilter(columnName: "name", op: .contains, value: "a",
                                                      value2: nil, values: nil, dataType: "text"))
    guard let expandedStack = mainStack(in: expanded.view) else {
        print("FAIL the expanded popover's main stack is reachable")
        print("\n\(failures + 1) FAILURE(S)")
        exit(1)
    }
    let advanced = expandedStack.arrangedSubviews[5]
    expectTrue(!advanced.isHidden, "an existing advanced filter opens the advanced area")
    expectTrue(abs(advanced.alignmentRect(forFrame: advanced.frame).minX - sideInset) < 0.5,
               "the advanced area starts at the same leading edge as the rest")

    // MARK: hostile text in the value list — drawn side and measured side together

    // A value's checkbox title is escaped, the search label stays raw, and the
    // popover is sized from the ESCAPED text — otherwise the disclosure just
    // added is the first thing truncated away.
    do {
        let hostile = "10.0.0\u{00A0}.1"
        let list = FilterValueListView(frame: .zero)
        list.setValues([hostile], checked: [hostile])

        expectTrue(list.escapedLabel(for: hostile).contains("<U+00A0>"),
                   "the checkbox title discloses a non-breaking space")
        expectTrue(list.displayLabel(for: hostile) == hostile,
                   "the search label stays raw so typing the real value still matches")
        let font = NSFont.systemFont(ofSize: 12)
        let escapedWidth = (list.escapedLabel(for: hostile) as NSString)
            .size(withAttributes: [.font: font]).width
        expectTrue(list.maxValueWidth(font: font) >= escapedWidth,
                   "the popover is measured from the escaped text, not the raw text")
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
