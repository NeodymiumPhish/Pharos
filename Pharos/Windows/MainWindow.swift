import AppKit

/// A main window: one query tab, shown as a native window tab.
///
/// Its one job beyond `NSWindow` is the tab bar's right-click menu. AppKit
/// builds that menu (Close Tab, Close Other Tabs, Move Tab to New Window, Show
/// All Tabs) and gives no way to add to it, so a right-click or Control-click
/// on a tab is caught here: AppKit's own menu is asked for through the public
/// `menu(for:)`, "Rename Tab…" goes on top (`TabBarMenu`), and the menu is shown
/// as AppKit would have shown it. Any other click goes on to `super`.
final class MainWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if let (menu, view) = TabBarMenu.menu(for: event, in: self) {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        super.sendEvent(event)
    }

    /// The tab bar menu's "Rename Tab…": the item represents the tab that was
    /// right-clicked, which need not be the one in front.
    @objc func renameTabFromTabBar(_ sender: NSMenuItem) {
        TabBarMenu.rename(sender)
    }
}

/// "Rename Tab…" in the native tab bar's right-click menu.
///
/// Measured on macOS 27 (2026-10-22): each tab is a view in the title bar,
/// outside the window's content view, and its `menu(for:)` returns AppKit's
/// menu, in which every item targets the right-clicked tab's own window — a
/// background tab's too. That is how the tab is found, without naming any
/// private class. If a later macOS builds the menu differently, nothing here
/// matches, the menu shows without the item, and File ▸ Rename Tab… remains.
/// A menu VoiceOver opens on a tab does not come through `sendEvent`, so it
/// has no Rename Tab… either. `scripts/test-tab-bar-menu.sh` covers this.
@MainActor
enum TabBarMenu {
    static let renameAction = #selector(MainWindow.renameTabFromTabBar(_:))
    /// `ContentViewController.menuRenameTab(_:)`, forwarded by the split view
    /// controller. By name, so the harness needs neither.
    static let renameTabAction = NSSelectorFromString("menuRenameTab:")

    /// AppKit's menu for the tab under a context click, with "Rename Tab…" and
    /// a separator on top, and the view the menu belongs to. Nil for any other
    /// click: not a context click, inside the content view, or on a title-bar
    /// view whose menu is not a tab's.
    static func menu(for event: NSEvent, in window: NSWindow) -> (NSMenu, NSView)? {
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick, let contentView = window.contentView,
              let frameView = contentView.superview,
              // The frame view has no superview, so window coordinates are its
              // superview's, which is what `hitTest(_:)` takes.
              let hit = frameView.hitTest(event.locationInWindow),
              !hit.isDescendant(of: contentView),
              let menu = hit.menu(for: event),
              let tabWindow = tabWindow(of: menu, in: window) else { return nil }

        if let existing = menu.items.first(where: { $0.action == renameAction }) {
            // AppKit may hand the same menu back on the next click.
            existing.target = window
            existing.representedObject = tabWindow
        } else {
            let item = NSMenuItem(title: String(localized: "Rename Tab…"), action: renameAction, keyEquivalent: "")
            item.target = window
            item.representedObject = tabWindow
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return (menu, hit)
    }

    /// The window of the tab a menu is for: the target of its Close Tab item,
    /// when that is a window of this tab group.
    static func tabWindow(of menu: NSMenu, in window: NSWindow) -> NSWindow? {
        let close = #selector(NSWindow.performClose(_:))
        guard let target = menu.items.first(where: { $0.action == close })?.target as? NSWindow else { return nil }
        let group = window.tabGroup?.windows ?? [window]
        return group.contains(target) ? target : nil
    }

    /// Bring the item's tab to the front, then ask its content controller for
    /// the rename sheet, which goes on that tab's window.
    static func rename(_ item: NSMenuItem) {
        guard let tabWindow = item.representedObject as? NSWindow else { return }
        tabWindow.tabGroup?.selectedWindow = tabWindow
        tabWindow.makeKeyAndOrderFront(nil)
        NSApp.sendAction(renameTabAction, to: tabWindow.contentViewController, from: item)
    }
}
