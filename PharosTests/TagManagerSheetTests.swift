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

/// Ticks or unticks a rule's checkbox the way a click does.
///
/// It refuses a HIDDEN box and a DISABLED one. A helper that reached past
/// either would let a mode that draws no checkboxes, or a rule that has no id
/// to delete, appear to take a tick that the analyst could never give it —
/// which is the whole property assertions 6 to 8 exist to hold.
private func tick(_ box: NSButton, _ on: Bool, _ what: String) {
    guard !box.isHidden else {
        failures += 1
        print("FAIL a hidden checkbox cannot be ticked (\(what))")
        return
    }
    guard box.isEnabled else {
        failures += 1
        print("FAIL a disabled checkbox cannot be ticked (\(what))")
        return
    }
    box.state = on ? .on : .off
    guard let action = box.action, let target = box.target as? NSObject else {
        failures += 1
        print("FAIL the checkbox has no target/action (\(what))")
        return
    }
    target.perform(action, with: box)
}

/// Ticks a CAPTURE checklist box by its column index, the way a click does.
///
/// Refuses a missing row as loudly as `tick` refuses a hidden or disabled box: a
/// helper that silently did nothing when the checklist was never drawn would let
/// every assertion below it pass against a sheet with no checklist at all.
private func tickCapture(_ sheet: TagManagerSheet, _ column: Int, _ on: Bool,
                         _ what: String) {
    let rows = sheet.captureList.rows
    guard rows.indices.contains(column) else {
        failures += 1
        print("FAIL there is no capture row \(column) to tick (\(what))")
        return
    }
    // `isHiddenOrHasHiddenAncestor`, not `isHidden`: the checklist is hidden by
    // hiding the BOX around it, so asking the list itself would answer "visible"
    // for a checklist nobody can see.
    guard !sheet.captureList.isHiddenOrHasHiddenAncestor else {
        failures += 1
        print("FAIL a hidden capture checklist cannot be ticked (\(what))")
        return
    }
    tick(rows[column].box, on, what)
}

