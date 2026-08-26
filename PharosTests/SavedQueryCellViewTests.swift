// Standalone test runner for SavedQueryCellView — real AppKit, headless.
//
// This cell draws an AUTHORED LABEL (a saved-query name or a folder name) and
// is ALSO the field for the inline rename of that same label. Those two jobs
// want opposite treatments of a hostile scalar, and the cell must give each
// job the treatment it needs:
//
//   - As a LABEL it must DISCLOSE — `safe<U+202E>gpj.exe` — so a bidi override
//     cannot reorder the row and make one query read as another.
//   - As a FIELD it must SANITISE — `safegpj.exe` — because whatever the field
//     holds is what the user saves. Putting the disclosure token in the field
//     would let the user save the literal text `<U+202E>` as the name.
//
// So the raw name has to be kept, and each mode derived from it. The tests
// below are mostly about that: which string is in the label at each step of
// configure → beginEditing → endEditing, and that nothing is derived from the
// escaped form.
//
// Compiled with SavedQueryCellView.swift, NSTextField+AuthoredLabel.swift,
// AuthoredLabelSanitizer.swift and DisplayEscape.swift by
// scripts/test-saved-query-cell-view.sh.
import AppKit

private var failures = 0

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - Harness helpers

/// A borderless, never-shown window hosting one cell.
///
/// A window is required rather than optional plumbing: `beginEditing` asks for
/// the first responder and the field editor, and both are the WINDOW's to give.
/// A windowless cell would appear to edit while never producing a field editor,
/// which is the one thing these tests must observe.
private func makeHostedCell() -> (window: NSWindow, cell: SavedQueryCellView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 24),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let cell = SavedQueryCellView(identifier: NSUserInterfaceItemIdentifier("row"))
    cell.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
    window.contentView?.addSubview(cell)
    window.layoutIfNeeded()
    return (window, cell)
}

/// What the row DRAWS, read out of the view hierarchy rather than through an
/// accessor added for the tests. The cell holds exactly one text field.
private func drawnTitle(_ cell: SavedQueryCellView) -> String {
    let fields = cell.subviews.compactMap { $0 as? NSTextField }
    guard fields.count == 1 else { return "<expected exactly 1 NSTextField, found \(fields.count)>" }
    return fields[0].stringValue
}

/// What the RENAME holds — the field editor's text once editing has begun,
/// falling back to the field's own value before a field editor exists.
private func editedText(_ window: NSWindow, _ cell: SavedQueryCellView) -> String {
    let fields = cell.subviews.compactMap { $0 as? NSTextField }
    guard let field = fields.first else { return "<no NSTextField>" }
    if let editor = window.fieldEditor(false, for: field) { return editor.string }
    return field.stringValue
}

/// Records the name the cell hands back when the rename commits.
private final class RecordingDelegate: SavedQueryCellEditingDelegate {
    var committed: [String] = []
    func cellView(_ cellView: SavedQueryCellView, didFinishEditingWithText text: String) {
        committed.append(text)
    }
}

// MARK: - Tests

