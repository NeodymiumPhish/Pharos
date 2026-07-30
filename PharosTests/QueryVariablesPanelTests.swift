// Standalone test runner for QueryVariablesPanelVC — no Xcode project or test
// target involvement. Measures the two-level list/detail container: the level
// swap (list <-> detail), row-identity preservation on a referenced-names
// update, the abandoned-`+` prune, and layout ambiguity on both levels —
// using the same headless, never-shown NSWindow technique as
// VariableRowLayoutTests.swift and VariableDetailVCTests.swift. Separate
// binary (own `runTests()`) since only one can exist per compiled binary.
//
// `animatesLevelTransitions` is forced off throughout: the production default
// reads `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, which a
// headless harness cannot set, and the animated path resolves final frames
// only after a `NSAnimationContext` completion handler that this harness has
// no run loop to drive. Forcing the instant path is what makes every
// assertion below observe *final* state synchronously.
//
// Compiled with QueryVariablesPanelVC.swift, VariableListView.swift,
// VariableRowView.swift, VariableDetailVC.swift, VariableValueTextView.swift,
// VariableSubstitutor.swift, VariableValuePreview.swift, QueryVariable.swift,
// PulseClock.swift, SQLLexer.swift, SQLSegmentParser.swift,
// SQLFoldingParser.swift and LineNumberGutter.swift by
// scripts/test-query-variables-panel.sh.
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

// MARK: - Harness helpers

/// A borderless, never-shown window hosting the panel at a fixed size, with
/// level-swap animation forced off (see file header). A window is required
/// for Auto Layout to actually run — an unhosted view never resolves its
/// constraints, and `NSViewController.viewDidLayout` is only invoked when the
/// view participates in a real window's layout pass.
private func makeHostedPanel(
    width: CGFloat, height: CGFloat = 600
) -> (window: NSWindow, container: NSView, vc: QueryVariablesPanelVC) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView = container
    let vc = QueryVariablesPanelVC()
    vc.animatesLevelTransitions = false
    vc.view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(vc.view)
    NSLayoutConstraint.activate([
        vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        vc.view.topAnchor.constraint(equalTo: container.topAnchor),
        vc.view.widthAnchor.constraint(equalToConstant: width),
        vc.view.heightAnchor.constraint(equalToConstant: height),
    ])
    container.layoutSubtreeIfNeeded()

    // Second pass: the existing harnesses (VariableDetailVCTests,
    // VariableRowLayoutTests) document that this assembly's NSStackView
    // geometry is not fully settled after a single layoutSubtreeIfNeeded() —
    // a live window's run loop settles it within milliseconds with no code
    // involved, so a headless harness that never spins the run loop has to
    // force the follow-up pass explicitly.
    vc.view.needsLayout = true
    container.layoutSubtreeIfNeeded()

    return (window, container, vc)
}

private func allDescendants(of view: NSView) -> [NSView] {
    var result: [NSView] = []
    for sub in view.subviews {
        result.append(sub)
        result.append(contentsOf: allDescendants(of: sub))
    }
    return result
}

private func hasAmbiguousLayoutRecursively(_ view: NSView) -> Bool {
    if view.hasAmbiguousLayout { return true }
    return view.subviews.contains { hasAmbiguousLayoutRecursively($0) }
}

/// Neither `listView` nor `detailVC` is exposed by `QueryVariablesPanelVC` (both
/// private), so — mirroring how the other two harnesses locate internals —
/// these walk the public view/child-view-controller hierarchy instead of
/// reaching into private stored properties.
private func listView(in vc: QueryVariablesPanelVC) -> VariableListView {
    allDescendants(of: vc.view).compactMap { $0 as? VariableListView }.first!
}

/// `contentArea` (the view that must clip the level-slide animation) is a
/// private stored property, so it is located structurally instead: `loadView`
/// adds `listView` as a direct subview of `contentArea`, so `listView`'s
/// superview *is* `contentArea`.
private func contentArea(in vc: QueryVariablesPanelVC) -> NSView {
    listView(in: vc).superview!
}

/// `detailVC` is added via `addChild(detail)`, so `NSViewController.children`
/// — public API — surfaces it without needing the private stored property.
private func detailVC(in vc: QueryVariablesPanelVC) -> VariableDetailVC? {
    vc.children.compactMap { $0 as? VariableDetailVC }.first
}

