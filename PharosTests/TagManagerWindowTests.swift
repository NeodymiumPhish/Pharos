// Standalone test for the Tag Manager WINDOW's content, TagManagerHostVC —
// compiled by scripts/test-tag-manager-window.sh. A fake committer and tag
// list stand in for TagStore (Keychain-bound through the FFI); the shell
// (ManagerSplitViewController, ManagerSidebarVC, ManagerToolbarController), the
// detail (TagDetailVC) and the swatch picker are the real ones.
//
// What it pins: the sidebar's rows say what the tags are (swatch, name or
// "Untitled Tag", the edited rule count, the unsaved dot on exactly the edited
// tags); a sidebar pick drives the detail; + and the empty state's New Tag
// make a tag; Delete and the context menu delete one the way the sheet's trash
// button does; Save writes once and Revert writes nothing; closing with edits
// asks; the colour swatches set colorIndex by click, key and VoiceOver press;
// the window renders in Light and Dark with the swatch selection visible in
// both; and no layout here ever reports a constraint conflict.
import AppKit

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private final class FakeCommitter: TagManagerCommitting {
    var applied: [[TagManagerCommit]] = []
    var onApply: (() -> Void)?
    func apply(_ commits: [TagManagerCommit]) throws {
        applied.append(commits)
        onApply?()
    }
}

/// Counts AppKit's constraint-conflict reports: with
/// NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints on, AppKit
/// calls `visualizeConstraints(_:)` for every conflict, transient ones
/// included, which the unified log would otherwise swallow.
private final class SpyWindow: NSWindow {
    static var conflicts = 0
    override func visualizeConstraints(_ constraints: [NSLayoutConstraint]?) {
        if !(constraints ?? []).isEmpty { Self.conflicts += 1 }
    }
}

private func cond(_ family: String, _ display: String) -> TagCondition {
    TagCondition(family: family, kind: .exact,
                 value: TagValueNormalizer.normalize(display, family: family), display: display)
}

private func rule(_ id: String, _ display: String) -> TagRule {
    TagRule(id: id, conditions: [cond("text", display)], tupleKey: id,
            originConnection: "", originTable: "", createdAt: "")
}

private func tag(_ id: String, _ name: String, colorIndex: Int = 0, _ rules: [TagRule] = []) -> Tag {
    Tag(id: id, name: name, colorIndex: colorIndex, note: nil, createdAt: "", updatedAt: "", rules: rules)
}

private func keyDown(_ characters: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

/// Types into a field the way the app does: the text changes, then the
/// field's OWN delegate is told.
private func type(_ field: NSTextField, _ text: String) {
    guard field.isEnabled, field.isEditable, let delegate = field.delegate else {
        failures += 1
        print("FAIL the field cannot be typed into")
        return
    }
    field.stringValue = text
    delegate.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
}

// MARK: - Colour measurement

private func relativeLuminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB) ?? color
    func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
}

private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let la = relativeLuminance(a), lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)),
                  Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
}

/// A view rendered offscreen under one appearance. The rep follows the main
/// display's scale, so every read goes through `pixel`, which takes POINTS
/// (lessons, 2026-09-19).
private final class Rendered {
    let rep: NSBitmapImageRep
    let scale: CGFloat
    init(rep: NSBitmapImageRep, pointWidth: CGFloat) {
        self.rep = rep
        scale = (CGFloat(rep.pixelsWide) / pointWidth).rounded()
    }
    /// Top-left origin, in points.
    func pixel(_ point: NSPoint) -> NSColor? {
        rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }
}

/// `view.appearance` as well as the drawing appearance: `cacheDisplay`
/// restores each view's own appearance as it draws it (lessons, 2026-09-19).
private func render(_ view: NSView, _ appearance: NSAppearance) -> Rendered? {
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    return Rendered(rep: rep, pointWidth: view.bounds.width)
}

/// A point in `child` as a top-left-origin point of `root`.
private func topLeft(_ point: NSPoint, in child: NSView, of root: NSView) -> NSPoint {
    let p = child.convert(point, to: root)
    return root.isFlipped ? p : NSPoint(x: p.x, y: root.bounds.height - p.y)
}

