// Standalone tests for the shared manager shell under Pharos/Windows/Manager:
// ManagerSidebarItem, ManagerSidebarVC + ManagerSidebarCell,
// ManagerSplitViewController and ManagerToolbarController. Compiled with the
// implementation by scripts/test-manager-sidebar.sh.
//
// Real AppKit in offscreen windows. Two hazards this suite is written around
// (see tasks/lessons.md): the selection pill is only emphasized when the
// window is key AND has posted didBecomeKey — a never-activated test app has
// neither, so `KeyWindow` claims the first and the suite posts the second;
// and a colour claim is only proved by resolving it under BOTH appearances,
// so the selection pair is rendered and measured in Light and in Dark.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - Hosting

/// A window that says it is key, so the table's selection can be emphasized.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class SidebarHost {
    let window: KeyWindow
    let sidebar: ManagerSidebarVC
    /// A field outside the list, to prove the list never takes focus.
    let otherField = NSTextField(string: "")

    init(items: [ManagerSidebarItem], width: CGFloat = 280, height: CGFloat = 420) {
        window = KeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                           styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar = ManagerSidebarVC(accessibilityLabel: "Things")
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = root
        sidebar.view.frame = NSRect(x: 0, y: 40, width: width, height: height - 40)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(sidebar.view)
        otherField.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        root.addSubview(otherField)
        sidebar.setItems(items)
        window.orderFrontRegardless()
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        sidebar.tableView.layoutSubtreeIfNeeded()
    }

    var table: ManagerSidebarTableView { sidebar.tableView }

    /// Focus the table and announce the window key, which is what makes the
    /// selected row's background `.emphasized`.
    func focusTable() {
        window.makeFirstResponder(table)
        window.becomeKey()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        layout()
    }

    func cell(row: Int) -> ManagerSidebarCell? {
        table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ManagerSidebarCell
    }

    func close() { window.orderOut(nil) }
}

private func item(_ id: String, _ title: String, subtitle: String? = nil, mono: Bool = false,
                  badge: ManagerSidebarItem.Badge = .none,
                  trailing: [ManagerSidebarItem.Accessory] = []) -> ManagerSidebarItem {
    ManagerSidebarItem(id: id, title: title, titleIsMonospaced: mono, subtitle: subtitle,
                       badge: badge, trailing: trailing)
}

private let sample: [ManagerSidebarItem] = [
    item("alpha", "Alpha", subtitle: "Number · 42", badge: .symbol(name: "number", tint: .systemBlue)),
    item("beta", "Beta", subtitle: "3 rules", badge: .swatch(.systemRed)),
    item("gamma", "{{gamma}}", subtitle: "Text · Café", mono: true,
         trailing: [.warning(tooltip: "Not a number")]),
    item("delta", "Delta", subtitle: "db.example.com:5432 · app",
         badge: .symbol(name: "server.rack", tint: nil),
         trailing: [.statusDot(.systemGreen, accessibilityLabel: "Connected"), .unsavedDot]),
]

private func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [],
                     window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

// MARK: - Colour measurement

/// WCAG relative luminance of an sRGB colour.
private func relativeLuminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB) ?? color
    func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
}

private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let la = relativeLuminance(a), lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func over(_ top: NSColor, _ ground: NSColor) -> NSColor {
    let t = top.usingColorSpace(.sRGB)!, g = ground.usingColorSpace(.sRGB)!
    let a = t.alphaComponent
    return NSColor(srgbRed: t.redComponent * a + g.redComponent * (1 - a),
                   green: t.greenComponent * a + g.greenComponent * (1 - a),
                   blue: t.blueComponent * a + g.blueComponent * (1 - a), alpha: 1)
}

private func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)),
                  Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
}

/// A row view rendered offscreen under one appearance.
@MainActor
private struct RenderedRow {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    init?(_ rowView: NSView, appearance: NSAppearance) {
        guard let rep = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance { rowView.cacheDisplay(in: rowView.bounds, to: rep) }
        self.rep = rep
        scale = CGFloat(rep.pixelsWide) / rowView.bounds.width
    }