private func listScrollView(in list: VariableListView) -> NSScrollView {
    list.subviews.compactMap { $0 as? NSScrollView }.first!
}

private func rowsStackView(in list: VariableListView) -> NSStackView {
    listScrollView(in: list).documentView as! NSStackView
}

private func rowViews(in list: VariableListView) -> [VariableRowView] {
    rowsStackView(in: list).arrangedSubviews.compactMap { $0 as? VariableRowView }
}

/// The warning glyph sits inside `topRight`, the only `NSStackView` directly
/// among a row's subviews (mirroring `VariableRowLayoutTests.topRightStack`).
private func warningView(in row: VariableRowView) -> NSImageView {
    let topRight = row.subviews.compactMap { $0 as? NSStackView }.first!
    return topRight.subviews.compactMap { $0 as? NSImageView }.first!
}

/// The only editable `NSTextField` in a detail VC's tree — see
/// `VariableDetailVCTests.nameField(in:)` for the same discriminator
/// (`captionLabel`/`duplicationLabel` are label-style fields, not editable).
private func nameField(in vc: VariableDetailVC) -> NSTextField {
    allDescendants(of: vc.view).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
}

private func backButton(in vc: VariableDetailVC) -> NSButton {
    allDescendants(of: vc.view).compactMap { $0 as? NSButton }
        .first { !($0 is NSPopUpButton) && $0.toolTip == "Back to variables" }!
}

private func detailDeleteButton(in vc: VariableDetailVC) -> NSButton {
    allDescendants(of: vc.view).compactMap { $0 as? NSButton }
        .first { !($0 is NSPopUpButton) && $0.toolTip == "Delete variable" }!
}

private func detailScrollView(in vc: VariableDetailVC) -> NSScrollView {
    allDescendants(of: vc.view).compactMap { $0 as? NSScrollView }.first!
}

private func detailValueTextView(in vc: VariableDetailVC) -> VariableValueTextView {
    detailScrollView(in: vc).documentView as! VariableValueTextView
}

/// Simulates a real click on a target/action control — the same dispatch path
/// AppKit itself uses — rather than calling the (often private) action method
/// directly, which test code cannot reach anyway. Matches
/// `VariableDetailVCTests.triggerAction(of:)`.
private func triggerAction(of control: NSControl) {
    guard let action = control.action else { return }
    _ = NSApp.sendAction(action, to: control.target, from: control)
}

private func makeVariables(_ n: Int) -> [QueryVariable] {
    (0..<n).map { QueryVariable(name: "var\($0)", value: "v\($0)", type: .literal) }
}

// MARK: - Tests

/// The panel starts on the list level: no detail child view controller, list
/// visible.
private func testStartsOnListLevelNoDetailChild() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables(makeVariables(3), referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(detailVC(in: vc) == nil, "starts with no detail child view controller")
    expectTrue(vc.children.isEmpty, "starts with no child view controllers at all")
    expectTrue(!listView(in: vc).isHidden, "list view is visible on the list level")
}

/// Drilling in to a variable adds the detail VC as a child, hides the list,
/// and the detail shows that variable's name and value.
private func testDrillingInAddsDetailAndHidesList() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    let vars = makeVariables(3)
    vc.setVariables(vars, referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    let target = vars[1]
    let rows = rowViews(in: listView(in: vc))
    expectTrue(rows.count == 3, "setup: 3 rows present")
    rows[1].onClick?()
    vc.view.layoutSubtreeIfNeeded()

    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL drilling in: no detail child view controller was added")
        return
    }
    expectTrue(vc.children.contains { $0 === detail }, "detail VC is added as a child view controller")
    expectTrue(listView(in: vc).isHidden, "list view is hidden once the detail level is showing")
    expectEqual(nameField(in: detail).stringValue, target.name, "detail shows the drilled-in variable's name")
    expectEqual(
        detailValueTextView(in: detail).string, target.value,
        "detail shows the drilled-in variable's value")
}

/// Back returns to the list level: removes the detail child, and the list
/// shows the current (unchanged) variables.
private func testBackReturnsToListAndRemovesDetailChild() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables(makeVariables(2), referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    rowViews(in: listView(in: vc))[0].onClick?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after drilling in")
        return
    }

    triggerAction(of: backButton(in: detail))
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(detailVC(in: vc) == nil, "back removes the detail child")
    expectTrue(!listView(in: vc).isHidden, "back re-shows the list")
    expectTrue(
        rowViews(in: listView(in: vc)).count == 2,
        "back shows the current variables (still 2, none pruned — both were named)")
}

