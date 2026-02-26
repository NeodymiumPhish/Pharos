import AppKit

// Content item uses init(viewController:) to avoid macOS 26 Liquid Glass injecting
// an NSVisualEffectView into the content area. The sidebar uses sidebarWithViewController
// which correctly gets Liquid Glass vibrancy. This split keeps editor text crisp while
// the sidebar gets the native translucent appearance.
class PharosSplitViewController: NSSplitViewController {

    let sidebarVC = SidebarViewController()
    let contentVC = ContentViewController()
    let inspectorVC = InspectorViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar item — automatically gets Liquid Glass on macOS 26
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = false

        // Content item
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 400

        // Inspector item — uses inspectorWithViewController for standard
        // collapse/expand behavior and automatic Liquid Glass on macOS 26.
        // Starts collapsed; user must explicitly open via toolbar or Cmd+Opt+0.
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 400
        inspectorItem.isCollapsed = true
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)

        // Changed from "PharosSidebarSplit" to avoid 2-pane saved positions
        // corrupting the 3-pane layout
        splitView.autosaveName = "PharosMainSplit"
    }
}
