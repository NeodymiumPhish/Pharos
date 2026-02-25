import AppKit

// MARK: - SchemaDataSource Delegate

protocol SchemaDataSourceDelegate: AnyObject {
    func schemaDataSourceItemWillExpand(_ node: SchemaTreeNode)
}

// MARK: - SchemaDataSource

class SchemaDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let outlineView: NSOutlineView

    /// Data state (pushed by VC after load/filter operations).
    var rootNodes: [SchemaTreeNode] = []

    weak var delegate: SchemaDataSourceDelegate?

    init(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        super.init()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SchemaTreeNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SchemaTreeNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SchemaTreeNode)?.isExpandable ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SchemaTreeNode else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("SchemaCell")
        let cell = outlineView.makeView(withIdentifier: cellId, owner: nil) as? SchemaTreeCellView
            ?? SchemaTreeCellView(identifier: cellId)

        cell.configure(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SchemaTreeNode else { return 22 }
        return node.subtitle != nil ? 32 : 22
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SchemaTreeNode else { return }
        delegate?.schemaDataSourceItemWillExpand(node)
    }

    // MARK: - Double Click

    @objc private func outlineDoubleClicked(_: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SchemaTreeNode else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if outlineView.isExpandable(item) {
            outlineView.expandItem(item)
        }
    }
}