    /// The most common opaque colour: the selection pill, when there is one.
    func dominantOpaque() -> NSColor? {
        var counts: [UInt32: Int] = [:]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { continue }
                let key = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8
                    | UInt32(c.blueComponent * 255)
                counts[key, default: 0] += 1
            }
        }
        // A fill covers most of the row; glyphs alone never come close.
        let area = rep.pixelsWide * rep.pixelsHigh
        guard let top = counts.max(by: { $0.value < $1.value }), top.value * 3 > area else { return nil }
        return NSColor(srgbRed: CGFloat(top.key >> 16 & 0xFF) / 255, green: CGFloat(top.key >> 8 & 0xFF) / 255,
                       blue: CGFloat(top.key & 0xFF) / 255, alpha: 1)
    }

    /// The glyph ink inside `rect` (row-view points, flipped like the row):
    /// the composited pixel that stands furthest from `ground`.
    func ink(in rect: NSRect, ground: NSColor) -> NSColor? {
        var best: NSColor?
        var bestContrast: CGFloat = 0
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(rep.pixelsHigh, Int(rect.maxY * scale))
        guard x0 < x1, y0 < y1 else { return nil }
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let seen = over(c, ground)
                let k = contrast(seen, ground)
                if k > bestContrast { bestContrast = k; best = seen }
            }
        }
        return best
    }
}

/// `view`'s frame in `rowView`, top-left origin as `colorAt` counts.
@MainActor
private func topLeftRect(of view: NSView, in rowView: NSView) -> NSRect {
    var r = view.convert(view.bounds, to: rowView)
    if !rowView.isFlipped { r.origin.y = rowView.bounds.height - r.maxY }
    return r
}

// MARK: - Tests

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { runAll() }
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

@MainActor
private func runAll() {
    testItemModel()
    testSelectionKeptById()
    testFilter()
    testDeleteKey()
    testContextMenu()
    testReorder()
    testCell()
    testMetricsMatchAppKit()
    testSelectionColours()
    testSplitView()
    testToolbar()
    testScrollerAutohides()
    testLongItemKeepsWidths()
    testEveryCloseAsksOnce()
}

// MARK: 1. The row model

@MainActor
private func testItemModel() {
    let gamma = sample[2]
    expectTrue(gamma.matches("GAM"), "model: the title matches ignoring case")
    expectTrue(gamma.matches("cafe"), "model: the subtitle matches ignoring case and accents")
    expectTrue(gamma.matches("  "), "model: a blank filter matches everything")
    expectTrue(!gamma.matches("rules"), "model: a word in neither line does not match")
    expectEqual(gamma.typeSelectText, "gamma}}", "model: type-select skips the leading braces")
    expectEqual(item("u", "_under").typeSelectText, "_under", "model: a leading underscore stays")
    expectEqual(item("p", "{{}}").typeSelectText, "{{}}", "model: all punctuation falls back to the title")
}

// MARK: 2. setItems keeps the selection by id, and never takes focus

@MainActor
private func testSelectionKeptById() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    var selections: [String?] = []
    host.sidebar.onSelect = { selections.append($0) }

    host.window.makeFirstResponder(host.otherField)
    let focused = host.window.firstResponder

    host.sidebar.selectedId = "beta"
    expectEqual(host.table.selectedRow, 1, "selection: selectedId = … selects that row")

    // A new record above it moves it down a row.
    host.sidebar.setItems([item("new", "New")] + sample)
    expectEqual(host.table.selectedRow, 2, "selection: setItems follows the id to its new row")
    expectEqual(host.sidebar.selectedId, "beta", "selection: the id is unchanged")

    // Same rows, new text: refreshed in place, selection untouched.
    var renamed = [item("new", "New")] + sample
    renamed[2].title = "Beta Renamed"
    host.sidebar.setItems(renamed)
    expectEqual(host.table.selectedRow, 2, "selection: a rename keeps the row selected")
    expectEqual(host.cell(row: 2)?.titleField.stringValue, "Beta Renamed", "selection: the rename is on show")

    expectTrue(selections.isEmpty, "selection: none of that called onSelect (\(selections))")
    expectTrue(host.window.firstResponder === focused, "selection: none of that took keyboard focus")

    // The selected record goes away.
    host.sidebar.setItems(sample.filter { $0.id != "beta" })
    expectEqual(host.sidebar.selectedId, nil, "selection: a removed record clears selectedId")
    expectEqual(host.table.selectedRow, -1, "selection: and the table selects nothing")
    expectTrue(selections.isEmpty, "selection: still no onSelect — the owner removed it")

    host.sidebar.selectedId = "nope"
    expectEqual(host.sidebar.selectedId, nil, "selection: an unknown id selects nothing")

    // A user click reports.
    host.sidebar.setItems(sample)
    host.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
    expectEqual(selections, ["delta"], "selection: a user selection calls onSelect with its id")
    expectEqual(host.sidebar.selectedId, "delta", "selection: and becomes selectedId")
}

// MARK: 3. The filter

