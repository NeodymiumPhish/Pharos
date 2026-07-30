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

/// The only `NSTextField` added directly to `editorContainer` (the gutter
/// and scroll view are its other two direct subviews, neither an
/// `NSTextField`).
private func valuePlaceholderLabel(in vc: VariableDetailVC) -> NSTextField {
    editorContainer(in: vc).subviews.compactMap { $0 as? NSTextField }.first!
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

/// Minor: the multi-line value editor has no native placeholder (unlike
/// `nameField.placeholderString`), but the spec calls for keeping one — the
/// old single-line value field had "value". Shown only while the editor is
/// empty and the type isn't Bool (the choice control has no "empty" state
/// the way free text does), and updates live as the value is typed/cleared.
private func testValuePlaceholderShowsOnlyWhenEmpty() {
    let empty = QueryVariable(name: "v", value: "", type: .literal)
    let (_, _, vcEmpty) = makeHostedDetail(width: 300, variable: empty)
    expectTrue(!valuePlaceholderLabel(in: vcEmpty).isHidden, "placeholder shown for an empty Literal value")

    let filled = QueryVariable(name: "v", value: "something", type: .literal)
    let (_, _, vcFilled) = makeHostedDetail(width: 300, variable: filled)
    expectTrue(valuePlaceholderLabel(in: vcFilled).isHidden, "placeholder hidden for a non-empty value")

    let boolVar = QueryVariable(name: "b", value: "", type: .bool)
    let (_, _, vcBool) = makeHostedDetail(width: 300, variable: boolVar)
    expectTrue(valuePlaceholderLabel(in: vcBool).isHidden, "placeholder hidden for Bool regardless of value")

    // Live updates as the value is edited.
    let tv = valueTextView(in: vcFilled)
    tv.string = ""
    NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
    expectTrue(!valuePlaceholderLabel(in: vcFilled).isHidden, "clearing the value restores the placeholder")

    tv.string = "x"
    NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
    expectTrue(valuePlaceholderLabel(in: vcFilled).isHidden, "typing again hides the placeholder")
}

/// I5: every other test in this file that exercises `controlTextDidChange`
/// / `controlTextDidEndEditing` / `textDidChange` calls the delegate method
/// directly — which proves the *method* behaves correctly, but not that
/// `nameField.delegate = self` (or `valueTextView.delegate = self`) is
/// actually wired up. Mutation testing confirmed the gap: deleting either
/// assignment left every one of those tests green. This posts the real
/// `NSControl.textDidChangeNotification` — the notification AppKit itself
/// posts, naming the control as its object — and relies on `nameField
/// .delegate` being set to route it to `controlTextDidChange`, exactly as a
/// real keystroke would.
private func testNameFieldDelegateWiringReactsToRealNotification() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    // A COLLIDING value, deliberately: `attemptBack`/`commitNameIfValid`
    // read `nameField.stringValue` directly regardless of whether the
    // delegate ever ran, so a unique rename here would make the "back
    // commits it" assertion pass even with the delegate disconnected —
    // exactly the false confidence this test exists to avoid. Red is not
    // the field's default colour (indigo is), so it can only appear as a
    // result of `controlTextDidChange` actually running.
    field.stringValue = "ip"
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)

    expectTrue(field.textColor == .systemRed, "the real notification reached the delegate and flagged the collision")
    expectTrue(!duplicationLabel(in: vc).isHidden, "the real notification path shows the inline collision message")

    var backFired = false
    vc.onBack = { backFired = true }
    triggerAction(of: backButton(in: vc))
    expectTrue(!backFired, "back is refused: the delegate-driven collision state still blocks leaving")
}