// MARK: - Hosting

@MainActor
private final class Harness {
    var stored: [Tag]
    let committer = FakeCommitter()
    let host: TagManagerHostVC
    let window: SpyWindow

    init(_ tags: [Tag], size: NSSize = NSSize(width: 900, height: 600)) {
        stored = tags
        var box: Harness?
        host = TagManagerHostVC(tags: { box?.stored ?? [] }, committer: committer)
        window = SpyWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(size)
        host.split.installToolbarIfNeeded(on: window)
        box = self
        retained = box
    }
    private var retained: Harness?

    var sidebar: ManagerSidebarVC { host.sidebar }
    var detail: TagDetailVC { host.detail }

    func layout() { window.contentView?.layoutSubtreeIfNeeded() }

    /// A row picked the way a click does: the table's selection moves, then
    /// its own delegate is told.
    func click(row: Int) {
        let table = sidebar.tableView
        if row < 0 { table.deselectAll(nil) } else {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        table.delegate?.tableViewSelectionDidChange?(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table))
    }

    /// The toolbar's + pressed through the toolbar item's own target/action.
    func pressAdd() {
        guard let add = window.toolbar?.items.first(where: { $0.itemIdentifier == .pharosManagerAdd }),
              let action = add.action else {
            failures += 1
            print("FAIL the toolbar has no + item")
            return
        }
        NSApp.sendAction(action, to: add.target, from: add)
    }

    func close() {
        window.orderOut(nil)
        retained = nil
    }
}

// MARK: - The suite

@MainActor
private func testEmptyWindowAndNewTag() {
    let h = Harness([])
    defer { h.close() }
    h.host.reseed()
    h.layout()
    expect(h.sidebar.items.count, 0, "empty: the sidebar has no rows")
    expectTrue(!h.detail.emptyState.isHidden, "empty: the empty state shows")
    expect(h.detail.emptyState.titleText, "No Tags", "empty: titled No Tags")
    expectTrue(!h.detail.emptyState.actionButtonForTesting.isHidden, "empty: with a New Tag button")
    expect(h.detail.emptyState.actionButtonForTesting.title, "New Tag", "empty: named New Tag")
    expectTrue(h.detail.formScroll.isHidden, "empty: and no form")
    expect(h.host.hasEdits, false, "empty: nothing to save yet")

    // + in the toolbar, through the real item.
    h.pressAdd()
    expect(h.sidebar.items.count, 1, "+: the sidebar gains a row")
    expect(h.sidebar.items.first?.title, "New Tag", "+: named New Tag")
    expect(h.sidebar.items.first?.subtitle, "0 rules", "+: with no rules")
    expect(h.sidebar.items.first?.trailing, [.unsavedDot], "+: and the unsaved dot")
    expect(h.sidebar.selectedId, h.sidebar.items.first?.id, "+: and selected")
    expect(h.detail.nameField.stringValue, "New Tag", "+: the detail shows it")
    expectTrue(h.detail.emptyState.isHidden && !h.detail.formScroll.isHidden, "+: the form replaces the empty state")
    expect(h.host.hasEdits, true, "+: New Tag is an edit")

    // The empty state's own New Tag button does the same.
    let second = Harness([])
    defer { second.close() }
    second.host.reseed()
    second.detail.emptyState.actionButtonForTesting.performClick(nil)
    expect(second.sidebar.items.count, 1, "empty state: New Tag makes a tag too")

    // A blank name reads Untitled Tag in the sidebar.
    type(h.detail.nameField, "   ")
    expect(h.sidebar.items.first?.title, "Untitled Tag", "blank name: the sidebar says Untitled Tag")
}

