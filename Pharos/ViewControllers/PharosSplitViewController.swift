import AppKit

// The sidebar and the inspector are system split view items
// (`sidebarWithViewController:` / `inspectorWithViewController:`), so on
// macOS 26 they get the Liquid Glass material, the standard
// `toggleSidebar:` / `toggleInspector:` actions, the tracking-separator
// toolbar items and the system collapse animation for free. The content item
// opts into `automaticallyAdjustsSafeAreaInsets`, so its safe area grows where
// a glass pane overlays it; `ContentViewController` extends its background
// under that overlay with an `NSBackgroundExtensionView`.
//
// Holding priorities make the sidebar and inspector resize like classic
// panels (content absorbs window resize). They must stay LOW and only
// relative, or interactive divider drags snap back (tasks/lessons.md).
class PharosSplitViewController: NSSplitViewController, NSMenuItemValidation {

    let sidebarVC = SidebarViewController()
    let contentVC = ContentViewController()
    let inspectorVC = InspectorViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        // Just one step above the content's holding priority — enough to make
        // content (not the sidebar) absorb window resizing, but low enough that
        // NSSplitView still honors interactive divider drags. A high priority
        // here (e.g. .defaultHigh) overpowers the drag and the divider snaps
        // back, leaving the pane stuck at its minimum width.
        sidebarItem.holdingPriority = .defaultLow + 1
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        // Content item — absorbs window resize.
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 400
        contentItem.holdingPriority = .defaultLow
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 400
        inspectorItem.canCollapse = true
        // The inspector needs a higher holding priority than the sidebar. When the
        // inspector shows row detail, its content (a scrollable stack of labels)
        // hugs horizontally at ~.defaultLow, which would otherwise out-rank a
        // sidebar-level holding priority and snap the pane back to its minimum on
        // every divider release. `.defaultLow + 50` clears that content hugging
        // while staying well below the threshold (~.defaultHigh) at which the
        // holding constraint becomes strong enough to block interactive dragging.
        inspectorItem.holdingPriority = .defaultLow + 50
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        // Initial state for a fresh install; the autosave below overrides it
        // with the user's last layout.
        sidebarItem.isCollapsed = false
        inspectorItem.isCollapsed = true

        // Changed from "PharosSidebarSplit" to avoid 2-pane saved positions
        // corrupting the 3-pane layout
        splitView.autosaveName = "PharosMainSplit"
    }

    // MARK: - Query and tab menu forwarding

    // The Query and File menu items target `ContentViewController` selectors
    // with a nil target. The content controller is a SIBLING of the sidebar
    // and the inspector in the responder chain, so with the focus in either
    // of those the chain never reaches it and ⌘↩, ⌘., ⌘T, ⌘W go dead. This
    // controller is an ancestor of all three panes; it forwards those items
    // and their validation to the content controller. When the focus is
    // inside the content pane the chain finds the content controller first,
    // so nothing here runs twice.

    @objc func menuRunQuery(_ sender: Any?) { contentVC.menuRunQuery(sender) }
    @objc func menuCancelQuery(_ sender: Any?) { contentVC.menuCancelQuery(sender) }
    @objc func menuFormatSQL(_ sender: Any?) { contentVC.menuFormatSQL(sender) }
    @objc func menuNewTab(_ sender: Any?) { contentVC.menuNewTab(sender) }
    @objc func menuCloseTab(_ sender: Any?) { contentVC.menuCloseTab(sender) }
    @objc func menuReopenTab(_ sender: Any?) { contentVC.menuReopenTab(sender) }
    @objc func menuSelectTab(_ sender: NSMenuItem) { contentVC.menuSelectTab(sender) }
    @objc func menuSaveQuery(_ sender: Any?) { contentVC.menuSaveQuery(sender) }
    @objc func menuSaveQueryAs(_ sender: Any?) { contentVC.menuSaveQueryAs(sender) }
    @objc func menuExportEditorAsSQL(_ sender: Any?) { contentVC.menuExportEditorAsSQL(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // The two standard split view actions are ours to validate: this
        // override shadows NSSplitViewController's own validation, which is
        // what rewrites the titles between Show and Hide.
        if menuItem.action == #selector(NSSplitViewController.toggleSidebar(_:)) {
            menuItem.title = (splitViewItems.first?.isCollapsed ?? false) ? "Show Sidebar" : "Hide Sidebar"
            return true
        }
        if menuItem.action == #selector(NSSplitViewController.toggleInspector(_:)) {
            menuItem.title = (splitViewItems.last?.isCollapsed ?? true) ? "Show Inspector" : "Hide Inspector"
            return true
        }
        return contentVC.validateMenuItem(menuItem)
    }

    /// Reveals the inspector if it's currently collapsed. Unlike
    /// `toggleInspector:`, this never collapses an already-visible inspector —
    /// used when content is about to be pushed into it programmatically
    /// (e.g. showing a preview row's SQL).
    func showInspector() {
        if let item = splitViewItems.last, item.isCollapsed {
            item.animator().isCollapsed = false
        }
    }
}
