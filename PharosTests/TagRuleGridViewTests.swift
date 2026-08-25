// Standalone test runner for TagRuleGridView. Uses real AppKit: the grid is
// hosted in a headless, never-shown NSWindow so Auto Layout runs, and the real
// controls are driven through their own target/action and delegate wiring —
// the same approach as PharosTests/TagConditionRowViewTests.swift.
//
// What this suite is FOR. The grid holds NO state: it renders an `EditableTag`
// and reports what the analyst did, and `TagManagerModel` decides everything
// else. Three of its decisions are ones an ordinary-looking edit would quietly
// reverse:
//
//  - Every index it reports is a MODEL index. The view's own position is not
//    the same number, and a grid that reported one for the other would delete
//    the wrong rule.
//  - A rule this build cannot understand is GREYED, not hidden — and its own
//    DELETE control stays live, because deleting by id needs no understanding
//    of the conditions.
//  - Greying is per rule. An editable rule beside an unsupported one stays
//    fully editable.
//
// Each is asserted here rather than left to a manual pass.
import AppKit

// MARK: - Assertions

private var failures = 0

private func expectString(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectInt(_ actual: Int, _ expected: Int, _ name: String) {
    expectString("\(actual)", "\(expected)", name)
}

// MARK: - Recording callbacks

/// What the grid told its owner, in order. A class so the closures below can
/// write into it without capturing an inout.
private final class Recorder {
    var addedRule = 0
    var removedRules: [Int] = []
    var addedConditions: [Int] = []
    var removedConditions: [(Int, Int)] = []
    var changed: [(Int, Int, TagCondition)] = []
    var invalid: [(Int, Int, TagConditionEditor.Invalid?)] = []

    var callbacks: TagRuleGridView.Callbacks {
        TagRuleGridView.Callbacks(
            addRule: { [self] in addedRule += 1 },
            removeRule: { [self] in removedRules.append($0) },
            addCondition: { [self] in addedConditions.append($0) },
            removeCondition: { [self] in removedConditions.append(($0, $1)) },
            changedCondition: { [self] in changed.append(($0, $1, $2)) },
            invalidCondition: { [self] in invalid.append(($0, $1, $2)) })
    }

    func reset() {
        addedRule = 0
        removedRules = []
        addedConditions = []
        removedConditions = []
        changed = []
        invalid = []
    }
}

// MARK: - Hosting and driving

/// Hosting the grid is what makes Auto Layout run; an unhosted view keeps
/// whatever frame its initializer gave it, so the layout measurements below
/// would measure the initializer's guess rather than the real grid.
///
/// The container's width is pinned REQUIRED, and the container is an ordinary
/// subview rather than the window's own content view. Both matter, and the
/// second was measured the hard way. An `NSWindow` states its own size to the
/// layout engine at a priority BELOW `.defaultHigh`, so any `.defaultHigh`
/// minimum inside the content makes the WINDOW grow instead of making the
/// content compress: hosting straight on the content view, a 420pt window
/// measured 553pt across and every overflow assertion below passed by moving
/// the goalposts. A container that cannot grow is what actually asks the
/// question "does this fit".
@discardableResult
private func host(_ grid: TagRuleGridView, width: CGFloat = 720) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width + 400, height: 1200),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 400, height: 1200))
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(container)
    container.addSubview(grid)
    grid.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.widthAnchor.constraint(equalToConstant: width),
        container.heightAnchor.constraint(equalToConstant: 1180),
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        grid.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    return window
}

/// Types into a field the way the app does: the text changes, then the field's
/// OWN delegate is told.
///
/// Routed through `field.delegate` rather than through the row directly, so
/// that `field.delegate = row` is itself under test. (Posting
/// `NSControl.textDidChangeNotification` was the other candidate; it depends on
/// AppKit's own observer registration, which is set up when a field editor
/// begins editing and therefore does not exist in a window that is never shown.)
/// A DISABLED field refuses the text outright. Driving the delegate reaches
/// past enablement, so without this a greyed row would still appear to report
/// its edits — which is how the blanket-disable mutation nearly passed a named
/// assertion.
private func type(_ field: NSTextField, _ text: String) {
    guard field.isEnabled, field.isEditable else {
        failures += 1
        print("FAIL nothing can be typed into a disabled field")
        return
    }
    field.stringValue = text
    guard let delegate = field.delegate else {
        failures += 1
        print("FAIL the field has no delegate, so nothing can be typed into it")
        return
    }
    delegate.controlTextDidChange?(
        Notification(name: NSControl.textDidChangeNotification, object: field))
}

