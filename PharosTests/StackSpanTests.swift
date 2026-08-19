// Standalone test runner for NSStackView.spanArrangedSubviewsFullWidth, the
// layout rule the tag sheets share. Uses real AppKit: the stacks are laid out
// in a real view so the assertions read measured frames, not intentions.
// Compiled with the implementation by scripts/test-stack-span.sh.
//
// What this suite is FOR: `NSStackView` accepts `alignment = .width` and
// silently discards it, so a stack written that way is not aligned at all and
// each row's width is left to the solver. The bug that came out of it —
// identical rows starting at different offsets in `TagRemovalSheet` — was
// invisible in review because the code SAID the right thing. Three states are
// measured here so the rule cannot be argued about again: the rejected
// alignment, `.leading` on its own, and `.leading` with the span. A fourth
// case measures the span on a stack that pads its own sides, where "the
// stack's width" and "the width a row may take" are not the same number.
//
// The two sheets whose latent copies of the defect this fixes (TagSheet,
// TagManageSheet) cannot be hosted here — both reach TagStore.shared, which is
// @MainActor and Keychain-bound through the FFI. What they call is this
// helper. `scripts/test-tag-removal-sheet.sh` measures the third caller's real
// list.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private let hostWidth: CGFloat = 400

/// A vertical stack of rows that HUG their content, laid out at a known width.
///
/// The hugging is the whole point of the fixture. A row that would fill the
/// stack anyway hides this defect completely — which is exactly why the two
/// other sheets looked correct while carrying it — so each row here insists on
/// being narrower than the stack unless something holds it open, and the four
/// rows insist on four different widths so a drift cannot look uniform.
private func laidOutStack(alignment: NSLayoutConstraint.Attribute,
                          span: Bool) -> (stack: NSStackView, rows: [NSView]) {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = 4

    for index in 0..<4 {
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: CGFloat(60 + index * 20)).isActive = true
        content.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let row = NSStackView(views: [box, content])
        row.orientation = .horizontal
        row.setHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(row)
    }
    if span { stack.spanArrangedSubviewsFullWidth() }

    let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidth, height: 300))
    stack.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        stack.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    host.layoutSubtreeIfNeeded()
    return (stack, stack.arrangedSubviews)
}

