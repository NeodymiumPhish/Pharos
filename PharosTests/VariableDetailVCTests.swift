// Standalone test runner for VariableDetailVC — no Xcode project or test
// target involvement. Measures real AppKit geometry (Auto Layout, hit-testing,
// resolved colours, text-view round-tripping) inside a headless, never-shown
// NSWindow, the same technique VariableRowLayoutTests.swift uses for the list
// level. This is a separate binary (own `runTests()`) rather than appended to
// that file, since only one `runTests()` can exist per compiled binary.
//
// Compiled with VariableDetailVC.swift, VariableValueTextView.swift,
// VariableSubstitutor.swift, VariableValuePreview.swift, QueryVariable.swift,
// PulseClock.swift, SQLSegmentParser.swift, SQLFoldingParser.swift,
// SQLLexer.swift and LineNumberGutter.swift by
// scripts/test-variable-detail-vc.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.5, _ name: String) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

// MARK: - Harness helpers

/// A borderless, never-shown window hosting `vc.view` at a fixed size. As in
/// `VariableRowLayoutTests`, a window is required for Auto Layout to actually
/// run — an unhosted view never resolves its constraints.
private func makeHostedDetail(
    width: CGFloat, height: CGFloat = 400, variable: QueryVariable
) -> (window: NSWindow, container: NSView, vc: VariableDetailVC) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = container
    let vc = VariableDetailVC(variable: variable)
    vc.view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(vc.view)
    NSLayoutConstraint.activate([
        vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        vc.view.topAnchor.constraint(equalTo: container.topAnchor),
        vc.view.widthAnchor.constraint(equalToConstant: width),
        vc.view.heightAnchor.constraint(equalToConstant: height),
    ])
    container.layoutSubtreeIfNeeded()

    // Measured directly: `editorContainer`'s defaultLow vertical hugging
    // inside `body` (an NSStackView) is not fully resolved by this first
    // layoutSubtreeIfNeeded() call — the gutter/scrollView frames `viewDidLayout`
    // computes from `editorContainer.bounds` come out zero-height. This is not
    // a code defect: a live window's own run loop settles the same geometry
    // within milliseconds with no code involved (proven by spinning
    // RunLoop.main briefly here instead of forcing a second pass — it produces
    // the identical final frames). A headless harness that never spins the run
    // loop has to force that follow-up pass explicitly to read genuinely-final
    // geometry, or every measurement below the editor container would be
    // reading first-pass, not settled, layout.
    vc.view.needsLayout = true
    container.layoutSubtreeIfNeeded()

    return (window, container, vc)
}

/// Hosts the VC with only its width pinned — no height constraint — so
/// `vc.view.fittingSize` reflects the minimum height Auto Layout actually
/// needs for this content, rather than whatever fixed height a test harness
/// forces on it. Used only for the Bool-vs-Literal height comparison; every
/// other test in this file needs a concrete, pinned height to measure real
/// geometry inside.
private func makeHostedDetailForFittingSize(
    width: CGFloat, variable: QueryVariable
) -> (window: NSWindow, container: NSView, vc: VariableDetailVC) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
    window.contentView = container
    let vc = VariableDetailVC(variable: variable)
    vc.view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(vc.view)
    NSLayoutConstraint.activate([
        vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        vc.view.topAnchor.constraint(equalTo: container.topAnchor),
        vc.view.widthAnchor.constraint(equalToConstant: width),
    ])
    container.layoutSubtreeIfNeeded()
    vc.view.needsLayout = true
    container.layoutSubtreeIfNeeded()
    return (window, container, vc)
}

private func hasAmbiguousLayoutRecursively(_ view: NSView) -> Bool {
    if view.hasAmbiguousLayout { return true }
    return view.subviews.contains { hasAmbiguousLayoutRecursively($0) }
}

private func allDescendants(of view: NSView) -> [NSView] {
    var result: [NSView] = []
    for sub in view.subviews {
        result.append(sub)
        result.append(contentsOf: allDescendants(of: sub))
    }
    return result
}

