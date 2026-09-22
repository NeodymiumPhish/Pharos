import AppKit

// The sidebar and the inspector are system split view items
// (`sidebarWithViewController:` / `inspectorWithViewController:`), so on
// macOS 26 they get the Liquid Glass material, the standard
// `toggleSidebar:` / `toggleInspector:` actions, the tracking-separator
// toolbar items and the system collapse animation for free. The content item
// keeps `automaticallyAdjustsSafeAreaInsets` OFF, so its background stops at
// the divider and the translucent sidebar keeps a visible boundary.
//
// Holding priorities make the sidebar and inspector resize like classic
// panels (content absorbs window resize). They must stay LOW and only
// relative, or interactive divider drags snap back (tasks/lessons.md).
class PharosSplitViewController: NSSplitViewController, NSMenuItemValidation {

    let session: WindowSession
    let sidebarVC: SidebarViewController
    let contentVC: ContentViewController
    let inspectorVC = InspectorViewController()

    /// The window's session is handed down here, not looked up from
    /// `view.window`: a pane that is off screen, or one whose window is not
    /// key, must still read and write the right window's tabs.
    init(session: WindowSession) {
        self.session = session
        self.sidebarVC = SidebarViewController(session: session)
        self.contentVC = ContentViewController(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        // 280, not 200: the navigator group lives in the toolbar's sidebar
        // region, which runs from the traffic lights to the tracking
        // separator. Measured live, three expanded segments needed ~130pt
        // there and the traffic lights take the first ~92pt, so 240 held
        // three. With the fourth (Variables) segment, 240 sends the whole
        // group — and the sidebar toggle — to the overflow menu (measured
        // 2026-09-16); 280 holds all four.
        sidebarItem.minimumThickness = 280
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
        // Deliberately OFF. With it on, the content pane grows into the
        // safe-area inset the glass sidebar creates and paints its own plate
        // UNDER the sidebar, so the two panes read as one sheet. Xcode's
        // navigator keeps a visible boundary; so does this. (The pane root was
        // an `NSBackgroundExtensionView` until 2026-09-22 — see
        // `ContentViewController.loadView` for why it is a plain view now.)
        contentItem.automaticallyAdjustsSafeAreaInsets = false

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
    @objc func menuRunAllQueries(_ sender: Any?) { contentVC.menuRunAllQueries(sender) }
    @objc func menuExplainQuery(_ sender: Any?) { contentVC.menuExplainQuery(sender) }
    @objc func menuExplainAnalyzeQuery(_ sender: Any?) { contentVC.menuExplainAnalyzeQuery(sender) }
    @objc func menuConnect(_ sender: Any?) { contentVC.menuConnect(sender) }
    @objc func menuDisconnect(_ sender: Any?) { contentVC.menuDisconnect(sender) }
    @objc func menuRefreshMetadata(_ sender: Any?) { contentVC.menuRefreshMetadata(sender) }
    @objc func menuFormatSQL(_ sender: Any?) { contentVC.menuFormatSQL(sender) }
    @objc func menuNewTab(_ sender: Any?) { contentVC.menuNewTab(sender) }
    @objc func menuCloseTab(_ sender: Any?) { contentVC.menuCloseTab(sender) }
    @objc func menuReopenTab(_ sender: Any?) { contentVC.menuReopenTab(sender) }
    @objc func menuSelectTab(_ sender: NSMenuItem) { contentVC.menuSelectTab(sender) }
    @objc func menuSelectNextTab(_ sender: Any?) { contentVC.menuSelectNextTab(sender) }
    @objc func menuSelectPreviousTab(_ sender: Any?) { contentVC.menuSelectPreviousTab(sender) }
    @objc func menuSelectNextResultTab(_ sender: Any?) { contentVC.menuSelectNextResultTab(sender) }
    @objc func menuSelectPreviousResultTab(_ sender: Any?) { contentVC.menuSelectPreviousResultTab(sender) }
    @objc func menuSaveQuery(_ sender: Any?) { contentVC.menuSaveQuery(sender) }
    @objc func menuSaveQueryAs(_ sender: Any?) { contentVC.menuSaveQueryAs(sender) }
    @objc func menuExportEditorAsSQL(_ sender: Any?) { contentVC.menuExportEditorAsSQL(sender) }
    @objc func menuIncreaseEditorFont(_ sender: Any?) { contentVC.menuIncreaseEditorFont(sender) }
    @objc func menuDecreaseEditorFont(_ sender: Any?) { contentVC.menuDecreaseEditorFont(sender) }

    /// Edit > Find with the focus in the sidebar or the inspector: the editor
    /// and the grid handle it themselves when they are first responder; here
    /// the content controller's fallback (the grid find bar) takes it.
    override func performTextFinderAction(_ sender: Any?) { contentVC.performTextFinderAction(sender) }

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
        if menuItem.action == #selector(menuShowNavigator(_:)) {
            // A checkmark on the list that is showing. It stays checked with
            // the sidebar hidden: the item then means "show the sidebar on
            // this list", and the state says which one that is.
            menuItem.state = (menuItem.tag == sidebarVC.currentNavigator.rawValue) ? .on : .off
            return true
        }
        if menuItem.action == #selector(menuFocusNavigatorFilter(_:)) {
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

    // MARK: - Navigators

    /// View ▸ Navigators ▸ … — shows the sidebar if it is hidden, then swaps
    /// it to the chosen list. Asking for a navigator while the sidebar is
    /// closed means "show me that list", never "do nothing".
    @objc func menuShowNavigator(_ sender: NSMenuItem) {
        guard let navigator = Navigator(rawValue: sender.tag) else { return }
        revealNavigator(navigator)
    }

    /// Show the sidebar if it is hidden, then swap it to `navigator`. The
    /// content pane uses it to bring the Variables list forward when a run
    /// fails on a `{{token}}` that has no value.
    func revealNavigator(_ navigator: Navigator) {
        revealSidebar()
        sidebarVC.showNavigator(navigator)
    }

    /// View ▸ Filter in Navigator — shows the sidebar if it is hidden, then
    /// puts the caret in its filter field.
    @objc func menuFocusNavigatorFilter(_ sender: Any?) {
        revealSidebar()
        sidebarVC.focusFilter()
    }

    private func revealSidebar() {
        setSidebarCollapsed(false)
    }

    // MARK: - Sidebar collapse (for the toolbar's navigator group)

    /// The sidebar's split view item.
    private var sidebarItem: NSSplitViewItem? { splitViewItems.first }

    /// Whether the sidebar is hidden.
    var isSidebarCollapsed: Bool { sidebarItem?.isCollapsed ?? false }

    /// Shows or hides the sidebar, animated, and does nothing if it is already
    /// in that state.
    func setSidebarCollapsed(_ collapsed: Bool) {
        guard let item = sidebarItem, item.isCollapsed != collapsed else { return }
        item.animator().isCollapsed = collapsed
    }
}
