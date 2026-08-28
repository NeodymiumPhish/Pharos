// Standalone test runner for ResultTabContextMenu. Not part of the app target —
// compiled together with the implementation by
// scripts/test-result-tab-context-menu.sh.
//
// This is the menu BOTH result-tab surfaces show, so the item set, its order
// and its wiring are covered once here rather than twice by inspection. The
// horizontal bar had no test of any kind before this.
import AppKit

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func runTests() {
    // Symbol images and resolved colours need the app object; prohibited
    // activation keeps the binary headless.
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    // MARK: The item set and its order

    let builder = ResultTabContextMenu()
    let menu = builder.menu(forTabId: "r1")

    expectEqual("\(menu.items.count)", "4", "the menu carries four items")
    expectEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: ","),
                "View SQL Query,Rename…,—,Close",
                "in order: View SQL Query, Rename…, a separator, then Close")

    // The separator is what holds Close — the one destructive item — apart. Its
    // POSITION is the assertion: a separator at the end or the start separates
    // nothing.
    expectTrue(menu.items[2].isSeparatorItem && !menu.items[3].isSeparatorItem,
               "the separator sits immediately before Close")

    // An item with no target does nothing when chosen, and looks disabled.
    for item in menu.items where !item.isSeparatorItem {
        expectTrue(item.target != nil, "\(item.title) is wired to a target")
        expectTrue(item.action != nil, "\(item.title) carries an action")
        expectEqual(item.representedObject as? String ?? "<nil>", "r1",
                    "\(item.title) carries the tab id it was built for")
    }

    // MARK: Building fires nothing

    // The user may open the menu and press Escape. Nothing may happen until an
    // item is chosen — a rename dialog that appeared on right-click would be a
    // bug the user meets constantly.
    var detailed: [String] = []
    var renamed: [String] = []
    var closed: [String] = []
    let live = ResultTabContextMenu()
    live.onViewDetail = { detailed.append($0) }
    live.onRename = { renamed.append($0) }
    live.onClose = { closed.append($0) }

    let liveMenu = live.menu(forTabId: "r2")
    expectEqual("\(detailed.count + renamed.count + closed.count)", "0",
                "building the menu fires no callback")

    // MARK: Each item fires its own callback, with its own id

    // Chosen through `performAction`, the way AppKit dispatches a click, rather
    // than by calling the closure directly — that is the part that can be
    // miswired.
    for item in liveMenu.items where !item.isSeparatorItem {
        _ = item.target?.perform(item.action, with: item)
    }

    expectEqual(detailed.joined(separator: ","), "r2", "View SQL Query reports its tab once")
    expectEqual(renamed.joined(separator: ","), "r2", "Rename… reports its tab once")
    expectEqual(closed.joined(separator: ","), "r2", "Close reports its tab once")

    // MARK: Two menus for two tabs do not cross

    // One builder serves a whole surface, and a menu is rebuilt per right-click.
    // An item that read the id from the builder instead of from itself would
    // act on whichever tab was right-clicked LAST.
    var crossed: [String] = []
    let shared = ResultTabContextMenu()
    shared.onRename = { crossed.append($0) }
    let first = shared.menu(forTabId: "a")
    let second = shared.menu(forTabId: "b")
    for m in [first, second] {
        let rename = m.items[1]
        _ = rename.target?.perform(rename.action, with: rename)
    }
    expectEqual(crossed.joined(separator: ","), "a,b",
                "each menu renames the tab it was built for, not the most recent one")

    // MARK: Building into an existing menu

    // `NSMenuDelegate.menuNeedsUpdate` is handed the menu to populate, so this
    // overload has to work on a menu the builder did not create.
    let hosted = NSMenu()
    hosted.addItem(NSMenuItem(title: "Pre-existing", action: nil, keyEquivalent: ""))
    builder.build(forTabId: "r3", into: hosted)
    expectEqual("\(hosted.items.count)", "5", "the items are appended, not substituted")
    expectEqual(hosted.items[0].title, "Pre-existing", "and appended after what was there")
    expectEqual(hosted.items[2].representedObject as? String ?? "<nil>", "r3",
                "the appended items carry the new tab id")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    if failures > 0 { exit(1) }
}