/// `VariableDetailVC` exposes nothing test-visible beyond its view hierarchy
/// (all its controls are `private`), so — mirroring how
/// `VariableRowLayoutTests` locates `VariableListView`'s internals — these
/// helpers walk the public `subviews` tree instead of reaching into private
/// stored properties.

/// The only editable `NSTextField` in the tree: `nameField` is a plain,
/// input-configured `NSTextField()`. `captionLabel` and `duplicationLabel` are
/// both built with `NSTextField(labelWithString:)`, which is not editable —
/// that is the discriminator, not view order or text content.
private func nameField(in vc: VariableDetailVC) -> NSTextField {
    allDescendants(of: vc.view).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
}

private func typePopup(in vc: VariableDetailVC) -> NSPopUpButton {
    allDescendants(of: vc.view).compactMap { $0 as? NSPopUpButton }.first!
}

private func backButton(in vc: VariableDetailVC) -> NSButton {
    allDescendants(of: vc.view).compactMap { $0 as? NSButton }
        .first { !($0 is NSPopUpButton) && $0.toolTip == "Back to variables" }!
}

private func deleteButton(in vc: VariableDetailVC) -> NSButton {
    allDescendants(of: vc.view).compactMap { $0 as? NSButton }
        .first { !($0 is NSPopUpButton) && $0.toolTip == "Delete variable" }!
}

private func headerStack(in vc: VariableDetailVC) -> NSStackView {
    allDescendants(of: vc.view).compactMap { $0 as? NSStackView }.first { $0.orientation == .horizontal }!
}

private func bodyStack(in vc: VariableDetailVC) -> NSStackView {
    allDescendants(of: vc.view).compactMap { $0 as? NSStackView }.first { $0.orientation == .vertical }!
}

/// `body`'s arranged subviews are always `[duplicationLabel, editorContainer,
/// captionLabel]`, in that fixed order — positional lookup is safe here.
private func duplicationLabel(in vc: VariableDetailVC) -> NSTextField {
    bodyStack(in: vc).arrangedSubviews[0] as! NSTextField
}

private func editorContainer(in vc: VariableDetailVC) -> NSView {
    bodyStack(in: vc).arrangedSubviews[1]
}

private func captionLabel(in vc: VariableDetailVC) -> NSTextField {
    bodyStack(in: vc).arrangedSubviews[2] as! NSTextField
}

/// The separator is a private, file-scoped type (`HairlineView`, mirroring
/// `VariableListView`'s own private hairline), so it cannot be looked up by
/// concrete type from this file. It is identified structurally instead: of
/// `vc.view`'s three direct subviews (`header`, `headerSeparator`, `body`),
/// it is the only one that is not an `NSStackView`.
private func headerSeparatorView(in vc: VariableDetailVC) -> NSView {
    vc.view.subviews.first { !($0 is NSStackView) }!
}

private func gutterView(in vc: VariableDetailVC) -> LineNumberGutter {
    allDescendants(of: vc.view).compactMap { $0 as? LineNumberGutter }.first!
}

private func scrollView(in vc: VariableDetailVC) -> NSScrollView {
    allDescendants(of: vc.view).compactMap { $0 as? NSScrollView }.first!
}

private func valueTextView(in vc: VariableDetailVC) -> VariableValueTextView {
    scrollView(in: vc).documentView as! VariableValueTextView
}

/// The fourth (last) arranged subview of `body` — see the comment at its
/// construction site in `VariableDetailVC.loadView` for why it was appended
/// rather than inserted among the first three.
private func valueChoiceContainer(in vc: VariableDetailVC) -> NSView {
    bodyStack(in: vc).arrangedSubviews[3]
}

private func valueChoiceControl(in vc: VariableDetailVC) -> NSSegmentedControl {
    allDescendants(of: vc.view).compactMap { $0 as? NSSegmentedControl }.first!
}

/// Simulates a real click/selection on a control wired with `target`/`action`
/// — the same dispatch path AppKit itself uses, rather than calling the
/// (private) action method directly, which test code cannot reach anyway.
private func triggerAction(of control: NSControl) {
    guard let action = control.action else { return }
    _ = NSApp.sendAction(action, to: control.target, from: control)
}

