// Standalone test runner for TagConditionRowView. Uses real AppKit: the row is
// hosted in a headless, never-shown NSWindow so Auto Layout runs, and the real
// controls are driven through their own target/action and delegate wiring —
// the same approach as PharosTests/TagRemovalSheetTests.swift.
//
// What this suite is FOR. The row is the only place in the app where a
// condition is AUTHORED, and three of its decisions are ones an ordinary-looking
// edit would quietly reverse:
//
//  - The value is NEVER sanitised. It DESCRIBES hostile data, so a bidi
//    override an analyst types must survive into `display` byte for byte. The
//    badge discloses it instead.
//  - A rule this build cannot understand is GREYED, not hidden. Its values must
//    stay readable even though they cannot be changed.
//  - The upper bound belongs to `between` alone, and to nothing else.
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

/// What the row told its owner, in order. A class so the closures below can
/// write into it without capturing an inout.
private final class Recorder {
    var changed: [TagCondition] = []
    var invalid: [TagConditionEditor.Invalid?] = []
    var removed = 0

    var callbacks: TagConditionRowView.Callbacks {
        TagConditionRowView.Callbacks(
            changed: { [self] in changed.append($0) },
            invalid: { [self] in invalid.append($0) },
            removed: { [self] in removed += 1 })
    }

    func reset() {
        changed = []
        invalid = []
        removed = 0
    }
}

// MARK: - Hosting and driving

/// Hosting the row is what makes Auto Layout run; an unhosted view keeps
/// whatever frame its initializer gave it, so the layout measurements below
/// would measure the initializer's guess rather than the real row.
private func host(_ row: TagConditionRowView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
    container.addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        row.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    return window
}

/// Types into a field the way the app does: the text changes, then the field's
/// OWN delegate is told.
///
/// Routed through `field.delegate` rather than through the row directly, so
/// that `field.delegate = row` is itself under test — a row that forgot to
/// claim the field fires nothing and every assertion below it fails. (Posting
/// `NSControl.textDidChangeNotification` was the other candidate; it depends on
/// AppKit's own observer registration, which is set up when a field editor
/// begins editing and therefore does not exist in a window that is never shown.)
private func type(_ field: NSTextField, _ text: String) {
    field.stringValue = text
    guard let delegate = field.delegate else {
        failures += 1
        print("FAIL the field has no delegate, so nothing can be typed into it")
        return
    }
    delegate.controlTextDidChange?(
        Notification(name: NSControl.textDidChangeNotification, object: field))
}

/// Chooses a popup row by its stored value and fires the popup's real action,
/// which is what a click does. `selectItem` alone changes the selection without
/// telling anybody.
private func choose(_ value: String, in popup: NSPopUpButton, _ what: String) {
    PopupValueMenu.selectValue(value, in: popup)
    if PopupValueMenu.selectedValue(in: popup) != value {
        failures += 1
        print("FAIL there is no \(what) row for \(value.debugDescription) to choose")
        return
    }
    popup.sendAction(popup.action, to: popup.target)
}

private func titles(_ popup: NSPopUpButton) -> [String] {
    popup.itemArray.map(\.title)
}

// MARK: - Fixtures

private func condition(_ family: String, _ display: String,
                       kind: TagConditionKind = .exact, operand2: String? = nil) -> TagCondition {
    TagCondition(family: family, kind: kind,
                 value: TagValueNormalizer.normalize(display, family: family),
                 operand2: operand2, display: display)
}

private func makeRow(_ c: TagCondition, editable: Bool = true)
    -> (row: TagConditionRowView, log: Recorder) {
    let log = Recorder()
    let row = TagConditionRowView(condition: c, isEditable: editable, callbacks: log.callbacks)
    _ = host(row)
    return (row, log)
}