@MainActor
private func testSidebarRowsAndSelection() {
    let h = Harness([
        tag("a", "Alpha", colorIndex: 4, [rule("r1", "one.example"), rule("r2", "two.example")]),
        tag("b", "Beta", colorIndex: 1, [rule("r3", "three.example")]),
        tag("c", "", colorIndex: 2),
    ])
    defer { h.close() }
    h.host.reseed()
    h.layout()

    expect(h.sidebar.items.map(\.title), ["Alpha", "Beta", "Untitled Tag"], "rows: names, blank → Untitled Tag")
    expect(h.sidebar.items.map { $0.subtitle ?? "" }, ["2 rules", "1 rule", "0 rules"],
           "rows: the rule count, singular for one")
    expect(h.sidebar.items.map(\.badge),
           [.swatch(TagPalette.color(at: 4)), .swatch(TagPalette.color(at: 1)), .swatch(TagPalette.color(at: 2))],
           "rows: the tag's palette colour as the swatch")
    expect(h.sidebar.items.map(\.trailing), [[], [], []], "rows: no unsaved dot before any edit")
    expect(h.sidebar.items.map(\.id), ["a", "b", "c"], "rows: a stored tag goes by its id")
    expect(h.detail.selectedTagIndex, 0, "selection: the first tag is shown on open")

    // A click on Beta drives the detail.
    h.click(row: 1)
    expect(h.detail.nameField.stringValue, "Beta", "selection: the click fills the name")
    expect(h.detail.colorPicker.selectedIndex, 1, "selection: and the colour")
    expect(h.detail.grid.groups.count, 1, "selection: and the rules")

    // Editing Beta's name marks Beta, and only Beta.
    type(h.detail.nameField, "Beta Renamed")
    expect(h.sidebar.items[1].title, "Beta Renamed", "edit: the row follows the rename")
    expect(h.sidebar.items.map(\.trailing), [[], [.unsavedDot], []], "edit: the dot is on the edited tag only")
    // A trailing space the save would trim does not light a dot on its own.
    type(h.detail.nameField, "Beta ")
    expect(h.sidebar.items[1].trailing, [], "edit: a trailing space the save trims is not an edit")
    expect(h.sidebar.items[1].title, "Beta", "edit: and the row shows the trimmed name")

    // A value edit in a rule lights the dot too.
    if let field = h.detail.grid.groups.first?.conditionRows.first?.valueField {
        type(field, "changed.example")
    }
    expect(h.sidebar.items[1].trailing, [.unsavedDot], "edit: a rule value edit lights the dot")

    // Clearing the selection: "No Tag Selected", the action bar stays.
    h.click(row: -1)
    expect(h.detail.selectedTagIndex, nil, "no selection: nothing on show")
    expect(h.detail.emptyState.titleText, "No Tag Selected", "no selection: says No Tag Selected")
    expectTrue(h.detail.emptyState.actionButtonForTesting.isHidden, "no selection: with no New Tag button")
    expectTrue(h.detail.formScroll.isHidden, "no selection: the form goes")
    expectTrue(h.detail.saveButton.isEnabled, "no selection: Save is still there for the edits")

    // The filter narrows the sidebar.
    h.host.toolbar.filterField.stringValue = "alp"
    _ = h.host.toolbar.filterField.sendAction(h.host.toolbar.filterField.action, to: h.host.toolbar.filterField.target)
    expect(h.sidebar.shownItems.map(\.id), ["a"], "filter: the toolbar field narrows the sidebar")
    h.host.toolbar.filterField.stringValue = ""
    _ = h.host.toolbar.filterField.sendAction(h.host.toolbar.filterField.action, to: h.host.toolbar.filterField.target)
}