/// True when `a` sits visually above `b` in `view`'s own coordinate space,
/// flip-aware (this view happens to be a plain, non-flipped `NSView`, but the
/// check does not assume that).
private func isAbove(_ a: NSRect, _ b: NSRect, in view: NSView) -> Bool {
    view.isFlipped ? a.maxY <= b.minY : a.minY >= b.maxY
}

private func frameInView(_ subview: NSView, of vc: VariableDetailVC) -> NSRect {
    subview.superview!.convert(subview.frame, to: vc.view)
}

// MARK: - Fixtures

private func shortValueVariable() -> QueryVariable {
    QueryVariable(name: "target_ip", value: "10.0.0.1", type: .literal)
}

private func emptyVariable() -> QueryVariable {
    QueryVariable(name: "", value: "", type: .literal)
}

private func longValueVariable(lines: Int = 200) -> QueryVariable {
    let value = (1...lines).map { "line \($0) of a long value" }.joined(separator: "\n")
    return QueryVariable(name: "id_list", value: value, type: .literal)
}

// MARK: - Tests

/// Layout must fully resolve — no ambiguity anywhere in the tree — for an
/// empty variable, a short single-line value, and a 200-line value, at every
/// width the panel actually uses.
private func testLayoutUnambiguous() {
    let fixtures: [(String, QueryVariable)] = [
        ("empty", emptyVariable()),
        ("short single-line", shortValueVariable()),
        ("200-line", longValueVariable()),
    ]
    for width: CGFloat in [180, 300, 600] {
        for (label, variable) in fixtures {
            let (_, _, vc) = makeHostedDetail(width: width, variable: variable)
            vc.view.layoutSubtreeIfNeeded()
            expectTrue(
                !hasAmbiguousLayoutRecursively(vc.view),
                "layout unambiguous at \(Int(width))pt for \(label) value")
        }
    }
}