func runTests() {
    // AppKit needs the shared application before any window is made.
    _ = NSApplication.shared

    // MARK: A plain name reads as itself

    do {
        let (_, cell) = makeHostedCell()
        cell.configure(icon: nil, tint: .labelColor, title: "Monthly Revenue")
        expectEqual(drawnTitle(cell), "Monthly Revenue", "a plain name draws unchanged")
    }

    // MARK: The label DISCLOSES

    // The defect: a bidi override in a stored name reordered the sidebar row,
    // so one saved query could read as another — and the row is what the user
    // selects before every Open, Rename and Delete.
    do {
        let (_, cell) = makeHostedCell()
        cell.configure(icon: nil, tint: .labelColor, title: "safe\u{202E}gpj.exe")
        expectEqual(drawnTitle(cell), "safe<U+202E>gpj.exe",
                    "the row discloses a bidi override")
    }

    do {
        let (_, cell) = makeHostedCell()
        cell.configure(icon: nil, tint: .labelColor, title: "a\u{200B}b")
        expectEqual(drawnTitle(cell), "a<U+200B>b",
                    "the row discloses a zero-width character")
    }

    // TRIMMED, matching the delete confirmation and the store: both save paths
    // put the name through `AuthoredLabelSanitizer.committed`, so an edge space
    // in a stored name is a record written before they did. One name must not
    // read two ways in one window.
    do {
        let (_, cell) = makeHostedCell()
        cell.configure(icon: nil, tint: .labelColor, title: "  Reports  ")
        expectEqual(drawnTitle(cell), "Reports", "the row trims edge spaces")
    }

    do {
        let (_, cell) = makeHostedCell()
        cell.configure(icon: nil, tint: .labelColor, title: " \u{202E}x ")
        expectEqual(drawnTitle(cell), "<U+202E>x", "the row trims before it escapes")
    }

    do {
        let (_, cell) = makeHostedCell()
        cell.configure(icon: nil, tint: .labelColor, title: " a b ")
        expectEqual(drawnTitle(cell), "a b", "the row keeps interior spaces")
    }

    // MARK: The field SANITISES

    // The whole reason this is not a one-liner. The field is the SAME control
    // as the label, so an escape that stayed put would offer the user the
    // literal text `<U+202E>` to save as the name.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "safe\u{202E}gpj.exe")
        cell.beginEditing(delegate: delegate)
        expectEqual(editedText(window, cell), "safegpj.exe",
                    "the rename field holds the SANITISED name")
        expectTrue(!editedText(window, cell).contains("<U+202E>"),
                   "the disclosure token never reaches the rename field")
        expectTrue(!editedText(window, cell).unicodeScalars.contains { $0.value == 0x202E },
                   "the raw override never reaches the rename field either")

        // The row is renamed by typing straight away, with no second click, so
        // `beginEditing` must really take focus. Guards the one line that does
        // it: `selectText` focuses AND selects, and the `makeFirstResponder`
        // that used to follow it was removed as a duplicate.
        expectTrue(window.firstResponder is NSText,
                   "beginEditing gives the field editor first responder")
    }

    // The seed is `sanitized`, NOT `committed`: it is not trimmed. This matches
    // the rename sheet and the connections manager. An edge space is the
    // author's own text, still there to see and to keep or remove, and the save
    // trims it either way.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "  Reports  ")
        cell.beginEditing(delegate: delegate)
        expectEqual(editedText(window, cell), "  Reports  ",
                    "the rename field is not trimmed")
    }

    // The field is seeded from the RAW name, never from the escaped label. This
    // input separates the two: escaping first and sanitising second would give
    // `aU+200Bb`, because the sanitiser would strip the token's own scalars and
    // leave its text behind.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "a\u{200B}b")
        cell.beginEditing(delegate: delegate)
        expectEqual(editedText(window, cell), "ab",
                    "the field is seeded from the raw name, not from the label")
    }

    // MARK: The end of editing puts the label back

    // A rename that commits nothing — the name was emptied, so the cell refuses
    // it — calls no delegate and triggers no reload. The row is therefore left
    // exactly as the end of editing leaves it, and it must be left DISCLOSING.
    // Left in the sanitised form, a refused rename would make the row read as
    // though the hostile name were clean.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "safe\u{202E}gpj.exe")
        cell.beginEditing(delegate: delegate)
        let fields = cell.subviews.compactMap { $0 as? NSTextField }
        if let field = fields.first, let editor = window.fieldEditor(true, for: field) as NSText? {
            editor.string = "   "
            _ = cell.control(field, textShouldEndEditing: editor)
        }
        expectTrue(delegate.committed.isEmpty, "an emptied rename commits nothing")
        expectEqual(drawnTitle(cell), "safe<U+202E>gpj.exe",
                    "a refused rename restores the disclosing label")
    }

    // MARK: The commit still hands back a committed name

    // The existing contract, unchanged by the split: what leaves the cell is
    // sanitised AND trimmed, so the store never receives a deceptive name.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "Reports")
        cell.beginEditing(delegate: delegate)
        let fields = cell.subviews.compactMap { $0 as? NSTextField }
        if let field = fields.first, let editor = window.fieldEditor(true, for: field) as NSText? {
            editor.string = "  safe\u{202E}gpj.exe  "
            _ = cell.control(field, textShouldEndEditing: editor)
        }
        expectEqual(delegate.committed.first ?? "<nothing committed>", "safegpj.exe",
                    "the committed name is sanitised and trimmed")
    }

    // An untouched hostile name survives a begin-then-commit as its SANITISED
    // self. The row cannot launder the override, and it cannot save the token.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "safe\u{202E}gpj.exe")
        cell.beginEditing(delegate: delegate)
        let fields = cell.subviews.compactMap { $0 as? NSTextField }
        if let field = fields.first, let editor = window.fieldEditor(true, for: field) as NSText? {
            _ = cell.control(field, textShouldEndEditing: editor)
        }
        expectEqual(delegate.committed.first ?? "<nothing committed>", "safegpj.exe",
                    "an untouched hostile name commits as its sanitised self")
    }

    // The same restoration, but reached the way the APP reaches it: the field
    // resigns first responder, and AppKit — not the test — runs the end of
    // editing and writes the field editor back into the field. A restoration
    // that only holds when `control(_:textShouldEndEditing:)` is called by hand
    // would be a restoration AppKit then overwrites.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "safe\u{202E}gpj.exe")
        cell.beginEditing(delegate: delegate)
        window.makeFirstResponder(nil)
        expectEqual(drawnTitle(cell), "safe<U+202E>gpj.exe",
                    "AppKit's own end of editing leaves the label disclosing")
    }

    // MARK: Reconfigure

    // The row is recycled by NSOutlineView, so a second `configure` must fully
    // replace the first — including the raw name the field is seeded from.
    do {
        let (window, cell) = makeHostedCell()
        let delegate = RecordingDelegate()
        cell.configure(icon: nil, tint: .labelColor, title: "safe\u{202E}gpj.exe")
        cell.configure(icon: nil, tint: .labelColor, title: "Reports")
        expectEqual(drawnTitle(cell), "Reports", "a reused row draws its new name")
        cell.beginEditing(delegate: delegate)
        expectEqual(editedText(window, cell), "Reports",
                    "a reused row seeds the field from its new name")
    }

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