@MainActor
private func testColourSwatches() {
    let h = Harness([tag("a", "Alpha", colorIndex: 0), tag("b", "Beta", colorIndex: 3)])
    defer { h.close() }
    h.host.reseed()
    h.layout()
    let picker = h.detail.colorPicker
    expect(TagColorSwatchPicker.colorNames.count, TagPalette.colors.count, "swatches: one name per palette colour")
    expect(picker.count, TagPalette.colors.count, "swatches: one swatch per palette colour")
    expect(picker.selectedIndex, 0, "swatches: the tag's colour is the chosen swatch")

    // A click is `choose`, which sets AND sends — the only path that records.
    picker.selectedIndex = 2
    expect(h.detail.model.tags[0].colorIndex, 0, "swatches: setting selectedIndex alone records nothing")
    picker.choose(2)
    expect(h.detail.model.tags[0].colorIndex, 2, "swatches: a pick sets the tag's colorIndex")
    expect(h.sidebar.items[0].badge, .swatch(TagPalette.color(at: 2)), "swatches: and the sidebar swatch follows")
    expect(h.sidebar.items[0].trailing, [.unsavedDot], "swatches: and it is an edit")

    // The arrow keys walk the swatches.
    picker.keyDown(with: keyDown(String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), keyCode: 124, window: h.window))
    expect(h.detail.model.tags[0].colorIndex, 3, "swatches: → picks the next colour")

    // VoiceOver: a radio group of radio buttons named by colour; a press picks.
    expect(picker.accessibilityRole(), .radioGroup, "swatches: AX radio group")
    let children = picker.accessibilityChildren() as? [NSAccessibilityElement] ?? []
    expect(children.count, TagPalette.colors.count, "swatches: one AX child per colour")
    expect(children.map { $0.accessibilityRole() }, Array(repeating: NSAccessibility.Role.radioButton, count: children.count),
           "swatches: each a radio button")
    expect(children.map { $0.accessibilityLabel() ?? "" }, TagColorSwatchPicker.colorNames, "swatches: named by colour")
    expect(children.map { ($0.accessibilityValue() as? Int) ?? -1 }, [0, 0, 0, 1, 0, 0],
           "swatches: the chosen one's value is 1")
    let again = picker.accessibilityChildren() as? [NSAccessibilityElement] ?? []
    expectTrue(zip(children, again).allSatisfy { $0 === $1 },
               "swatches: the same AX elements every call (the server does not retain them)")
    _ = children[5].accessibilityPerformPress()
    expect(h.detail.model.tags[0].colorIndex, 5, "swatches: a VoiceOver press picks that colour")
    expect(picker.accessibilityValue() as? String, TagColorSwatchPicker.colorNames[5], "swatches: the group's value names it")

    // No tag on show: nothing can be picked.
    h.click(row: -1)
    expect(picker.selectedIndex, -1, "swatches: no tag, no chosen swatch")
    expectTrue(!picker.isEnabled, "swatches: and the picker is off")
    picker.choose(1)
    expect(h.detail.model.tags.map(\.colorIndex), [5, 3], "swatches: a pick with no tag changes nothing")
}

@MainActor
private func testDeleteSaveRevert() {
    let h = Harness([tag("a", "Alpha", [rule("r1", "one.example")]), tag("b", "Beta"), tag("c", "Gamma")])
    defer { h.close() }
    h.host.reseed()
    h.layout()

    // The Delete key on the selected row: the tag goes from the sidebar, and
    // the next one slides into its row (the sheet's "stay put" rule). The
    // MIDDLE row, so "stay put" (Gamma) and "back to the first" (Alpha)
    // cannot both pass.
    h.click(row: 1)
    h.sidebar.tableView.keyDown(with: keyDown("\u{7F}", keyCode: 51, window: h.window))
    expect(h.sidebar.items.map(\.id), ["a", "c"], "delete key: the tag leaves the sidebar")
    expect(h.sidebar.selectedId, "c", "delete key: the next tag slides into its row and is selected")
    expect(h.detail.nameField.stringValue, "Gamma", "delete key: and shown")
    expectTrue(h.detail.statusLabel.stringValue.contains("deletes 1 tag"),
               "delete key: the footer says what Save will destroy (\(h.detail.statusLabel.stringValue.debugDescription))")
    expect(h.committer.applied.count, 0, "delete key: nothing is written yet — no alert, no store write")

    // The context menu on a row that is NOT selected deletes that row and
    // leaves the selection alone.
    let menu = NSMenu()
    h.sidebar.populateContextMenu(menu, forRow: 0)
    expect(menu.items.map(\.title), ["Delete"], "context menu: Delete only (no Duplicate)")
    if let index = menu.items.firstIndex(where: { $0.title == "Delete" }) { menu.performActionForItem(at: index) }
    expect(h.sidebar.items.map(\.id), ["c"], "context menu: the clicked tag goes")
    expect(h.sidebar.selectedId, "c", "context menu: the selection stays where it was")
    expectTrue(h.detail.statusLabel.stringValue.contains("deletes 2 tags"),
               "context menu: the footer counts both deletes (\(h.detail.statusLabel.stringValue.debugDescription))")

    // Revert: every edit dropped, nothing written.
    expectTrue(h.detail.revertButton.isEnabled, "revert: on while there are edits")
    expectTrue(h.detail.revertButton.superview != nil && h.detail.cancelButton.superview == nil,
               "revert: the window shows Revert, not Cancel")
    h.detail.revertButton.performClick(nil)
    expect(h.committer.applied.count, 0, "revert: writes nothing")
    expect(h.sidebar.items.map(\.id), ["a", "b", "c"], "revert: the deleted tags are back")
    expect(h.host.hasEdits, false, "revert: no edits left")
    expectTrue(!h.detail.revertButton.isEnabled, "revert: and Revert is off again")
    expect(h.sidebar.selectedId, "c", "revert: the selection is kept by id")

    // Save: written once, the window stays on a fresh detail from the store.
    h.click(row: 0)
    h.sidebar.tableView.keyDown(with: keyDown("\u{7F}", keyCode: 51, window: h.window))
    let before = h.detail
    expect(h.detail.saveButton.keyEquivalent, "\r", "save: Save is the default button")
    h.committer.onApply = { h.stored = [tag("b", "Beta"), tag("c", "Gamma")] }
    h.detail.saveButton.performClick(nil)
    expect(h.committer.applied.count, 1, "save: one write")
    expect(h.committer.applied.first?.contains(.deleteTag("a")), true, "save: carrying the delete")
    expectTrue(h.detail !== before, "save: on a fresh detail")
    expect(h.sidebar.items.map(\.id), ["b", "c"], "save: built from the store")
    expect(h.host.hasEdits, false, "save: nothing unsaved")
    expect(h.sidebar.items.map(\.trailing), [[], []], "save: no dots left")
}