/// The abandoned-`+` prune: `+` then immediately back removes the still-empty
/// variable and fires `onChange`. A variable with a name (or a value) typed
/// before back is kept.
private func testAbandonedPlusIsPrunedButTypedOneIsKept() {
    // Abandoned case.
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables([], referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    var changeCount = 0
    vc.onChange = { _ in changeCount += 1 }

    listView(in: vc).onAdd?()
    vc.view.layoutSubtreeIfNeeded()
    expectTrue(vc.variables.count == 1, "setup: + appends one variable")
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: + did not drill in")
        return
    }
    expectTrue(
        detail.variable.name.isEmpty && detail.variable.value.isEmpty,
        "setup: freshly added variable is empty")

    triggerAction(of: backButton(in: detail))
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(vc.variables.isEmpty, "an abandoned (still-empty) + is pruned on back")
    expectTrue(changeCount >= 2, "onChange fires for both the add and the prune (got \(changeCount))")
    expectTrue(detailVC(in: vc) == nil, "back returns to the list level after pruning")

    // Kept case: a name is typed before back.
    let (_, _, vc2) = makeHostedPanel(width: 300)
    vc2.setVariables([], referenced: [])
    vc2.view.layoutSubtreeIfNeeded()
    listView(in: vc2).onAdd?()
    vc2.view.layoutSubtreeIfNeeded()
    guard let detail2 = detailVC(in: vc2) else {
        failures += 1
        print("FAIL setup: + did not drill in (kept case)")
        return
    }

    let field = nameField(in: detail2)
    field.stringValue = "kept_name"
    detail2.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    triggerAction(of: backButton(in: detail2))
    vc2.view.layoutSubtreeIfNeeded()

    expectTrue(vc2.variables.count == 1, "a variable with a typed name survives back")
    expectEqual(vc2.variables.first?.name ?? "<none>", "kept_name", "the surviving variable keeps the typed name")
}

/// Delete from the detail level removes the variable, fires `onChange`, and
/// returns to the list level.
private func testDeleteFromDetailRemovesVariableAndReturnsToList() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    let vars = makeVariables(3)
    vc.setVariables(vars, referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    var changeCount = 0
    vc.onChange = { _ in changeCount += 1 }

    rowViews(in: listView(in: vc))[1].onClick?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after drilling in")
        return
    }
    let deletedId = detail.variable.id

    triggerAction(of: detailDeleteButton(in: detail))
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(!vc.variables.contains { $0.id == deletedId }, "delete from detail removes the variable")
    expectTrue(changeCount >= 1, "delete from detail fires onChange")
    expectTrue(detailVC(in: vc) == nil, "delete from detail returns to the list level")
    expectTrue(!listView(in: vc).isHidden, "delete from detail re-shows the list")
}

/// `setVariables(_:referenced:)` resets to the list level even when the
/// detail level was showing — the tab-switch path.
private func testSetVariablesResetsToListLevel() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables(makeVariables(2), referenced: [])
    vc.view.layoutSubtreeIfNeeded()
    rowViews(in: listView(in: vc))[0].onClick?()
    vc.view.layoutSubtreeIfNeeded()
    expectTrue(detailVC(in: vc) != nil, "setup: detail level showing before setVariables")

    vc.setVariables(makeVariables(4), referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(detailVC(in: vc) == nil, "setVariables resets to the list level")
    expectTrue(!listView(in: vc).isHidden, "setVariables re-shows the list")
    expectTrue(rowViews(in: listView(in: vc)).count == 4, "setVariables shows the newly-set variables")
}

/// `setReferencedNames` updates row state in place: the row view instances
/// are identical before and after, and a row's rendering actually changes
/// when its name becomes referenced (not a vacuous identity check).
private func testSetReferencedNamesUpdatesRowStateInPlace() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    var vars = makeVariables(3)
    vars[0].value = ""  // empty literal — flags once referenced
    vc.setVariables(vars, referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    let before = rowViews(in: listView(in: vc))
    expectTrue(before.count == 3, "setup: 3 rows present")
    expectTrue(warningView(in: before[0]).isHidden, "row 0 warning hidden before its name is referenced")

    vc.setReferencedNames([vars[0].name])
    vc.view.layoutSubtreeIfNeeded()

    let after = rowViews(in: listView(in: vc))
    expectTrue(after.count == before.count, "setReferencedNames keeps the same row count")
    for (i, pair) in zip(before, after).enumerated() {
        expectTrue(pair.0 === pair.1, "setReferencedNames reuses the same VariableRowView instance at index \(i)")
    }
    expectTrue(
        !warningView(in: after[0]).isHidden,
        "row 0 warning becomes visible once its name is referenced (rendering actually changed)")
}