@MainActor
private func testFilter() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    var selections: [String?] = []
    host.sidebar.onSelect = { selections.append($0) }
    host.sidebar.selectedId = "gamma"

    host.sidebar.filterText = "ta"   // Beta, Delta
    expectEqual(host.sidebar.shownItems.map(\.id), ["beta", "delta"], "filter: only matching rows are on show")
    expectEqual(host.table.numberOfRows, 2, "filter: the table shows two rows")
    expectEqual(host.table.selectedRow, -1, "filter: a hidden selection leaves no row selected")
    expectEqual(host.sidebar.selectedId, "gamma", "filter: but the record stays the selected one")

    host.sidebar.filterText = "app"  // Delta's subtitle
    expectEqual(host.sidebar.shownItems.map(\.id), ["delta"], "filter: the subtitle is searched too")

    host.sidebar.filterText = "zzz"
    expectTrue(host.sidebar.isShowingNoMatches, "filter: nothing matches → the No Matches state")
    expectEqual(host.table.numberOfRows, 1, "filter: one row on show")
    let noMatches = host.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ManagerNoMatchesCell
    expectEqual(noMatches?.message, "No Matches", "filter: the row says No Matches")
    expectTrue(host.sidebar.tableView(host.table, shouldSelectRow: 0) == false,
               "filter: the No Matches row cannot be selected")
    expectEqual(host.sidebar.tableView(host.table, typeSelectStringFor: nil, row: 0), nil,
                "filter: the No Matches row is not a type-select target")

    host.sidebar.filterText = ""
    expectEqual(host.table.numberOfRows, sample.count, "filter: cleared → every row is back")
    expectEqual(host.table.selectedRow, 2, "filter: cleared → the kept selection is selected again")
    expectTrue(selections.isEmpty, "filter: filtering never called onSelect (\(selections))")

    // Type-select: "g" finds {{gamma}} past its braces, as a user selection.
    host.sidebar.selectedId = "alpha"
    host.focusTable()
    host.table.keyDown(with: keyDown("g", keyCode: 5, window: host.window))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    expectEqual(host.table.selectedRow, 2, "type-select: typing g selects {{gamma}}")
}

// MARK: 4. The Delete key

@MainActor
private func testDeleteKey() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    var deleted: [[String]] = []
    host.sidebar.selectedId = "beta"
    host.focusTable()

    // No handler: the key falls through and nothing is reported.
    expectTrue(!host.sidebar.deleteSelectedRows(), "delete: with no onDelete there is nothing to do")

    host.sidebar.onDelete = { deleted.append($0) }
    host.table.keyDown(with: keyDown("\u{7F}", keyCode: 51, window: host.window))
    expectEqual(deleted, [["beta"]], "delete: ⌫ calls onDelete with the selected id")

    let forward = String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!)
    host.table.keyDown(with: keyDown(forward, keyCode: 117, flags: .function, window: host.window))
    expectEqual(deleted.count, 2, "delete: ⌦ does too")

    host.table.keyDown(with: keyDown("\u{7F}", keyCode: 51, flags: .command, window: host.window))
    expectEqual(deleted.count, 3, "delete: ⌘⌫ does too")

    host.table.keyDown(with: keyDown("\u{7F}", keyCode: 51, flags: .option, window: host.window))
    expectEqual(deleted.count, 3, "delete: ⌥⌫ does not")

    let menuItem = NSMenuItem(title: "Delete", action: #selector(ManagerSidebarTableView.delete(_:)),
                              keyEquivalent: "")
    expectTrue(host.table.validateUserInterfaceItem(menuItem), "delete: Edit ▸ Delete is enabled on a selection")
    host.sidebar.selectedId = nil
    expectTrue(!host.table.validateUserInterfaceItem(menuItem), "delete: and disabled with none")
    host.table.keyDown(with: keyDown("\u{7F}", keyCode: 51, window: host.window))
    expectEqual(deleted.count, 3, "delete: ⌫ with no selection reports nothing")
}

// MARK: 5. The context menu