@MainActor
private func testStoreAndClose() {
    let h = Harness([])
    defer { h.close() }
    h.host.reseed()
    h.pressAdd()
    let first = h.detail

    // Another window changed the tags: with edits here, the detail is kept.
    h.stored = [tag("other", "From the grid")]
    h.host.storeChanged()
    expectTrue(h.detail === first, "store: a change elsewhere does not replace a detail with edits")

    // Save, then with no edits the window follows the store.
    h.committer.onApply = { h.stored = [tag("other", "From the grid"), tag("new", "New Tag")] }
    h.detail.saveButton.performClick(nil)
    expect(h.detail.model.tags.map(\.name), ["From the grid", "New Tag"], "store: rebuilt after the save")
    let second = h.detail
    h.stored = [tag("other", "Renamed elsewhere")]
    h.host.storeChanged()
    expectTrue(h.detail !== second, "store: no edits, another window's change is followed")
    expect(h.sidebar.items.first?.title, "Renamed elsewhere", "store: with its names")

    // Preselect, and keep the selection across a rebuild.
    h.stored = [tag("a", "Alpha"), tag("b", "Beta")]
    h.host.reseed(preselect: "b")
    expect(h.host.selectedTagId, "b", "preselect: the tag is selected")
    expect(h.sidebar.selectedId, "b", "preselect: in the sidebar too")
    h.host.reseed()
    expect(h.host.selectedTagId, "b", "preselect: and stays selected across a rebuild")
    h.host.select(tagId: "a")
    expect(h.detail.nameField.stringValue, "Alpha", "select(tagId:): shows that tag")

    // Closing with edits asks; without, it does not.
    var asked = 0
    h.host.askDiscard = { asked += 1; return false }
    expect(h.host.confirmClose(), true, "close: no edits, no question")
    expect(asked, 0, "close: none asked")
    type(h.detail.nameField, "Alpha Renamed")
    expect(h.host.confirmClose(), false, "close: edits, and Cancel in the question keeps the window")
    expect(asked, 1, "close: the question was asked")
    h.host.askDiscard = { asked += 1; return true }
    expect(h.host.confirmClose(), true, "close: Discard lets it close")
}

