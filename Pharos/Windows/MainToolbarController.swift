import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let pharosFilterSidebar = NSToolbarItem.Identifier("PharosFilterSidebar")
    static let pharosFormatSQL = NSToolbarItem.Identifier("PharosFormatSQL")
    static let pharosNewTab = NSToolbarItem.Identifier("PharosNewTab")
    static let pharosSaveQuery = NSToolbarItem.Identifier("PharosSaveQuery")
    /// The grouped navigator selector. Defined by the factory that builds it.
    static let pharosNavigator = NavigatorToolbarGroup.identifier
}

/// Delegate and state driver for the main window's `NSToolbar`.
///
/// Default set, left to right: navigator group | tracking separator | flexible
/// space | tracking separator | flexible space | inspector toggle. The
/// inspector toggle holds the window's right edge whether the inspector is
/// open or closed. The navigator group stands where the sidebar toggle used
/// to: it both picks the sidebar's list and, when the lit segment is pressed
/// again, collapses the pane — the way Calendar's Calendars/Invites control
/// behaves.
///
/// Only window-wide items live here. Every query tab is its own window (a
/// native window tab), and what belongs to one tab — its connection, schema
/// and transaction — is in the tab's context row in the editor pane (HIG,
/// Tab views: controls in a pane affect only that pane). There is no Run or
/// Cancel item: each card has its own. The window title is the tab's name,
/// with "connection · schema" under it. Every item here has a menu command or
/// an editor-side equivalent; the toolbar adds nothing that cannot be reached
/// another way.
///
/// The user can customize the toolbar (View > Customize Toolbar…). The
/// allowed-but-not-default items are the sidebar filter field, Format SQL,
/// New Tab and Save Query.
@MainActor
final class MainToolbarController: NSObject {

    /// The split view controller is the single source for the two panes and
    /// for the sidebar's collapse state; holding one weak reference instead of
    /// three keeps them from disagreeing.
    private weak var splitVC: PharosSplitViewController?
    private var contentVC: ContentViewController? { splitVC?.contentVC }
    private var sidebarVC: SidebarViewController? { splitVC?.sidebarVC }
    private let session: WindowSession

    /// One toolbar per window; the items are created on demand and kept
    /// weakly so state updates reach the live ones.
    private weak var toolbar: NSToolbar?
    private weak var navigatorItem: NSToolbarItemGroup?

    init(session: WindowSession, splitVC: PharosSplitViewController) {
        self.session = session
        self.splitVC = splitVC
        super.init()
        // ⌥⌘1/2/3 go straight to the sidebar; this is how the group hears about
        // them. Weak, or the sidebar (owned by the window) would keep this
        // controller alive past `windowWillClose`.
        splitVC.sidebarVC.onNavigatorChanged = { [weak self] navigator in
            self?.navigatorItem?.selectedIndex = navigator.rawValue
        }
    }

    /// Installs a customizable toolbar on `window` with this object as delegate.
    func install(on window: NSWindow) {
        // "PharosToolbar4", not "PharosToolbar3". `autosavesConfiguration` is
        // on, and AppKit reconciles a saved configuration by DROPPING unknown
        // identifiers, never by adding new default ones — so a window that had
        // saved the old set would lose Run and Cancel altogether when their two
        // items became the one Run | Cancel control (as, one bump earlier, it
        // would never have shown the schema pull-down). The new name costs one
        // reset of the user's own toolbar customisation, display mode and size
        // mode. The same rule made removing items free: a saved
        // "PharosRunControl", "PharosConnection" or "PharosSchema" is an
        // unknown identifier now, and is dropped.
        let toolbar = NSToolbar(identifier: "PharosToolbar4")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        self.toolbar = toolbar
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSSearchField) {
        sidebarVC?.setFilterText(sender.stringValue)
    }

    // MARK: - Navigator group

    /// The sidebar's navigator group was pressed.
    ///
    /// Pressing the segment that is already lit collapses the sidebar, and
    /// pressing it again brings it back — Calendar's behaviour. Any other
    /// segment shows the sidebar on that list.
    @objc private func navigatorChanged(_ sender: NSToolbarItemGroup) {
        guard let splitVC,
              let sidebarVC,
              let navigator = NavigatorToolbarGroup.navigator(forSelectedIndex: sender.selectedIndex)
        else { return }

        if navigator == sidebarVC.currentNavigator && !splitVC.isSidebarCollapsed {
            splitVC.setSidebarCollapsed(true)
        } else {
            splitVC.setSidebarCollapsed(false)
            sidebarVC.showNavigator(navigator)
        }
    }