/// No ambiguity or conflicts anywhere in the tree, on both levels, at every
/// width the panel actually uses.
private func testLayoutUnambiguousOnBothLevels() {
    for width: CGFloat in [180, 300, 600] {
        let (_, _, vc) = makeHostedPanel(width: width)
        vc.setVariables(makeVariables(4), referenced: [])
        vc.view.layoutSubtreeIfNeeded()
        vc.view.needsLayout = true
        vc.view.layoutSubtreeIfNeeded()
        expectTrue(!hasAmbiguousLayoutRecursively(vc.view), "list level layout unambiguous at \(Int(width))pt")

        rowViews(in: listView(in: vc))[0].onClick?()
        vc.view.layoutSubtreeIfNeeded()
        vc.view.needsLayout = true
        vc.view.layoutSubtreeIfNeeded()
        expectTrue(!hasAmbiguousLayoutRecursively(vc.view), "detail level layout unambiguous at \(Int(width))pt")
    }
}

/// The `+` flow appends a variable, fires `onChange`, and drills straight in
/// with the name field focused.
private func testPlusAppendsFiresOnChangeAndDrillsIn() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables(makeVariables(1), referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    var changeCount = 0
    var lastVars: [QueryVariable] = []
    vc.onChange = { vars in
        changeCount += 1
        lastVars = vars
    }

    listView(in: vc).onAdd?()
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(vc.variables.count == 2, "+ appends a variable")
    expectTrue(changeCount >= 1, "+ fires onChange")
    expectTrue(lastVars.count == 2, "onChange is passed the updated variable list")
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL + does not drill straight in")
        return
    }
    expectTrue(detail.variable.id == vc.variables.last?.id, "+ drills into the newly-added variable")
    expectTrue(
        nameField(in: detail).currentEditor() != nil,
        "+ focuses the new variable's name field (it has an active field editor)")
}

/// Deleting via the list's context-menu path (`onDelete` by id, without
/// drilling in) removes it and leaves the list showing.
private func testDeleteViaListContextMenuLeavesListShowing() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    let vars = makeVariables(3)
    vc.setVariables(vars, referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    var changeCount = 0
    vc.onChange = { _ in changeCount += 1 }

    let rows = rowViews(in: listView(in: vc))
    let deletedId = vars[1].id
    // Simulates the row's right-click "Delete" menu item, which calls this
    // same `onDelete` closure via `deleteSelected()`. `menu(for:)` needs a
    // real `NSEvent` a headless harness has no practical way to construct,
    // and does not read the event it is passed, so invoking the closure
    // directly exercises the identical call site without that plumbing.
    rows[1].onDelete?()
    vc.view.layoutSubtreeIfNeeded()

    expectTrue(!vc.variables.contains { $0.id == deletedId }, "context-menu delete removes the variable")
    expectTrue(changeCount >= 1, "context-menu delete fires onChange")
    expectTrue(detailVC(in: vc) == nil, "context-menu delete never drills in")
    expectTrue(!listView(in: vc).isHidden, "context-menu delete leaves the list showing")
    expectTrue(rowViews(in: listView(in: vc)).count == 2, "context-menu delete leaves 2 rows")
}

