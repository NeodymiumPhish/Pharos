// Standalone test runner for TagManagerSheet. Uses real AppKit: the sheet is
// hosted in a headless, never-shown NSWindow so Auto Layout runs, and the real
// controls are driven through their own target/action and delegate wiring —
// the same approach as PharosTests/TagRuleGridViewTests.swift.
//
// What this suite is FOR. The sheet is the shell around parts that are already
// tested: the matching engine, the condition editor, the model and the rule
// grid. What is NEW here is the wiring, and four of its decisions are ones an
// ordinary-looking edit would quietly reverse:
//
//  - The grid is re-rendered ONLY on a STRUCTURAL change. `render` destroys the
//    field the analyst is typing in, and `changedCondition` fires per
//    keystroke, so a re-render there makes the value field unusable. Pinned by
//    comparing the identity of a value field across a keystroke.
//  - The NAME field is sanitised as it is typed; the NOTE field is NOT. A name
//    is an authored label this app then draws in its own voice; a note is prose
//    that is EDITED here, so escaping it would save the escape tokens.
//  - Edits commit on SAVE, exactly once — never per keystroke, because
//    `TagStore.reloadTags` posts a global change that rebuilds every open
//    grid's match.
//  - A save that fails leaves the sheet OPEN with the edits intact.
//
// Each is asserted here rather than left to a manual pass.
import AppKit

// MARK: - Recording committer

/// The sheet commits through `TagManagerCommitting`, which sits in its own
/// dependency-free file, so this suite supplies its own conformer and the real
/// `TagStore` — `@MainActor` and Keychain-bound through the FFI — stays out of
/// the binary entirely. Same shape as `TagRemovalSheetTests`' `RecordingRemover`.
///
/// A conformer, NOT a stand-in for the store: `TagStore` conforms in
/// `TagStore.swift`, so a change to `apply(_:)` fails the APP build rather than
/// letting this suite pass against something that no longer matches.
private final class RecordingCommitter: TagManagerCommitting {
    /// One entry per `apply` call. The COUNT is the assertion that matters:
    /// a per-keystroke commit would push this past one.
    private(set) var applied: [[TagManagerCommit]] = []
    /// Set to make every commit throw, standing in for a Rust-side failure.
    var failure: Error?

    func apply(_ commits: [TagManagerCommit]) throws {
        applied.append(commits)
        if let failure { throw failure }
    }
}

private struct StoreFailure: Error {}

/// Counts what `dismiss(nil)` cannot be asked: whether the sheet closed.
///
/// `dismiss(nil)` is a no-op on a controller that was never presented, so the
/// sheet reports its own closing through `onClose` — which it calls IN ADDITION
/// to dismissing, so the app's behaviour does not depend on anyone listening.
private final class CloseCounter {
    var count = 0
}

private func countClosings(_ sheet: TagManagerSheet) -> CloseCounter {
    let counter = CloseCounter()
    sheet.onClose = { counter.count += 1 }
    return counter
}

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

// MARK: - Hosting and driving

/// Hosting the sheet is what makes Auto Layout run.
///
/// The container's width is pinned REQUIRED, and the container is an ordinary
/// subview rather than the window's own content view: an `NSWindow` states its
/// own size BELOW `.defaultHigh`, so hosting straight on the content view lets
/// the window GROW instead of making the content compress, and any overflow
/// question would be answered by moving the goalposts.
@discardableResult
private func host(_ sheet: TagManagerSheet, width: CGFloat = 900) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width + 300, height: 900),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 300, height: 900))
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(container)
    let content = sheet.view
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
        container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        container.topAnchor.constraint(equalTo: root.topAnchor),
        container.widthAnchor.constraint(equalToConstant: width),
        container.heightAnchor.constraint(equalToConstant: 640),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        content.topAnchor.constraint(equalTo: container.topAnchor),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    return window
}