/// The `NSTextViewDelegate` counterpart, via `NSText.didChangeNotification`
/// — the real notification a text view's own typing posts, naming the text
/// view as its object — relying on `valueTextView.delegate` being wired up.
/// Also checks the two things `textDidChange` is responsible for:
/// `variable.value` and the size caption, both of which apply live (the
/// value editor is not part of commit-on-settle).
private func testValueTextViewDelegateWiringReactsToRealNotification() {
    let variable = QueryVariable(name: "v", value: "old", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    let tv = valueTextView(in: vc)

    tv.string = "new value here"
    NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)

    expectEqual(vc.variable.value, "new value here", "the real notification reaches variable.value")
    expectEqual(
        captionLabel(in: vc).stringValue, VariableValuePreview.caption(for: "new value here"),
        "the real notification updates the size caption to match the new value")
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
/// show the state-specific copy for `.shadowed`, and render nothing at all
/// for `.overriding` — deleted because the new name-collision refusal (see
/// `testCollidingNameNeverReachesModelOrFiresOnChange` etc. below) makes it
/// unreachable for anything the user can type; only a duplicate pair loaded
/// from a saved query that predates that rule can still produce `.shadowed`.
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
    expectTrue(
        duplicationLabel(in: vcOverriding).isHidden,
        ".overriding renders no note at all (deleted — unreachable via typing; only .shadowed still shows)")

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
    vcBoth.setState(.init(duplication: .shadowed, problem: .emptyLiteral))
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

/// I5: `boolSegmentIndex(for:)`'s doc comment claims "segment order has to
/// match `BoolChoice.allCases`, which the harness asserts" — it did not.
/// Every existing test (including the one below) compares segment *indices*
/// against expected index numbers, which stays green even if the control's
/// construction-time labels are reordered: mutation-tested directly by
/// rebuilding with `["NULL", "True", "False"]` — in that build a `true`
/// value selects index 0, which now reads "NULL" on screen, and clicking
/// "NULL" writes `true`. This ties the actual label *text* at each index to
/// what that index means, closing the gap.
private func testBoolSegmentLabelsMatchChoiceOrder() {
    let variable = QueryVariable(name: "b", value: "true", type: .bool)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    let seg = valueChoiceControl(in: vc)

    for (index, choice) in VariableSubstitutor.BoolChoice.allCases.enumerated() {
        let expectedLabel: String
        switch choice {
        case .isTrue: expectedLabel = "True"
        case .isFalse: expectedLabel = "False"
        case .isNull: expectedLabel = "NULL"
        }
        expectEqual(
            seg.label(forSegment: index) ?? "<none>", expectedLabel,
            "segment \(index) displays the label a user would read as \(choice)")
    }
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

// MARK: - Name collision refusal (defect 2)

/// A typed name that collides (exact, trimmed, case-sensitive) with another
/// row's name is refused: never written to `variable.name`, and `onChange`
/// never fires for it.
private func testCollidingNameNeverReachesModelOrFiresOnChange() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    var changeCount = 0
    vc.onChange = { _ in changeCount += 1 }

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    expectEqual(vc.variable.name, "original", "colliding name is not written to variable.name")
    expectTrue(changeCount == 0, "colliding name fires no onChange (got \(changeCount))")
}

/// The collision surfaces as red inline text in the slot the old duplication
/// note used, and reddens the name field — which itself keeps showing
/// exactly what was typed, since the refusal must not fight the user's
/// typing.
private func testCollidingNameShowsInlineErrorAndRedTint() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    expectEqual(field.stringValue, "ip", "the field keeps showing exactly what was typed")
    expectTrue(field.textColor == .systemRed, "the name field is tinted red")
    expectTrue(!duplicationLabel(in: vc).isHidden, "the inline error is shown")
    expectEqual(
        duplicationLabel(in: vc).stringValue, "A variable named \"ip\" already exists. Choose a different name.",
        "the inline error names the colliding value and instructs the user what to do")
    expectTrue(duplicationLabel(in: vc).textColor == .systemRed, "the inline error is red")
}

/// A unique (non-colliding) typed name updates the live UI immediately —
/// normal colour, no inline error — but is NOT written to the model, and
/// fires no `onChange`, while it is still just typed. Commit is deferred to
/// a settle point (see `testTypingUniqueNameCommitsExactlyOnceAtEachSettlePoint`
/// below for the commit side of this): mirrors
/// `testCollidingNameNeverReachesModelOrFiresOnChange` in that neither a
/// colliding nor a non-colliding keystroke reaches the model by itself.
private func testUniqueNameNotCommittedUntilSettle() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    var changeCount = 0
    vc.onChange = { _ in changeCount += 1 }

    let field = nameField(in: vc)
    field.stringValue = "hostname"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    expectEqual(vc.variable.name, "original", "a unique typed name is not written to variable.name while still just typed")
    expectTrue(changeCount == 0, "no onChange fires for typing alone, even when the typed name is unique (got \(changeCount))")
    expectTrue(field.textColor == .systemIndigo, "the name field shows its normal colour for a non-colliding name")
    expectTrue(duplicationLabel(in: vc).isHidden, "no inline error for a non-colliding name")
}