@MainActor
private func testAddValuesSampleAndKeyLoop() {
    let h = Harness([tag("ioc", "IOCs")])
    defer { h.close() }
    h.host.reseed(preselect: "ioc")
    h.layout()
    let detail = h.detail
    expectTrue(!detail.addValuesButton.isHiddenOrHasHiddenAncestor && detail.addValuesButton.window != nil,
               "add values: the footer button shows in the Tag Manager")
    expectTrue(detail.grid.addValuesButton.isHidden, "add values: the grid's own button stays hidden")

    let pasteSheet = TagAddValuesSheet(existing: []) { detail.addRules($0) }
    _ = pasteSheet.view
    pasteSheet.textView.string = "10.0.0.0/8\n10.0.0.1\n10.0.0.1\n"
    pasteSheet.refresh()
    expect(pasteSheet.addButton.title, "Add 2 Rules", "add values: the button counts the ready lines")
    expect(pasteSheet.summaryLabel.stringValue, "1 line(s) left out — see Status.", "add values: and says what was left out")
    pasteSheet.addButton.performClick(nil)
    expect(detail.model.tags[0].rules.count, 2, "add values: two rules added to the selected tag")
    expect(h.sidebar.items.first?.subtitle, "2 rules", "add values: the sidebar counts them")
    expect(h.host.hasEdits, true, "add values: they are edits until Save")

    // Test a value.
    expectTrue(!detail.sampleField.isHiddenOrHasHiddenAncestor && detail.sampleField.window != nil,
               "sample: Test a value shows in the Tag Manager")
    detail.sampleField.stringValue = "10.20.30.40"
    detail.refreshSample()
    expect(detail.sampleResultLabel.stringValue, "Matches rule 1.", "sample: an address inside the pasted range")
    expect(detail.sampleResultLabel.textColor, NSColor.systemGreen, "sample: a match is green")
    expect(detail.grid.groups.first?.sampleMark, .match, "sample: the matching rule is marked")
    detail.sampleField.stringValue = "192.168.1.1"
    detail.refreshSample()
    expect(detail.sampleResultLabel.stringValue, "No rule matches this value.", "sample: and one outside every rule")
    detail.sampleField.stringValue = ""
    detail.refreshSample()
    expect(detail.grid.groups.compactMap(\.sampleMark).count, 0, "sample: an empty sample clears every mark")

    // Tab: sidebar → name → colour → note → rules … → Add Values… → Test a
    // value → Revert → Save → sidebar.
    let row = detail.grid.groups.first!.conditionRows.first!
    expectTrue(h.sidebar.tableView.nextKeyView === detail.nameField, "tab: the sidebar leads to the name")
    expectTrue(detail.nameField.nextKeyView === detail.colorPicker, "tab: then the colour swatches")
    expectTrue(detail.colorPicker.nextKeyView === detail.noteField, "tab: then the note")
    expectTrue(detail.noteField.nextKeyView === detail.grid.groups.first!.deleteRuleButton, "tab: the note leads into the first rule")
    expectTrue(row.valueField.nextKeyView === row.upperField, "tab: a value goes to its upper bound")
    expectTrue(detail.addValuesButton.nextKeyView === detail.sampleField, "tab: Add Values… leads to Test a value")
    expectTrue(detail.sampleField.nextKeyView === detail.revertButton, "tab: then Revert")
    expectTrue(detail.saveButton.nextKeyView === h.sidebar.tableView, "tab: and the loop closes on the sidebar")
    detail.addRules([cond("text", "x")])
    let newRow = detail.grid.groups.last!.conditionRows.first!
    expectTrue(newRow.valueField.nextKeyView === newRow.upperField, "tab: a rule added later is in the loop too")
}

