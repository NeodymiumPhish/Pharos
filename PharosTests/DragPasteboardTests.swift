// Standalone test runner for the drag-out payload of the results grid (D2).
//
// A drag out of the grid is the one export path with no dialog and no
// preview: whatever `ResultsDragProvider` declares is what the destination
// app receives, and a missing representation or a mis-escaped CSV would only
// ever show up in the OTHER application. So the writer is asserted directly —
// the types it offers, the text behind each of them, and the bytes the file
// promise writes to disk.
//
// Compiled with ResultsCopyExport.swift + ResultsCellSelection.swift by
// scripts/test-drag-pasteboard.sh (same file set as test-sql-copy-format.sh).
import AppKit
import UniformTypeIdentifiers

private var failures = 0

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

/// Two columns, two rows, one value holding a comma and one holding a quote,
/// plus a SQL NULL — the three things every format has to decide about.
private func sampleData(includeHeaders: Bool = true) -> CopyData {
    CopyData(
        columnNames: ["n", "t"],
        columnIndices: [0, 1],
        rows: [
            ["1", "a,b"],
            ["2", nil],
            ["3", "say \"hi\""],
        ],
        includeHeaders: includeHeaders
    )
}

func runTests() {
    let provider = ResultsDragProvider(data: sampleData(), fileName: "Results.csv")

    // MARK: The drag carries the same three text types a copy writes
    let types = provider.writableTypes(for: NSPasteboard.general)
    expectTrue(types.contains(.string), "the drag offers .string")
    expectTrue(types.contains(.tabularText), "the drag offers .tabularText")
    expectTrue(types.contains(.html), "the drag offers .html")
    expectTrue(types.contains(.fileNameType(forPathExtension: "csv"))
                || types.contains(where: { $0.rawValue == "com.apple.pasteboard.promised-file-content-type" })
                || types.contains(where: { $0.rawValue.contains("file-promise") }),
               "the drag offers a file promise alongside the text types")

    // MARK: What a destination actually READS back off the drag pasteboard
    //
    // The assertion that matters, and the one a types-only check misses: with
    // these types declared `.promised`, the drag advertised all three and gave
    // back nil for every one of them — a drop into the editor or a spreadsheet
    // delivered nothing at all, with no error anywhere.
    let board = NSPasteboard(name: NSPasteboard.Name("PharosDragTests"))
    board.clearContents()
    board.writeObjects([provider])
    expectEqual(board.string(forType: .string) ?? "<nil>", "n\tt\n1\ta,b\n2\t\n3\t\"say \"\"hi\"\"\"",
                "a destination reads the TSV back off the drag pasteboard")
    expectTrue((board.string(forType: .tabularText) ?? "").hasPrefix("n\tt"),
               "and the tabular text")
    expectTrue((board.string(forType: .html) ?? "").hasPrefix("<table>"),
               "and the HTML table")

    // MARK: .string and .tabularText are the TSV form, .html a plain table
    let tsv = provider.pasteboardPropertyList(forType: .string) as? String ?? ""
    expectEqual(tsv, "n\tt\n1\ta,b\n2\t\n3\t\"say \"\"hi\"\"\"",
                "the .string representation is the TSV form, NULL an empty field")
    let tabular = provider.pasteboardPropertyList(forType: .tabularText) as? String ?? ""
    expectEqual(tabular, tsv, "the .tabularText representation matches .string")
    let html = provider.pasteboardPropertyList(forType: .html) as? String ?? ""
    expectTrue(html.hasPrefix("<table><thead><tr><th>n</th><th>t</th></tr></thead>"),
               "the .html representation is a plain table with the headers")
    expectTrue(html.contains("<td>say &quot;hi&quot;</td>"),
               "the .html representation escapes the cell text")

    // MARK: The file promise is a CSV named after the result
    expectEqual(provider.fileType, UTType.commaSeparatedText.identifier,
                "the file promise is typed as CSV")
    expectEqual(provider.filePromiseProvider(provider, fileNameForType: provider.fileType), "Results.csv",
                "the promised file keeps the name it was built with")
    expectEqual(ResultsCopyExport.dragFileName(base: "public/users"), "public-users.csv",
                "a table name with a path separator is sanitised into the file name")
    expectEqual(ResultsCopyExport.dragFileName(base: "   "), "Results.csv",
                "a name that sanitises away falls back to Results.csv")

    // MARK: The promise writes the CSV, quoted, to the URL it is given
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pharos-drag-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let target = dir.appendingPathComponent("Results.csv")
    let done = DispatchSemaphore(value: 0)
    var writeError: Error?
    provider.filePromiseProvider(provider, writePromiseTo: target) { error in
        writeError = error
        done.signal()
    }
    let finished = done.wait(timeout: .now() + 5) == .success
    expectTrue(finished && writeError == nil, "the file promise completes without an error")
    let written = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
    expectEqual(written, "n,t\n1,\"a,b\"\n2,\n3,\"say \"\"hi\"\"\"",
                "the promised file holds the CSV: header, quoted comma, empty NULL, doubled quotes")

    // MARK: Headers off drops the header line from both the text and the file
    let noHeaders = ResultsDragProvider(data: sampleData(includeHeaders: false), fileName: "Results.csv")
    let bare = noHeaders.pasteboardPropertyList(forType: .string) as? String ?? ""
    expectTrue(!bare.hasPrefix("n\tt"), "with headers off the dragged text starts at the first row")
    let bareTarget = dir.appendingPathComponent("NoHeaders.csv")
    let done2 = DispatchSemaphore(value: 0)
    noHeaders.filePromiseProvider(noHeaders, writePromiseTo: bareTarget) { _ in done2.signal() }
    _ = done2.wait(timeout: .now() + 5)
    let bareWritten = (try? String(contentsOf: bareTarget, encoding: .utf8)) ?? ""
    expectTrue(bareWritten.hasPrefix("1,\"a,b\""), "with headers off the promised file starts at the first row")

    runGestureTests()

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Drag Gesture

/// Five rows, two columns (`#` + one data column) — enough geometry for a
/// mouse-down to land on a known cell.
private final class GridStub: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 5 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        "r\(row)"
    }
}

