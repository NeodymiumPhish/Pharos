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

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