/// Commit-on-settle, end to end, at each of the four settle points: typing
/// a unique name never commits it, and reaching exactly one settle point
/// commits it exactly once, with the final value.
private func testTypingUniqueNameCommitsExactlyOnceAtEachSettlePoint() {
    // `expectedChangeCount` is 1 for every settle point except the type
    // popup, which is two logically separate edits landing in the same
    // gesture: `typeChanged` commits the deferred name (one `onChange`),
    // then applies the type change itself (a second, independent
    // `onChange` — the same call it always made, with or without a pending
    // name). Two calls for two edits is not the per-keystroke-commit bug
    // this suite guards against; only a *name* commit firing more than
    // once per edit would be.
    func run(_ label: String, expectedChangeCount: Int = 1, settle: (VariableDetailVC) -> Void) {
        let variable = QueryVariable(name: "original", value: "v", type: .literal)
        let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
        vc.otherNames = ["ip"]

        var changeCount = 0
        var lastName: String?
        vc.onChange = { changeCount += 1; lastName = $0.name }

        let field = nameField(in: vc)
        for prefix in ["h", "ho", "hos", "host", "hostname"] {
            field.stringValue = prefix
            vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        expectTrue(changeCount == 0, "\(label): no onChange fires while typing (got \(changeCount))")
        expectEqual(vc.variable.name, "original", "\(label): the model is unchanged while still just typed")

        settle(vc)

        expectTrue(
            changeCount == expectedChangeCount,
            "\(label): settling commits the name exactly once (expected \(expectedChangeCount) onChange call(s), "
                + "got \(changeCount))")
        expectEqual(lastName ?? "<no onChange fired>", "hostname", "\(label): the committed name is the final typed value")
    }

    run("back") { vc in triggerAction(of: backButton(in: vc)) }
    run("Enter") { vc in
        _ = vc.control(
            nameField(in: vc), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }
    run("losing first responder") { vc in
        vc.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: nameField(in: vc)))
    }
    run("type change via popup", expectedChangeCount: 2) { vc in
        let popup = typePopup(in: vc)
        let textIndex = VariableType.allCases.firstIndex(of: .text)!
        popup.selectItem(at: textIndex)
        triggerAction(of: popup)
    }
}

/// The new invariant commit-on-settle exists to guarantee: for as long as
/// the user is just typing — before any settle point — the model's name is
/// exactly what it was before this edit began, at every intermediate
/// prefix, not just the final one.
private func testModelNameUnchangedWhileTypingUntilSettle() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    for prefix in ["h", "ho", "hos", "host", "hostname"] {
        field.stringValue = prefix
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        expectEqual(
            vc.variable.name, "original",
            "the model name stays \"original\" mid-typing at prefix \(prefix.debugDescription)")
    }
}

/// While the field collides, the back button must do nothing except keep
/// the message visible and return focus to the name field — not revert the
/// field, not commit anything, not navigate. (See `testSeedListPrefixWalk...`
/// below for why reverting is actively wrong, not just unnecessary.)
private func testBackRefusedWhileColliding() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    var backFired = false
    vc.onBack = { backFired = true }
    triggerAction(of: backButton(in: vc))

    expectTrue(!backFired, "back does not navigate while the field collides")
    expectEqual(field.stringValue, "ip", "back does not revert the field while it collides")
    expectTrue(!duplicationLabel(in: vc).isHidden, "the collision message stays visible after a refused back")
    expectTrue(
        field.currentEditor() != nil,
        "focus returns to the name field after a refused back (it has an active field editor)")
}

/// Escape is refused the same way as the back button, through both the
/// paths that can trigger it: the name field's own delegate (Escape while
/// it has focus) and `cancelOperation` (Escape with no text control
/// focused, e.g. right after the level-slide).
private func testEscapeRefusedWhileColliding() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    var backFired = false
    vc.onBack = { backFired = true }

    let handled = vc.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    expectTrue(handled, "the name field's delegate still claims to handle Escape while colliding")
    expectTrue(!backFired, "Escape via the name field's delegate does not navigate while colliding")
    expectEqual(field.stringValue, "ip", "Escape via the delegate does not revert the field while colliding")

    vc.cancelOperation(nil)
    expectTrue(!backFired, "Escape via cancelOperation does not navigate while colliding")
    expectEqual(field.stringValue, "ip", "Escape via cancelOperation does not revert the field while colliding")
}

