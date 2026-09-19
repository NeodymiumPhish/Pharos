import AppKit
import UniformTypeIdentifiers

// MARK: - SchemaDataSource Delegate

protocol SchemaDataSourceDelegate: AnyObject {
    func schemaDataSourceItemWillExpand(_ node: SchemaTreeNode)
    func schemaDataSourceSelectionDidChange(_ node: SchemaTreeNode?)
    /// The browser's connection, or nil when there is none. A drop needs one:
    /// there is nothing to import into without it.
    var schemaDataSourceConnectionId: String? { get }
    /// A CSV/TSV file was dropped on `node` (always a `.table`). The receiver
    /// opens the import sheet with the file already chosen.
    func schemaDataSourceDidDropFile(_ url: URL, onTable node: SchemaTreeNode)
    /// `node` was double-clicked. The receiver owns Settings ▸ Navigator ▸
    /// On double-click and returns `true` when it ran the chosen action.
    /// `false` — the setting is "Expand or collapse", or the row is not an
    /// object that action can be run against — leaves the disclosure
    /// behaviour to the data source.
    func schemaDataSourceDidDoubleClick(_ node: SchemaTreeNode) -> Bool
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
        outlineView.registerForDraggedTypes([.fileURL])
    }

    // MARK: - File Drop (import)

    /// The single CSV/TSV file on `pasteboard`, or nil.
    ///
    /// Exactly one: an import writes ONE file into ONE table, and silently
    /// taking the first of several dragged files would import a file the user
    /// did not point at.
    static func importableFileURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              urls.count == 1, let url = urls.first else { return nil }
        return isImportable(url) ? url : nil
    }

    /// Whether a dropped file is one the import sheet can read: CSV or TSV.
    /// The extension is the fallback for a file Launch Services has no type
    /// for, mirroring `AppDelegate.application(_:open:)`; `.txt` is allowed
    /// because a delimited export very often arrives under that name.
    static func isImportable(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) {
                return true
            }
            // A plain-text file whose extension says csv/tsv still counts —
            // some exporters write text/plain files named `.csv`.
            if type.conforms(to: .plainText) {
                return ["csv", "tsv"].contains(url.pathExtension.lowercased())
            }
            return false
        }
        return ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased())
    }

    /// Only a plain table takes a drop: a view cannot be written to, and a
    /// partition is loaded through its parent.
    static func acceptsDrop(_ item: Any?) -> SchemaTreeNode? {
        guard let node = item as? SchemaTreeNode, case .table = node.kind else { return nil }
        return node
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard delegate?.schemaDataSourceConnectionId != nil,
              let node = Self.acceptsDrop(item),
              Self.importableFileURL(from: info.draggingPasteboard) != nil else { return [] }
        // Drop ON the table, never between rows: the tree has no order to
        // insert into.
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard delegate?.schemaDataSourceConnectionId != nil,
              let node = Self.acceptsDrop(item),
              let url = Self.importableFileURL(from: info.draggingPasteboard) else { return false }
        delegate?.schemaDataSourceDidDropFile(url, onTable: node)
        return true
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

    // Row height intentionally NOT implemented as a delegate method — the
    // outline uses a fixed `rowHeight` set on NSOutlineView so reload is
    // O(visible-rows) instead of O(total-rows). Implementing this method
    // would put NSOutlineView back on the slow per-row layout path.

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SchemaTreeNode else { return }
        delegate?.schemaDataSourceItemWillExpand(node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        let node = row >= 0 ? outlineView.item(atRow: row) as? SchemaTreeNode : nil
        delegate?.schemaDataSourceSelectionDidChange(node)
    }

    // MARK: - Double Click

    @objc private func outlineDoubleClicked(_: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SchemaTreeNode else { return }
        // Settings ▸ Navigator ▸ On double-click. Expanding is the default
        // and the fallback: a schema row has no contents to view and no name
        // worth inserting, so it still opens.
        if delegate?.schemaDataSourceDidDoubleClick(item) == true { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if outlineView.isExpandable(item) {
            outlineView.expandItem(item)
        }
    }
}
