// Standalone test for TabBarMenu — "Rename Tab…" in the native tab bar's
// right-click menu. Compiled by scripts/test-tab-bar-menu.sh.
//
// Three MainWindows in one tab group, off-screen. The tabs are found the way
// the code finds them — by asking each title-bar view for its menu — and the
// clicks are NSEvents built here, so nothing reaches the screen.
import AppKit

private var failures = 0
private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

/// Stands in for the split view controller: records the rename it is asked for.
private final class FakeController: NSViewController {
    var renames = 0
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400)) }
    @objc func menuRenameTab(_ sender: Any?) { renames += 1 }
}

@MainActor
private func makeWindow(_ title: String) -> (MainWindow, FakeController) {
    let w = MainWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 400),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
    w.title = title
    w.tabbingMode = .preferred
    w.tabbingIdentifier = "TabBarMenuTests"
    w.isReleasedWhenClosed = false
    let c = FakeController()
    w.contentViewController = c
    w.setFrame(NSRect(x: -20000, y: -20000, width: 700, height: 400), display: false)
    return (w, c)
}

@MainActor
private func click(_ type: NSEvent.EventType, at p: NSPoint, in w: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// The centre of each title-bar view whose own menu is a tab's, keyed by the
/// window that menu is for. Found through the public `menu(for:)`, not by class.
@MainActor
private func tabPoints(in w: NSWindow) -> [(NSWindow, NSPoint)] {
    let frame = w.contentView!.superview!
    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    let probe = click(.rightMouseDown, at: .zero, in: w)
    var found: [(NSWindow, NSPoint)] = []
    for v in all(frame) where !v.isDescendant(of: w.contentView!) {
        let r = v.convert(v.bounds, to: nil)
        guard r.width > 40, let m = v.menu(for: probe), let tab = TabBarMenu.tabWindow(of: m, in: w) else { continue }
        let p = NSPoint(x: r.midX, y: r.midY)
        // Keep only the view a click there actually hits (the tab itself).
        if frame.hitTest(p) === v, !found.contains(where: { $0.0 === tab }) { found.append((tab, p)) }
    }
    return found
}

@MainActor
private func testTabBarMenu() {
    let (a, _) = makeWindow("Tab A"), (b, bc) = makeWindow("Tab B"), (c, _) = makeWindow("Tab C")
    a.orderFrontRegardless()
    a.addTabbedWindow(b, ordered: .above)
    a.addTabbedWindow(c, ordered: .above)
    c.orderFrontRegardless()
    c.tabGroup?.selectedWindow = c
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    let tabs = tabPoints(in: c)
    expect(tabs.count == 3, "each of the three tabs is found by its own menu", "\(tabs.map { $0.0.title })")
    guard let (bWindow, bPoint) = tabs.first(where: { $0.0 === b }) else { return }

    // A right-click on a BACKGROUND tab, delivered to the front window.
    let right = click(.rightMouseDown, at: bPoint, in: c)
    guard let (menu, view) = TabBarMenu.menu(for: right, in: c) else {
        expect(false, "a right-click on a tab gives a menu"); return
    }
    let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    expect(titles.first == "Rename Tab…", "Rename Tab… is the first item", "\(titles)")
    expect(menu.items.count > 1 && menu.items[1].isSeparatorItem, "a separator follows it", "\(titles)")
    expect(titles.contains("Close Tab") && titles.contains("Move Tab to New Window"),
           "AppKit's own items are still there", "\(titles)")
    let rename = menu.items[0]
    expect(rename.representedObject as? NSWindow === bWindow, "the item is for the tab that was right-clicked, not the front one")
    expect(rename.target === c && rename.action == TabBarMenu.renameAction, "it targets the window's action")
    expect(c.validateMenuItem(rename), "the item is enabled")
    expect(frameHit(c, bPoint) === view, "the menu is shown for the clicked tab view")

    // AppKit may hand back the same menu: never two Rename items.
    let again = TabBarMenu.menu(for: right, in: c)?.0
    expect((again?.items.filter { $0.action == TabBarMenu.renameAction }.count ?? 0) == 1, "a second right-click adds no second item")

    // Control-click is a context click too.
    let control = click(.leftMouseDown, at: bPoint, in: c, flags: .control)
    expect(TabBarMenu.menu(for: control, in: c)?.0.items.first?.title == "Rename Tab…", "Control-click gives the same menu")

    // Not a tab: a plain left click, and a right-click in the content view.
    expect(TabBarMenu.menu(for: click(.leftMouseDown, at: bPoint, in: c), in: c) == nil, "a plain click on a tab is left to AppKit")
    let inside = NSPoint(x: 350, y: 100)
    expect(TabBarMenu.menu(for: click(.rightMouseDown, at: inside, in: c), in: c) == nil,
           "a right-click in the content view is left to the view")

    // Through sendEvent: a right-click on a tab opens a context menu (closed
    // again as soon as it starts tracking); a right-click in the content view
    // does not come from here.
    var tracked = 0
    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                          queue: nil) { note in
        tracked += 1
        let menu = note.object as? NSMenu
        RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) { menu?.cancelTracking() }
    }
    c.sendEvent(right)
    expect(tracked == 1, "a right-click on a tab still opens a context menu through sendEvent (which menu: not readable, AppKit wraps it)", "tracked \(tracked)")
    c.sendEvent(click(.rightMouseDown, at: inside, in: c))
    expect(tracked == 1, "and none of its own for a right-click in the content view", "tracked \(tracked)")
    NotificationCenter.default.removeObserver(observer)

    // Choosing it brings that tab forward and asks its controller to rename.
    c.renameTabFromTabBar(rename)
    expect(c.tabGroup?.selectedWindow === b, "Rename Tab… selects the right-clicked tab")
    expect(bc.renames == 1, "and sends menuRenameTab: to that tab's controller")
    for w in [a, b, c] { w.close() }
}

@MainActor
private func frameHit(_ w: NSWindow, _ p: NSPoint) -> NSView? { w.contentView?.superview?.hitTest(p) }

func runTests() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { testTabBarMenu() }
    if failures == 0 { print("\nAll tab bar menu tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