@MainActor
private func testContextMenu() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    let menu = NSMenu()
    func titles() -> [String] { menu.items.map { $0.isSeparatorItem ? "—" : $0.title } }

    host.sidebar.onDelete = { _ in }
    host.sidebar.populateContextMenu(menu, forRow: 1)
    expectEqual(titles(), ["Delete"], "menu: without onDuplicate there is no Duplicate")

    var duplicated: [String] = []
    var deleted: [[String]] = []
    host.sidebar.onDuplicate = { duplicated.append($0) }
    host.sidebar.onDelete = { deleted.append($0) }
    host.sidebar.populateContextMenu(menu, forRow: 1)
    expectEqual(titles(), ["Duplicate", "—", "Delete"], "menu: with onDuplicate, Duplicate comes first")

    menu.performActionForItem(at: 0)
    expectEqual(duplicated, ["beta"], "menu: Duplicate acts on the clicked row")
    menu.performActionForItem(at: 2)
    expectEqual(deleted, [["beta"]], "menu: Delete acts on the clicked row")

    host.sidebar.populateContextMenu(menu, forRow: -1)
    expectTrue(menu.items.isEmpty, "menu: below the rows there is no menu")

    host.sidebar.filterText = "zzz"
    host.sidebar.populateContextMenu(menu, forRow: 0)
    expectTrue(menu.items.isEmpty, "menu: the No Matches row has no menu")
}

// MARK: 6. Drag reorder

@MainActor
private func testReorder() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    let dragType = NSPasteboard.PasteboardType("com.pharos.manager-sidebar.row")

    expectTrue(host.sidebar.tableView(host.table, pasteboardWriterForRow: 0) == nil,
               "reorder: no onMove → rows cannot be dragged")
    expectTrue(!host.table.registeredDraggedTypes.contains(dragType), "reorder: no onMove → no drop type")

    var moves: [[Int]] = []
    host.sidebar.onMove = { moves.append([$0, $1]) }
    expectTrue(host.table.registeredDraggedTypes.contains(dragType), "reorder: onMove → the table takes drops")
    expectTrue(host.sidebar.tableView(host.table, pasteboardWriterForRow: 0) != nil,
               "reorder: onMove and no filter → rows can be dragged")

    host.sidebar.filterText = "a"
    expectTrue(!host.sidebar.canReorder, "reorder: off while filtering")
    expectTrue(host.sidebar.tableView(host.table, pasteboardWriterForRow: 0) == nil,
               "reorder: while filtering no row starts a drag")
    expectTrue(!host.sidebar.performMove(from: 0, to: 3), "reorder: while filtering a drop is refused")

    host.sidebar.filterText = ""
    expectTrue(host.sidebar.performMove(from: 0, to: 3), "reorder: a real move is reported")
    expectTrue(!host.sidebar.performMove(from: 1, to: 2), "reorder: a drop in its own gap is not")
    expectTrue(!host.sidebar.performMove(from: 1, to: 1), "reorder: nor a drop just above itself")
    expectTrue(!host.sidebar.performMove(from: 9, to: 0), "reorder: nor a row that does not exist")
    expectEqual(moves, [[0, 3]], "reorder: onMove got (from, gap) as Array.move(fromOffsets:toOffset:) does")
}

// MARK: 7. The cell

@MainActor
private func testCell() {
    let host = SidebarHost(items: sample)
    defer { host.close() }

    guard let beta = host.cell(row: 1), let gamma = host.cell(row: 2), let delta = host.cell(row: 3) else {
        expectTrue(false, "cell: rows have ManagerSidebarCells")
        return
    }
    expectEqual(beta.titleField.accessibilityIdentifier(), "manager.sidebar.beta",
                "cell: the AX identifier is on the title LABEL")
    expectEqual(beta.titleField.accessibilityLabel(), "Beta", "cell: the label reads the title")
    expectEqual(beta.subtitleField.stringValue, "3 rules", "cell: the subtitle is on show")
    expectTrue(!beta.subtitleField.isHidden, "cell: a subtitle row shows the second line")

    expectTrue(gamma.titleField.font?.isFixedPitch == true, "cell: a monospaced title is fixed-pitch")
    expectTrue(beta.titleField.font?.isFixedPitch == false, "cell: a plain title is not")
    expectEqual(gamma.titleField.font?.pointSize, gamma.currentMetrics.titleSize,
                "cell: the monospaced title keeps the size style's size")

    expectEqual(gamma.accessoryViews.map(\.accessory), [.warning(tooltip: "Not a number")],
                "cell: the warning mark is on show")
    expectEqual(gamma.accessoryViews.first?.toolTip, "Not a number", "cell: the warning's tooltip is its text")
    expectEqual(delta.accessoryViews.count, 2, "cell: a row can carry a status dot AND the unsaved dot")
    expectEqual(delta.accessoryViews.first?.accessibilityLabel(), "Connected",
                "cell: the status dot reads its label, not its colour")

    // A row with no subtitle is one line tall; a row with one is taller.
    host.sidebar.setItems([item("solo", "Solo"), item("two", "Two", subtitle: "Second line")])
    host.layout()
    let one = host.table.rect(ofRow: 0).height, two = host.table.rect(ofRow: 1).height
    expectEqual(one, host.table.rowHeight, "cell: a one-line row is the size style's row height (\(one))")
    expectTrue(two > one + 10, "cell: a two-line row is a caption line taller (\(two) vs \(one))")
    let solo = host.cell(row: 0)
    expectTrue(solo?.subtitleField.isHidden == true, "cell: no subtitle → the second line is hidden")

    // The title truncates before it reaches the marks.
    host.sidebar.setItems([item("long", String(repeating: "Very long name ", count: 10),
                                trailing: [.unsavedDot])])
    host.layout()
    if let long = host.cell(row: 0), let mark = long.accessoryViews.first {
        long.layoutSubtreeIfNeeded()
        let titleEnd = long.titleField.frame.maxX
        let markStart = mark.convert(mark.bounds, to: long).minX
        expectTrue(markStart > 0 && titleEnd <= markStart,
                   "cell: a long title stops before the trailing mark (\(titleEnd) ≤ \(markStart))")
    } else {
        expectTrue(false, "cell: the long row has its mark")
    }
}

