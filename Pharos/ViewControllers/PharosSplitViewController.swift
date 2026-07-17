import AppKit

// All three items use init(viewController:) to bypass macOS 26's Liquid Glass
// "floating" sidebar/inspector treatment, which insets the panels with rounded
// corners and leaves a transparent gap to the window chrome. We want a classic
// edge-to-edge sidebar so the trailing border meets the bottom of the window
// cleanly. Holding priorities make the sidebar and inspector resize like
// classic panels (content absorbs window resize).
//
// Because the split items have `.default` behavior (not `.sidebar` /
// `.inspector`), the built-in `NSSplitViewController.toggleSidebar(_:)` /
// `toggleInspector(_:)` actions short-circuit during validation and never
// fire. The menu and toolbar use our own selectors (`pharosToggleSidebar:`,
// `pharosToggleInspector:`) so we control both dispatch and validation.
class PharosSplitViewController: NSSplitViewController {

    let sidebarVC = SidebarViewController()
    let contentVC = ContentViewController()
    let inspectorVC = InspectorViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar item — classic edge-to-edge.
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = false
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

        // Inspector item — classic edge-to-edge, starts collapsed.
        let inspectorItem = NSSplitViewItem(viewController: inspectorVC)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 400
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
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

        // Changed from "PharosSidebarSplit" to avoid 2-pane saved positions
        // corrupting the 3-pane layout
        splitView.autosaveName = "PharosMainSplit"
    }

    // MARK: - Responder Actions

    /// Custom toggle for the sidebar — avoids NSSplitViewController's
    /// built-in `toggleSidebar:` validation that disables the action when no
    /// item has `.sidebar` behavior.
    @objc func pharosToggleSidebar(_ sender: Any?) {
        guard let item = splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
    }

    /// Custom toggle for the inspector — mirror of the above for the
    /// trailing pane.
    @objc func pharosToggleInspector(_ sender: Any?) {
        guard let item = splitViewItems.last else { return }
        item.animator().isCollapsed.toggle()
    }

    /// Reveals the inspector if it's currently collapsed. Unlike
    /// `pharosToggleInspector`, this never collapses an already-visible
    /// inspector — used when content is about to be pushed into it
    /// programmatically (e.g. showing a preview row's SQL).
    func showInspector() {
        if let item = splitViewItems.last, item.isCollapsed {
            item.animator().isCollapsed = false
        }
    }
}