/// I4: Escape while the *value editor* has focus is a fourth path off this
/// screen, distinct from the name field's own Escape handling above —
/// `VariableValueTextView.onCancel` used to call `onBack` directly, bypassing
/// `attemptBack` (and so the collision refusal) entirely. The value editor
/// has its own focus, independent of the name field's, so a colliding name
/// can still be showing when this fires.
private func testEscapeInValueEditorRoutesThroughAttemptBack() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    var backFired = false
    vc.onBack = { backFired = true }

    // The real production path: cancelOperation is what AppKit calls when
    // Escape is pressed while this view has focus, and
    // VariableValueTextView routes it to `onCancel`.
    valueTextView(in: vc).cancelOperation(nil)

    expectTrue(!backFired, "Escape in the value editor does not navigate while the name field collides")
    expectEqual(field.stringValue, "ip", "Escape in the value editor does not revert the colliding name field")

    // And once the name field is unique again, this same path must still
    // work — it is a real way off the screen, not merely blocked forever.
    field.stringValue = "ip2"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    valueTextView(in: vc).cancelOperation(nil)

    expectTrue(backFired, "Escape in the value editor navigates normally once the name field is unique")
    expectEqual(vc.variable.name, "ip2", "Escape in the value editor commits the unique name on the way out")
}

/// Once the field is unique again, back (and therefore Escape) works
/// normally — the refusal is specific to the colliding state, not a
/// permanent lock on this screen.
private func testBackSucceedsOnceUnique() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    field.stringValue = "ip2"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    expectEqual(vc.variable.name, "original", "setup: the unique extension is not committed until a settle point")

    var backFired = false
    vc.onBack = { backFired = true }
    triggerAction(of: backButton(in: vc))

    expectTrue(backFired, "back navigates normally once the field is unique again")
    expectEqual(vc.variable.name, "ip2", "back commits the unique name on the way out")
}

/// Delete must still work while the field collides — it is the only
/// guaranteed way off this screen if the user does not want to resolve the
/// collision by typing. Without this, refusing to leave would trap the user
/// outright, which is worse than the bug the refusal exists to prevent.
private func testDeleteWorksWhileColliding() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    var deleteFired = false
    vc.onDelete = { deleteFired = true }
    triggerAction(of: deleteButton(in: vc))

    expectTrue(deleteFired, "delete still works while the name field collides")
}

/// The regression this fix exists for. Renaming an existing "seed_list" by
/// typing a second "seed_list" walks the field through every prefix on the
/// way there — "s", "se", …, "seed_lis" — none of which collide, so each is
/// accepted and committed in turn; only the final keystroke, "seed_list"
/// itself, collides. Under the old "revert to the variable's last valid
/// name" rule, attempting to leave right after typing that final character
/// committed "seed_lis" — a name the user never typed and does not
/// recognize, with the actual collision "silently resolved" by mangling
/// their input instead of being surfaced. Refusing to leave instead of
/// reverting means the field is never touched by anything but the user's
/// own typing, and continuing past the collision (to "seed_list2") is still
/// how they actually get off this screen.
private func testSeedListPrefixWalkNeverMangledOnBack() {
    let variable = QueryVariable(name: "", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["seed_list"]

    let field = nameField(in: vc)
    var backFired = false
    vc.onBack = { backFired = true }

    for prefix in ["s", "se", "see", "seed", "seed_", "seed_l", "seed_li", "seed_lis", "seed_list"] {
        field.stringValue = prefix
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        expectEqual(
            vc.variable.name, "",
            "the model's name is unchanged mid-walk at prefix \(prefix.debugDescription) — nothing "
                + "intermediate is ever committed, not even \"seed_lis\"")
    }

    triggerAction(of: backButton(in: vc))
    expectTrue(!backFired, "back is refused while the final keystroke collides")
    expectEqual(
        field.stringValue, "seed_list",
        "the field is not reverted by the refused back — it still shows exactly what was typed")
    expectEqual(vc.variable.name, "", "the model still has its pre-edit name after a refused back")

    field.stringValue = "seed_list2"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    expectEqual(vc.variable.name, "", "the unique extension is not committed until the next settle point")

    triggerAction(of: backButton(in: vc))
    expectTrue(backFired, "back succeeds once the field is extended to a unique name")
    expectEqual(vc.variable.name, "seed_list2", "the final committed name is exactly what the user typed")
    expectTrue(
        vc.variable.name != "seed_lis",
        "the name is never left as the mangled intermediate prefix \"seed_lis\"")
}

/// The commit trims, matching every collision rule (which also trims).
/// Typing "ip " (trailing space) settles to the trimmed "ip", not the raw
/// string with the space still attached — an untrimmed commit produced a
/// row no `{{token}}` could ever reference, showed healthy (indigo, no
/// badge — `rowStates` cannot flag a collision the model itself does not
/// contain), and then refused the correctly-spelled "ip" on another row as
/// a duplicate, with no visible reason why the two looked different.
private func testCommitTrimsTheName() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = []

    var lastName: String?
    vc.onChange = { lastName = $0.name }

    let field = nameField(in: vc)
    field.stringValue = "ip "
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    triggerAction(of: backButton(in: vc))

    expectEqual(vc.variable.name, "ip", "the committed name is trimmed, not \"ip \" verbatim")
    expectEqual(lastName ?? "<no onChange fired>", "ip", "onChange reports the trimmed name")
}

