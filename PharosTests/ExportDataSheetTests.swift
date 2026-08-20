// Standalone test runner for ExportDataSheet's column section. Uses real
// AppKit: the sheet's view is hosted in a headless, never-shown NSWindow so
// Auto Layout runs and the measurements below are the ones the user sees.
// Compiled with ExportDataSheet.swift, Schema.swift, NSTextField+FormLabel.swift
// and NSStackView+SpanFullWidth.swift by scripts/test-export-data-sheet.sh.
//
// The one thing this pins is geometry the sheet had no test for at all: the
// column section asked for `alignment = .width`, which NSStackView rejects, and
// its two rows filled the section only because both happen to stretch on their
// own. Nothing would have reported it if one stopped.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func columns(_ count: Int) -> [ColumnInfo] {
    (1...count).map {
        ColumnInfo(name: "column_\($0)", dataType: "text", isNullable: true,
                   isPrimaryKey: false, ordinalPosition: Int32($0), columnDefault: nil)
    }
}

/// The column section: the vertical stack holding the Columns header row and
/// the checkbox scroll view. `loadView` keeps it to itself, so it is found by
/// its contents rather than exposed — the production code owes nothing here.
private func columnSection(in view: NSView) -> NSStackView? {
    func walk(_ v: NSView) -> NSStackView? {
        for sub in v.subviews {
            if let stack = sub as? NSStackView, stack.orientation == .vertical,
               stack.arrangedSubviews.count == 2,
               stack.arrangedSubviews[1] is NSScrollView {
                return stack
            }
            if let found = walk(sub) { return found }
        }
        return nil
    }
    return walk(view)
}

private func checkboxTitles(in view: NSView) -> [String] {
    var found: [String] = []
    func walk(_ v: NSView) {
        for sub in v.subviews {
            if let button = sub as? NSButton, !button.title.isEmpty { found.append(button.title) }
            walk(sub)
        }
    }
    walk(view)
    return found
}

private func allLabelStrings(in view: NSView) -> [String] {
    var found: [String] = []
    func walk(_ v: NSView) {
        for sub in v.subviews {
            if let field = sub as? NSTextField { found.append(field.stringValue) }
            walk(sub)
        }
    }
    walk(view)
    return found
}

func runTests() {
    let sheet = ExportDataSheet(schema: "public", table: "users",
                                columns: columns(4), onExport: { _ in })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = sheet.view
    sheet.view.layoutSubtreeIfNeeded()

    guard let section = columnSection(in: sheet.view) else {
        print("FAIL the column section is reachable from the sheet's view")
        print("\n1 FAILURE(S)")
        exit(1)
    }

    expectTrue(section.alignment == .leading,
               "the column section asks for an alignment NSStackView accepts")
    expectTrue(section.frame.width > 0, "the column section has a measured width")

    // Measured on alignment rects, not frames: an NSTextField label's frame
    // overhangs its alignment rect by 2pt each side, so a correctly-placed
    // label reads x=-2 as a frame and x=0 as an alignment rect.
    let rects = section.arrangedSubviews.map { $0.alignmentRect(forFrame: $0.frame) }
    expectTrue(rects.allSatisfy { $0.minX == 0 },
               "the Columns header and the list start at the same leading edge")
    expectTrue(rects.allSatisfy { $0.width == section.frame.width },
               "the Columns header and the list both span the section")

    // The header's All/None buttons reach the trailing edge only because the
    // header row spans; a header that hugged its label would take them with it.
    let header = section.arrangedSubviews[0]
    expectTrue(header.frame.maxX == section.frame.width,
               "the Columns header reaches the section's trailing edge")

    // The checkbox title is display-only: the export reads the raw column name
    // from the parallel (checkbox, name) tuple, so escaping the title must not
    // change what is exported.
    do {
        let hostileColumns = [
            ColumnInfo(name: "ip\u{200B}addr", dataType: "text", isNullable: true,
                       isPrimaryKey: false, ordinalPosition: 1, columnDefault: nil)
        ]
        let sheet2 = ExportDataSheet(schema: "pub\u{202E}lic", table: "users",
                                     columns: hostileColumns, onExport: { _ in })
        let window2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window2.contentView = sheet2.view
        sheet2.view.layoutSubtreeIfNeeded()

        expectTrue(checkboxTitles(in: sheet2.view).contains { $0.contains("<U+200B>") },
                   "a column checkbox discloses a zero-width space in its name")
        expectTrue(allLabelStrings(in: sheet2.view).contains { $0.contains("<U+202E>") },
                   "the sheet subtitle discloses a bidi override in the schema name")
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
