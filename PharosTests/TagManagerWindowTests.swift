// Standalone test for TagManagerHostVC — compiled by
// scripts/test-tag-manager-window.sh. A fake committer and tag list stand in
// for TagStore (Keychain-bound through the FFI); the sheet is the real one.
import AppKit

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private final class FakeCommitter: TagManagerCommitting {
    var applied: [[TagManagerCommit]] = []
    var onApply: (() -> Void)?
    func apply(_ commits: [TagManagerCommit]) throws {
        applied.append(commits)
        onApply?()
    }
}

private func tag(_ id: String, _ name: String) -> Tag {
    Tag(id: id, name: name, colorIndex: 0, note: nil, createdAt: "", updatedAt: "", rules: [])
}

@MainActor
private func testWindowContent() {
    var stored: [Tag] = []
    let committer = FakeCommitter()
    let host = TagManagerHostVC(tags: { stored }, committer: committer)
    var closed = 0
    host.closeWindow = { closed += 1 }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = host.view

    // Opens with no tags at all: the empty state, and New Tag.
    host.reseed()
    guard let first = host.sheet else { expect(false, true, "a sheet is built"); return }
    expect(first.model.tags.isEmpty, true, "no tags")
    expect(first.emptyLabel.isHidden, false, "the empty state shows")
    expect(first.emptyLabel.stringValue.contains("New Tag"), true, "and says how to make one")
    expect(host.hasEdits, false, "nothing to save yet")

    first.newTagButton.performClick(nil)
    expect(host.hasEdits, true, "New Tag is an edit")

    // Another window changed the tags: with edits here, the sheet is kept.
    stored = [tag("other", "From the grid")]
    host.storeChanged()
    expect(host.sheet === first, true, "the store's change does not replace a sheet with edits")

    // Save: written once, the window stays open on a fresh sheet from the store.
    committer.onApply = { stored = [tag("other", "From the grid"), tag("new", "New Tag")] }
    first.saveButton.performClick(nil)
    expect(committer.applied.count, 1, "one save")
    expect(closed, 0, "a save keeps the window open")
    expect(host.sheet !== first, true, "on a fresh sheet")
    expect(host.sheet?.model.tags.map(\.name), ["From the grid", "New Tag"], "built from the store")
    expect(host.hasEdits, false, "with nothing unsaved")

    // With no edits, the window follows the store.
    let second = host.sheet
    stored = [tag("other", "Renamed elsewhere")]
    host.storeChanged()
    expect(host.sheet !== second, true, "no edits: another window's change is followed")
    expect(host.sheet?.model.tags.first?.name, "Renamed elsewhere", "with its names")

    // Preselect a tag the way a click does.
    stored = [tag("a", "Alpha"), tag("b", "Beta")]
    host.reseed(preselect: "b")
    expect(host.selectedTagId, "b", "the preselected tag is selected")
    host.reseed()
    expect(host.selectedTagId, "b", "and stays selected across a rebuild")

    // Closing with edits asks; without, it does not.
    var asked = 0
    host.askDiscard = { asked += 1; return false }
    expect(host.confirmClose(), true, "no edits: the window closes without asking")
    host.sheet?.newTagButton.performClick(nil)
    expect(host.confirmClose(), false, "edits: Cancel in the question keeps it open")
    expect(asked, 1, "and the question was asked")

    // Add Values…: offered in the Tag Manager, and its rules land on the tag.
    stored = [tag("ioc", "IOCs")]
    host.reseed(preselect: "ioc")
    guard let manage = host.sheet else { return }
    expect(manage.grid.addValuesButton.isHidden, false, "Add Values… shows in the Tag Manager")
    let pasteSheet = TagAddValuesSheet(existing: []) { manage.addRules($0) }
    _ = pasteSheet.view
    pasteSheet.textView.string = "10.0.0.0/8\n10.0.0.1\n10.0.0.1\n"
    pasteSheet.refresh()
    expect(pasteSheet.addButton.title, "Add 2 Rules", "the button counts the ready lines")
    expect(pasteSheet.summaryLabel.stringValue, "1 line(s) left out — see Status.", "and says what was left out")
    pasteSheet.addButton.performClick(nil)
    expect(manage.model.tags[manage.model.tags.firstIndex { $0.id == "ioc" }!].rules.count, 2,
           "two rules added to the selected tag")
    expect(host.hasEdits, true, "they are edits until Save")
    // Test a value: the sample is checked against the tag's rules, edits included.
    expect(manage.sampleField.superview?.isHidden, false, "Test a value shows in the Tag Manager")
    manage.sampleField.stringValue = "10.20.30.40"
    manage.refreshSample()
    expect(manage.sampleResultLabel.stringValue, "Matches rule 1.", "an address inside the pasted range")
    manage.sampleField.stringValue = "192.168.1.1"
    manage.refreshSample()
    expect(manage.sampleResultLabel.stringValue, "No rule matches this value.", "and one outside every rule")

    let emptySheet = TagAddValuesSheet(existing: []) { _ in }
    _ = emptySheet.view
    expect(emptySheet.addButton.isEnabled, false, "nothing typed: Add is off")

    // Cancel closes the window.
    host.askDiscard = { true }
    host.sheet?.cancelButton.performClick(nil)
    expect(closed, 1, "Cancel closes the window")
}

func runTests() {
    _ = NSApplication.shared
    MainActor.assumeIsolated { testWindowContent() }
    if failures == 0 { print("\nAll tag manager window tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