/// The prune-gap half of the same fix: a name of only whitespace commits as
/// empty (not as a non-empty string of spaces), so an abandoned `+` row
/// still prunes on back rather than surviving as an unreferenceable junk
/// row.
private func testWhitespaceOnlyNameCommitsEmptyAndStillPrunes() {
    let variable = QueryVariable(name: "", value: "", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = []

    let field = nameField(in: vc)
    field.stringValue = "   "
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    triggerAction(of: backButton(in: vc))

    expectEqual(vc.variable.name, "", "a whitespace-only name commits as empty, not as three spaces")
}

/// An empty (trimmed) name never collides with anything, including another
/// empty name — two freshly added rows are not duplicates of each other.
private func testEmptyNameNeverCollides() {
    let variable = QueryVariable(name: "x", value: "", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    // Deliberately includes "" — the panel is documented to exclude empty
    // names from what it supplies, but the VC's own check must not depend on
    // that: an empty typed name must never collide even if `otherNames`
    // somehow contained one (e.g. another freshly added, still-empty row).
    vc.otherNames = [""]

    var changeCount = 0
    var lastName: String?
    vc.onChange = { changeCount += 1; lastName = $0.name }

    let field = nameField(in: vc)
    field.stringValue = ""
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    expectTrue(duplicationLabel(in: vc).isHidden, "no collision note for an empty name")
    expectTrue(changeCount == 0, "clearing to an empty name does not commit while still just typed (got \(changeCount))")
    expectEqual(vc.variable.name, "x", "the model is unchanged mid-typing")

    triggerAction(of: backButton(in: vc))

    expectTrue(changeCount == 1, "settling commits the empty name exactly once (got \(changeCount))")
    expectEqual(lastName ?? "<no onChange fired>", "", "the committed name is empty, as typed, even against another empty name")
}

/// Matching is case-sensitive: `{{IP}}` and `{{ip}}` are different tokens to
/// `render`, so they must not collide here either.
private func testCaseDifferenceDoesNotCollide() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, variable: variable)
    vc.otherNames = ["ip"]

    var changeCount = 0
    var lastName: String?
    vc.onChange = { changeCount += 1; lastName = $0.name }

    let field = nameField(in: vc)
    field.stringValue = "IP"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    expectTrue(field.textColor == .systemIndigo, "a case-different name is not treated as a collision")
    expectTrue(changeCount == 0, "a case-different (non-colliding) name does not commit while still just typed (got \(changeCount))")

    triggerAction(of: backButton(in: vc))

    expectTrue(changeCount == 1, "settling commits the case-different name exactly once (got \(changeCount))")
    expectEqual(lastName ?? "<no onChange fired>", "IP", "the committed name is exactly what was typed, case preserved")
}