    /// Lights the segment for the navigator on screen.
    ///
    /// The lit segment deliberately stays lit while the sidebar is hidden: it
    /// then reads as "the list the sidebar will come back on", which is
    /// already how the View ▸ Navigators menu items behave (they keep their
    /// checkmark when the pane is collapsed). It is also the only option —
    /// measured live, `NSToolbarItemGroup` in `.selectOne` mode ignores
    /// `selectedIndex = -1` and keeps the previous segment lit, with or
    /// without the macOS 27 `.tabs` role.
    private func syncNavigatorSelection(group: NSToolbarItemGroup? = nil) {
        guard let group = group ?? navigatorItem, let sidebarVC else { return }
        group.selectedIndex = sidebarVC.currentNavigator.rawValue
    }
}

// MARK: - NSToolbarDelegate

extension MainToolbarController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space,
             .inspectorTrackingSeparator, .toggleInspector:
            return NSToolbarItem(itemIdentifier: itemIdentifier)

        case .pharosNavigator:
            let group = NavigatorToolbarGroup.make(target: self,
                                                   action: #selector(navigatorChanged(_:)))
            if flag {
                navigatorItem = group
                // Seeded HERE, not from the sidebar's change callback. The
                // sidebar restores its last navigator in `loadView`, which runs
                // when the window's content view controller is set — before this
                // controller exists — so the callback would fire into nothing and
                // the group would always launch lit on Query Library.
                syncNavigatorSelection(group: group)
            }
            return group

        case .pharosFilterSidebar:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Filter")
            item.paletteLabel = String(localized: "Filter Sidebar")
            item.toolTip = String(localized: "Filter the sidebar list")
            item.searchField.placeholderString = String(localized: "Filter")
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(filterChanged(_:))
            item.preferredWidthForSearchField = 180
            return item

        case .pharosFormatSQL:
            return imageItem(itemIdentifier, label: String(localized: "Format"), palette: String(localized: "Format SQL"),
                             symbol: "text.alignleft", tip: String(localized: "Format SQL (⌃I)"),
                             action: #selector(ContentViewController.menuFormatSQL(_:)))

        case .pharosNewTab:
            return imageItem(itemIdentifier, label: String(localized: "New Tab"), palette: String(localized: "New Tab"),
                             symbol: "plus", tip: String(localized: "New Tab (⌘T)"),
                             action: #selector(NSResponder.newWindowForTab(_:)))

        case .pharosSaveQuery:
            return imageItem(itemIdentifier, label: String(localized: "Save"), palette: String(localized: "Save Query"),
                             symbol: "square.and.arrow.down", tip: String(localized: "Save Query… (⌘S)"),
                             action: #selector(ContentViewController.menuSaveQuery(_:)))

        default:
            return nil
        }
    }

    /// An image item whose action goes up the responder chain, so it is
    /// validated and dispatched exactly like the menu item with the same
    /// selector.
    private func imageItem(_ identifier: NSToolbarItem.Identifier, label: String, palette: String,
                           symbol: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = palette
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: palette)
        item.isBordered = true
        item.target = nil
        item.action = action
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .pharosNavigator,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .inspectorTrackingSeparator,
            // The separator is pinned to the inspector's divider, so a second
            // flexible space after it pushes the toggle to the window's right
            // edge — where Xcode keeps it. Without it the toggle sits against
            // the divider and walks left and right as the inspector opens
            // and closes.
            .flexibleSpace,
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .pharosNavigator,
            // Still offered in Customize Toolbar… for anyone who wants a plain
            // toggle back. ⌃⌘S works either way; it goes to the split view
            // controller, never to a toolbar item.
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .pharosFilterSidebar,
            .pharosFormatSQL,
            .pharosNewTab,
            .pharosSaveQuery,
            .space,
            .flexibleSpace,
            .inspectorTrackingSeparator,
            .toggleInspector,
        ]
    }
}
