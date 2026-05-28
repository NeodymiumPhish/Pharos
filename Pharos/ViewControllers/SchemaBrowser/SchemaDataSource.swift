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

    // Diagnostic counter — measures how many cells NSOutlineView realizes
    // per "burst" (reset by the wallclock-tick logging in viewFor). Remove
    // once the per-tab-switch slowdown is resolved.
    private var __viewForCount: Int = 0
    private var __viewForBurstStart: CFAbsoluteTime = 0

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SchemaTreeNode else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        if __viewForCount == 0 {
            __viewForBurstStart = now
        }
        __viewForCount += 1
        // After a quiet period of 100ms, dump the burst stats.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if CFAbsoluteTimeGetCurrent() - now >= 0.1 && self.__viewForCount > 0 {
                let elapsed = (CFAbsoluteTimeGetCurrent() - self.__viewForBurstStart) * 1000
                NSLog("[perf] SchemaDataSource.viewFor burst=\(self.__viewForCount) cells over \(String(format: "%.1f", elapsed))ms")
                self.__viewForCount = 0
            }
        }

        let cellId = NSUserInterfaceItemIdentifier("SchemaCell")
        let cell = outlineView.makeView(withIdentifier: cellId, owner: nil) as? SchemaTreeCellView
            ?? SchemaTreeCellView(identifier: cellId)

        cell.configure(node: node)
        return cell
    }

    // Row height intentionally NOT implemented as a delegate method — the
    // outline uses a fixed `rowHeight` set on NSOutlineView so reload is
    // O(visible-rows) instead of O(total-rows). Implementing this method
    // would put NSOutlineView back on the slow per-row layout path.

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