/// The layout-shift bug the note exposed: the editor's frame must move in
/// the same call that shows the inline message, not on some later pass that
/// happens to be triggered by something else (in practice, the user's next
/// keystroke) — pinned by NOT forcing a layout pass here ourselves.
private func testInlineMessageShiftsEditorInSameLayoutPass() {
    let variable = QueryVariable(name: "original", value: "v", type: .literal)
    let (_, _, vc) = makeHostedDetail(width: 300, height: 300, variable: variable)
    vc.otherNames = ["ip"]

    let editorFrameBefore = editorContainer(in: vc).frame

    let field = nameField(in: vc)
    field.stringValue = "ip"
    vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    // No explicit layoutSubtreeIfNeeded() call here: the fix must force its
    // own relayout as part of showing the message, not rely on this test (or
    // anything else) to trigger a follow-up pass.
    let editorFrameAfter = editorContainer(in: vc).frame

    // The stack keeps the editor's *bottom* edge anchored (captionLabel and
    // valueChoiceContainer sit below it) and shrinks its *height* to make
    // room for the note appearing above — so the frame that actually moves
    // is its top edge / height, not `minY`. Comparing the whole rect catches
    // that shift regardless of which edge the stack happens to move.
    expectTrue(
        editorFrameAfter != editorFrameBefore,
        "editor container's frame moves in the same pass the inline message appears "
            + "(before: \(editorFrameBefore), after: \(editorFrameAfter))")
}

// MARK: - Gutter line-number alignment (defect 3)

/// Ground truth for where line `line` actually renders, in `gutter`'s own
/// coordinate space — measured via real view-hierarchy coordinate
/// conversion (`NSView.convert(_:to:)`), NOT by restating the gutter's own
/// y-computation formula. A hand-duplicated copy of that formula would
/// agree with the gutter even if both copies shared the same bug; asking
/// AppKit where the glyph actually paints cannot.
private func groundTruthGutterY(line: Int, textView tv: NSTextView, gutter: LineNumberGutter) -> CGFloat? {
    guard let lm = tv.layoutManager else { return nil }
    let ns = tv.string as NSString
    let lines = tv.string.components(separatedBy: "\n")
    guard line >= 1, line <= lines.count else { return nil }
    let charIndex = lines[0..<(line - 1)].reduce(0) { $0 + $1.utf16.count + 1 }
    let lineRange = ns.lineRange(for: NSRange(location: min(charIndex, ns.length), length: 0))
    let glyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
    let lineRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
    var rectInTextView = lineRect
    rectInTextView.origin.x += tv.textContainerInset.width
    rectInTextView.origin.y += tv.textContainerInset.height
    return tv.convert(rectInTextView, to: gutter).origin.y
}

/// Convenience for the `VariableDetailVC`-hosted checks below.
private func groundTruthGutterY(line: Int, in vc: VariableDetailVC) -> CGFloat? {
    groundTruthGutterY(line: line, textView: valueTextView(in: vc), gutter: gutterView(in: vc))
}

/// Hosts a real `VariableDetailVC` for `variable`, optionally overriding the
/// value editor's `textContainerInset` (to prove the fix generalizes across
/// insets rather than merely cancelling out at the one `VariableValueTextView`
/// happens to use), and checks the gutter's `y(forLine:)` seam against
/// `groundTruthGutterY` for every line.
private func checkGutterAlignment(
    variable: QueryVariable, lineCount: Int, inset: NSSize?, label: String
) {
    let (_, _, vc) = makeHostedDetail(width: 300, height: 300, variable: variable)
    let tv = valueTextView(in: vc)
    if let inset { tv.textContainerInset = inset }
    vc.view.layoutSubtreeIfNeeded()
    if let container = tv.textContainer { tv.layoutManager?.ensureLayout(for: container) }

    let gutter = gutterView(in: vc)
    for line in 1...lineCount {
        guard let groundTruth = groundTruthGutterY(line: line, in: vc) else {
            expectTrue(false, "\(label): could not measure ground-truth y for line \(line)")
            continue
        }
        let seam = gutter.y(forLine: line)
        let matched = seam.map { abs($0 - groundTruth) < 1.0 } ?? false
        expectTrue(
            matched,
            "\(label): gutter y for line \(line) matches the text's line-fragment y "
                + "(seam=\(seam.map { String(format: "%.2f", $0) } ?? "nil"), "
                + "text=\(String(format: "%.2f", groundTruth)))")
    }
}