/// Defect 1: the level-slide animation parallaxes the outgoing view to
/// `x = -bounds.width * 0.35` (see `push`/`pop` in `QueryVariablesPanelVC`),
/// and AppKit does not clip subviews to their superview's bounds by default —
/// so without an explicit clip, the part that slides past the panel's
/// leading edge keeps drawing over the resize divider and the editor beside
/// it until the animation finishes. `contentArea` is already layer-backed,
/// so `masksToBounds` is the fix. This pins that it's set, and — with
/// animation forced off via the existing `animatesLevelTransitions` seam —
/// that the fix changes nothing about the final, settled frames: the list
/// fills `contentArea`'s bounds on the list level, and the detail view fills
/// it after drilling in and again after back, exactly as before the clip was
/// added.
private func testContentAreaClipsAndFinalFramesUnchanged() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables(makeVariables(2), referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    let area = contentArea(in: vc)
    expectTrue(area.wantsLayer, "setup: contentArea is layer-backed")
    expectTrue(area.layer?.masksToBounds == true, "contentArea clips its children (masksToBounds)")

    expectTrue(
        listView(in: vc).frame == area.bounds,
        "list view fills contentArea's bounds on the list level")

    rowViews(in: listView(in: vc))[0].onClick?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after drilling in")
        return
    }
    expectTrue(
        detail.view.frame == area.bounds,
        "detail view fills contentArea's bounds after drilling in (non-animated)")

    triggerAction(of: backButton(in: detail))
    vc.view.layoutSubtreeIfNeeded()
    expectTrue(
        listView(in: vc).frame == area.bounds,
        "list view fills contentArea's bounds again after back (non-animated)")
}

/// C1: a double-click on a row must not drill in twice. `VariableRowView
/// .mouseUp` does not check `clickCount`, and `push` only hides `listView`
/// inside its animation completion handler — up to `slideDuration` (180ms)
/// later — so for that whole window the list stays visible and
/// hit-testable, and a second `mouseUp` (the second half of a double-click)
/// reaches `onClick` again.
///
/// Requires the ANIMATED path specifically. `makeHostedPanel` forces
/// `animatesLevelTransitions = false` for every other test in this file so
/// their assertions can read final frames synchronously — but that seam
/// closes exactly the window this bug lives in: with animation off, `push`
/// hides `listView` immediately (its early-return branch), so a same-tick
/// second click never reaches a hit-testable row at all, and the bug is
/// invisible. This test re-enables animation explicitly. The harness never
/// spins a run loop, so the animation's completion handler (what the
/// production 180ms window stands in for here) simply never runs between
/// the two synchronous `onClick?()` calls below — a deterministic stand-in
/// for "mid-animation" that doesn't need to race an actual timer.
private func testDoubleClickOnRowDoesNotDrillInTwice() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.animatesLevelTransitions = true
    vc.setVariables(makeVariables(2), referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    let row = rowViews(in: listView(in: vc))[0]
    row.onClick?()
    row.onClick?()  // the second half of a double-click, same tick — no run loop in between

    // `detailVC(in:)` uses `.compactMap { … }.first`, which would report
    // exactly one child even if a second, orphaned one were also present —
    // asserting `children.count` directly is what actually catches it.
    expectTrue(
        vc.children.count == 1,
        "a double-click adds exactly one detail child, not two (got \(vc.children.count))")
    expectTrue(
        contentArea(in: vc).subviews.count == 2,
        "contentArea holds exactly listView + one detail view after a double-click "
            + "(got \(contentArea(in: vc).subviews.count))")

    // Recovery: with only ever one child to dismiss, back is unconditionally
    // reachable — no orphan sitting on top capturing clicks that dismiss the
    // wrong (or no) child.
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after the double-click")
        return
    }
    triggerAction(of: backButton(in: detail))
    expectTrue(vc.children.count == 0, "back recovers cleanly: no detail child remains")
}

/// Defect 2, end to end through the real panel: the detail level cannot see
/// its own siblings, so the panel must supply the comparison set on drill-in
/// — excluding this row's own name and any empty-named rows — and a typed
/// rename that collides with a sibling must never reach `vc.variables`.
private func testPanelSuppliesOtherNamesAndRefusesCollidingRename() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    var vars = makeVariables(3)  // var0, var1, var2
    vars.append(QueryVariable(name: "", value: "", type: .literal))  // an empty-named row
    vc.setVariables(vars, referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    rowViews(in: listView(in: vc))[1].onClick?()  // drill into var1
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after drilling in")
        return
    }

    expectTrue(
        detail.otherNames == ["var0", "var2"],
        "panel supplies siblings' names, excluding this row's own name and the empty-named row "
            + "(got \(detail.otherNames))")

    let field = nameField(in: detail)
    field.stringValue = "var0"
    detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

    expectEqual(vc.variables[1].name, "var1", "a rename colliding with a sibling never reaches vc.variables")
}