func runTests() {

    // MARK: - 1. The root cause, stated as a measurement

    do {
        // The reason every one of these call sites was written wrong: the
        // assignment compiles, reads plausibly, and is thrown away. A stored
        // note in this repo asserted the opposite and cost a shipped bug, so
        // the answer is measured here rather than believed.
        let vertical = NSStackView()
        vertical.orientation = .vertical
        vertical.alignment = .width
        expectEqual(vertical.alignment, .notAnAttribute,
                    "a vertical stack silently discards .width — it is NOT an alignment")
        vertical.alignment = .leading
        expectEqual(vertical.alignment, .leading, "and it keeps .leading, which is one")
    }

    // MARK: - 2. What the discarded alignment costs

    do {
        let broken = laidOutStack(alignment: .width, span: false)
        expectEqual(broken.rows.count, 4, "the fixture has four rows")
        let edges = broken.rows.map { Int($0.frame.minX) }
        expectTrue(Set(edges).count > 1,
                   "with .width the rows start at DIFFERENT offsets (\(edges))")
        expectTrue((broken.rows.map(\.frame.minX).max() ?? 0) > 100,
                   "and they are pushed right, because the trailing edge constraint outranks the leading one (\(edges))")
        expectTrue(broken.rows.allSatisfy { $0.frame.width < hostWidth },
                   "each row hugging its own content, none of them the stack's width (\(broken.rows.map { Int($0.frame.width) }))")
    }

    // MARK: - 3. `.leading` alone fixes the edge, not the width

    do {
        // Worth measuring separately: it is the half-fix somebody reaching for
        // the quickest change would stop at, and it leaves every row a
        // different width — so anything that has to line up on the trailing
        // side, or any row background, would still be wrong.
        let aligned = laidOutStack(alignment: .leading, span: false)
        let edges = aligned.rows.map { Int($0.frame.minX) }
        expectTrue(Set(edges) == [0], "with .leading every row starts at the stack's edge (\(edges))")
        expectTrue(aligned.rows.contains { $0.frame.width < hostWidth - 1 },
                   "but the rows still hug, at their own widths (\(aligned.rows.map { Int($0.frame.width) }))")
    }

    // MARK: - 4. `.leading` plus the span, which is what the sheets do

    do {
        let fixed = laidOutStack(alignment: .leading, span: true)
        let edges = fixed.rows.map { Int($0.frame.minX) }
        expectTrue(Set(edges) == [0], "every row starts at one leading edge (\(edges))")
        expectTrue(fixed.rows.allSatisfy { abs($0.frame.width - fixed.stack.frame.width) < 0.5 },
                   "and every row is the stack's width (\(fixed.rows.map { Int($0.frame.width) }) of \(Int(fixed.stack.frame.width)))")
        // The checkbox is the control the hand goes to, so its edge is where a
        // misalignment is felt. It sits inside a row that is now the full
        // width, so it can only be at the row's start.
        let boxes = fixed.rows.compactMap { row in
            (row as? NSStackView)?.arrangedSubviews.first
        }
        expectEqual(boxes.count, 4, "each row's first control is measurable")
        let boxEdges = boxes.map { Int($0.convert($0.bounds, to: fixed.stack).minX) }
        expectTrue(Set(boxEdges).count == 1,
                   "so every checkbox sits at one leading edge too (\(boxEdges))")
    }

    // MARK: - 5. The span constrains what is there when it runs

    do {
        // The ordering rule the callers depend on, and the one a later edit is
        // most likely to break: TagSheet spans its column list AFTER building
        // the rows. A row added afterwards is simply not held.
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        let early = NSStackView(views: [NSButton(checkboxWithTitle: "", target: nil, action: nil)])
        early.setHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(early)
        stack.spanArrangedSubviewsFullWidth()
        let late = NSStackView(views: [NSButton(checkboxWithTitle: "", target: nil, action: nil)])
        late.setHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(late)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidth, height: 200))
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        expectTrue(abs(early.frame.width - stack.frame.width) < 0.5,
                   "the row present at the call is held at the stack's width (\(Int(early.frame.width)))")
        expectTrue(late.frame.width < stack.frame.width,
                   "a row added after it is not (\(Int(late.frame.width)) of \(Int(stack.frame.width))) — call it last")
        // And the reason `alignment = .leading` is still worth setting even
        // though the pin decides the width of every row it reached: it is what
        // governs a row the pin did NOT reach.
        expectTrue(abs(late.frame.minX) < 0.5,
                   "the unheld row still starts at the leading edge, because the alignment is .leading (\(Int(late.frame.minX)))")
    }

    // MARK: - 6. A stack that pads its own sides keeps its padding

    do {
        // The pin means "as wide as a row may be", not "as wide as the stack".
        // On a padded stack those differ, and pinning to the raw width anchor
        // widens every row over its own padding — the content then runs to the
        // container's edge. `ColumnFilterPopoverVC` pads 12pt each side.
        let inset: CGFloat = 12
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        // A row that hugs, so only the pin can make it span.
        let row = NSStackView(views: [NSButton(checkboxWithTitle: "", target: nil, action: nil)])
        row.setHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(row)
        stack.spanArrangedSubviewsFullWidth()

        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidth, height: 200))
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        expectTrue(abs(row.frame.minX - inset) < 0.5,
                   "a padded stack still starts its rows inside the padding (\(Int(row.frame.minX)) of \(Int(inset)))")
        expectTrue(abs(row.frame.width - (stack.frame.width - inset * 2)) < 0.5,
                   "and the row spans the padded width, not the stack's (\(Int(row.frame.width)) of \(Int(stack.frame.width - inset * 2)))")
    }

    if failures == 0 {
        print("\nAll stack span tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