/// Pins the defect: for a one-line and a five-line value, at the value
/// editor's own inset and again at `SQLTextView`'s (4, 8) inset, the gutter's
/// computed y for every line must match where that line's text actually is.
/// Measured directly: before the fix, `y(forLine:)`'s predecessor (inline
/// `lineRect.origin.y + textInset.height - scrollOffset` arithmetic) put line
/// 1 at y≈25 while the text itself rendered at y≈4 — the gutter number a
/// full line below its text, matching the reported symptom exactly.
private func testGutterLineNumberAlignsWithTextLine() {
    let oneLine = QueryVariable(name: "v", value: "test text", type: .literal)
    let fiveLine = QueryVariable(name: "v", value: "line1\nline2\nline3\nline4\nline5", type: .literal)

    checkGutterAlignment(variable: oneLine, lineCount: 1, inset: nil, label: "one-line, default inset")
    checkGutterAlignment(variable: fiveLine, lineCount: 5, inset: nil, label: "five-line, default inset")
    checkGutterAlignment(
        variable: oneLine, lineCount: 1, inset: NSSize(width: 4, height: 8),
        label: "one-line, SQLTextView-style inset")
    checkGutterAlignment(
        variable: fiveLine, lineCount: 5, inset: NSSize(width: 4, height: 8),
        label: "five-line, SQLTextView-style inset")
}

// MARK: - SQL editor gutter-alignment regression guard

/// Mirrors `SQLTextView`'s exact shape — a subclass with its own manually
/// assembled `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`,
/// swapping only its `FoldingLayoutManager` for plain `NSLayoutManager`
/// (irrelevant to this bug, which lives in TextKit/AppKit's own geometry,
/// not in anything either subclass adds on top) — including setting
/// `textContainerInset` from *inside* its own init, exactly where
/// `SQLTextView.commonInit()` sets it (`Pharos/Editor/SQLTextView.swift`).
///
/// Measured directly, and this is the one genuinely surprising part: that
/// last detail is *the* discriminator. Assigning the identical `(4, 8)`
/// inset from outside, after construction (as this test's first draft did,
/// and as the resizing/scroller flags genuinely are assigned externally by
/// `QueryEditorVC.loadView`) never reproduced defect 3's symptom, in a
/// subclass or not. Setting it inside init — which is genuinely how
/// `SQLTextView` and `VariableValueTextView` (the view that actually hit
/// this bug) both do it — reproduces it every time. That means `SQLTextView`
/// sits in the exact same risk class as `VariableValueTextView`,
/// independently of anything specific to the variables panel. This class
/// exists so a test can stand in for `SQLTextView` without pulling in its
/// `FoldingLayoutManager`, syntax highlighting, or any of `QueryEditorVC`'s
/// dependency graph.
private final class SQLEditorStyleTextView: NSTextView {
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }
    private func commonInit() {
        // SQLTextView.commonInit() sets exactly this, exactly here.
        textContainerInset = NSSize(width: 4, height: 8)
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}

/// Hosts `SQLEditorStyleTextView` with the SQL editor's own configuration on
/// top of that shared construction shape — not horizontally resizable,
/// width-tracking container, vertical-only scroller, all assigned
/// externally exactly as `QueryEditorVC.loadView` assigns them (only the
/// inset is internal — see `SQLEditorStyleTextView.commonInit()`). Uses
/// `makeKeyAndOrderFront` + `displayIfNeeded()` rather than the other
/// harnesses' `orderFrontRegardless()` + `layoutSubtreeIfNeeded()` —
/// measured directly: this bug only surfaces once the window actually
/// displays, not merely lays out, so a harness that skips a real display
/// pass would silently fail to reproduce it.
private func makeHostedSQLEditorStyleGutter(
    text: String, width: CGFloat = 300, height: CGFloat = 200
) -> (window: NSWindow, textView: NSTextView, scrollView: NSScrollView, gutter: LineNumberGutter) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = container

    let textView = SQLEditorStyleTextView()
    textView.string = text
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true

    let scrollView = NSScrollView(frame: container.bounds)
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.documentView = textView

    let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
    gutter.frame = NSRect(x: 0, y: 0, width: gutter.desiredWidth, height: height)
    scrollView.frame = NSRect(
        x: gutter.frame.width, y: 0, width: width - gutter.frame.width, height: height)

    container.addSubview(gutter)
    container.addSubview(scrollView)

    window.makeKeyAndOrderFront(nil)
    container.layoutSubtreeIfNeeded()
    container.displayIfNeeded()
    if let tc = textView.textContainer { textView.layoutManager?.ensureLayout(for: tc) }

    return (window, textView, scrollView, gutter)
}