/// Item 1's consequence for legacy data, observed end to end through the
/// real panel: a duplicate pair loaded from a saved query (predating the
/// collision refusal) has committed names that genuinely collide with each
/// other. Drilling into either one correctly supplies the sibling's own
/// name as part of `otherNames` — the same wiring
/// `testPanelSuppliesOtherNamesAndRefusesCollidingRename` above already
/// proves in general, extended here to the specific case where the OTHER
/// variable's name also happens to equal this row's own committed name.
/// (`VariableDetailVCTests.swift`'s
/// `testLegacyDuplicateShowsCollisionNoticeWhenOtherNamesIsRefreshed` and
/// `testCommittedCollisionDetectedBeforeViewEverLoads` already confirm what
/// the detail level does with that `otherNames` value on its own: shows the
/// collision notice immediately, keeps the name field editable, and clears
/// normally once you type past it — sane, not broken.)
private func testLegacyDuplicatePairSuppliesSiblingNameOnDrillIn() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    let first = QueryVariable(name: "dup", value: "v1", type: .literal)
    let second = QueryVariable(name: "dup", value: "v2", type: .literal)
    vc.setVariables([first, second], referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    rowViews(in: listView(in: vc))[0].onClick?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after drilling into the first of the duplicate pair")
        return
    }

    expectTrue(
        detail.otherNames == ["dup"],
        "drilling into either half of a legacy duplicate pair supplies the sibling's own name "
            + "(got \(detail.otherNames)) — so its committed name genuinely collides the moment you open it")
}

/// The regression commit-on-settle exists to close, at the door that
/// actually got hit. Renaming an existing "seed_list" by typing a second
/// "seed_list" walks the field through every prefix on the way there —
/// each one unique on its own. Under a per-keystroke-commit rule, every one
/// of those prefixes really did reach `vc.onChange` (what the real app
/// persists to a tab's stored variables) before the final, colliding
/// keystroke was ever reached — so switching tabs mid-edit, which calls
/// `setVariables` directly and never goes through `VariableDetailVC`'s
/// settle points at all, left the variable renamed to whatever prefix was
/// typed last. `attemptBack` refusing to leave while colliding (the
/// previous fix) does not touch this path, because no door in
/// `VariableDetailVC` is involved — the panel replaces the whole array out
/// from under it. Commit-on-settle closes it anyway, by leaving nothing
/// intermediate to have ever reached `vc.onChange` in the first place.
private func testTabSwitchMidCollisionTypingDoesNotCommitPrefix() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    let seedList = QueryVariable(name: "seed_list", value: "v0", type: .literal)
    let other = QueryVariable(name: "other", value: "v1", type: .literal)
    vc.setVariables([seedList, other], referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    var lastVariables = [seedList, other]
    vc.onChange = { lastVariables = $0 }

    rowViews(in: listView(in: vc))[1].onClick?()  // drill into "other"
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: no detail child after drilling in")
        return
    }

    let field = nameField(in: detail)
    for prefix in ["s", "se", "see", "seed", "seed_", "seed_l", "seed_li", "seed_lis", "seed_list"] {
        field.stringValue = prefix
        detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    // Nothing has settled — no back, no Enter, no focus change, no type
    // change — so nothing about "other" should have reached vc.onChange
    // (what the real app persists to a tab's stored variables) at all.
    let midTyping = lastVariables.first { $0.id == other.id }
    expectTrue(
        midTyping?.name == "other",
        "mid-typing, before any settle point, the row's committed name is still \"other\" "
            + "(got \(midTyping?.name ?? "<missing>"))")

    // The tab switch itself. Handing the SAME array back here (rather than a
    // genuinely different one, as `testValidRenameSurvivesTabSwitch` now
    // does) makes these three checks trivially true regardless of ordering —
    // `seedList`/`other` are untouched local values, so `vc.variables` can
    // only equal what was just passed in. They stay only as a belt-and-braces
    // sanity check; the assertion above (before any switch happens at all)
    // is the one actually pinning "a colliding draft never reaches
    // onChange," and it does not depend on which array `setVariables` is
    // given.
    vc.setVariables([seedList, other], referenced: [])

    let afterSwitch = vc.variables.first { $0.id == other.id }
    expectTrue(afterSwitch?.name == "other", "after the tab switch, the row is still named \"other\"")
    expectTrue(afterSwitch?.name != "seed_lis", "the row's name is never the mangled prefix \"seed_lis\"")
    expectTrue(afterSwitch?.name != "seed_list", "the row's name never silently becomes the colliding \"seed_list\"")
}