/// Lets the main queue run, until `done` answers true or the deadline passes.
///
/// A never-shown window has no event loop of its own, so a background count's
/// `DispatchQueue.main.async` hop back would never be executed without this. The
/// timer is not decoration: with NO input source attached, `RunLoop.run` returns
/// immediately and drains nothing at all.
///
/// Waiting on a CONDITION rather than on a duration matters. A fixed sleep long
/// enough today is a race tomorrow — libdispatch can be slow to start a second
/// thread while the first is blocked, which is exactly the situation this suite
/// arranges on purpose.
private func pump(_ seconds: TimeInterval = 1.0, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    let keepAlive = Timer(timeInterval: 0.005, repeats: true) { _ in }
    RunLoop.current.add(keepAlive, forMode: .default)
    while Date() < deadline, !done() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    keepAlive.invalidate()
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

/// Every rule id a save would delete, in the order the commands would run.
private func deletedRuleIds(_ commits: [TagManagerCommit]) -> [String] {
    commits.flatMap { commit -> [String] in
        if case .deleteRules(let ids) = commit { return ids }
        return []
    }
}

private func addedRules(_ commits: [TagManagerCommit]) -> [AddTagRules] {
    commits.compactMap {
        if case .addRules(let add) = $0 { return add }
        return nil
    }
}

private func createdTags(_ commits: [TagManagerCommit]) -> [CreateTag] {
    commits.compactMap {
        if case .create(let create) = $0 { return create }
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
                       tags: [Tag] = fixtureTags(),
                       mode: TagManagerModel.Mode = .manage,
                       columns: [ColumnDef] = [],
                       loadedRows: [[String?]] = []) -> TagManagerSheet {
    TagManagerSheet(model: TagManagerModel(tags: tags, mode: mode),
                    committer: committer, columns: columns, loadedRows: loadedRows)
}

// MARK: - Fixtures for the live count

/// A result the fixture tags can be counted against: an address column and a
/// text one, which are the two families `fixtureTags` uses.
private func countColumns() -> [ColumnDef] {
    [
        ColumnDef(name: "ip", dataType: "inet", relationOid: nil, relationAttno: nil),
        ColumnDef(name: "host", dataType: "text", relationOid: nil, relationAttno: nil),
    ]
}

/// Ten rows. Tag "Suspect" (10.0.0.1 or evil.example) matches exactly ONE of
/// them; changing its address rule to 10.0.0.2 makes it match TWO, which is
/// also over the breadth threshold.
private func countRows() -> [[String?]] {
    var rows: [[String?]] = [
        ["10.0.0.1", "a.example"],
        ["10.0.0.2", "b.example"],
        ["10.0.0.2", "c.example"],
    ]
    for index in 0..<7 { rows.append(["10.0.0.9", "x\(index).example"]) }
    return rows
}

/// Above `asyncCountThreshold`, so the count leaves the main thread — which is
/// the only path on which a stale count can exist at all.
private func manyRows() -> [[String?]] {
    (0..<5_001).map { ["10.9.\($0 / 256).\($0 % 256)", "h\($0).example"] }
}

/// What a grid selection offers, carrying the provenance a captured finding
/// must keep.
private func capture(_ rows: [[String?]]) -> TagCapture {
    TagCapture(columns: countColumns(), selectedRows: rows,
               originConnection: "conn-42", originTable: "public.certs")
}

/// Three selected rows: every one holds the same host, and each holds a
/// different address. That is the shape the checklist has to describe two
/// different ways in the same list — one shared value, and a count.
private func fixtureCapture() -> TagCapture {
    capture([
        ["203.0.113.7", "shared.example"],
        ["203.0.113.8", "shared.example"],
        ["203.0.113.9", "shared.example"],
    ])
}

/// A hostile value: `safe\u{202E}gpj.exe` DISPLAYS as `safeexe.jpg`, so an
/// unescaped checklist row would read as a different value than the one the
/// analyst is ticking.
private let hostileValue = "safe\(bidi)gpj.exe"

// MARK: - A counting function the test drives

/// Stands in for `TagRuleMatcher.matchCount` on the sheet's injectable seam.
///
/// The stale-count guard cannot be pinned by racing the real matcher: the two
/// counts would be ordered by whichever thread happened to win, and a test whose
/// result depends on that is a flaky test pretending to be a guarantee. This
/// blocks the FIRST count on a semaphore the test releases when it chooses, so
/// "a slow count lands after a newer one" is ARRANGED rather than hoped for.
private final class GatedCounter {
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    /// What each call returns, by call number. Deliberately distinct, so the
    /// footer names WHICH count it is showing.
    private let results = [11, 22, 33]

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// Has the held-back first count RETURNED? The test waits for this before
    /// asserting that its answer was thrown away — otherwise it would be
    /// asserting that a count which had not happened yet did not land, which
    /// every implementation passes.
    ///
    /// Behind the lock like `calls`: it is written on a background thread and
    /// read on the main one.
    var firstFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedFirst
    }

    private var finishedFirst = false

    func count(_ tag: Tag, _ columns: [ColumnDef], _ rows: [[String?]]) -> Int {
        lock.lock()
        calls += 1
        let ordinal = calls
        lock.unlock()
        // Only the first is held back. Every later count runs straight through,
        // so the newest number reaches the footer while the first is still
        // inside this function.
        if ordinal == 1 {
            gate.wait()
            lock.lock()
            finishedFirst = true
            lock.unlock()
        }
        return ordinal <= results.count ? results[ordinal - 1] : 99
    }
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

    // MARK: 15 — `.manage` shows every tag and preselects the first

    let managing = makeSheet(RecordingCommitter())
    host(managing)
    expectInt(managing.tableView.numberOfRows, 3, "`.manage` lists every tag")
    expectInt(managing.selectedTagIndex ?? -1, 0, "and preselects the first")
    expectString(managing.titleLabel.stringValue, "Tags",
                 "under the plain heading — nothing is being added or removed")

    // MARK: 16 — `.add` shows every tag, and says how many rows are joining one

    let addSheet = makeSheet(RecordingCommitter(), mode: .add(capture: fixtureCapture()))
    host(addSheet)
    expectInt(addSheet.tableView.numberOfRows, 3,
              "`.add` lists every tag, because the analyst is choosing which one the draft joins")
    expectTrue(addSheet.titleLabel.stringValue.contains("3 rows"),
               "and the header states how many rows are being added "
               + "(\(addSheet.titleLabel.stringValue.debugDescription))")
    // The heading counts SELECTED ROWS, so it does not move as boxes are
    // ticked: it answers "did the sheet catch the selection I made", and
    // nothing has been ticked here at all.
    expectTrue(addSheet.model.draftRules.isEmpty,
               "with nothing ticked yet, so the heading is not a count of rules")

    // MARK: 17 — `.add` onto an existing tag keeps the draft's PROVENANCE

    // The point of the whole entry. An authored rule has empty origin strings
    // because it came from nobody's result; a captured finding must arrive with
    // the connection and table it was seen on, or the record of where it was
    // found is lost at the moment it is filed.
    let joinCommitter = RecordingCommitter()
    let joining = makeSheet(joinCommitter, mode: .add(capture: fixtureCapture()))
    host(joining)
    select(joining, row: 0)
    expectTrue(!joining.saveButton.isEnabled,
               "with nothing ticked there is nothing to add, so Save is held back")
    tickCapture(joining, 0, true, "the address column")
    tickCapture(joining, 1, true, "the host column")
    expectTrue(joining.saveButton.isEnabled,
               "a ticked capture with a tag chosen can be saved without any other edit")
    // Which makes the footer load-bearing: the tag the draft joins is chosen by
    // a SIDEBAR SELECTION, which looks like navigation rather than a decision,
    // and Save is the default button. This line is what makes it a decision.
    expectString(joining.statusLabel.stringValue,
                 "Saving adds 3 rules to \u{201C}Suspect\u{201D}, one per selected row.",
                 "and the footer names the tag the rows would join, how many, and "
                 + "that three rules from three rows is one each rather than a cross product")
    joining.saveButton.performClick(nil)
    expectInt(joinCommitter.applied.count, 1, "saving commits once")
    let joined = addedRules(joinCommitter.applied.first ?? [])
    expectInt(joined.count, 1, "with one add-rules command")
    if let add = joined.first {
        expectString(add.tagId, "t1", "naming the chosen tag")
        expectInt(add.rules.count, 3, "one rule per selected row")
        expectString(add.rules.map { "\($0.conditions.count)" }.joined(separator: ","),
                     "2,2,2",
                     "each holding the two TICKED columns, never a cross product")
        expectString(add.rules.map(\.originConnection).joined(separator: ","),
                     "conn-42,conn-42,conn-42",
                     "each with the connection it was captured on, not an empty string")
        expectString(add.rules.map(\.originTable).joined(separator: ","),
                     "public.certs,public.certs,public.certs",
                     "and the table it was captured from")
    }

    // MARK: 18 — `.add` onto a NEW tag creates it WITH the draft

    let bornCommitter = RecordingCommitter()
    let born = makeSheet(bornCommitter, mode: .add(capture: fixtureCapture()))
    host(born)
    born.newTagButton.performClick(nil)
    type(born.nameField, "Fresh Finding")
    tickCapture(born, 0, true, "the address column")
    tickCapture(born, 1, true, "the host column")
    born.saveButton.performClick(nil)
    expectInt(bornCommitter.applied.count, 1, "saving commits once")
    let bornCreates = createdTags(bornCommitter.applied.first ?? [])
    expectInt(bornCreates.count, 1, "with one create command")
    if let create = bornCreates.first {
        expectString(create.name, "Fresh Finding", "under the typed name")
        expectInt(create.rules.count, 3,
                  "and the ticked rules go IN it — a second command could not name "
                  + "a tag whose id does not exist yet")
        expectString(create.rules.map { "\($0.conditions.count)" }.joined(separator: ","),
                     "2,2,2",
                     "each holding the same two ticked columns as the existing-tag path")
        expectString(create.rules.map(\.originTable).joined(separator: ","),
                     "public.certs,public.certs,public.certs",
                     "still carrying their provenance")
    }

    // MARK: 19 — `.remove` narrows the sidebar to the tags holding those rules

    let removing = makeSheet(RecordingCommitter(), mode: .remove(ruleIds: ["r1"]))
    host(removing)
    expectInt(removing.tableView.numberOfRows, 1,
              "`.remove` answers a question about ONE row, so it lists only the "
              + "tags holding the named rules")
    expectString(rowText(removing, 0), "Suspect — 2 rules", "which is the one holding r1")
    expectString(removing.titleLabel.stringValue, "Remove from Tag",
                 "and the header says what this entry is for")

    // MARK: 20 — `.remove` draws a checkbox per rule, with the named ones TICKED

    expectInt(removing.grid.groups.count, 2, "the selected tag draws both its rules")
    if removing.grid.groups.count == 2 {
        expectTrue(!removing.grid.groups[0].selectionBox.isHidden
                    && !removing.grid.groups[1].selectionBox.isHidden,
                   "every rule gets a checkbox")
        expectTrue(removing.grid.groups[0].selectionBox.state == .on,
                   "the rule the analyst came here about starts TICKED")
        expectTrue(removing.grid.groups[1].selectionBox.state == .off,
                   "and a rule they did not ask about does not")
    }

    // MARK: 21 — Save deletes exactly what is TICKED, not what was preselected

    // The disclosure property this entry exists to guarantee. Whatever the sheet
    // opened with, the boxes on screen are the promise — so the promise is
    // changed BOTH ways before it is read: one more ticked, and the preselected
    // one taken back.
    if removing.grid.groups.count == 2 {
        tick(removing.grid.groups[1].selectionBox, true, "rule 2")
        tick(removing.grid.groups[0].selectionBox, false, "rule 1")
    }
    let removeCommitter = RecordingCommitter()
    let removeSheet = removing
    removeSheet.onClose = nil
    expectTrue(removeSheet.saveButton.isEnabled,
               "a tick is a change, so Save is available")
    expectTrue(removeSheet.statusLabel.stringValue.contains("1 rule"),
               "and the footer says what will go "
               + "(\(removeSheet.statusLabel.stringValue.debugDescription))")
    // A second sheet, driven the same way, so the assertion reads the commits a
    // click actually hands over rather than a recomputation of them.
    let ticking = makeSheet(removeCommitter, mode: .remove(ruleIds: ["r1"]))
    host(ticking)
    if ticking.grid.groups.count == 2 {
        tick(ticking.grid.groups[1].selectionBox, true, "rule 2")
        tick(ticking.grid.groups[0].selectionBox, false, "rule 1")
    } else {
        failures += 1
        print("FAIL the remove sheet did not draw two rules to tick")
    }
    ticking.saveButton.performClick(nil)
    expectInt(removeCommitter.applied.count, 1, "saving commits once")
    expectString(deletedRuleIds(removeCommitter.applied.first ?? []).joined(separator: ","),
                 "r2",
                 "and deletes exactly the TICKED rule, never the preselected one")

    // MARK: 21b — a rule that does not exist yet draws NO checkbox

    // A rule added this session has no id, so nothing could ever remove it. A
    // DISABLED box would say "not now"; the truth is "never, this rule does not
    // exist yet", and only a hidden box says that. The left inset stays, so the
    // rules beside it keep one column.
    let unsavedCommitter = RecordingCommitter()
    let unsaved = makeSheet(unsavedCommitter, mode: .remove(ruleIds: ["r1"]))
    host(unsaved)
    unsaved.grid.addRuleButton.performClick(nil)
    expectInt(unsaved.grid.groups.count, 3, "the tag gains a rule added this session")
    if unsaved.grid.groups.count == 3 {
        expectTrue(unsaved.grid.groups[2].ruleId == nil,
                   "which has no id, because it has never been saved")
        expectTrue(unsaved.grid.groups[2].selectionBox.isHidden,
                   "so it draws NO checkbox — nothing could ever delete it")
        expectTrue(!unsaved.grid.groups[0].selectionBox.isHidden
                    && !unsaved.grid.groups[1].selectionBox.isHidden,
                   "while the stored rules beside it still draw theirs")
        // The inset is kept, so hiding the box does not pull the rule's heading
        // left and break the column.
        unsaved.view.layoutSubtreeIfNeeded()
        let stored = unsaved.grid.groups[0]
        let fresh = unsaved.grid.groups[2]
        expectString("\(Int(stored.titleLabel.convert(NSPoint.zero, to: stored).x))",
                     "\(Int(fresh.titleLabel.convert(NSPoint.zero, to: fresh).x))",
                     "and the heading starts at the same x, so the rules stay aligned")
    }
    expectString(unsaved.grid.selectedRuleIds.sorted().joined(separator: ","), "r1",
                 "and the ticked set is untouched by its arrival")
    // End to end: take the unsaved rule away again, and what a save deletes is
    // still exactly the one tick.
    if unsaved.grid.groups.count == 3 {
        unsaved.grid.groups[2].deleteRuleButton.performClick(nil)
    }
    unsaved.saveButton.performClick(nil)
    expectInt(unsavedCommitter.applied.count, 1, "saving commits once")
    expectString(deletedRuleIds(unsavedCommitter.applied.first ?? []).joined(separator: ","),
                 "r1",
                 "deleting exactly the ticked rule, and nothing the id-less one touched")

    // MARK: 22 — `.manage` and `.add` draw no checkboxes at all

    expectTrue(managing.grid.groups.allSatisfy { $0.selectionBox.isHidden },
               "`.manage` draws no checkboxes — nothing there is being chosen for deletion")
    select(addSheet, row: 0)
    expectTrue(!addSheet.grid.groups.isEmpty,
               "the `.add` sheet has rules on screen to check")
    expectTrue(addSheet.grid.groups.allSatisfy { $0.selectionBox.isHidden },
               "and `.add` draws none either")

    // MARK: 23 — the footer counts with the REAL matcher, and follows an edit

    let counting = makeSheet(RecordingCommitter(),
                             columns: countColumns(), loadedRows: countRows())
    host(counting)
    expectString(counting.countLabel.stringValue, "Matches 1 of 10 loaded rows.",
                 "the footer counts the selected tag over the loaded rows")
    expectString(counting.warningLabel.stringValue, "",
                 "one row in ten is not broad, so nothing is said")
    guard counting.grid.groups.count == 2,
          counting.grid.groups[0].conditionRows.count == 1 else {
        failures += 1
        print("FAIL the counted tag did not render a rule with a value to edit")
        finish()
        return
    }
    type(counting.grid.groups[0].conditionRows[0].valueField, "10.0.0.2")
    expectString(counting.countLabel.stringValue, "Matches 2 of 10 loaded rows.",
                 "and the count follows an edit")

    // MARK: 24 — a broad tag is DISCLOSED, never blocked

    // A deliberately broad temporary tag is a legitimate tool, and only the
    // analyst knows which this is.
    expectString(counting.warningLabel.stringValue, "This tag is broad.",
                 "two rows in ten is over the threshold, so the warning appears")
    expectTrue(counting.saveButton.isEnabled,
               "and a broad tag can still be SAVED — the warning never blocks")

    // MARK: 25 — with no result behind the sheet the footer says so

    // "Matches 0 of 0 loaded rows" would read as "this tag matches nothing",
    // which is a claim about the TAG made from having nothing to compare it to.
    let unbacked = makeSheet(RecordingCommitter())
    host(unbacked)
    expectString(unbacked.countLabel.stringValue,
                 "No rows are loaded here, so there is nothing to count against.",
                 "an empty result is stated as a fact about the RESULT")
    expectTrue(!unbacked.countLabel.stringValue.contains("Matches"),
               "and never as a count of zero, which would be a claim about the tag")
    expectString(unbacked.warningLabel.stringValue, "",
                 "and nothing can be called broad against nothing")

    // MARK: 26 — a slow count landing after a newer edit is DISCARDED

    // Two async counts cannot be raced deterministically by timing, so the
    // counting function is injected: the first call blocks on a semaphore this
    // test releases, which arranges the stale landing instead of hoping for it.
    let counter = GatedCounter()
    let gated = TagManagerSheet(
        model: TagManagerModel(tags: fixtureTags(), mode: .manage),
        committer: RecordingCommitter(),
        columns: countColumns(), loadedRows: manyRows())
    gated.countMatches = { counter.count($0, $1, $2) }
    host(gated)
    expectInt(counter.callCount, 1, "opening the sheet starts one count")
    guard gated.grid.groups.count == 2,
          gated.grid.groups[0].conditionRows.count == 1 else {
        failures += 1
        print("FAIL the gated sheet did not render a rule with a value to edit")
        finish()
        return
    }
    // The first count is still inside the counting function, holding the gate.
    type(gated.grid.groups[0].conditionRows[0].valueField, "10.9.0.3")
    pump(5.0) { gated.countLabel.stringValue.hasPrefix("Matches") }
    expectInt(counter.callCount, 2, "an edit starts a second count")
    expectString(gated.countLabel.stringValue, "Matches 22 of 5001 loaded rows.",
                 "and the SECOND count reaches the footer")
    // Released only now, so the first count returns its answer into a sheet that
    // has already moved on.
    counter.gate.signal()
    pump(5.0) { counter.firstFinished }
    // And a further turn of the run loop, so its hop back to the main thread is
    // delivered rather than merely queued.
    pump(0.5)
    expectString(gated.countLabel.stringValue, "Matches 22 of 5001 loaded rows.",
                 "the first count, landing afterwards, is DISCARDED rather than "
                 + "overwriting the newer number")

    // MARK: 27 — the checklist is drawn in `.add` ONLY, one row per column

    // The capability the migration to this modal dropped. `TagSheet` made the
    // analyst tick which columns a tag captured from; "capture every column"
    // replaced it, and on a twenty-column result that produces a rule matching
    // almost nothing but the row it came from.
    let listing = makeSheet(RecordingCommitter(), mode: .add(capture: fixtureCapture()),
                            columns: countColumns(), loadedRows: countRows())
    host(listing)
    expectInt(listing.captureList.rows.count, countColumns().count,
              "`.add` draws one checklist row per result column")
    expectInt(listing.captureList.rows.count, 2, "which here is two")
    expectTrue(!listing.captureList.isHiddenOrHasHiddenAncestor,
               "and the checklist is on screen")
    expectInt(managing.captureList.rows.count, 0,
              "`.manage` draws no checklist — it has no selection to capture from")
    expectTrue(managing.captureList.isHiddenOrHasHiddenAncestor,
               "and the space it would take goes with it")
    expectInt(removing.captureList.rows.count, 0, "`.remove` draws none either")
    expectTrue(removing.captureList.isHiddenOrHasHiddenAncestor,
               "and hides its box too")

    // MARK: 28 — a row shows the FAMILY, never the column name

    // A column name never takes part in matching, and a hand-authored condition
    // has no column at all — so a name here would promise a precision the tag
    // does not have.
    expectString(listing.captureList.rows.map(\.familyLabel.stringValue)
                    .joined(separator: "|"),
                 "Address|Text",
                 "each row names the family the condition will be described by")
    expectTrue(listing.captureList.rows.allSatisfy {
                   $0.familyLabel.stringValue != "ip" && $0.familyLabel.stringValue != "host"
               },
               "and never the column's own name")

    // MARK: 29 — with ONE row selected, each row shows THAT row's value

    let single = makeSheet(RecordingCommitter(),
                           mode: .add(capture: capture([["198.51.100.4", "one.example"]])),
                           columns: countColumns(), loadedRows: countRows())
    host(single)
    expectString(single.captureList.rows.map(\.valueLabel.stringValue).joined(separator: "|"),
                 "198.51.100.4|one.example",
                 "one selected row shows its own values, which is what the analyst "
                 + "is actually deciding about")
    expectTrue(single.titleLabel.stringValue.contains("1 row"),
               "and the heading says one row "
               + "(\(single.titleLabel.stringValue.debugDescription))")

    // MARK: 30 — with SEVERAL rows, a shared value is shown and the rest counted

    // A column constant across the selection is a strong indicator and worth
    // seeing at a glance; that is what the old sheet's distinct count was for.
    expectString(listing.captureList.rows.map(\.valueLabel.stringValue).joined(separator: "|"),
                 "3 values|shared.example",
                 "a column the three rows differ on is COUNTED, and one they all "
                 + "share shows the value itself")

    // MARK: 31 — every box starts UNTICKED

    // A tag is a durable artifact and the choice should be deliberate.
    expectTrue(listing.captureList.rows.allSatisfy { $0.box.state == .off },
               "no capture box starts ticked")
    expectTrue(listing.model.checkedCaptureColumns.isEmpty,
               "and the model agrees nothing is ticked")

    // MARK: 32 — with nothing ticked, a save writes no rules at all

    // Save is held back by the ordinary `noChanges` blocker first...
    select(listing, row: 0)
    expectTrue(!listing.saveButton.isEnabled,
               "an untouched `.add` sheet cannot be saved")
    expectString(listing.statusLabel.stringValue, "Nothing has changed yet.",
                 "and says so in the ordinary words, not in a special case")
    // ...and when something ELSE makes the save legal, the untouched checklist
    // still contributes nothing. Asserted through a real save, because that is
    // where an accidentally-full draft would actually escape.
    let untickedCommitter = RecordingCommitter()
    let unticked = makeSheet(untickedCommitter, mode: .add(capture: fixtureCapture()),
                             columns: countColumns(), loadedRows: countRows())
    host(unticked)
    select(unticked, row: 0)
    type(unticked.nameField, "Renamed Only")
    unticked.saveButton.performClick(nil)
    expectInt(untickedCommitter.applied.count, 1, "the rename alone saves")
    expectInt(addedRules(untickedCommitter.applied.first ?? []).count, 0,
              "and writes NO add-rules command, because nothing was ticked")
    expectInt(createdTags(untickedCommitter.applied.first ?? []).count, 0,
              "and creates no tag either")

    // MARK: 33 — a tick moves the LIVE COUNT

    // The whole reason the checklist rebuilds the draft rather than carrying a
    // fixed list: the analyst must see immediately that ticking one more column
    // narrowed the tag — including to nothing.
    let counted = makeSheet(RecordingCommitter(),
                            mode: .add(capture: capture([["10.0.0.2", "b.example"]])),
                            columns: countColumns(), loadedRows: countRows())
    host(counted)
    select(counted, row: 0)
    let countBeforeTick = counted.countLabel.stringValue
    expectString(countBeforeTick, "Matches 1 of 10 loaded rows.",
                 "before any tick the count is the tag's own")
    tickCapture(counted, 0, true, "the address column")
    expectTrue(counted.countLabel.stringValue != countBeforeTick,
               "ticking a box moves the count "
               + "(\(countBeforeTick.debugDescription) -> "
               + "\(counted.countLabel.stringValue.debugDescription))")
    expectString(counted.countLabel.stringValue, "Matches 3 of 10 loaded rows.",
                 "to what the tag would reach WITH the captured address")
    // Ticking a SECOND column makes the captured rule strictly narrower — it now
    // needs BOTH values present in one row — and that IS what would be written.
    tickCapture(counted, 1, true, "the host column")
    expectInt(counted.model.draftRules.first?.conditions.count ?? 0, 2,
              "ticking a second column narrows the captured rule to both values")
    // The FOOTER's number does not come down, and that is pinned as it is rather
    // than as it ought to be. `TagRuleMatcher.matchCount` counts every row the
    // tag TOUCHES — dashed as well as solid — so a second condition can only add
    // touches, never remove one: 10.0.0.2 still touches rows 1 and 2 even though
    // only row 1 satisfies the whole rule now. That is pre-existing behaviour,
    // shared with the `TagSheet` this modal replaced, and it means "Matches N"
    // overstates what the tag actually applies to. It is NOT introduced here and
    // is not fixed here — a change to the count's meaning is its own task, with
    // its own reading of what the footer should promise.
    expectString(counted.countLabel.stringValue, "Matches 3 of 10 loaded rows.",
                 "while the footer's number counts every row TOUCHED, so it does "
                 + "not come down (a known pre-existing overstatement)")
    tickCapture(counted, 0, false, "the address column")
    tickCapture(counted, 1, false, "the host column")
    expectString(counted.countLabel.stringValue, "Matches 1 of 10 loaded rows.",
                 "unticking everything returns the count to the tag's own")

    // MARK: 34 — a NULL cell contributes no condition

    // A NULL is the ABSENCE of a value, not a value: a slot nothing can satisfy
    // would make the whole rule inert.
    let nullCommitter = RecordingCommitter()
    let nulled = makeSheet(nullCommitter,
                           mode: .add(capture: capture([["10.0.0.2", nil]])),
                           columns: countColumns(), loadedRows: countRows())
    host(nulled)
    expectString(nulled.captureList.rows.map(\.valueLabel.stringValue).joined(separator: "|"),
                 "10.0.0.2|NULL",
                 "a NULL cell says so, rather than drawing an empty row that reads "
                 + "as a rendering fault")
    select(nulled, row: 0)
    tickCapture(nulled, 0, true, "the address column")
    tickCapture(nulled, 1, true, "the NULL host column")
    nulled.saveButton.performClick(nil)
    expectInt(nullCommitter.applied.count, 1, "saving commits once")
    let nullAdds = addedRules(nullCommitter.applied.first ?? [])
    expectInt(nullAdds.count, 1, "with one add-rules command")
    if let add = nullAdds.first {
        expectInt(add.rules.count, 1, "carrying the one selected row")
        if let rule = add.rules.first {
            expectInt(rule.conditions.count, 1,
                      "as a NARROWER rule — the NULL column contributes nothing")
            expectString(rule.conditions.first?.display ?? "<none>", "10.0.0.2",
                         "keeping only the column that held a value")
        }
    }

    // MARK: 35 — a hostile value is ESCAPED in the checklist

    // The row is drawn in this app's own voice and is what the analyst reads
    // before ticking. `safe<U+202E>gpj.exe` DISPLAYS as `safeexe.jpg`, so an
    // unescaped row would have them tick a value they never saw.
    let hostile = makeSheet(RecordingCommitter(),
                            mode: .add(capture: capture([["10.0.0.2", hostileValue]])),
                            columns: countColumns(), loadedRows: countRows())
    host(hostile)
    guard hostile.captureList.rows.count == 2 else {
        failures += 1
        print("FAIL the hostile-value sheet drew no checklist to read")
        finish()
        return
    }
    expectString(hostile.captureList.rows[1].valueLabel.stringValue,
                 DisplayEscape.escaped(hostileValue),
                 "the row shows the escaped value")
    expectTrue(!hostile.captureList.rows[1].valueLabel.stringValue.contains(bidi),
               "so the override itself never reaches the label")
    // The escape is DISPLAY only: what a save writes is the value as it was
    // seen, or the indicator would be corrupt the moment it was filed.
    let hostileCommitter = RecordingCommitter()
    let hostileSaving = makeSheet(hostileCommitter,
                                  mode: .add(capture: capture([["10.0.0.2", hostileValue]])),
                                  columns: countColumns(), loadedRows: countRows())
    host(hostileSaving)
    select(hostileSaving, row: 0)
    tickCapture(hostileSaving, 1, true, "the hostile host column")
    hostileSaving.saveButton.performClick(nil)
    let hostileAdds = addedRules(hostileCommitter.applied.first ?? [])
    if let rule = hostileAdds.first?.rules.first, let condition = rule.conditions.first {
        expectString(condition.display, hostileValue,
                     "while the STORED value keeps its bytes — an escaped indicator "
                     + "would be a corrupt one")
    } else {
        failures += 1
        print("FAIL the hostile capture wrote no condition to inspect")
    }

    // MARK: 36 — the checklist scrolls, and never squeezes the rules grid

    // A sixty-column result draws sixty rows. Measured rather than assumed: an
    // earlier task found a value field silently collapsed to zero width because
    // two views hugged at the same priority.
    let wide = (0..<60).map {
        ColumnDef(name: "c\($0)", dataType: $0 % 2 == 0 ? "inet" : "text",
                  relationOid: nil, relationAttno: nil)
    }
    let wideRow: [String?] = (0..<60).map { $0 % 2 == 0 ? "10.0.0.\($0 % 250)" : "host\($0)" }
    let wideSheet = makeSheet(
        RecordingCommitter(),
        mode: .add(capture: TagCapture(columns: wide, selectedRows: [wideRow],
                                       originConnection: "conn-42",
                                       originTable: "public.certs")),
        columns: countColumns(), loadedRows: countRows())
    host(wideSheet)
    wideSheet.view.layoutSubtreeIfNeeded()
    expectInt(wideSheet.captureList.rows.count, 60, "sixty columns draw sixty rows")
    // ONE selected row, like the wide sheet: the caption is a line longer when
    // several rows are selected, and that alone moves the grid by a dozen
    // points. Holding the row count equal leaves the COLUMN count as the only
    // difference, which is the thing under test.
    let narrowList = makeSheet(RecordingCommitter(),
                               mode: .add(capture: capture([["10.0.0.2", "b.example"]])),
                               columns: countColumns(), loadedRows: countRows())
    host(narrowList)
    narrowList.view.layoutSubtreeIfNeeded()
    // The rows are drawn at full height and the VIEWPORT does not grow, which is
    // what "it scrolls" means in measurements rather than in words.
    expectTrue(wideSheet.captureList.frame.height
                > wideSheet.captureScroll.contentView.bounds.height,
               "the rows overflow the checklist's viewport "
               + "(\(Int(wideSheet.captureList.frame.height))pt of rows in "
               + "\(Int(wideSheet.captureScroll.contentView.bounds.height))pt), so it scrolls")
    expectInt(Int(wideSheet.captureScroll.frame.height),
              Int(narrowList.captureScroll.frame.height),
              "and the viewport is the same height beside sixty rows as beside two")
    // The grid below keeps its floor whatever the checklist holds, because the
    // checklist's viewport is a fixed height rather than a share of the sheet.
    expectInt(Int(wideSheet.gridScroll.frame.height),
              Int(narrowList.gridScroll.frame.height),
              "so the rules grid is not squeezed by a wide result "
              + "(\(Int(wideSheet.gridScroll.frame.height))pt vs "
              + "\(Int(narrowList.gridScroll.frame.height))pt)")
    expectTrue(wideSheet.gridScroll.frame.height >= 220,
               "and still has its own floor "
               + "(\(Int(wideSheet.gridScroll.frame.height))pt)")
    // Every value must have real width. Zero would draw a blank row, which reads
    // as missing data rather than as a layout fault.
    let squeezed = wideSheet.captureList.rows.filter { $0.valueLabel.frame.width < 40 }
    expectInt(squeezed.count, 0,
              "and no value label is squeezed to nothing by the family beside it")

    finish()
}

private func finish() {
    print(failures == 0 ? "\nAll TagManagerSheet tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