/// Types into a field the way the app does: the text changes, then the field's
/// OWN delegate is told.
///
/// Routed through `field.delegate` rather than through the sheet directly, so
/// that `field.delegate = sheet` is itself under test. (A never-shown window
/// has no field editor, so `NSControl.textDidChangeNotification` would depend
/// on observer registration that does not exist here.)
///
/// A DISABLED field refuses the text outright, and driving the delegate reaches
/// PAST enablement — so without this guard a greyed field would still appear to
/// report its edits.
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

/// Fires a control's action the way a click does, without depending on
/// `NSApplication` being up. Used for the colour control, whose segment must be
/// chosen BEFORE the action fires.
private func click(_ control: NSControl) {
    guard control.isEnabled else {
        failures += 1
        print("FAIL a disabled control cannot be clicked")
        return
    }
    guard let action = control.action, let target = control.target as? NSObject else {
        failures += 1
        print("FAIL the control has no target/action")
        return
    }
    target.perform(action, with: control)
}

/// Selects a sidebar row the way AppKit does: the table's selection changes,
/// then the table's OWN delegate is told. `tableViewSelectionDidChange` is
/// idempotent, so the explicit call is harmless if AppKit posted one too.
private func select(_ sheet: TagManagerSheet, row: Int) {
    guard let delegate = sheet.tableView.delegate else {
        failures += 1
        print("FAIL the sidebar table has no delegate")
        return
    }
    sheet.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    delegate.tableViewSelectionDidChange?(
        Notification(name: NSTableView.selectionDidChangeNotification, object: sheet.tableView))
}

/// One sidebar row's text, read from the real cell view the table would draw.
private func rowText(_ sheet: TagManagerSheet, _ row: Int) -> String {
    guard let column = sheet.tableView.tableColumns.first else {
        failures += 1
        print("FAIL the sidebar table has no column")
        return "<no column>"
    }
    guard row >= 0, row < sheet.tableView.numberOfRows else {
        failures += 1
        print("FAIL there is no sidebar row \(row)")
        return "<no row>"
    }
    guard let cell = sheet.tableView(sheet.tableView, viewFor: column, row: row)
            as? NSTableCellView, let field = cell.textField else {
        failures += 1
        print("FAIL sidebar row \(row) has no text field")
        return "<no cell>"
    }
    return field.stringValue
}

/// The `.update` payloads a save would write, in order.
private func updates(_ sheet: TagManagerSheet) -> [UpdateTag] {
    sheet.model.commits().compactMap {
        if case .update(let update) = $0 { return update }
        return nil
    }
}

/// The ids a save would delete.
private func deletedTagIds(_ commits: [TagManagerCommit]) -> [String] {
    commits.compactMap {
        if case .deleteTag(let id) = $0 { return id }
        return nil
    }
}

// MARK: - Fixtures

private let bidi = "\u{202E}"

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