// MARK: 8. The type sizes match what AppKit gives its own cells

@MainActor
private func testMetricsMatchAppKit() {
    final class PlainSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 1 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "Row")
            cell.addSubview(label)
            cell.textField = label
            return cell
        }
    }
    let source = PlainSource()
    let table = NSTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("c")))
    table.style = .sourceList
    table.dataSource = source
    table.delegate = source
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    scroll.documentView = table
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    for (style, name) in [(NSTableView.RowSizeStyle.small, "small"), (.medium, "medium"), (.large, "large")] {
        // The cell's font follows the style one layout pass late, so turn
        // the run loop before reading it.
        table.rowSizeStyle = style
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let size = (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?
            .textField?.font?.pointSize
        expectEqual(size, ManagerSidebarCell.Metrics.forStyle(style).titleSize,
                    "metrics: \(name) title size matches NSTableCellView's own")
    }

    // And the real sidebar follows the system setting.
    let host = SidebarHost(items: sample)
    defer { host.close() }
    expectEqual(host.table.rowSizeStyle, .default, "metrics: the sidebar's row size follows the system")
    expectEqual(host.cell(row: 0)?.currentMetrics, ManagerSidebarCell.Metrics.forStyle(host.table.effectiveRowSizeStyle),
                "metrics: the cell uses the effective size style")
}

// MARK: 9. Selected vs unselected text, measured in Light and Dark

@MainActor
private func testSelectionColours() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    host.sidebar.selectedId = "alpha"
    host.focusTable()

    guard let selectedRow = host.table.rowView(atRow: 0, makeIfNecessary: true),
          let plainRow = host.table.rowView(atRow: 1, makeIfNecessary: true),
          let selectedCell = host.cell(row: 0), let plainCell = host.cell(row: 1) else {
        expectTrue(false, "colours: rows and cells exist")
        return
    }
    expectTrue(selectedRow.isEmphasized, "colours: the focused selection is emphasized")
    expectEqual(selectedCell.backgroundStyle, .emphasized, "colours: the selected cell's background is emphasized")
    expectEqual(plainCell.backgroundStyle, .normal, "colours: an unselected cell's background is normal")
    expectTrue(selectedCell.titleField.textColor == ManagerSidebarCell.textColors(for: .emphasized).title
               && selectedCell.subtitleField.textColor == ManagerSidebarCell.textColors(for: .emphasized).subtitle,
               "colours: the selected cell took the emphasized pair")

    for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
        host.window.appearance = appearance
        host.layout()
        guard let selected = RenderedRow(selectedRow, appearance: appearance),
              let plain = RenderedRow(plainRow, appearance: appearance) else {
            expectTrue(false, "colours \(name): rows render")
            continue
        }
        // Prove the capture sees the pill before measuring against it
        // (lessons, 2026-09-17: glass and bezels may not land offscreen).
        guard let pill = selected.dominantOpaque() else {
            expectTrue(false, "colours \(name): the selection pill is in the offscreen render")
            continue
        }
        expectTrue(plain.dominantOpaque() == nil, "colours \(name): an unselected row paints no fill")

        // The unselected row sits on the sidebar; its glass is not in the
        // render, so the window background stands in for the ground.
        var ground = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            ground = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
        }

        let pairs: [(String, ManagerSidebarCell, RenderedRow, NSView, NSColor, CGFloat)] = [
            ("selected title", selectedCell, selected, selectedRow, pill, 3),
            ("selected subtitle", selectedCell, selected, selectedRow, pill, 3),
            ("unselected title", plainCell, plain, plainRow, ground, 4.5),
            ("unselected subtitle", plainCell, plain, plainRow, ground, 3),
        ]
        for (label, cell, render, rowView, background, minimum) in pairs {
            let field = label.hasSuffix("subtitle") ? cell.subtitleField : cell.titleField
            let rect = topLeftRect(of: field, in: rowView)
            guard let ink = render.ink(in: rect, ground: background) else {
                expectTrue(false, "colours \(name): \(label) has ink")
                continue
            }
            let ratio = contrast(ink, background)
            expectTrue(ratio >= minimum,
                       "colours \(name): \(label) \(hex(ink)) on \(hex(background)) = \(String(format: "%.2f", ratio)):1 ≥ \(minimum)")
        }
    }
    host.window.appearance = nil
}