@MainActor
private func testRenderAndLayout() {
    // At the window's minimum size too: the detail's 540 pt minimum and the
    // sidebar's 220 pt make up the 760 pt window minimum exactly.
    expect(ManagerSplitViewController.sidebarMinimum + TagManagerHostVC.detailMinimum, 760,
           "layout: sidebar + detail minimums are the 760 pt window minimum")
    for size in [NSSize(width: 900, height: 600), NSSize(width: 760, height: 480)] {
        let h = Harness([tag("a", "Alpha", colorIndex: 4, [rule("r1", "one.example")]), tag("b", "Beta")], size: size)
        defer { h.close() }
        h.host.reseed()
        h.layout()
        let label = "\(Int(size.width))×\(Int(size.height))"
        // Measured before the hidden "newer version" notice in each rule
        // yielded its width: the detail held the window open at 837 pt.
        expect(h.window.contentView?.frame.width, size.width,
               "layout \(label): the window keeps its width — nothing in the detail holds it wider")
        expectTrue(h.detail.view.frame.width >= TagManagerHostVC.detailMinimum - 0.5,
                   "layout \(label): the detail is at least its minimum (\(Int(h.detail.view.frame.width)) pt)")
        // The action bar must be on screen, not below the fold.
        let save = h.detail.saveButton.convert(h.detail.saveButton.bounds, to: h.detail.view)
        expectTrue(h.detail.view.bounds.contains(save), "layout \(label): Save is inside the detail")
        // The picker gets its whole width in the row.
        expectTrue(abs(h.detail.colorPicker.frame.width - h.detail.colorPicker.intrinsicContentSize.width) < 0.5,
                   "layout \(label): the swatches are not squeezed (\(Int(h.detail.colorPicker.frame.width)) pt)")

        // Every state, each laid out, under a conflict spy.
        h.detail.grid.addRuleButton.performClick(nil)
        h.layout()
        h.click(row: -1)
        h.layout()
        h.click(row: 1)
        h.layout()

        // Both appearances render, the whole window included (glass and all).
        for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            expectTrue(render(h.host.view, appearance) != nil, "render \(label) \(name): the window content renders")
        }
    }

    // The swatch selection, measured in both appearances on the plate it
    // sits on.
    let h = Harness([tag("a", "Alpha", colorIndex: 4)])
    defer { h.close() }
    h.host.reseed()
    h.layout()
    let picker = h.detail.colorPicker
    let root = h.detail.view
    var plates: [String: NSColor] = [:]
    for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
        guard let shot = render(root, appearance) else {
            expectTrue(false, "swatch \(name): the detail renders")
            continue
        }
        // One point into the ring band at the top of the hit circle, where
        // the ring is horizontal: the chosen swatch (4) and an unchosen one (1).
        func ringPoint(_ index: Int) -> NSPoint {
            let hit = picker.hitRect(index)
            return topLeft(NSPoint(x: hit.midX, y: hit.minY + 1), in: picker, of: root)
        }
        guard let chosen = shot.pixel(ringPoint(4)), let plain = shot.pixel(ringPoint(1)),
              let fill = shot.pixel(topLeft(NSPoint(x: picker.swatchRect(1).midX, y: picker.swatchRect(1).midY),
                                            in: picker, of: root)) else {
            expectTrue(false, "swatch \(name): pixels to read")
            continue
        }
        plates[name] = plain
        let ratio = contrast(chosen, plain)
        // WCAG 1.4.11's 3:1 for a UI component's state. Measured against the
        // system accent at the time of the run.
        expectTrue(ratio >= 3, "swatch \(name): the ring \(hex(chosen)) on the plate \(hex(plain)) = \(String(format: "%.2f", ratio)):1 ≥ 3")
        expectTrue(contrast(fill, plain) > 1.2, "swatch \(name): the unchosen swatch itself is drawn (\(hex(fill)))")
    }
    if let light = plates["light"], let dark = plates["dark"] {
        expectTrue(contrast(light, dark) > 1.5, "swatch: the light and dark plates differ, so dark really rendered dark")
    }
    root.appearance = nil
}

func runTests() {
    _ = NSApplication.shared
    UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
    MainActor.assumeIsolated {
        testEmptyWindowAndNewTag()
        testSidebarRowsAndSelection()
        testColourSwatches()
        testDeleteSaveRevert()
        testStoreAndClose()
        testAddValuesSampleAndKeyLoop()
        testRenderAndLayout()
    }
    expect(SpyWindow.conflicts, 0, "layout: no constraint conflict was reported anywhere in this suite")
    UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames PharosTagManagerSplit")
    if failures == 0 { print("\nAll tag manager window tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