/// The regression on the other side of the same fix: `dismissDetail` used
/// to read `detail.variable` for its prune check without ever settling the
/// name field first, so on the tab-switch path a *valid, unique* typed
/// rename was discarded too — not just a colliding one. Under the old
/// per-keystroke-commit rule the rename survived (each accepted keystroke
/// wrote straight through), so commit-on-settle traded one bug (a colliding
/// draft leaking through) for a smaller one (a valid draft being lost) on
/// this specific path. `VariableDetailVC.settleForDismissal()`, called from
/// `dismissDetail` before it reads `detail.variable`, closes this: a valid
/// rename now commits on the way out here too, exactly as it already does
/// via `attemptBack` on the back/Escape path.
/// The regression on the other side of the same fix, corrected. The
/// original version of this test passed for the wrong reason: it handed the
/// SAME array back on the simulated "tab switch", so `variableEdited`'s id
/// lookup happened to still find the row regardless of when the settle
/// happened. A real tab switch hands over a genuinely different tab's own
/// array — the outgoing row's id is simply absent from it — which this
/// version does instead.
///
/// Same rename, same genuinely-different incoming array, two call orders:
/// `setVariables` alone — relying only on `dismissDetail`'s own
/// `settleForDismissal()`, which by the time it runs has already had
/// `variables` swapped to the incoming array — loses the rename outright,
/// since `variableEdited`'s id lookup fails silently and `onChange` never
/// fires for it. `settlePendingEdit()`, called *first* — the order
/// `EditorPaneVC.paneStateChanged` now uses (verified directly against that
/// file, not assumed: it calls this before reassigning `lastActiveTabId`,
/// specifically because `variablesDidChange` looks the tab up by
/// `lastActiveTabId`, and by the time `setVariables` itself runs that id
/// already points at the incoming tab) — settles the rename while
/// `variables` still belongs to the outgoing tab, and it survives.
private func testValidRenameSurvivesTabSwitch() {
    /// Drills into a fresh single-variable panel, renames it without
    /// touching any settle point, switches to a genuinely different
    /// variable (simulating a real tab switch), and returns whatever the
    /// panel's own `onChange` last reported for the original variable's id
    /// — nil if `onChange` never fired for it at all.
    func rename(settleFirst: Bool) -> String? {
        let (_, _, vc) = makeHostedPanel(width: 300)
        let original = QueryVariable(name: "original", value: "v", type: .literal)
        vc.setVariables([original], referenced: [])
        vc.view.layoutSubtreeIfNeeded()

        var lastVariables = [original]
        vc.onChange = { lastVariables = $0 }

        rowViews(in: listView(in: vc))[0].onClick?()
        vc.view.layoutSubtreeIfNeeded()
        guard let detail = detailVC(in: vc) else { return nil }

        let field = nameField(in: detail)
        field.stringValue = "renamed"
        detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        // Deliberately touches no settle point of its own before the switch.

        if settleFirst { vc.settlePendingEdit() }

        // A genuinely different tab's own array — a fresh variable, a
        // different id — never the same row handed back.
        let incoming = QueryVariable(name: "unrelated", value: "v2", type: .literal)
        vc.setVariables([incoming], referenced: [])

        return lastVariables.first { $0.id == original.id }?.name
    }

    expectEqual(
        rename(settleFirst: false) ?? "<missing>", "original",
        "setVariables alone, without settling first, loses the rename: onChange never fires for it, "
            + "so the outgoing tab's stored variables would keep the pre-edit name")
    expectEqual(
        rename(settleFirst: true) ?? "<missing>", "renamed",
        "settlePendingEdit(), called before setVariables, preserves the rename")
}

/// The ordering consequence of settling before the prune check: a freshly
/// added row that was given a valid name is no longer empty by the time
/// `dismissDetail` checks for an abandoned row, so it is correctly kept.
/// Exercised via the back path — the only path that ever prunes at all
/// (`pruningEmpty` is `true` only from `onBack`) — as a consistency check
/// that the ordering fix does not regress the case `attemptBack` already
/// handled on its own.
private func testPlusRowGivenValidNameSurvivesDismissalNotPruned() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables([], referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    listView(in: vc).onAdd?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: + did not drill in")
        return
    }

    let field = nameField(in: detail)
    field.stringValue = "new_var"
    detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    expectEqual(vc.variables.first?.name ?? "<missing>", "", "setup: not committed until a settle point")

    triggerAction(of: backButton(in: detail))

    expectTrue(vc.variables.count == 1, "a + row given a valid name survives dismissal instead of being pruned")
    expectEqual(vc.variables.first?.name ?? "<missing>", "new_var", "the surviving row has the typed name")
}

