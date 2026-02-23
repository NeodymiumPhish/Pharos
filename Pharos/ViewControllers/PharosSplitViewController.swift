import AppKit

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
        let contentItem = NSSplitViewItem(contentListWithViewController: contentVC)
        contentItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        splitView.autosaveName = "PharosSidebarSplit"
    }
}