private func storedTag(_ id: String, _ name: String, colorIndex: Int,
                       note: String?, _ rules: [TagRule]) -> Tag {
    Tag(id: id, name: name, colorIndex: colorIndex, note: note,
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", rules: rules)
}

/// Three tags: an ordinary one with two rules, a plain one, and one whose
/// stored name carries a bidi override.
private func fixtureTags() -> [Tag] {
    [
        storedTag("t1", "Suspect", colorIndex: 0, note: "watch closely", [
            storedRule("r1", [cond("address", "10.0.0.1")]),
            storedRule("r2", [cond("text", "evil.example")]),
        ]),
        storedTag("t2", "Beta", colorIndex: 3, note: nil, [
            storedRule("r3", [cond("numeric", "443")]),
        ]),
        storedTag("t3", "Case\(bidi)gpj.exe", colorIndex: 1, note: "", [
            storedRule("r4", [cond("text", "quiet")]),
        ]),
    ]
}

private func makeSheet(_ committer: RecordingCommitter,
                       tags: [Tag] = fixtureTags()) -> TagManagerSheet {
    TagManagerSheet(model: TagManagerModel(tags: tags, mode: .manage),
                    committer: committer, columns: [], loadedRows: [])
}

// MARK: - The suite

func runTests() {
    let committer = RecordingCommitter()
    let sheet = makeSheet(committer)
    host(sheet)

    // MARK: 1 — the sidebar lists exactly the visible tags

    expectInt(sheet.tableView.numberOfRows, sheet.model.visibleTagIndices.count,
              "the sidebar has one row per visible tag")
    expectInt(sheet.tableView.numberOfRows, 3, "which is all three of them")
    expectString(rowText(sheet, 0), "Suspect — 2 rules",
                 "a row names the tag and counts its rules")
    expectString(rowText(sheet, 1), "Beta — 1 rule",
                 "and says 'rule' in the singular for one")
    expectString(rowText(sheet, 2), "\(DisplayEscape.escaped("Case\(bidi)gpj.exe")) — 1 rule",
                 "a hostile name is ESCAPED in the list, which the app draws in its own voice")
    expectTrue(!rowText(sheet, 2).contains(bidi),
               "so the override itself never reaches the row")

    // MARK: 8a — Save is disabled with nothing changed, and says why

    expectTrue(!sheet.saveButton.isEnabled, "a sheet with no edits cannot be saved")
    expectString(sheet.statusLabel.stringValue, "Nothing has changed yet.",
                 "and says why, rather than presenting a dead button")

    // MARK: 2 — selecting a tag fills the identity controls from it

    select(sheet, row: 1)
    expectString(sheet.nameField.stringValue, "Beta", "selecting a tag fills the name")
    expectInt(sheet.colorControl.selectedSegment, 3, "and its colour")
    expectString(sheet.noteField.stringValue, "", "and a tag with no note shows an empty field")
    expectTrue(sheet.nameField.isEnabled && sheet.noteField.isEnabled
                && sheet.colorControl.isEnabled,
               "and the identity controls are live")

    select(sheet, row: 0)
    expectString(sheet.nameField.stringValue, "Suspect", "selecting another tag re-fills the name")
    expectInt(sheet.colorControl.selectedSegment, 0, "its colour")
    expectString(sheet.noteField.stringValue, "watch closely", "and its note")
    expectInt(sheet.grid.groups.count, 2, "and the grid shows that tag's rules")

    // MARK: 3 — editing the name updates the MODEL

    type(sheet.nameField, "Suspect Renamed")
    let renamed = updates(sheet)
    expectInt(renamed.count, 1, "renaming a tag makes exactly one update commit")
    if renamed.count == 1 {
        expectString(renamed[0].id, "t1", "for the selected tag")
        expectString(renamed[0].name ?? "<nil>", "Suspect Renamed", "carrying the typed name")
    }
    expectString(rowText(sheet, 0), "Suspect Renamed — 2 rules",
                 "and the sidebar row follows the edit")
    expectTrue(sheet.saveButton.isEnabled, "Save is now available")
    expectString(sheet.statusLabel.stringValue, "",
                 "and nothing is said about why it would not be")

    // MARK: 4 — clearing the note commits an empty STRING, never nil

    // nil means "leave it alone" in an UpdateTag, so nil could never clear a
    // note that is already there.
    type(sheet.noteField, "")
    let cleared = updates(sheet)
    expectInt(cleared.count, 1, "clearing the note still makes one update commit")
    if cleared.count == 1 {
        expectTrue(cleared[0].note != nil,
                   "the note is SENT — nil would mean 'leave it alone' and could never clear one")
        expectString(cleared[0].note ?? "<nil>", "", "and it is the empty string")
    }

    // MARK: 5 — the NAME field is sanitised as it is typed

    // A tag name is an authored label this app then draws in its own voice: a
    // bidi override in it makes every one of those surfaces read as something
    // the tag is not.
    type(sheet.nameField, "\(bidi)Suspect")
    expectTrue(!sheet.nameField.stringValue.contains(bidi),
               "a bidi override typed into the NAME field is taken out of the field itself")
    expectString(sheet.nameField.stringValue,
                 AuthoredLabelSanitizer.sanitized("\(bidi)Suspect"),
                 "leaving exactly what the sanitiser allows")
    let sanitisedName = updates(sheet)
    expectInt(sanitisedName.count, 1, "and one update commit still describes the tag")
    if sanitisedName.count == 1 {
        expectTrue(!(sanitisedName[0].name ?? bidi).contains(bidi),
                   "with the override gone from what would be STORED, not only from the field")
    }

    // MARK: 6 — the NOTE field is NOT sanitised

    // A note is prose, and it is EDITED here rather than rendered: escaping it
    // would save the escape tokens, and sanitising it would destroy a note that
    // legitimately quotes hostile text. It is DISCLOSED instead.
    let hostileNote = "seen as \(bidi)txt.exe"
    type(sheet.noteField, hostileNote)
    expectString(sheet.noteField.stringValue, hostileNote,
                 "the NOTE field keeps what was typed, byte for byte")
    let notedCommits = updates(sheet)
    expectInt(notedCommits.count, 1, "and one update commit carries it")
    if notedCommits.count == 1 {
        expectString(notedCommits[0].note ?? "<nil>", hostileNote,
                     "byte for byte, into the store")
    }
    expectTrue(!sheet.noteBadge.isHidden,
               "and a badge says an invisible character is in there")
    type(sheet.noteField, "seen as txt.exe")
    expectTrue(sheet.noteBadge.isHidden,
               "the badge lowers again once the override is gone")

    // MARK: 7 — a colour change reaches the model

    // Otherwise `recolour(tagAt:to:)` is unreachable from the UI.
    sheet.colorControl.selectedSegment = 4
    click(sheet.colorControl)
    let recoloured = updates(sheet)
    expectInt(recoloured.count, 1, "recolouring still describes the tag with one update")
    if recoloured.count == 1 {
        expectInt(recoloured[0].colorIndex ?? -1, 4, "carrying the chosen colour")
    }

    // MARK: 13 — typing a VALUE does not rebuild the grid

    // The focus defect, pinned. `render` destroys the field being typed in and
    // focus does not survive it, and `changedCondition` fires per keystroke —
    // so a re-render there makes the value field unusable. A value edit changes
    // nothing structural: the row already shows what was typed and owns its own
    // error line.
    guard sheet.grid.groups.count == 2, sheet.grid.groups[0].conditionRows.count == 1 else {
        failures += 1
        print("FAIL the selected tag did not render two rules with a row to type in")
        finish()
        return
    }
    let fieldBefore = sheet.grid.groups[0].conditionRows[0].valueField
    let groupBefore = sheet.grid.groups[0]
    type(fieldBefore, "10.0.0.99")
    expectInt(sheet.grid.groups.count, 2, "typing a value leaves the rule count alone")
    if sheet.grid.groups.count == 2, sheet.grid.groups[0].conditionRows.count == 1 {
        expectTrue(sheet.grid.groups[0].conditionRows[0].valueField === fieldBefore,
                   "and the very field being typed in SURVIVES — the grid is not re-rendered")
        expectTrue(sheet.grid.groups[0] === groupBefore,
                   "nor is the group around it")
    }
    let editedRule = sheet.model.commits().compactMap { commit -> UpdateTagRule? in
        if case .updateRule(let update) = commit { return update }
        return nil
    }
    expectInt(editedRule.count, 1, "and the edit still reached the model")
    if editedRule.count == 1, let first = editedRule[0].conditions.first {
        expectString(first.display, "10.0.0.99", "carrying the typed value")
    } else if editedRule.count == 1 {
        failures += 1
        print("FAIL the edited rule reached the model with no conditions")
    }

    // MARK: 14 — adding a RULE does re-render

    sheet.grid.addRuleButton.performClick(nil)
    expectInt(sheet.grid.groups.count, 3, "adding a rule draws a third group")
    // The stored tag has TWO rules. The sidebar says three, because it counts
    // what is being edited — every other surface in this sheet shows the edit
    // in progress, and a sidebar disagreeing with the grid about the same tag
    // would be read as a fault. (The name is back to "Suspect": the sanitising
    // assertion above typed over the rename.)
    expectString(rowText(sheet, 0), "Suspect — 3 rules",
                 "and the sidebar's rule count follows the EDIT, not the stored tag")
    expectTrue(!sheet.saveButton.isEnabled,
               "a rule whose one condition has no value yet holds Save back")
    expectTrue(sheet.statusLabel.stringValue.contains("value"),
               "and the reason names the missing value (\(sheet.statusLabel.stringValue.debugDescription))")

    // Take it away again, and Save comes back.
    if sheet.grid.groups.count == 3 {
        sheet.grid.groups[2].deleteRuleButton.performClick(nil)
    }
    expectInt(sheet.grid.groups.count, 2, "deleting that rule draws two groups again")
    expectTrue(sheet.saveButton.isEnabled, "and Save is available once more")

    // MARK: 8b — a rule emptied HERE blocks Save, and says which one

    if sheet.grid.groups.count == 2, sheet.grid.groups[0].conditionRows.count == 1 {
        sheet.grid.groups[0].conditionRows[0].removeButton.performClick(nil)
    }
    expectTrue(!sheet.saveButton.isEnabled, "a rule stripped of every condition blocks Save")
    expectTrue(sheet.statusLabel.stringValue.contains("Rule 1"),
               "and the reason names the rule (\(sheet.statusLabel.stringValue.debugDescription))")

    // MARK: 9 — Save commits once, and hands over exactly what the model says

    let saveCommitter = RecordingCommitter()
    let saving = makeSheet(saveCommitter)
    let savingClosings = countClosings(saving)
    host(saving)
    select(saving, row: 0)
    type(saving.nameField, "Renamed On Save")
    expectInt(saveCommitter.applied.count, 0,
              "typing commits NOTHING — a per-keystroke write would rebuild every open grid")
    let expected = saving.model.commits()
    expectTrue(saving.saveButton.isEnabled, "Save is available for a renamed tag")
    saving.saveButton.performClick(nil)
    expectInt(saveCommitter.applied.count, 1, "clicking Save commits EXACTLY ONCE")
    if saveCommitter.applied.count == 1 {
        expectTrue(saveCommitter.applied[0] == expected,
                   "handing over exactly what the model says, in order")
        expectInt(saveCommitter.applied[0].count, 1, "which here is one command")
        if let first = saveCommitter.applied[0].first, case .update(let update) = first {
            expectString(update.name ?? "<nil>", "Renamed On Save", "the rename")
        } else {
            failures += 1
            print("FAIL the one command was not an update")
        }
    }
    expectInt(savingClosings.count, 1, "and a save that lands closes the sheet")

    // MARK: 10 — a failing commit leaves the sheet OPEN, with the edits intact

    let failingCommitter = RecordingCommitter()
    failingCommitter.failure = StoreFailure()
    let failing = makeSheet(failingCommitter)
    let failingClosings = countClosings(failing)
    let failingWindow = host(failing)
    select(failing, row: 0)
    type(failing.nameField, "Edited But Unsaved")
    expectInt(failingWindow.sheets.count, 0, "a fresh sheet has no alert on it")
    failing.saveButton.performClick(nil)
    expectInt(failingCommitter.applied.count, 1, "the failing save was attempted once")
    expectInt(failingClosings.count, 0, "a save that fails does NOT close the sheet")
    expectInt(failingWindow.sheets.count, 1,
              "it raises an error alert, never a silent no-op")
    expectString(failing.nameField.stringValue, "Edited But Unsaved",
                 "and the edit is still in the field")
    let survived = updates(failing)
    expectInt(survived.count, 1, "and still in the model, ready to be saved again")
    if survived.count == 1 {
        expectString(survived[0].name ?? "<nil>", "Edited But Unsaved", "unchanged")
    }

    // MARK: 11 — "New tag" adds an editable tag and selects it

    let newCommitter = RecordingCommitter()
    let adding = makeSheet(newCommitter)
    host(adding)
    let beforeCount = adding.tableView.numberOfRows
    adding.newTagButton.performClick(nil)
    expectInt(adding.tableView.numberOfRows, beforeCount + 1, "the sidebar gains a row")
    expectInt(adding.selectedTagIndex ?? -1, adding.model.tags.count - 1,
              "and the new tag is the one selected")
    expectTrue(adding.nameField.isEnabled && adding.nameField.isEditable,
               "its name can be typed straight away")
    expectTrue(adding.grid.addRuleButton.isEnabled, "and a rule can be added to it")
    expectInt(adding.grid.groups.count, 0, "it starts with no rules")
    type(adding.nameField, "Fresh Case")
    let creates = adding.model.commits().compactMap { commit -> CreateTag? in
        if case .create(let create) = commit { return create }
        return nil
    }
    expectInt(creates.count, 1, "saving would create exactly one tag")
    if creates.count == 1 {
        expectString(creates[0].name, "Fresh Case", "under the typed name")
    }

    // MARK: 12 — the sidebar's delete removes the selected tag

    // Without this the capability ships dead: the model supports it and nothing
    // else would reach it.
    let deleteCommitter = RecordingCommitter()
    let deleting = makeSheet(deleteCommitter)
    host(deleting)
    select(deleting, row: 0)
    expectInt(deleting.selectedTagIndex ?? -1, 0, "the first tag is selected")
    expectTrue(deleting.deleteTagButton.isEnabled, "and it can be deleted")
    deleting.deleteTagButton.performClick(nil)
    expectInt(deleting.tableView.numberOfRows, 2, "the sidebar loses that row")
    expectTrue(!deleting.model.visibleTagIndices.contains(0),
               "and the tag leaves the visible set")
    expectTrue(deleting.selectedTagIndex.map { deleting.model.visibleTagIndices.contains($0) }
                ?? false,
               "the selection moves to a SURVIVING tag, never to the gap")
    expectString(deleting.nameField.stringValue, "Beta",
                 "which is the one that slid into the removed row")
    expectTrue(deleting.saveButton.isEnabled, "a staged delete is a change, so Save is available")
    deleting.saveButton.performClick(nil)
    expectInt(deleteCommitter.applied.count, 1, "saving commits once")
    if deleteCommitter.applied.count == 1 {
        expectString(deletedTagIds(deleteCommitter.applied[0]).joined(separator: ","), "t1",
                     "and the command is a delete naming that tag's id")
    }

    // MARK: 12b — deleting the LAST tag leaves no phantom behind

    let emptying = makeSheet(RecordingCommitter())
    host(emptying)
    for _ in 0..<3 {
        select(emptying, row: 0)
        emptying.deleteTagButton.performClick(nil)
    }
    expectInt(emptying.tableView.numberOfRows, 0, "every tag can be deleted")
    expectTrue(emptying.selectedTagIndex == nil, "and nothing is left selected")
    expectString(emptying.nameField.stringValue, "",
                 "the name field shows no phantom tag")
    expectTrue(!emptying.nameField.isEnabled && !emptying.noteField.isEnabled
                && !emptying.colorControl.isEnabled && !emptying.deleteTagButton.isEnabled,
               "the identity controls are dead, because there is nothing to edit")
    expectInt(emptying.grid.groups.count, 0, "and no rules are drawn for a tag that is not there")
    expectTrue(!emptying.emptyLabel.isHidden, "the empty sidebar says so in words")
    expectTrue(emptying.newTagButton.isEnabled,
               "and a new tag can still be made, so the sheet is not a dead end")

    finish()
}

private func finish() {
    print(failures == 0 ? "\nAll TagManagerSheet tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