func runTests() {
    let (row, log) = makeRow(condition("text", "evil.com"))

    // MARK: 1 — the family popup offers every family this build can describe

    // In `TagFamilyLabel`'s own order, and with its own words. A second list
    // here could drift from the one the Inspector and the removal sheet read.
    expectString(titles(row.familyPopup).joined(separator: "|"),
                 TagFamilyLabel.known.map(\.label).joined(separator: "|"),
                 "the family popup lists every known family, in TagFamilyLabel's order")
    expectString(PopupValueMenu.selectedValue(in: row.familyPopup) ?? "<none>", "text",
                 "and starts on the condition's own family")

    // MARK: 2 — the operators follow the family

    // `TagConditionEditor` owns which operators a family offers. The row asks
    // it; it must not hold a second list.
    expectString(titles(row.operatorPopup).joined(separator: "|"), "is|matches",
                 "Text offers exactly is and matches")

    choose("uuid", in: row.familyPopup, "family")
    expectString(titles(row.operatorPopup).joined(separator: "|"), "is",
                 "UUID offers only is")

    choose("temporal", in: row.familyPopup, "family")
    expectTrue(titles(row.operatorPopup).contains("after"),
               "Date & time reads its comparator as after")
    expectTrue(!titles(row.operatorPopup).contains(">"),
               "and never as the bare comparator — that is a number's word, not a date's")

    choose("numeric", in: row.familyPopup, "family")
    expectTrue(titles(row.operatorPopup).contains(">"),
               "Number reads the same comparator as > ")
    expectString(titles(row.operatorPopup).joined(separator: "|"),
                 TagConditionEditor.operators(for: "numeric")
                    .map { TagConditionEditor.label(for: $0, family: "numeric") }
                    .joined(separator: "|"),
                 "every operator Number offers is on the popup, in the editor's order")

    // MARK: 3 — the hint, and 4 — the upper bound

    // The hint is ALWAYS visible for an operator that has one, never on focus.
    // An operator that explains itself has no hint rather than a filler
    // sentence the reader learns to skip.
    for kind in TagConditionEditor.operators(for: "numeric") {
        choose(kind.rawValue, in: row.operatorPopup, "operator")
        expectString(row.hintLabel.stringValue, TagConditionEditor.hint(for: kind),
                     "the hint for numeric/\(kind.rawValue) is the editor's own")
        expectTrue(row.upperField.isHidden == (kind != .between),
                   "the upper bound is shown for between alone (numeric/\(kind.rawValue))")
    }

    choose("text", in: row.familyPopup, "family")
    choose("exact", in: row.operatorPopup, "operator")
    expectString(row.hintLabel.stringValue, "", "`is` needs no hint at all")
    choose("glob", in: row.operatorPopup, "operator")
    expectTrue(row.hintLabel.stringValue.contains("*"),
               "`matches` answers how to wildcard, under the field")

    // A hidden upper field must leave NO gap: an NSStackView detaches a hidden
    // arranged subview, and a row that reserved its space would show an empty
    // slot beside every operator that takes no bound.
    choose("numeric", in: row.familyPopup, "family")
    choose("between", in: row.operatorPopup, "operator")
    row.layoutSubtreeIfNeeded()
    let upperWidth = row.upperField.frame.width
    let valueWithUpper = row.valueField.frame.width
    // BOTH bounds, not just one. Measured before the equal-width pin existed:
    // the upper bound took 381pt and the value field collapsed to ZERO, so the
    // LOWER bound of a range could be neither read nor typed. Nothing else in
    // this suite can see that — every callback fires correctly against a field
    // no one can reach.
    expectTrue(upperWidth > 20, "a shown upper bound gets real width (\(Int(upperWidth)))")
    expectTrue(valueWithUpper > 20,
               "and the value field keeps real width beside it (\(Int(valueWithUpper)))")
    // Within a point: an odd remaining width cannot split into two equal
    // halves, so the solver rounds one of them.
    expectTrue(abs(valueWithUpper - upperWidth) <= 1,
               "the two bounds of a range share the slack evenly "
                + "(\(Int(valueWithUpper)) vs \(Int(upperWidth)))")
    choose("greaterThan", in: row.operatorPopup, "operator")
    row.layoutSubtreeIfNeeded()
    // The width the upper bound had must go back to the VALUE field. A stack
    // that merely made it invisible would leave that space empty, and the
    // frames alone cannot tell the two apart — only the reclaim can.
    expectTrue(row.valueField.frame.width >= valueWithUpper + upperWidth - 1,
               "hiding the upper bound gives its width back, leaving no gap "
                + "(value \(Int(row.valueField.frame.width)) was \(Int(valueWithUpper)) "
                + "+ upper \(Int(upperWidth)))")
    expectTrue(row.controlsRow.detachesHiddenViews,
               "the controls row detaches a hidden arranged subview rather than reserving it")

    // MARK: 5 — the typed value survives byte for byte

    choose("text", in: row.familyPopup, "family")
    choose("exact", in: row.operatorPopup, "operator")
    log.reset()
    type(row.valueField, "10.0.0.1")
    expectInt(log.changed.count, 1, "a valid value is reported once")
    if log.changed.count == 1 {
        expectString(log.changed[0].display, "10.0.0.1", "and carries the typed text")
        expectString(log.changed[0].family, "text", "with the chosen family")
        expectTrue(log.changed[0].kind == .exact, "and the chosen operator")
    }

    // A condition value is TIER 1 — never altered. An analyst hunting Trojan
    // Source or IDN homograph abuse must be able to NAME a hostname that
    // genuinely carries a bidi override; sanitising the field would destroy the
    // hunt this feature exists for.
    log.reset()
    let bidi = "ev\u{202E}il.com"
    type(row.valueField, bidi)
    expectInt(log.changed.count, 1, "a value holding a bidi override is still valid")
    if log.changed.count == 1 {
        expectString(log.changed[0].display, bidi,
                     "and its display is the typed text BYTE FOR BYTE, override included")
        expectTrue(log.changed[0].display.unicodeScalars.contains("\u{202E}"),
                   "the override itself survives")
    }

    // MARK: 8 — the badge discloses what the field cannot

    // Both directions. A badge that never hides is as wrong as one that never
    // shows: it would outlive the value that raised it and cry wolf on the next.
    expectTrue(!row.badge.isHidden, "the badge is raised for an invisible scalar")
    type(row.valueField, "plain.example.com")
    expectTrue(row.badge.isHidden, "and lowered again when the value is ordinary")

    // MARK: 6 and 7 — a refusal, and its correction

    let (cidr, cidrLog) = makeRow(condition("address", "10.0.0.0/8"))
    choose("address", in: cidr.familyPopup, "family")
    choose("cidr", in: cidr.operatorPopup, "operator")
    cidrLog.reset()
    type(cidr.valueField, "10.2.3.999")
    expectInt(cidrLog.changed.count, 0, "a malformed CIDR is never reported as a condition")
    expectInt(cidrLog.invalid.count, 1, "it is reported as invalid instead")
    expectTrue(cidrLog.invalid.first.flatMap { $0 } != nil, "with a reason, not a cleared error")
    expectTrue(!cidr.errorLabel.stringValue.isEmpty,
               "and the row says what is wrong, beside the field")

    cidrLog.reset()
    type(cidr.valueField, "10.2.3.0/24")
    expectInt(cidrLog.changed.count, 1, "correcting it reports the condition")
    expectString(cidr.errorLabel.stringValue, "", "and clears the error")
    expectTrue(cidrLog.invalid.contains { $0 == nil },
               "the owner is told the error cleared, so it can re-enable Save")

    // MARK: 9 — removal

    log.reset()
    row.removeButton.performClick(nil)
    expectInt(log.removed, 1, "the remove button reports exactly once")

    // MARK: 10 — a rule this build cannot understand is GREYED, not hidden

    // The analyst can SEE what it matches even though nothing here can change
    // it. Hiding the controls would hide the values with them, and an
    // unreadable rule is one nobody can decide whether to delete.
    let stored = condition("type:bytea", "safe\u{202E}gpj.exe", kind: .unsupported("startsWith"))
    let (frozen, frozenLog) = makeRow(stored, editable: false)
    expectTrue(!frozen.familyPopup.isEnabled, "the family popup is disabled")
    expectTrue(!frozen.operatorPopup.isEnabled, "the operator popup is disabled")
    expectTrue(!frozen.valueField.isEnabled, "the value field is disabled")
    // An unsupported rule is deleted WHOLE, not condition by condition: a rule
    // missing one condition is EASIER to satisfy than the analyst wrote, and a
    // too-easy rule is a false match.
    expectTrue(!frozen.removeButton.isEnabled, "and so is the remove button")
    expectString(frozen.valueField.stringValue, "safe\u{202E}gpj.exe",
                 "and the value is still READABLE — greyed, not hidden")
    expectTrue(!frozen.familyPopup.isHidden && !frozen.operatorPopup.isHidden
                && !frozen.valueField.isHidden && !frozen.removeButton.isHidden,
               "none of the four controls is hidden")
    expectTrue(!frozen.badge.isHidden,
               "a stored hostile value is disclosed even where it cannot be edited")
    // The operator popup must still SAY what the stored rule tests, even though
    // this build cannot evaluate it.
    expectTrue(titles(frozen.operatorPopup).contains("startsWith"),
               "the unsupported operator is shown by its own raw value")
    expectTrue(titles(frozen.familyPopup).contains(TagFamilyLabel.text(for: "type:bytea")),
               "and the exotic family is on the popup rather than mislabelled as Text")
    // A disabled control fires nothing, so nothing can be authored from here.
    frozen.removeButton.performClick(nil)
    expectInt(frozenLog.removed, 0, "a disabled remove button commits nothing")

    print(failures == 0 ? "\nAll TagConditionRowView tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