// MARK: 10. The split view's set-up

@MainActor
private func testSplitView() {
    let sidebar = ManagerSidebarVC(accessibilityLabel: "Things")
    let first = NSViewController()
    first.view = NSView()
    let split = ManagerSplitViewController(sidebar: sidebar, detail: first,
                                           autosaveName: "PharosManagerTestSplit", detailMinimum: 480)
    _ = split.view
    let items = split.splitViewItems
    expectEqual(items.count, 2, "split: sidebar and detail")
    guard items.count == 2 else { return }
    let side = items[0], detail = items[1]
    expectEqual(side.behavior, .sidebar, "split: the sidebar item is a SIDEBAR item (the glass)")
    expectEqual(side.minimumThickness, 220, "split: sidebar minimum 220")
    expectEqual(side.maximumThickness, 320, "split: sidebar maximum 320")
    expectTrue(!side.canCollapse, "split: the sidebar cannot collapse")
    expectEqual(side.holdingPriority, .defaultLow + 50, "split: sidebar holds at defaultLow + 50, clear of a label's 251 hug")
    expectEqual(detail.holdingPriority, .defaultLow, "split: the detail absorbs a resize")
    expectEqual(detail.minimumThickness, 480, "split: the detail minimum is the caller's")
    expectTrue(!detail.automaticallyAdjustsSafeAreaInsets, "split: the detail does not run under the glass")
    expectEqual(split.splitView.autosaveName, "PharosManagerTestSplit", "split: the divider autosaves by name")
    expectEqual(split.splitView.dividerStyle, .thin, "split: thin divider")

    let second = NSViewController()
    second.view = NSView()
    split.setDetail(second)
    expectTrue(split.detail === second, "split: setDetail swaps the detail")
    expectTrue(first.view.superview == nil && first.parent == nil, "split: the old detail is gone")
    expectTrue(second.view.superview === detail.viewController.view, "split: the new detail is in the pane")
    expectTrue(split.splitViewItems[1] === detail, "split: the split item itself is unchanged")
    UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames PharosManagerTestSplit")
}

// MARK: 11. The toolbar