/// C1-class bug, pinned specifically on the view that constructs the editor:
/// the embedded `valueTextView` must actually hold text, both what `loadView`
/// seeds it with from the variable and what is set afterwards. A value
/// containing a tab and newlines must round-trip exactly.
private func testValueEditorHoldsText() {
    let seeded = "line one\twith a tab\nline two\nline three"
    let variable = QueryVariable(name: "v", value: seeded, type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    let tv = valueTextView(in: vc)

    expectEqual(tv.string, seeded, "valueTextView is seeded with the variable's value at construction")

    let reassigned = "a\tb\nc\r\nd\te"
    tv.string = reassigned
    expectEqual(tv.string, reassigned, "valueTextView round-trips a value containing tabs and mixed line breaks")
}

/// Tab must insert a literal tab character; Shift-Tab (`insertBacktab`) must
/// hand focus to the host's name field rather than inserting anything.
private func testTabAndBacktabBehavior() {
    let (_, _, vc) = makeHostedDetail(width: 300, variable: shortValueVariable())
    let tv = valueTextView(in: vc)
    let name = nameField(in: vc)

    tv.string = ""
    tv.insertTab(nil)
    expectEqual(tv.string, "\t", "insertTab inserts a literal tab character in the value editor")

    _ = vc.view.window?.makeFirstResponder(tv)
    expectTrue(vc.view.window?.firstResponder === tv, "setup: valueTextView is first responder before backtab")

    tv.string = "unchanged"
    tv.insertBacktab(nil)
    expectEqual(tv.string, "unchanged", "insertBacktab does not insert any text into the value editor")
    expectTrue(
        vc.view.window?.firstResponder !== tv,
        "insertBacktab hands focus away from the value editor")
    expectTrue(
        name.currentEditor() != nil,
        "insertBacktab hands focus specifically to the name field (it has an active field editor)")
}

/// The editor container must fill the remaining height between the header
/// separator and the footer caption with nothing overlapping, and grow when
/// the view is made taller.
private func testEditorContainerFillsRemainingHeight() {
    for height: CGFloat in [250, 500] {
        let (_, _, vc) = makeHostedDetail(width: 300, height: height, variable: shortValueVariable())
        vc.view.layoutSubtreeIfNeeded()

        let headerFrame = frameInView(headerStack(in: vc), of: vc)
        let sepFrame = frameInView(headerSeparatorView(in: vc), of: vc)
        let editorFrame = frameInView(editorContainer(in: vc), of: vc)
        let captionFrame = frameInView(captionLabel(in: vc), of: vc)

        expectTrue(
            isAbove(headerFrame, sepFrame, in: vc.view),
            "header sits above the header separator at \(Int(height))pt tall")
        expectTrue(
            isAbove(sepFrame, editorFrame, in: vc.view),
            "header separator sits above the editor container at \(Int(height))pt tall")
        expectTrue(
            isAbove(editorFrame, captionFrame, in: vc.view),
            "editor container sits above the footer caption at \(Int(height))pt tall")
    }

    let (_, _, shortVC) = makeHostedDetail(width: 300, height: 250, variable: shortValueVariable())
    shortVC.view.layoutSubtreeIfNeeded()
    let (_, _, tallVC) = makeHostedDetail(width: 300, height: 600, variable: shortValueVariable())
    tallVC.view.layoutSubtreeIfNeeded()

    let shortHeight = editorContainer(in: shortVC).frame.height
    let tallHeight = editorContainer(in: tallVC).frame.height
    expectTrue(
        tallHeight > shortHeight,
        "editor container grows when the view is made taller (\(shortHeight) at 250pt vs \(tallHeight) at 600pt)")
}

/// The gutter and scroll view must be laid out inside `editorContainer`, side
/// by side, neither zero-width nor overlapping, and the gutter's width must
/// track `desiredWidth`.
private func testGutterAndScrollViewLayout() {
    for width: CGFloat in [180, 300, 600] {
        let (_, _, vc) = makeHostedDetail(width: width, variable: shortValueVariable())
        vc.view.layoutSubtreeIfNeeded()

        let gutter = gutterView(in: vc)
        let scroll = scrollView(in: vc)

        expectTrue(gutter.frame.width > 0, "gutter is not zero-width at \(Int(width))pt")
        expectTrue(scroll.frame.width > 0, "scroll view is not zero-width at \(Int(width))pt")
        expectTrue(
            gutter.frame.maxX <= scroll.frame.minX + 0.5,
            "gutter does not overlap the scroll view at \(Int(width))pt")
        expectClose(
            gutter.frame.maxX, scroll.frame.minX,
            "gutter and scroll view sit directly side by side (no gap) at \(Int(width))pt")
        expectClose(
            gutter.frame.width, gutter.desiredWidth,
            "gutter width tracks desiredWidth at \(Int(width))pt")
    }
}

/// The duplication note must collapse (contribute no height) when absent,
/// and show the state-specific copy for `.shadowed` / `.overriding`.
private func testDuplicationNoteCollapsesWhenAbsent() {
    let (_, _, vcNone) = makeHostedDetail(width: 300, variable: shortValueVariable())
    // The label starts hidden by construction (before any `setState` call at
    // all), which would make "hidden when state is nil" pass vacuously if
    // checked only on a freshly-built VC — proven by reverting the `nil` case
    // in `setState`'s switch to skip re-hiding: that regression left this test
    // green, because a VC that had never been given a duplication note has
    // nothing to reset. Setting `.shadowed` first, then `nil`, exercises the
    // actual shown → hidden transition `setState` is responsible for.
    vcNone.setState(.init(duplication: .shadowed, problem: nil))
    vcNone.view.layoutSubtreeIfNeeded()
    vcNone.setState(nil)
    vcNone.view.layoutSubtreeIfNeeded()
    expectTrue(
        duplicationLabel(in: vcNone).isHidden,
        "duplication label re-hides when setState(nil) follows a prior .shadowed state")
    let heightNone = editorContainer(in: vcNone).frame.height

    let (_, _, vcShadowed) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vcShadowed.setState(.init(duplication: .shadowed, problem: nil))
    vcShadowed.view.layoutSubtreeIfNeeded()
    expectTrue(!duplicationLabel(in: vcShadowed).isHidden, "duplication label shown for .shadowed")
    expectEqual(
        duplicationLabel(in: vcShadowed).stringValue,
        "Redefined below — this row has no effect.",
        ".shadowed shows the shadowed copy")
    let heightShadowed = editorContainer(in: vcShadowed).frame.height

    let (_, _, vcOverriding) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vcOverriding.setState(.init(duplication: .overriding, problem: nil))
    vcOverriding.view.layoutSubtreeIfNeeded()
    expectTrue(!duplicationLabel(in: vcOverriding).isHidden, "duplication label shown for .overriding")
    expectEqual(
        duplicationLabel(in: vcOverriding).stringValue,
        "Also defined above — this definition wins.",
        ".overriding shows the overriding copy")

    // With the total body height fixed by the outer constraints, a note that
    // truly collapses (rather than merely going blank while still reserving
    // its row) reclaims that height for the editor container.
    expectTrue(
        heightNone > heightShadowed,
        "editor container is taller with no duplication note (\(heightNone)) than with one present (\(heightShadowed))")
}

/// `setState` must render its two signals independently: a state with only
/// `.problem` reddens the name and shows no note; a state with only
/// `.duplication` shows the note and leaves the name its normal colour; a
/// state with both shows both.
private func testSetStateRendersSignalsIndependently() {
    let (_, _, vcProblemOnly) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vcProblemOnly.setState(.init(duplication: nil, problem: .emptyLiteral))
    expectTrue(
        nameField(in: vcProblemOnly).textColor == .systemRed,
        "problem-only: name field reddens")
    expectTrue(
        duplicationLabel(in: vcProblemOnly).isHidden,
        "problem-only: no duplication note")

    let (_, _, vcDupOnly) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vcDupOnly.setState(.init(duplication: .shadowed, problem: nil))
    expectTrue(
        nameField(in: vcDupOnly).textColor == .systemIndigo,
        "duplication-only: name field stays its normal colour")
    expectTrue(
        !duplicationLabel(in: vcDupOnly).isHidden,
        "duplication-only: duplication note shown")

    let (_, _, vcBoth) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vcBoth.setState(.init(duplication: .overriding, problem: .emptyLiteral))
    expectTrue(
        nameField(in: vcBoth).textColor == .systemRed,
        "both: name field reddens")
    expectTrue(
        !duplicationLabel(in: vcBoth).isHidden,
        "both: duplication note shown")
}

/// A separator box with no explicit height constraint measures 5pt, not 1pt
/// (verified in the list level's own hairlines). Pinned here for the header
/// separator too.
private func testHeaderSeparatorIsOnePoint() {
    let (_, _, vc) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vc.view.layoutSubtreeIfNeeded()
    expectClose(headerSeparatorView(in: vc).frame.height, 1, "header separator is 1pt tall, not 5pt")
}

/// `hitTest` over the name field must return something that can take text
/// input — unlike the list level, where every label is a passthrough — and
/// the type popup and delete button must be hit-testable.
private func testHitTestReachesControls() {
    let (_, container, vc) = makeHostedDetail(width: 300, variable: shortValueVariable())
    vc.view.layoutSubtreeIfNeeded()

    let name = nameField(in: vc)
    expectTrue(name.isEditable, "name field is a real editable control")
    let nameHitPoint = name.convert(NSPoint(x: name.bounds.midX, y: name.bounds.midY), to: container)
    let nameHit = container.hitTest(nameHitPoint)
    expectTrue(
        nameHit === name || nameHit?.isDescendant(of: name) == true,
        "hitTest over the name field reaches an editable control")

    let popup = typePopup(in: vc)
    let popupHitPoint = popup.convert(NSPoint(x: popup.bounds.midX, y: popup.bounds.midY), to: container)
    let popupHit = container.hitTest(popupHitPoint)
    expectTrue(
        popupHit === popup || popupHit?.isDescendant(of: popup) == true,
        "hitTest over the type popup reaches it")

    let del = deleteButton(in: vc)
    let delHitPoint = del.convert(NSPoint(x: del.bounds.midX, y: del.bounds.midY), to: container)
    let delHit = container.hitTest(delHitPoint)
    expectTrue(
        delHit === del || delHit?.isDescendant(of: del) == true,
        "hitTest over the delete button reaches it")
}

/// Sanity check the harness's own control-lookup helpers against the back
/// button too, and confirm the type popup carries every `VariableType` case.
private func testControlsWireUpCorrectly() {
    let (_, _, vc) = makeHostedDetail(width: 300, variable: shortValueVariable())
    let popup = typePopup(in: vc)
    expectTrue(
        popup.itemTitles == VariableType.allCases.map(\.displayName),
        "type popup lists every VariableType in order")
    expectTrue(backButton(in: vc).toolTip == "Back to variables", "back button is reachable and labeled")
}

// MARK: - Bool value control tests

/// `.bool` shows the True/False/NULL choice and hides the free-text editor
/// and its `N chars` caption (a per-character caption is meaningless for a
/// three-way choice); every other type does the reverse. Both hidden
/// controls must contribute zero height, not merely go invisible while still
/// reserving their row (the same distinction `testDuplicationNoteCollapsesWhenAbsent`
/// already draws for the duplication note).
private func testBoolTypeSwapsValueControl() {
    for width: CGFloat in [180, 300, 600] {
        let boolVariable = QueryVariable(name: "b", value: "true", type: .bool)
        let (_, _, vcBool) = makeHostedDetail(width: width, variable: boolVariable)
        vcBool.view.layoutSubtreeIfNeeded()

        expectTrue(
            !valueChoiceContainer(in: vcBool).isHidden,
            "bool @\(Int(width))pt: choice control is visible")
        expectTrue(
            editorContainer(in: vcBool).isHidden, "bool @\(Int(width))pt: editor is hidden")
        expectTrue(
            captionLabel(in: vcBool).isHidden, "bool @\(Int(width))pt: caption is hidden")
        expectClose(
            editorContainer(in: vcBool).frame.height, 0,
            "bool @\(Int(width))pt: hidden editor contributes no height")
        // Not asserted the same way for `captionLabel`: unlike `editorContainer`
        // (a plain, size-less `NSView`, forced to exactly 0 by the fallback
        // constraint added in `loadView`), a hidden `NSTextField` label simply
        // retains its own last intrinsic frame rather than collapsing to
        // zero — measured directly (11pt, its text height), even though it
        // reserves no space in the stack and paints nothing. The height
        // comparison in `testBoolViewIsShorterThanLiteral` below is what
        // actually proves the caption isn't consuming space.

        for type: VariableType in [.literal, .text, .number] {
            let variable = QueryVariable(name: "v", value: "true", type: type)
            let (_, _, vc) = makeHostedDetail(width: width, variable: variable)
            vc.view.layoutSubtreeIfNeeded()
            expectTrue(
                valueChoiceContainer(in: vc).isHidden,
                "\(type) @\(Int(width))pt: choice control is hidden")
            expectTrue(!editorContainer(in: vc).isHidden, "\(type) @\(Int(width))pt: editor is visible")
            expectTrue(!captionLabel(in: vc).isHidden, "\(type) @\(Int(width))pt: caption is visible")
            expectClose(
                valueChoiceContainer(in: vc).frame.height, 0,
                "\(type) @\(Int(width))pt: hidden choice control contributes no height")
        }
    }
}

/// A `.bool` variable's natural content height is shorter than the same
/// value rendered as a `.literal` — the choice control replaces both the
/// editor and its caption rather than just one of them. Measured via
/// `fittingSize` with only width pinned (see `makeHostedDetailForFittingSize`),
/// since a harness that also pins height would force both configurations to
/// the same forced number regardless of content.
private func testBoolViewIsShorterThanLiteral() {
    let boolVariable = QueryVariable(name: "b", value: "true", type: .bool)
    let literalVariable = QueryVariable(name: "b", value: "true", type: .literal)
    let (_, _, vcBool) = makeHostedDetailForFittingSize(width: 300, variable: boolVariable)
    let (_, _, vcLiteral) = makeHostedDetailForFittingSize(width: 300, variable: literalVariable)
    let boolHeight = vcBool.view.fittingSize.height
    let literalHeight = vcLiteral.view.fittingSize.height
    expectTrue(
        boolHeight < literalHeight,
        "bool view (\(boolHeight)pt) is shorter than the same variable rendered as Literal (\(literalHeight)pt)")
}

/// Entry-side selection mapping: the same case-insensitive, trimmed sets
/// `VariableSubstitutor.format`'s `.bool` branch matches against must select
/// the matching segment, and anything that matches none of them — including
/// empty and a leftover non-bool value like "abc" — must leave no segment
/// selected at all, never a guessed default.
private func testBoolSelectionMappingOnEntry() {
    let matching: [(String, Int)] = [
        ("true", 0), ("TRUE", 0), ("True", 0), ("t", 0), ("1", 0), ("yes", 0), ("y", 0),
        ("false", 1), ("FALSE", 1), ("f", 1), ("0", 1), ("no", 1), ("n", 1),
        ("null", 2), ("NULL", 2), ("Null", 2),
    ]
    for (value, expectedSegment) in matching {
        let variable = QueryVariable(name: "b", value: value, type: .bool)
        let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
        let selected = valueChoiceControl(in: vc).selectedSegment
        expectTrue(
            selected == expectedSegment,
            "value \(value.debugDescription) selects segment \(expectedSegment) (got \(selected))")
    }

    for unmatched in ["", "abc", "  ", "truee"] {
        let variable = QueryVariable(name: "b", value: unmatched, type: .bool)
        let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
        let selected = valueChoiceControl(in: vc).selectedSegment
        expectTrue(
            selected == -1,
            "value \(unmatched.debugDescription) selects no segment (got \(selected))")
    }
}

/// Exit-side mapping: choosing each segment writes the canonical spelling
/// (not whatever variant was there before) and fires `onChange` exactly
/// once — the same contract the text editor's `textDidChange` honors.
private func testChoosingSegmentWritesCanonicalValueAndFiresOnChangeOnce() {
    let cases: [(Int, String)] = [(0, "true"), (1, "false"), (2, "NULL")]
    for (segmentIndex, expectedValue) in cases {
        let variable = QueryVariable(name: "b", value: "", type: .bool)
        let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
        var changeCount = 0
        var lastValue: String?
        vc.onChange = { updated in
            changeCount += 1
            lastValue = updated.value
        }

        let seg = valueChoiceControl(in: vc)
        seg.selectedSegment = segmentIndex
        triggerAction(of: seg)

        expectEqual(
            lastValue ?? "<no onChange fired>", expectedValue,
            "choosing segment \(segmentIndex) writes the canonical value")
        expectTrue(
            changeCount == 1,
            "choosing segment \(segmentIndex) fires onChange exactly once (got \(changeCount))")
    }
}

/// The assertion that ties the control to what actually executes, rather
/// than to this file's own restatement of the mapping rule: after choosing
/// NULL through the real control, `VariableSubstitutor.render` must produce
/// the literal SQL keyword.
private func testChoosingNullRoundTripsThroughSubstitutor() {
    let variable = QueryVariable(name: "n", value: "", type: .bool)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    let seg = valueChoiceControl(in: vc)
    seg.selectedSegment = 2
    triggerAction(of: seg)

    let result = VariableSubstitutor.render("x = {{n}}", with: [vc.variable])
    expectEqual(result.sql, "x = NULL", "choosing NULL renders to \"x = NULL\" through the real substitutor")
}

/// Switching type via the popup — Bool → Text → Bool — must swap which
/// control is showing both ways, and must never mutate the value along the
/// way: `"true"` is a perfectly good `Literal`/`Text` value too.
private func testSwitchingTypeSwapsControlsAndPreservesValue() {
    let variable = QueryVariable(name: "b", value: "true", type: .bool)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    let popup = typePopup(in: vc)

    expectTrue(!valueChoiceContainer(in: vc).isHidden, "starts Bool: choice control visible")
    expectTrue(editorContainer(in: vc).isHidden, "starts Bool: editor hidden")

    let textIndex = VariableType.allCases.firstIndex(of: .text)!
    popup.selectItem(at: textIndex)
    triggerAction(of: popup)
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(valueChoiceContainer(in: vc).isHidden, "Bool -> Text: choice control hidden")
    expectTrue(!editorContainer(in: vc).isHidden, "Bool -> Text: editor visible")
    expectEqual(vc.variable.value, "true", "Bool -> Text preserves the value")
    expectEqual(valueTextView(in: vc).string, "true", "Bool -> Text: text editor reflects the preserved value")

    let boolIndex = VariableType.allCases.firstIndex(of: .bool)!
    popup.selectItem(at: boolIndex)
    triggerAction(of: popup)
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(!valueChoiceContainer(in: vc).isHidden, "Text -> Bool: choice control visible")
    expectTrue(editorContainer(in: vc).isHidden, "Text -> Bool: editor hidden")
    expectEqual(vc.variable.value, "true", "Text -> Bool preserves the value")
    expectTrue(
        valueChoiceControl(in: vc).selectedSegment == 0,
        "Text -> Bool: re-selects True from the preserved value")
}

/// No ambiguity or conflicts anywhere in the tree for any `VariableType`,
/// not just `.bool` — extends `testLayoutUnambiguous`'s width matrix across
/// every type, since the Bool/non-Bool control swap is the part of this
/// view most likely to introduce a fresh ambiguity the original test never
/// had reason to check for.
private func testAllTypesLayoutUnambiguous() {
    for width: CGFloat in [180, 300, 600] {
        for type in VariableType.allCases {
            let variable = QueryVariable(name: "v", value: "true", type: type)
            let (_, _, vc) = makeHostedDetail(width: width, variable: variable)
            vc.view.layoutSubtreeIfNeeded()
            expectTrue(
                !hasAmbiguousLayoutRecursively(vc.view),
                "layout unambiguous at \(Int(width))pt for type \(type)")
        }
    }
}

/// The choice control must actually fit the panel at its 180pt minimum
/// width: its natural (`fittingSize`) width must not exceed the available
/// editor width (panel width minus the `body` stack's 10pt-per-side insets).
/// A failure here is the documented signal to switch from a segmented
/// control to a popup instead.
private func testChoiceControlFitsAvailableWidth() {
    let variable = QueryVariable(name: "b", value: "true", type: .bool)
    let (_, _, vc) = makeHostedDetail(width: 180, variable: variable)
    vc.view.layoutSubtreeIfNeeded()
    let seg = valueChoiceControl(in: vc)
    let availableWidth: CGFloat = 180 - 20
    expectTrue(
        seg.fittingSize.width <= availableWidth,
        "choice control's natural width (\(seg.fittingSize.width)pt) fits the available "
            + "editor width (\(availableWidth)pt) at the panel's 180pt minimum")
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    testLayoutUnambiguous()
    testValueEditorHoldsText()
    testTabAndBacktabBehavior()
    testEditorContainerFillsRemainingHeight()
    testGutterAndScrollViewLayout()
    testDuplicationNoteCollapsesWhenAbsent()
    testSetStateRendersSignalsIndependently()
    testHeaderSeparatorIsOnePoint()
    testHitTestReachesControls()
    testControlsWireUpCorrectly()

    testBoolTypeSwapsValueControl()
    testBoolViewIsShorterThanLiteral()
    testBoolSelectionMappingOnEntry()
    testChoosingSegmentWritesCanonicalValueAndFiresOnChangeOnce()
    testChoosingNullRoundTripsThroughSubstitutor()
    testSwitchingTypeSwapsControlsAndPreservesValue()
    testAllTypesLayoutUnambiguous()
    testChoiceControlFitsAvailableWidth()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