/// Protects the SQL editor from a regression introduced by changes made to
/// `LineNumberGutter` for the variables panel (defect 3, above, rewrote
/// `y(forLine:)` from `lineRect.origin.y + inset.height - scrollOffset`
/// arithmetic to real `NSView.convert(_:to:)` coordinate conversion).
/// Checks alignment for lines 1–3 of a multi-line string under the SQL
/// editor's own text-view configuration, both at rest and — the assertion
/// that actually pins the bug *class*, not just the one instance the
/// variables panel hit — after the clip view has been scrolled to a
/// nonzero `contentView.bounds.origin.y`, which is exactly the condition
/// that broke the old formula for the value editor.
private func testSQLEditorStyleGutterAlignmentUnscrolledAndScrolled() {
    let text = "select 1;\nselect 2;\nselect 3;\nselect 4;\nselect 5;\nselect 6;\nselect 7;\nselect 8;"
    let (_, textView, scrollView, gutter) = makeHostedSQLEditorStyleGutter(text: text, height: 60)

    func checkAlignment(_ label: String) {
        for line in 1...3 {
            guard let groundTruth = groundTruthGutterY(line: line, textView: textView, gutter: gutter) else {
                expectTrue(false, "\(label): could not measure ground truth for line \(line)")
                continue
            }
            let seam = gutter.y(forLine: line)
            let matched = seam.map { abs($0 - groundTruth) < 1.0 } ?? false
            expectTrue(
                matched,
                "\(label): line \(line) gutter y "
                    + "(seam=\(seam.map { String(format: "%.2f", $0) } ?? "nil")) matches the text's "
                    + "line-fragment y (\(String(format: "%.2f", groundTruth)))")
        }
    }

    checkAlignment("SQL-editor-style gutter, unscrolled")

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let scrollOffset = scrollView.contentView.bounds.origin.y
    expectTrue(scrollOffset != 0, "setup: scrolling actually moved the clip view (offset=\(scrollOffset))")

    checkAlignment("SQL-editor-style gutter, scrolled to a nonzero contentView.bounds.origin.y")
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    testLayoutUnambiguous()
    testValueEditorHoldsText()
    testValuePlaceholderShowsOnlyWhenEmpty()
    testNameFieldDelegateWiringReactsToRealNotification()
    testValueTextViewDelegateWiringReactsToRealNotification()
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
    testBoolSegmentLabelsMatchChoiceOrder()
    testBoolSelectionMappingOnEntry()
    testChoosingSegmentWritesCanonicalValueAndFiresOnChangeOnce()
    testChoosingNullRoundTripsThroughSubstitutor()
    testSwitchingTypeSwapsControlsAndPreservesValue()
    testAllTypesLayoutUnambiguous()
    testChoiceControlFitsAvailableWidth()

    testCollidingNameNeverReachesModelOrFiresOnChange()
    testCollidingNameShowsInlineErrorAndRedTint()
    testUniqueNameNotCommittedUntilSettle()
    testTypingUniqueNameCommitsExactlyOnceAtEachSettlePoint()
    testModelNameUnchangedWhileTypingUntilSettle()
    testBackRefusedWhileColliding()
    testEscapeRefusedWhileColliding()
    testEscapeInValueEditorRoutesThroughAttemptBack()
    testBackSucceedsOnceUnique()
    testDeleteWorksWhileColliding()
    testSeedListPrefixWalkNeverMangledOnBack()
    testCommitTrimsTheName()
    testWhitespaceOnlyNameCommitsEmptyAndStillPrunes()
    testEmptyNameNeverCollides()
    testCaseDifferenceDoesNotCollide()
    testInlineMessageShiftsEditorInSameLayoutPass()

    testGutterLineNumberAlignsWithTextLine()
    testSQLEditorStyleGutterAlignmentUnscrolledAndScrolled()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
