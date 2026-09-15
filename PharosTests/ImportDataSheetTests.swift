// Standalone test runner for ImportDataSheet's button layout (F1). Uses real
// AppKit: the sheet's view is hosted in a headless, never-shown NSWindow so
// Auto Layout runs and the measurements below are the ones the user sees.
// Compiled with ImportDataSheet.swift, DisplayEscape.swift and
// NSStackView+SpanFullWidth.swift by scripts/test-import-data-sheet.sh.
//
// ImportDataSheet has no PharosCore/AppStateManager dependency, so it builds
// standalone — unlike ConnectionSheet and SaveQuerySheet, which pull in the
// FFI bridge and are skipped for a script of this shape.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func findButton(titled title: String, in view: NSView) -> NSButton? {
    for sub in view.subviews {
        if let button = sub as? NSButton, button.title == title { return button }
        if let found = findButton(titled: title, in: sub) { return found }
    }
    return nil
}

/// A non-editable text field whose string contains `text` — how the chosen
/// file name is shown.
private func findLabel(reading text: String, in view: NSView) -> NSTextField? {
    for sub in view.subviews {
        if let field = sub as? NSTextField, !(field is NSSearchField),
           field.stringValue.contains(text) { return field }
        if let found = findLabel(reading: text, in: sub) { return found }
    }
    return nil
}

func runTests() {
    let sheet = ImportDataSheet(schema: "public", table: "users", onImport: { _, _ in })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = sheet.view
    sheet.view.layoutSubtreeIfNeeded()

    // MARK: Cancel/Import sit at the trailing edge (F1)
    //
    // The main stack now spans full width with `.leading` alignment (see
    // NSStackView+SpanFullWidth.swift) instead of `.centerX`, and the button
    // row's leading spacer pushes Cancel/Import to the trailing edge rather
    // than centering the pair.
    if let cancelButton = findButton(titled: "Cancel", in: sheet.view),
       let importButton = findButton(titled: "Import", in: sheet.view) {
        let cancelFrame = cancelButton.convert(cancelButton.bounds, to: sheet.view)
        let importFrame = importButton.convert(importButton.bounds, to: sheet.view)
        // The stack itself has no edgeInsets (default 0); the 20pt side
        // margin comes from the leading/trailing constraints pinning it to
        // the container instead.
        let expectedTrailingX = sheet.view.frame.width - 20
        expectTrue(importFrame.maxX == expectedTrailingX,
                   "the default Import button reaches the trailing edge")
        expectTrue(cancelFrame.maxX < importFrame.minX,
                   "Cancel sits to the left of the default Import button")
    } else {
        failures += 1
        print("FAIL Cancel and Import buttons are reachable from the sheet's view")
    }

    // MARK: A dropped file arrives already chosen (D2)
    //
    // The drop on a table node opens this same sheet, so the file it carried
    // has to show as the chosen one and Import has to be live: an open panel
    // the user must drive again would make the drop pointless.
    let dropped = URL(fileURLWithPath: "/tmp/pharos-drop-test/indicators.csv")
    let droppedSheet = ImportDataSheet(schema: "public", table: "users",
                                       preselectedFileURL: dropped, onImport: { _, _ in })
    let droppedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
    droppedWindow.contentView = droppedSheet.view
    droppedSheet.view.layoutSubtreeIfNeeded()

    if let importButton = findButton(titled: "Import", in: droppedSheet.view) {
        expectTrue(importButton.isEnabled, "a preselected file leaves Import enabled")
    } else {
        failures += 1
        print("FAIL the Import button is reachable from the dropped-file sheet")
    }
    expectTrue(findLabel(reading: "indicators.csv", in: droppedSheet.view) != nil,
               "the preselected file's name is shown in the sheet")

    // And without one, Import stays disabled until a file is chosen.
    if let importButton = findButton(titled: "Import", in: sheet.view) {
        expectTrue(!importButton.isEnabled, "with no file chosen Import is disabled")
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
