// Standalone test runner for ShortcutCatalog — the read-only Shortcuts pane's
// source of truth. Menus are built by hand here, so the assertions are about
// the walk and the rendering, not about whatever MainMenu happens to contain
// today. Compiled by scripts/test-shortcut-catalog.sh.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func menuBar() -> NSMenu {
    let bar = NSMenu()

    let fileItem = NSMenuItem()
    let file = NSMenu(title: "File")
    let newTab = file.addItem(withTitle: "New Tab", action: nil, keyEquivalent: "t")
    newTab.keyEquivalentModifierMask = [.command]
    file.addItem(.separator())
    // No shortcut: must not appear at all.
    file.addItem(withTitle: "Connect", action: nil, keyEquivalent: "")
    let reopen = file.addItem(withTitle: "Reopen Closed Tab", action: nil, keyEquivalent: "T")
    reopen.keyEquivalentModifierMask = [.command, .shift]
    let exportItem = file.addItem(withTitle: "Export…", action: nil, keyEquivalent: "s")
    exportItem.keyEquivalentModifierMask = [.command, .option]
    // A submenu: its entries belong to the top-level menu's group.
    let recentItem = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
    let recent = NSMenu(title: "Open Recent")
    let clear = recent.addItem(withTitle: "Clear Menu", action: nil, keyEquivalent: "k")
    clear.keyEquivalentModifierMask = [.command, .control]
    recentItem.submenu = recent
    fileItem.submenu = file
    bar.addItem(fileItem)

    // A top-level item with no submenu must be skipped, not crash.
    bar.addItem(NSMenuItem(title: "Orphan", action: nil, keyEquivalent: "x"))
    return bar
}

private func testWalk() {
    let entries = ShortcutCatalog.entries(fromMenuBar: menuBar())
    expectEqual(entries.count, 4, "only items WITH a shortcut are listed")
    expectEqual(entries.map(\.command), ["New Tab", "Reopen Closed Tab", "Export…", "Clear Menu"],
                "menu order is kept, and a submenu is followed in place")
    // The defect this caught: a menu bar built in code leaves the TOP-LEVEL
    // item's title empty and names the submenu, which is how MainMenu builds
    // every menu. Reading `top.title` gave every entry an empty group.
    expectTrue(entries.allSatisfy { $0.group == "File" }, "the group is the submenu's title, not the empty top item's")
    expectTrue(!entries.contains { $0.command == "Connect" }, "an item with no key equivalent is left out")
    expectTrue(!entries.contains { $0.command == "Orphan" }, "a top-level item with no submenu is skipped")
}

private func testRendering() {
    let entries = ShortcutCatalog.entries(fromMenuBar: menuBar())
    let byCommand = Dictionary(uniqueKeysWithValues: entries.map { ($0.command, $0.shortcut) })
    expectEqual(byCommand["New Tab"], "⌘T", "a plain command shortcut")
    // The one that is easy to get wrong: an upper-case key equivalent IS
    // Shift, even though the modifier mask does not always say so.
    expectEqual(byCommand["Reopen Closed Tab"], "⇧⌘T", "an upper-case key renders the Shift glyph")
    expectEqual(byCommand["Export…"], "⌥⌘S", "modifiers are in the Apple order")
    expectEqual(byCommand["Clear Menu"], "⌃⌘K", "Control comes first")

    // An upper-case letter with NO shift flag still shows Shift.
    expectEqual(ShortcutCatalog.display(key: "T", modifiers: [.command]), "⇧⌘T",
                "an upper-case letter alone implies Shift")
    expectEqual(ShortcutCatalog.display(key: "t", modifiers: [.command, .shift]), "⇧⌘T",
                "an explicit shift flag gives the same answer")
    expectEqual(ShortcutCatalog.display(key: "[", modifiers: [.command]), "⌘[", "a punctuation key is not upper-cased away")
    expectEqual(ShortcutCatalog.display(key: "\r", modifiers: [.command]), "⌘↩", "Return has a glyph")
    expectEqual(ShortcutCatalog.display(key: "\u{1b}", modifiers: []), "Esc", "Escape has a name and no modifier")
    expectEqual(ShortcutCatalog.display(key: "\t", modifiers: [.shift]), "⇧⇥", "Tab has a glyph")
    expectEqual(ShortcutCatalog.keyName(String(UnicodeScalar(NSUpArrowFunctionKey)!)), "↑", "the up arrow has a glyph")
    expectEqual(ShortcutCatalog.keyName(" "), "Space", "the space bar is named, not blank")
}

private func testFilter() {
    let entries = ShortcutCatalog.entries(fromMenuBar: menuBar()) + ShortcutCatalog.viewShortcuts
    expectEqual(ShortcutCatalog.filter(entries, query: "").count, entries.count, "an empty query selects everything")
    expectEqual(ShortcutCatalog.filter(entries, query: "   ").count, entries.count, "a blank query selects everything")
    expectEqual(ShortcutCatalog.filter(entries, query: "new tab").map(\.command), ["New Tab"], "a two-word query matches")
    expectEqual(ShortcutCatalog.filter(entries, query: "tab new").map(\.command), ["New Tab"], "word order does not matter")
    expectEqual(ShortcutCatalog.filter(entries, query: "NEW").map(\.command), ["New Tab"], "matching ignores case")
    expectTrue(ShortcutCatalog.filter(entries, query: "grid").allSatisfy { $0.group.contains("grid") },
               "a group name is searchable")
    expectTrue(!ShortcutCatalog.filter(entries, query: "⌘T").isEmpty, "the rendered shortcut is searchable")
    expectEqual(ShortcutCatalog.filter(entries, query: "nothing here at all").count, 0, "a query that matches nothing returns nothing")
}

private func testGroupName() {
    let named = NSMenu(title: "View")
    expectEqual(ShortcutCatalog.groupName(top: NSMenuItem(), submenu: named), "View",
                "a named submenu names the group")
    let titledItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    expectEqual(ShortcutCatalog.groupName(top: titledItem, submenu: NSMenu()), "Window",
                "an untitled submenu falls back to the item's title")
    // The application menu has neither title; macOS shows the app's name.
    expectTrue(!ShortcutCatalog.groupName(top: NSMenuItem(), submenu: NSMenu()).isEmpty,
               "with neither title the group is still named")
}

private func testViewShortcuts() {
    let view = ShortcutCatalog.viewShortcuts
    expectTrue(!view.isEmpty, "the hand-maintained view keys are listed")
    expectTrue(view.allSatisfy { !$0.command.isEmpty && !$0.group.isEmpty && !$0.shortcut.isEmpty },
               "every view entry is complete")
    expectTrue(ShortcutCatalog.all(menuBar: nil).count == view.count, "with no menu bar, only the view keys are listed")
    expectTrue(ShortcutCatalog.all(menuBar: menuBar()).count == view.count + 4, "the menu walk and the view keys are both included")
}

func runTests() {
    _ = NSApplication.shared
    testWalk()
    testRendering()
    testFilter()
    testGroupName()
    testViewShortcuts()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