@MainActor
private func testToolbar() {
    let sidebar = ManagerSidebarVC(accessibilityLabel: "Things")
    sidebar.setItems(sample)
    let detail = NSViewController()
    detail.view = NSView()
    let split = ManagerSplitViewController(sidebar: sidebar, detail: detail,
                                           autosaveName: "PharosManagerTestToolbarSplit", detailMinimum: 400)
    let toolbarController = ManagerToolbarController(identifier: "PharosManagerTestToolbar",
                                                     addLabel: "New Thing")
    var adds = 0
    toolbarController.onAdd = { adds += 1 }
    split.toolbarController = toolbarController

    let window = UtilityWindow(autosaveName: "PharosManagerTestWindow", title: "Things",
                               defaultSize: NSSize(width: 860, height: 560),
                               minimumSize: NSSize(width: 720, height: 440))
    window.contentViewController = split
    window.setContentSize(NSSize(width: 860, height: 560))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame PharosManagerTestWindow")
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames PharosManagerTestToolbarSplit")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    guard let toolbar = window.toolbar else {
        expectTrue(false, "toolbar: installed when the window appeared")
        return
    }
    expectEqual(toolbar.items.map(\.itemIdentifier), ManagerToolbarController.defaultItems,
                "toolbar: the items are the default set, in order")
    // Spelled out, not read back from `defaultItems`: the order IS the fix.
    // Over the sidebar: space, +. Then the separator. Over the detail:
    // space, filter — the filter is not over the sidebar, where a 220–260 pt
    // sidebar collapsed it to a magnifier button.
    expectEqual(toolbar.items.map(\.itemIdentifier),
                [.flexibleSpace, .pharosManagerAdd, .pharosManagerSidebarSeparator, .flexibleSpace,
                 .pharosManagerFilter],
                "toolbar: space, +, the tracking separator, space, then the filter at the trailing edge")
    expectTrue(!toolbar.allowsUserCustomization, "toolbar: not customisable")

    let separator = toolbar.items.first { $0.itemIdentifier == .pharosManagerSidebarSeparator }
        as? NSTrackingSeparatorToolbarItem
    expectTrue(separator?.splitView === split.splitView, "toolbar: the separator tracks THIS split view")
    expectEqual(separator?.dividerIndex, 0, "toolbar: at the sidebar's divider")

    let add = toolbar.items.first { $0.itemIdentifier == .pharosManagerAdd }
    expectEqual(add?.label, "New Thing", "toolbar: + is labelled with the caller's text")
    expectEqual(add?.toolTip, "New Thing", "toolbar: and that is its tooltip")
    expectEqual(add?.image?.accessibilityDescription, "New Thing", "toolbar: and its VoiceOver label")
    if let add, let action = add.action {
        NSApp.sendAction(action, to: add.target, from: add)
    }
    expectEqual(adds, 1, "toolbar: + calls onAdd")

    let filter = toolbar.items.first { $0.itemIdentifier == .pharosManagerFilter } as? NSSearchToolbarItem
    expectEqual(filter?.searchField.placeholderString, "Filter", "toolbar: the field says Filter")
    expectEqual(filter?.preferredWidthForSearchField, ManagerToolbarController.filterPreferredWidth,
                "toolbar: the field asks for its own width, not the sidebar's")
    expectTrue((180...240).contains(ManagerToolbarController.filterPreferredWidth),
               "toolbar: and that width is 180–240 pt")
    toolbarController.filterField.stringValue = "del"
    _ = toolbarController.filterField.sendAction(toolbarController.filterField.action,
                                                 to: toolbarController.filterField.target)
    expectEqual(sidebar.filterText, "del", "toolbar: typing in the field filters the sidebar")
    expectEqual(sidebar.shownItems.map(\.id), ["delta"], "toolbar: and the sidebar shows the match")

    split.installToolbarIfNeeded(on: window)
    expectTrue(window.toolbar === toolbar, "toolbar: installed once — a second install keeps the wired bar")

    // Where the field landed. Informational: the toolbar's layout in an
    // offscreen window is AppKit's, and the frames may be zero.
    let sidebarWidth = split.splitViewItems[0].viewController.view.frame.width
    if let field = filter?.searchField, let fieldWindow = field.window {
        let frame = field.convert(field.bounds, to: nil)
        print("INFO filter field frame in window: \(frame), sidebar width \(sidebarWidth), window \(fieldWindow.frame.size)")
    } else {
        print("INFO filter field is not in a window (toolbar not laid out offscreen)")
    }
    for width: CGFloat in [220, 260, 320] {
        split.splitView.setPosition(width, ofDividerAt: 0)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let shownWidth = split.splitViewItems[0].viewController.view.frame.width
        if let field = filter?.searchField, field.window != nil {
            let frame = field.convert(field.bounds, to: nil)
            print("INFO sidebar \(shownWidth): filter field frame \(frame)")
            // Only when AppKit laid the bar out (a zero frame says nothing).
            if frame.width > 0 {
                expectTrue(frame.minX >= shownWidth,
                           "toolbar: with a \(Int(width)) pt sidebar the filter is over the detail (x \(frame.minX))")
                expectTrue(frame.width > 100,
                           "toolbar: with a \(Int(width)) pt sidebar the filter is a field, not a magnifier (w \(frame.width))")
            }
        }
    }
}

// MARK: 12. The scroller shows only when there is something to scroll

@MainActor
private func testScrollerAutohides() {
    let host = SidebarHost(items: sample)
    defer { host.close() }
    guard let scroll = host.table.enclosingScrollView else {
        expectTrue(false, "scroller: the table is in a scroll view")
        return
    }
    // Legacy scrollers are what a mouse, or "Show scroll bars: Always",
    // gives: the style that drew an empty track beside four rows.
    scroll.scrollerStyle = .legacy
    func shown() -> Bool {
        scroll.tile()
        host.layout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return scroll.verticalScroller.map { !$0.isHidden } ?? false
    }
    expectTrue(!shown(), "scroller: four rows that fit show no scroller track")
    host.sidebar.setItems((0..<60).map { item("row\($0)", "Row \($0)", subtitle: "Subtitle \($0)") })
    expectTrue(shown(), "scroller: sixty rows that do not fit show it")
    host.sidebar.setItems(sample)
    expectTrue(!shown(), "scroller: and it goes again when they fit")
    scroll.scrollerStyle = NSScroller.preferredScrollerStyle
}

