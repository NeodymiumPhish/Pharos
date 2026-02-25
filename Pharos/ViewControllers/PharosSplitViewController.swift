import AppKit

// APPROACH A APPLIED: init(viewController:) instead of contentListWithViewController.
// This removes the auto-created NSVisualEffectView that was causing washed-out text.
// init(viewController:) uses .default behavior -- no vibrancy, no VEV wrapping.
// The previous test (2026-02-25) was confounded with 8 other simultaneous changes.
// This isolated re-test changes ONLY this one line.
// Awaiting visual verification at checkpoint.
class PharosSplitViewController: NSSplitViewController {

    let sidebarVC = SidebarViewController()
    let contentVC = ContentViewController()

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

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        splitView.autosaveName = "PharosSidebarSplit"
    }
}
