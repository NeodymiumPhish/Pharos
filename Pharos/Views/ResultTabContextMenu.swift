import AppKit

/// The right-click menu for one result tab, shared by both surfaces that show
/// result tabs: `ResultTabBar` (horizontal) and `ResultTabsPanelVC` (vertical).
///
/// It exists because those two built the menu separately and had already
/// drifted — the bar put a separator before Close and the panel did not — so
/// every item added by hand to both was a chance for them to disagree about
/// what a result tab can do. One builder, one order, one set of titles.
///
/// What deliberately stays with the callers is what happens BEFORE the menu
/// opens: the bar selects the tab it was invoked on, the panel does not (see
/// the note at `ResultTabsPanelVC.buildRowMenu` — selecting from an unfocused
/// pane's panel would switch the active editor tab and swap the grid). That is
/// a property of the surface, not of the menu.
///
/// Carries no model type, which is what lets
/// `scripts/test-result-tab-context-menu.sh` compile it on its own — and gives
/// the horizontal bar's menu its first coverage.
final class ResultTabContextMenu: NSObject {

    var onViewDetail: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    /// Fill `menu` with the items for the tab `id`.
    ///
    /// Takes an existing menu rather than only returning one, because
    /// `NSMenuDelegate.menuNeedsUpdate` is handed the menu it must populate.
    /// Every item carries its own tab id in `representedObject`, so nothing
    /// here depends on which row is selected when the item is finally chosen —
    /// the menu can outlive a selection change and still act on the right tab.
    func build(forTabId id: String, into menu: NSMenu) {
        add(title: "View SQL Query", action: #selector(viewDetailChosen(_:)), id: id, to: menu)
        add(title: "Rename…", action: #selector(renameChosen(_:)), id: id, to: menu)
        // Holds the one item that destroys something apart from the two that
        // do not.
        menu.addItem(.separator())
        add(title: "Close", action: #selector(closeChosen(_:)), id: id, to: menu)
    }

    /// A fresh menu for the tab `id`, for a caller that pops one up itself.
    func menu(forTabId id: String) -> NSMenu {
        let menu = NSMenu()
        build(forTabId: id, into: menu)
        return menu
    }

    private func add(title: String, action: Selector, id: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        menu.addItem(item)
    }

    @objc private func viewDetailChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onViewDetail?(id)
    }

    @objc private func renameChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRename?(id)
    }

    @objc private func closeChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onClose?(id)
    }
}