/// Every value field of one group, in the order the group drew them.
private func values(_ group: TagRuleGroupView) -> [String] {
    group.conditionRows.map(\.valueField.stringValue)
}

// MARK: - Fixtures

private func cond(_ family: String, _ display: String,
                  kind: TagConditionKind = .exact) -> TagCondition {
    TagCondition(family: family, kind: kind,
                 value: TagValueNormalizer.normalize(display, family: family),
                 display: display)
}

private func storedRule(_ id: String, _ conditions: [TagCondition]) -> TagRule {
    TagRule(id: id, conditions: conditions, tupleKey: id,
            originConnection: "", originTable: "", createdAt: "2026-01-01T00:00:00Z")
}

private func storedTag(_ rules: [TagRule]) -> Tag {
    Tag(id: "tag-1", name: "Suspect", colorIndex: 0, note: nil,
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", rules: rules)
}

private func editable(_ rules: [EditableRule]) -> EditableTag {
    EditableTag(id: "tag-1", name: "Suspect", colorIndex: 0, note: "", rules: rules)
}

func runTests() {
    let log = Recorder()

    // MARK: 1 — one group per rule, and none at all for a tag with no rules

    let two = editable([
        EditableRule(id: "r1", conditions: [cond("address", "10.0.0.1")]),
        EditableRule(id: "r2", conditions: [cond("text", "evil.com"),
                                            cond("numeric", "443")]),
    ])
    let grid = TagRuleGridView()
    host(grid)
    grid.render(two, callbacks: log.callbacks)
    grid.layoutSubtreeIfNeeded()
    expectInt(grid.groups.count, 2, "a tag with two rules renders two rule groups")

    let empty = TagRuleGridView()
    host(empty)
    empty.render(editable([]), callbacks: Recorder().callbacks)
    expectInt(empty.groups.count, 0, "a tag with no rules renders no rule group")
    expectTrue(empty.addRuleButton.isEnabled,
               "and the add-rule control is still there, so the first rule can be made")

    // MARK: 2 — one row per condition, in the rule's own order

    if grid.groups.count == 2 {
        expectInt(grid.groups[0].conditionRows.count, 1, "the first rule renders one row")
        expectString(values(grid.groups[0]).joined(separator: "|"), "10.0.0.1",
                     "holding its condition's display text")
        expectInt(grid.groups[1].conditionRows.count, 2, "the second rule renders two rows")
        expectString(values(grid.groups[1]).joined(separator: "|"), "evil.com|443",
                     "in the rule's own order")
    }

    // MARK: 3 — a rule this build cannot understand is GREYED, not hidden

    // `isEditable` is false exactly when a condition carries a kind from a
    // newer build. The analyst must still SEE what such a rule matches, in
    // order to decide whether to delete it.
    let frozenRule = EditableRule(id: "r9", conditions: [
        cond("type:bytea", "safe\u{202E}gpj.exe", kind: .unsupported("startsWith")),
        cond("text", "still readable"),
    ])
    let frozenGrid = TagRuleGridView()
    let frozenLog = Recorder()
    host(frozenGrid)
    frozenGrid.render(editable([frozenRule]), callbacks: frozenLog.callbacks)
    frozenGrid.layoutSubtreeIfNeeded()
    expectInt(frozenGrid.groups.count, 1, "an unsupported rule still renders a group")
    if frozenGrid.groups.count == 1 {
        let group = frozenGrid.groups[0]
        expectTrue(!group.isEditableRule, "the group knows the rule cannot be edited")
        expectInt(group.conditionRows.count, 2,
                  "and renders EVERY condition of it, unknown kind included")
        for (index, row) in group.conditionRows.enumerated() {
            expectTrue(!row.familyPopup.isEnabled
                        && !row.operatorPopup.isEnabled
                        && !row.valueField.isEnabled
                        && !row.removeButton.isEnabled,
                       "row \(index) of an unsupported rule has every control disabled")
            // Hidden is NOT greyed. A hidden field keeps its `stringValue`, so
            // a readability assertion alone cannot tell the two apart — this is
            // the one that can.
            expectTrue(!row.isHidden
                        && !row.familyPopup.isHidden
                        && !row.operatorPopup.isHidden
                        && !row.valueField.isHidden,
                       "row \(index) is VISIBLE — greyed, not hidden")
            expectTrue(row.frame.width > 20 && row.frame.height > 0,
                       "and drawn with real size (\(Int(row.frame.width))x\(Int(row.frame.height)))")
        }
        expectString(values(group).joined(separator: "|"),
                     "safe\u{202E}gpj.exe|still readable",
                     "and the values are still READABLE, byte for byte")
        // A greyed row with no explanation is just a broken row.
        expectTrue(!group.unsupportedNotice.isHidden,
                   "the group says WHY it is greyed")
        expectTrue(!group.unsupportedNotice.stringValue.isEmpty,
                   "with words, not an empty label")

        // MARK: 4 — the rule's own delete stays live

        // Deleting by id needs no understanding of the conditions, and an
        // analyst must be able to remove a rule they cannot edit. The
        // CONDITION removes stay dead: a rule missing one condition is EASIER
        // to satisfy than the analyst wrote, which is a false match.
        expectTrue(group.deleteRuleButton.isEnabled,
                   "an unsupported rule can still be DELETED WHOLE")
        expectTrue(!group.addConditionButton.isEnabled,
                   "but nothing can be added to it")
        expectTrue(group.conditionRows.allSatisfy { !$0.removeButton.isEnabled },
                   "and no single condition can be taken out of it")
        frozenLog.reset()
        group.deleteRuleButton.performClick(nil)
        expectInt(frozenLog.removedRules.count, 1,
                  "clicking that delete reports the rule")
        if frozenLog.removedRules.count == 1 {
            expectInt(frozenLog.removedRules[0], 0, "by its model index")
        }
    }

    // MARK: 5 — every index reported is a MODEL index

    // The view's own position is NOT the same number: the grid draws a caption
    // above the groups, so group N sits at arranged position N+1. A grid that
    // read its index off the view tree would delete the wrong rule.
    var model = TagManagerModel(
        tags: [storedTag([storedRule("r1", [cond("address", "10.0.0.1")]),
                          storedRule("r2", [cond("text", "evil.com")])])],
        mode: .manage)
    let indexGrid = TagRuleGridView()
    let indexLog = Recorder()
    host(indexGrid)
    indexGrid.render(model.tags[0], callbacks: indexLog.callbacks)
    expectInt(indexGrid.groups.count, 2, "both rules render before the delete")

    model.removeRule(at: 0, fromTagAt: 0)
    indexGrid.render(model.tags[0], callbacks: indexLog.callbacks)
    indexGrid.layoutSubtreeIfNeeded()
    expectInt(indexGrid.groups.count, 1, "re-rendering after a delete leaves ONE group")
    // A stale group left in `subviews` — what `removeArrangedSubview` alone
    // does — is invisible to `groups.count` but shifts every view position.
    expectInt(indexGrid.subviews.compactMap { $0 as? TagRuleGroupView }.count, 1,
              "and no stale group is left behind in the view tree")
    if indexGrid.groups.count == 1 {
        expectString(values(indexGrid.groups[0]).joined(separator: "|"), "evil.com",
                     "the surviving group is the SECOND rule")
        indexLog.reset()
        indexGrid.groups[0].deleteRuleButton.performClick(nil)
        expectInt(indexLog.removedRules.count, 1, "deleting it reports once")
        if indexLog.removedRules.count == 1 {
            expectInt(indexLog.removedRules[0], 0,
                      "with its MODEL index, not its position in the view tree")
        }
    }

    // MARK: 6 — a change carries the right (rule, condition) pair

    log.reset()
    if grid.groups.count == 2, grid.groups[1].conditionRows.count == 2 {
        type(grid.groups[1].conditionRows[1].valueField, "8443")
        expectInt(log.changed.count, 1, "editing a row reports one condition")
        if log.changed.count == 1 {
            expectInt(log.changed[0].0, 1, "from the SECOND rule")
            expectInt(log.changed[0].1, 1, "and its SECOND condition")
            expectString(log.changed[0].2.display, "8443", "carrying the typed text")
        }
        // A refusal must carry the same pair, or the owner cannot draw it
        // against the row that caused it.
        log.reset()
        type(grid.groups[1].conditionRows[0].valueField, "")
        expectInt(log.invalid.count, 1, "an empty value is reported as invalid")
        if log.invalid.count == 1 {
            expectInt(log.invalid[0].0, 1, "from the second rule")
            expectInt(log.invalid[0].1, 0, "and its FIRST condition")
        }
        // Removing one condition names the pair too.
        log.reset()
        grid.groups[1].conditionRows[0].removeButton.performClick(nil)
        expectInt(log.removedConditions.count, 1, "removing a condition reports once")
        if log.removedConditions.count == 1 {
            expectInt(log.removedConditions[0].0, 1, "from the second rule")
            expectInt(log.removedConditions[0].1, 0, "naming the first condition")
        }
    }

    // MARK: 7 — add-condition names its own rule

    log.reset()
    if grid.groups.count == 2 {
        grid.groups[1].addConditionButton.performClick(nil)
        expectInt(log.addedConditions.count, 1, "the second rule's add reports once")
        if log.addedConditions.count == 1 {
            expectInt(log.addedConditions[0], 1, "with that rule's index")
        }
        grid.groups[0].addConditionButton.performClick(nil)
        expectInt(log.addedConditions.count, 2, "the first rule's add reports too")
        if log.addedConditions.count == 2 {
            expectInt(log.addedConditions[1], 0, "with ITS index")
        }
    }

    // MARK: 8 — the grid's own add

    log.reset()
    grid.addRuleButton.performClick(nil)
    expectInt(log.addedRule, 1, "the add-rule control reports exactly once")

    // MARK: 9 — greying is per RULE, not per grid

    // A blanket disable is the plausible bug: one unsupported rule freezing the
    // whole tag would make every other rule uneditable for no reason.
    let mixed = editable([
        EditableRule(id: "ok", conditions: [cond("text", "editable.example")]),
        EditableRule(id: "frozen", conditions: [
            cond("type:bytea", "opaque", kind: .unsupported("startsWith"))]),
    ])
    let mixedGrid = TagRuleGridView()
    let mixedLog = Recorder()
    host(mixedGrid)
    mixedGrid.render(mixed, callbacks: mixedLog.callbacks)
    mixedGrid.layoutSubtreeIfNeeded()
    expectInt(mixedGrid.groups.count, 2, "both rules of a mixed tag render")
    if mixedGrid.groups.count == 2 {
        let live = mixedGrid.groups[0]
        let dead = mixedGrid.groups[1]
        expectTrue(live.isEditableRule, "the supported rule is editable")
        expectTrue(!dead.isEditableRule, "the unsupported one is not")
        expectTrue(live.addConditionButton.isEnabled,
                   "the supported rule can still take a new condition")
        expectTrue(live.deleteRuleButton.isEnabled, "and can still be deleted")
        expectTrue(live.unsupportedNotice.isHidden,
                   "and says nothing about newer versions, because nothing is wrong with it")
        expectTrue(live.conditionRows.allSatisfy {
                       $0.familyPopup.isEnabled && $0.operatorPopup.isEnabled
                           && $0.valueField.isEnabled && $0.removeButton.isEnabled
                   },
                   "every control of the supported rule stays ENABLED beside the frozen one")
        expectTrue(dead.conditionRows.allSatisfy { !$0.valueField.isEnabled },
                   "while the unsupported rule stays greyed")
        // And it still WORKS, not merely looks enabled.
        mixedLog.reset()
        if live.conditionRows.count == 1 {
            type(live.conditionRows[0].valueField, "changed.example")
            expectInt(mixedLog.changed.count, 1,
                      "the supported rule's row still reports its edits")
            if mixedLog.changed.count == 1 {
                expectInt(mixedLog.changed[0].0, 0, "as rule 0")
            }
        }
    }

    // MARK: 10 — a bordered group of many conditions stays inside the grid

    // Measured, not assumed. Task 1 found a defect no behavioural assertion
    // could see: two fields hugging at the same priority let the solver give
    // one of them all the slack, collapsing the other to ZERO width. Every
    // callback fired correctly against a field nobody could reach.
    let many = editable([EditableRule(id: "big", conditions: [
        cond("address", "10.0.0.1"), cond("address", "192.168.0.0/16", kind: .cidr),
        cond("text", "evil.com"), cond("text", "*.bad.example", kind: .glob),
        cond("numeric", "443"), cond("numeric", "1000", kind: .between),
        cond("temporal", "2026-01-01"), cond("uuid", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"),
    ])])
    for width in [720.0, 420.0] as [CGFloat] {
        let wide = TagRuleGridView()
        host(wide, width: width)
        wide.render(many, callbacks: Recorder().callbacks)
        wide.layoutSubtreeIfNeeded()
        guard wide.groups.count == 1 else {
            failures += 1
            print("FAIL the many-condition tag did not render one group at \(Int(width))pt")
            continue
        }
        let group = wide.groups[0]
        expectTrue(wide.frame.width <= width + 0.5,
                   "at \(Int(width))pt the grid stays inside its container "
                    + "(\(Int(wide.frame.width)))")
        expectTrue(group.frame.width <= wide.frame.width + 0.5,
                   "and the bordered group stays inside the grid "
                    + "(\(Int(group.frame.width)) vs \(Int(wide.frame.width)))")
        expectInt(group.conditionRows.count, 8, "all eight conditions are drawn at \(Int(width))pt")
        var narrowest = CGFloat.greatestFiniteMagnitude
        var overflow = false
        for row in group.conditionRows {
            narrowest = min(narrowest, row.valueField.frame.width)
            // The remove button is the LAST control on the line, so its right
            // edge is where the row really ends. A row wider than the strip it
            // was given has overflowed the border it is drawn inside.
            if row.removeButton.frame.maxX > row.controlsRow.frame.width + 0.5 { overflow = true }
        }
        expectTrue(!overflow,
                   "no condition row overflows its own group at \(Int(width))pt")
        expectTrue(narrowest > 20,
                   "and every value field keeps real width at \(Int(width))pt "
                    + "(narrowest \(Int(narrowest)))")
        // Reported, not asserted: the width below which the group must start
        // compressing its own controls. Useful to whoever chooses the sheet's
        // width; not a property of this view.
        print("NOTE at \(Int(width))pt the eight-condition group's natural width is "
              + "\(Int(wide.fittingSize.width))pt")
    }

    // MARK: A note on focus, not an assertion
    //
    // `render` rebuilds from scratch, so a field the analyst is typing in is
    // destroyed and replaced. Whether the caret survives that is a DESIGN
    // decision for the owner, not a property of this view, so it is measured
    // and reported rather than pinned.
    let focusGrid = TagRuleGridView()
    let focusWindow = host(focusGrid)
    focusGrid.render(two, callbacks: Recorder().callbacks)
    focusGrid.layoutSubtreeIfNeeded()
    if let field = focusGrid.groups.first?.conditionRows.first?.valueField {
        let took = focusWindow.makeFirstResponder(field)
        let focusedBefore = isFocused(field, in: focusWindow)
        focusGrid.render(two, callbacks: Recorder().callbacks)
        let after = focusGrid.groups.first?.conditionRows.first?.valueField
        let focusedAfter = after.map { isFocused($0, in: focusWindow) } ?? false
        print("NOTE focus: makeFirstResponder=\(took) beforeRender=\(focusedBefore) "
              + "afterRender=\(focusedAfter)")
    }

    print(failures == 0 ? "\nAll TagRuleGridView tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

/// Is this field the one being edited? A focused `NSTextField` is not itself
/// the first responder — its field editor is, and the field is that editor's
/// delegate.
private func isFocused(_ field: NSTextField, in window: NSWindow) -> Bool {
    if window.firstResponder === field { return true }
    guard let editor = window.firstResponder as? NSTextView else { return false }
    return editor.delegate === field
}