/// Item 3: the prune used to only run on the back path (`pruningEmpty` was
/// `false` for the tab-switch path), so a colliding draft — which never
/// commits, per `commitNameIfValid`'s collision guard — left an
/// empty-name, empty-value row sitting in `variables` forever once the user
/// switched tabs instead of pressing Back. Reported symptom: type an
/// existing name, switch tabs, switch back, and the row persists as a
/// subdued `{{name}}` with "no value."
///
/// Exercises `settlePendingEdit()` directly, in the order
/// `EditorPaneVC.paneStateChanged` actually calls it — before the array
/// moves on to a different tab — since that ordering is what makes the
/// prune (like the rename fix before it) land while `variables` still
/// belongs to the tab it's pruning from.
private func testColliderRowIsDiscardedOnTabSwitch() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    let existing = QueryVariable(name: "seed", value: "v0", type: .literal)
    vc.setVariables([existing], referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    listView(in: vc).onAdd?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: + did not drill in")
        return
    }
    let newId = detail.variable.id

    let field = nameField(in: detail)
    field.stringValue = "seed"  // collides with the existing variable; never commits
    detail.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    expectTrue(vc.variables.count == 2, "setup: the new row is present, still unnamed, alongside the existing one")

    vc.settlePendingEdit()

    expectTrue(vc.variables.count == 1, "the colliding, never-committed row is discarded on tab switch")
    expectTrue(!vc.variables.contains { $0.id == newId }, "specifically, the abandoned row is the one discarded")
    expectTrue(vc.variables.contains { $0.id == existing.id }, "the pre-existing variable is untouched")
}

/// The other half of the same rule: a variable with an empty name but a
/// NON-empty value must survive — the user typed something, and discarding
/// it silently would be the same class of mistake the mangled-prefix bug
/// was.
private func testEmptyNameButNonEmptyValueSurvivesTabSwitch() {
    let (_, _, vc) = makeHostedPanel(width: 300)
    vc.setVariables([], referenced: [])
    vc.view.layoutSubtreeIfNeeded()

    listView(in: vc).onAdd?()
    vc.view.layoutSubtreeIfNeeded()
    guard let detail = detailVC(in: vc) else {
        failures += 1
        print("FAIL setup: + did not drill in")
        return
    }

    // A value, but never a name. The value editor applies live (it is not
    // part of commit-on-settle), so this reaches `vc.variables` immediately.
    let tv = detailValueTextView(in: detail)
    tv.string = "some value"
    NotificationCenter.default.post(name: NSText.didChangeNotification, object: tv)
    expectEqual(
        vc.variables.first?.value ?? "<missing>", "some value",
        "setup: the value committed live")

    vc.settlePendingEdit()

    expectTrue(
        vc.variables.count == 1,
        "a variable with an empty name but a non-empty value survives a tab switch")
}

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    testStartsOnListLevelNoDetailChild()
    testDrillingInAddsDetailAndHidesList()
    testBackReturnsToListAndRemovesDetailChild()
    testAbandonedPlusIsPrunedButTypedOneIsKept()
    testDeleteFromDetailRemovesVariableAndReturnsToList()
    testSetVariablesResetsToListLevel()
    testSetReferencedNamesUpdatesRowStateInPlace()
    testLayoutUnambiguousOnBothLevels()
    testPlusAppendsFiresOnChangeAndDrillsIn()
    testDeleteViaListContextMenuLeavesListShowing()
    testContentAreaClipsAndFinalFramesUnchanged()
    testDoubleClickOnRowDoesNotDrillInTwice()
    testPanelSuppliesOtherNamesAndRefusesCollidingRename()
    testLegacyDuplicatePairSuppliesSiblingNameOnDrillIn()
    testTabSwitchMidCollisionTypingDoesNotCommitPrefix()
    testValidRenameSurvivesTabSwitch()
    testPlusRowGivenValidNameSurvivesDismissalNotPruned()
    testColliderRowIsDiscardedOnTabSwitch()
    testEmptyNameButNonEmptyValueSurvivesTabSwitch()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