/// A mouse event at the centre of `(row, column)`.
private func event(_ type: NSEvent.EventType, at position: CellPosition,
                   in table: NSTableView, window: NSWindow) -> NSEvent {
    let cell = table.frameOfCell(atColumn: position.column, row: position.row)
    let inWindow = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
    return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil,
                              eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// Same, offset by `dx` points — a drag that has passed the threshold.
private func draggedEvent(from position: CellPosition, dx: CGFloat,
                          in table: NSTableView, window: NSWindow) -> NSEvent {
    let cell = table.frameOfCell(atColumn: position.column, row: position.row)
    let inWindow = table.convert(NSPoint(x: cell.midX + dx, y: cell.midY), to: nil)
    return NSEvent.mouseEvent(with: .leftMouseDragged, location: inWindow, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil,
                              eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// The mouse-down inside an existing selection is the only one held back. It
/// must not collapse the selection the way an ordinary click does — a drag
/// starting there has to carry the WHOLE block — and it must still collapse it
/// when the button is released without moving.
private func runGestureTests() {
    let table = ResultsTableView()
    let stub = GridStub()
    table.dataSource = stub
    table.headerView = nil
    table.rowHeight = 20

    let rowNum = NSTableColumn(identifier: CellSelectionController.rowNumberColumnId)
    rowNum.width = 40
    let dataCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("a"))
    dataCol.width = 120
    table.addTableColumn(rowNum)
    table.addTableColumn(dataCol)

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    table.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView?.addSubview(table)
    table.reloadData()
    table.layoutSubtreeIfNeeded()

    let controller = CellSelectionController()
    controller.tableView = table
    table.cellSelectionController = controller

    // A block covering rows 1-3 of the single data column.
    controller.state.anchor = CellPosition(row: 1, column: 1)
    controller.state.active = CellPosition(row: 3, column: 1)

    let inside = CellPosition(row: 2, column: 1)
    let outside = CellPosition(row: 0, column: 1)

    // Nothing to drag while no provider is wired: the old behaviour stands.
    table.dragWriterProvider = nil
    table.mouseDown(with: event(.leftMouseDown, at: inside, in: table, window: window))
    expectTrue(controller.state.selectedRange?.topLeft.row == 2,
               "with no drag payload a click inside the selection still collapses it at once")

    controller.state.anchor = CellPosition(row: 1, column: 1)
    controller.state.active = CellPosition(row: 3, column: 1)
    table.dragWriterProvider = { NSPasteboardItem() }

    expectTrue(controller.hitsExistingSelection(event(.leftMouseDown, at: inside, in: table, window: window)),
               "a click on a cell inside the block hits the selection")
    expectTrue(!controller.hitsExistingSelection(event(.leftMouseDown, at: outside, in: table, window: window)),
               "a click on a cell outside it does not")

    table.mouseDown(with: event(.leftMouseDown, at: inside, in: table, window: window))
    expectTrue(controller.state.selectedRange?.topLeft.row == 1
                && controller.state.selectedRange?.bottomRight.row == 3,
               "the mouse-down inside the selection leaves the whole block selected")

    table.mouseUp(with: event(.leftMouseUp, at: inside, in: table, window: window))
    expectTrue(controller.state.selectedRange?.topLeft.row == 2
                && controller.state.selectedRange?.bottomRight.row == 2,
               "releasing without moving collapses the selection to the clicked cell")

    // A click outside the selection selects straight away, as it always did.
    controller.state.anchor = CellPosition(row: 1, column: 1)
    controller.state.active = CellPosition(row: 3, column: 1)
    table.mouseDown(with: event(.leftMouseDown, at: outside, in: table, window: window))
    expectTrue(controller.state.selectedRange?.topLeft.row == 0,
               "a click outside the selection still selects on mouse-down")

    // A held-back mouse-down with no payload after all falls back to selecting,
    // so the gesture is never swallowed.
    controller.state.anchor = CellPosition(row: 1, column: 1)
    controller.state.active = CellPosition(row: 3, column: 1)
    table.dragWriterProvider = { nil }
    table.mouseDown(with: event(.leftMouseDown, at: inside, in: table, window: window))
    table.mouseDragged(with: draggedEvent(from: inside, dx: 40, in: table, window: window))
    expectTrue(controller.state.selectedRange?.topLeft.row == 2,
               "a drag with no payload falls back to the selection the click would have made")
    expectTrue(!table.beginSelectionDrag(with: event(.leftMouseDown, at: inside, in: table, window: window)),
               "beginSelectionDrag reports failure when there is nothing to drag")
}