// MARK: 13. A row never resizes the sidebar or the window

@MainActor
private func testLongItemKeepsWidths() {
    let sidebar = ManagerSidebarVC(accessibilityLabel: "Things")
    sidebar.setItems(sample)
    // A detail like the forms: section headers made with `labelWithString:`
    // (which hug at 251) held at the detail's full width. Two of them once
    // pulled the sidebar to its maximum.
    let detail = NSViewController()
    let headers = ["Variable", "Value", "Connections"].map { NSTextField(labelWithString: $0) }
    let stack = NSStackView(views: headers)
    stack.orientation = .vertical
    stack.alignment = .leading
    detail.view = stack
    for header in headers { header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    let empty = NSViewController()
    empty.view = NSView()
    let split = ManagerSplitViewController(sidebar: sidebar, detail: empty,
                                           autosaveName: "PharosManagerTestWidthSplit", detailMinimum: 460)
    let window = UtilityWindow(autosaveName: "PharosManagerTestWidthWindow", title: "Things",
                               defaultSize: NSSize(width: 860, height: 560),
                               minimumSize: NSSize(width: 720, height: 440))
    window.contentViewController = split
    window.setContentSize(NSSize(width: 860, height: 560))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame PharosManagerTestWidthWindow")
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames PharosManagerTestWidthSplit")
    }
    func widths() -> (window: CGFloat, sidebar: CGFloat) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
        return (window.frame.width, split.splitViewItems[0].viewController.view.frame.width)
    }
    let before = widths()
    expectEqual(before.sidebar, ManagerSplitViewController.sidebarMinimum, "widths: the sidebar opens at its 220 pt")
    split.setDetail(detail)
    let formShown = widths()
    expectEqual(formShown.sidebar, before.sidebar, "widths: a form with section headers does not widen the sidebar")
    expectEqual(formShown.window, before.window, "widths: nor change the window's width")
    let long = String(repeating: "a_very_long_record_name_", count: 8)
    sidebar.setItems(sample + [item("long", long, subtitle: "Text · " + long, mono: true,
                                    trailing: [.warning(tooltip: long), .unsavedDot])])
    sidebar.selectedId = "long"
    let after = widths()
    expectEqual(after.sidebar, before.sidebar, "widths: a long row does not widen the sidebar")
    expectEqual(after.window, before.window, "widths: nor change the window's width")
}

// MARK: 14. Every close path asks once

@MainActor
private func testEveryCloseAsksOnce() {
    /// The Variable Manager's shape: a delegate that answers windowWillClose
    /// and not windowShouldClose.
    final class WillCloseDelegate: NSObject, NSWindowDelegate {
        var closes = 0
        func windowWillClose(_ notification: Notification) { closes += 1 }
    }
    for withDelegate in [false, true] {
        let tag = withDelegate ? " (with a windowWillClose delegate)" : ""
        let window = UtilityWindow(autosaveName: "PharosManagerTestCloseWindow", title: "Things",
                                   defaultSize: NSSize(width: 400, height: 300),
                                   minimumSize: NSSize(width: 200, height: 200))
        let delegate = WillCloseDelegate()
        if withDelegate { window.delegate = delegate }
        var asks = 0
        var answer = false
        window.shouldClose = { asks += 1; return answer }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame PharosManagerTestCloseWindow")
        }
        let closeButton = window.standardWindowButton(.closeButton)
        let paths: [(String, () -> Void)] = [
            ("the title-bar close button", { closeButton?.performClick(nil) }),
            ("⌘W (File ▸ Close Tab, performClose:)", {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: window, from: nil)
            }),
            ("Escape (cancelOperation:)", { window.cancelOperation(nil) }),
        ]
        expectTrue(closeButton != nil, "close\(tag): the window has a close button")
        for (name, close) in paths {
            answer = false
            asks = 0
            close()
            expectEqual(asks, 1, "close\(tag): \(name) answered No asks exactly once")
            expectTrue(window.isVisible, "close\(tag): \(name) answered No keeps the window")
            answer = true
            asks = 0
            close()
            expectEqual(asks, 1, "close\(tag): \(name) answered Yes asks exactly once")
            expectTrue(!window.isVisible, "close\(tag): \(name) answered Yes closes the window")
            window.orderFrontRegardless()
        }
        if withDelegate { expectEqual(delegate.closes, paths.count, "close\(tag): the delegate still hears windowWillClose") }
        asks = 0
        window.close()
        expectEqual(asks, 0, "close\(tag): close() itself does not ask (a prompt that answered closes with it)")
    }
}
