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
        sidebarItem.holdingPriority = .defaultHigh + 1
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
        inspectorItem.holdingPriority = .defaultHigh + 1
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
}
