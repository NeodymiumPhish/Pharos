import AppKit

// MARK: - Notification Names

extension Notification.Name {
    static let openSavedQuery = Notification.Name("PharosOpenSavedQuery")
    static let savedQueriesDidChange = Notification.Name("PharosSavedQueriesDidChange")
}

// MARK: - Saved Query Tree Node

class SavedQueryNode: NSObject {
    enum Kind {
        case folder(String)      // user-created folder
        case query(SavedQuery)   // saved query with SQL
    }

    let kind: Kind
    var children: [SavedQueryNode] = []

    init(_ kind: Kind) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case .folder(let name): return name
        case .query(let q): return q.name
        }
    }

    var icon: NSImage? {
        switch kind {
        case .folder:
            return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        case .query:
            return NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "Query")
        }
    }

    var tintColor: NSColor {
        switch kind {
        case .folder: return .systemBlue
        case .query: return .systemIndigo
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .folder: return true
        case .query: return false
        }
    }

    /// Returns the query ID if this is a query node, nil for folders.
    var queryId: String? {
        if case .query(let q) = kind { return q.id }
        return nil
    }
}

// MARK: - Drag Pasteboard Type

private extension NSPasteboard.PasteboardType {
    static let savedQueryDrag = NSPasteboard.PasteboardType("com.pharos.savedQuery")
}

// MARK: - SavedQueriesVC

class SavedQueriesVC: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    private var rootNodes: [SavedQueryNode] = []
    private var allQueries: [SavedQuery] = []
    private var filterText: String?
    private var editingFolderNode: SavedQueryNode?

    /// Called when outline view selection changes. Bool indicates whether a query is selected.
    var onSelectionChanged: ((Bool) -> Void)?

    override func loadView() {
        let container = NSView()
        self.view = container

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SavedQueries"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .custom
        outlineView.autoresizesOutlineColumn = true
        outlineView.indentationPerLevel = 14
        outlineView.doubleAction = #selector(doubleClickedRow(_:))
        outlineView.target = self
        outlineView.menu = buildContextMenu()

        // Multi-select support
        outlineView.allowsMultipleSelection = true

        // Drag-and-drop support
        outlineView.registerForDraggedTypes([.savedQueryDrag])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom bar with New Folder button
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let newFolderButton = NSButton()
        let folderConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        newFolderButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")?.withSymbolConfiguration(folderConfig)
        newFolderButton.bezelStyle = .recessed
        newFolderButton.isBordered = false
        newFolderButton.toolTip = "New Folder"
        newFolderButton.target = self
        newFolderButton.action = #selector(newFolderClicked)
        newFolderButton.translatesAutoresizingMaskIntoConstraints = false
        newFolderButton.contentTintColor = .secondaryLabelColor

        bottomBar.addSubview(newFolderButton)
        NSLayoutConstraint.activate([
            newFolderButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            newFolderButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            newFolderButton.widthAnchor.constraint(equalToConstant: 28),
            newFolderButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        container.addSubview(scrollView)
        container.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // MARK: - Public API

    func reload() {
        do {
            allQueries = try PharosCore.loadSavedQueries()
            rebuildTree()
            outlineView.reloadData()
            expandAll()
        } catch {
            NSLog("Failed to load saved queries: \(error)")
        }
    }

    // MARK: - Filter API (called by SidebarViewController)

    func applyFilter(_ text: String) {
        filterText = text.lowercased()
        rebuildTree()
        outlineView.reloadData()
        expandAll()
    }

    func clearFilter() {
        filterText = nil
        rebuildTree()
        outlineView.reloadData()
        expandAll()
    }

    /// Delete the currently selected saved queries with confirmation (supports multi-select).
    func deleteSelectedQueries() {
        let selectedIds = collectSelectedQueryIds()
        guard !selectedIds.isEmpty else { return }

        let alert = NSAlert()
        if selectedIds.count == 1 {
            // Find the name for a nicer message
            let name = selectedQueryNames().first ?? "this query"
            alert.messageText = "Delete '\(name)'?"
        } else {
            alert.messageText = "Delete \(selectedIds.count) queries?"
        }
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                _ = try PharosCore.batchDeleteSavedQueries(ids: selectedIds)
                self?.reload()
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            } catch {
                NSLog("Failed to batch delete saved queries: \(error)")
            }
        }
    }

    // MARK: - Key Events

    override func keyDown(with event: NSEvent) {
        // Delete/Backspace key
        if event.keyCode == 51 || event.keyCode == 117 {
            let selectedIds = collectSelectedQueryIds()
            if !selectedIds.isEmpty {
                deleteSelectedQueries()
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Selection Helpers

    /// Collect query IDs from all selected rows (skips folder nodes).
    private func collectSelectedQueryIds() -> [String] {
        var ids: [String] = []
        for row in outlineView.selectedRowIndexes {
            guard let node = outlineView.item(atRow: row) as? SavedQueryNode,
                  let qId = node.queryId else { continue }
            ids.append(qId)
        }
        return ids
    }

    /// Collect query names from all selected rows (skips folder nodes).
    private func selectedQueryNames() -> [String] {
        var names: [String] = []
        for row in outlineView.selectedRowIndexes {
            guard let node = outlineView.item(atRow: row) as? SavedQueryNode,
                  case .query(let q) = node.kind else { continue }
            names.append(q.name)
        }
        return names
    }

    // MARK: - Tree Building

    private func rebuildTree() {
        // Filter queries by text if needed
        let queries: [SavedQuery]
        if let filter = filterText, !filter.isEmpty {
            queries = allQueries.filter {
                $0.name.lowercased().contains(filter) ||
                $0.sql.lowercased().contains(filter)
            }
        } else {
            queries = allQueries
        }

        // Group by folder -- flat list of folders + unfiled queries at root
        var folders: [String: SavedQueryNode] = [:]
        var unfiled: [SavedQueryNode] = []

        for query in queries {
            let node = SavedQueryNode(.query(query))
            if let folder = query.folder, !folder.isEmpty {
                if folders[folder] == nil {
                    folders[folder] = SavedQueryNode(.folder(folder))
                }
                folders[folder]!.children.append(node)
            } else {
                unfiled.append(node)
            }
        }

        // Sort folders alphabetically, then unfiled queries by name
        let sortedFolders = folders.keys.sorted().compactMap { folders[$0] }
        unfiled.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        rootNodes = sortedFolders + unfiled
    }

    private func expandAll() {
        for node in rootNodes where node.isExpandable {
            outlineView.expandItem(node)
        }
    }



    // MARK: - Actions

    @objc private func doubleClickedRow(_: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SavedQueryNode else { return }
        if case .query(let q) = node.kind {
            openQueryInTab(q)
        }
    }

    private func openQueryInTab(_ query: SavedQuery) {
        NotificationCenter.default.post(
            name: .openSavedQuery,
            object: nil,
            userInfo: ["query": query]
        )
    }

    @objc private func contextOpenInTab(_: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        openQueryInTab(q)
    }

    @objc private func contextCopySQL(_: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(q.sql, forType: .string)
    }

    @objc private func contextRename(_: Any?) {
        guard let node = clickedNode() else { return }
        let currentName: String
        switch node.kind {
        case .query(let q): currentName = q.name
        case .folder(let name): currentName = name
        }

        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = currentName
        alert.accessoryView = textField

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, newName != currentName else { return }
            self?.performRename(node: node, newName: newName)
        }
    }

    private func performRename(node: SavedQueryNode, newName: String) {
        switch node.kind {
        case .query(let q):
            do {
                let update = UpdateSavedQuery(id: q.id, name: newName, folder: q.folder, sql: q.sql)
                _ = try PharosCore.updateSavedQuery(update)
                reload()
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            } catch {
                NSLog("Failed to rename query: \(error)")
            }
        case .folder(let oldName):
            // Rename all queries in this folder
            let folderQueries = allQueries.filter { $0.folder == oldName }
            for q in folderQueries {
                do {
                    let update = UpdateSavedQuery(id: q.id, name: q.name, folder: newName, sql: q.sql)
                    _ = try PharosCore.updateSavedQuery(update)
                } catch {
                    NSLog("Failed to rename folder query: \(error)")
                }
            }
            reload()
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        }
    }

    @objc private func contextDelete(_: Any?) {
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .query(let q):
            do {
                _ = try PharosCore.deleteSavedQuery(id: q.id)
                reload()
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            } catch {
                NSLog("Failed to delete saved query: \(error)")
            }

        case .folder(let name):
            let count = node.children.count
            guard count > 0 else {
                // Empty folder -- just reload (it'll disappear)
                reload()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Delete folder \"\(name)\"?"
            alert.informativeText = "This will delete \(count) saved quer\(count == 1 ? "y" : "ies") in this folder."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")

            guard let window = view.window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let ids = node.children.compactMap { $0.queryId }
                if !ids.isEmpty {
                    _ = try? PharosCore.batchDeleteSavedQueries(ids: ids)
                }
                self?.reload()
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            }
        }
    }

    /// Context menu action for batch deleting multiple selected queries.
    @objc private func contextDeleteSelected(_: Any?) {
        deleteSelectedQueries()
    }

    @objc private func contextNewFolder(_: Any?) {
        createNewFolderInline()
    }

    @objc private func newFolderClicked(_: Any?) {
        createNewFolderInline()
    }

    /// Creates a new folder named "New Folder" and immediately begins inline editing of its name.
    private func createNewFolderInline() {
        createEmptyFolder(name: "New Folder")

        // Find the newly created folder node and begin editing
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for i in 0..<self.outlineView.numberOfRows {
                guard let node = self.outlineView.item(atRow: i) as? SavedQueryNode,
                      case .folder(let name) = node.kind,
                      name == "New Folder" else { continue }
                self.editingFolderNode = node
                self.outlineView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                self.outlineView.scrollRowToVisible(i)
                // Begin inline editing on the cell's text field
                if let cellView = self.outlineView.view(atColumn: 0, row: i, makeIfNecessary: false) as? SavedQueryCellView {
                    cellView.beginEditing(delegate: self)
                }
                break
            }
        }
    }

    private func createEmptyFolder(name: String) {
        // Create a placeholder query in the folder so the folder persists
        let query = CreateSavedQuery(name: "New Query", folder: name, sql: "", connectionId: nil)
        do {
            _ = try PharosCore.createSavedQuery(query)
            reload()
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        } catch {
            NSLog("Failed to create folder: \(error)")
        }
    }

    @objc private func contextNewQuery(_: Any?) {
        let query = CreateSavedQuery(name: "Untitled Query", folder: nil, sql: "", connectionId: nil)
        do {
            let saved = try PharosCore.createSavedQuery(query)
            reload()
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            openQueryInTab(saved)
        } catch {
            NSLog("Failed to create query: \(error)")
        }
    }

    private func clickedNode() -> SavedQueryNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SavedQueryNode
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SavedQueryNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SavedQueryNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SavedQueryNode)?.isExpandable ?? false
    }

    // MARK: - Drag-and-Drop (NSOutlineViewDataSource)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? SavedQueryNode, let qId = node.queryId else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(qId, forType: .savedQueryDrag)
        return pbItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Accept drops on folder nodes or on root (nil = move to no folder)
        if let node = item as? SavedQueryNode {
            switch node.kind {
            case .folder:
                return .move
            case .query:
                // Can't drop onto a query node
                return []
            }
        }
        // item is nil => root level drop
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let pasteboard = info.draggingPasteboard

        // Collect all dragged query IDs
        guard let items = pasteboard.pasteboardItems else { return false }
        var draggedIds: [String] = []
        for pbItem in items {
            if let qId = pbItem.string(forType: .savedQueryDrag) {
                draggedIds.append(qId)
            }
        }
        guard !draggedIds.isEmpty else { return false }

        // Determine target folder
        let targetFolder: String?
        if let node = item as? SavedQueryNode, case .folder(let name) = node.kind {
            targetFolder = name
        } else {
            targetFolder = nil  // dropped on root = no folder
        }

        // Move each query to the target folder
        for qId in draggedIds {
            guard let query = allQueries.first(where: { $0.id == qId }) else { continue }
            let update = UpdateSavedQuery(id: qId, name: query.name, folder: targetFolder, sql: query.sql)
            _ = try? PharosCore.updateSavedQuery(update)
        }

        reload()
        NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SavedQueryNode else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("NavigatorCell")
        let cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? SavedQueryCellView
            ?? SavedQueryCellView(identifier: cellId)
        cell.configure(icon: node.icon, tint: node.tintColor, title: node.title)

        // Show SQL preview as tooltip for query nodes
        if case .query(let q) = node.kind {
            let flat = q.sql
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            cell.toolTip = flat.isEmpty ? nil : (flat.count > 80 ? String(flat.prefix(80)) + "..." : flat)
        } else {
            cell.toolTip = nil
        }

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        24
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SavedQueryNode
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SavedQueryNode)?.isExpandable ?? true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Check if any selected row is a query node
        var hasQuery = false
        for row in outlineView.selectedRowIndexes {
            if let node = outlineView.item(atRow: row) as? SavedQueryNode,
               case .query = node.kind {
                hasQuery = true
                break
            }
        }
        onSelectionChanged?(hasQuery)
    }
}

// MARK: - NSMenuDelegate

extension SavedQueriesVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Check if multiple queries are selected
        let selectedQueryCount = collectSelectedQueryIds().count
        if selectedQueryCount > 1 {
            // Multi-select context menu: only batch operations
            let deleteItem = NSMenuItem(
                title: "Delete \(selectedQueryCount) Queries",
                action: #selector(contextDeleteSelected),
                keyEquivalent: ""
            )
            menu.addItem(deleteItem)
            return
        }

        guard let node = clickedNode() else { return }

        switch node.kind {
        case .query:
            menu.addItem(withTitle: "Open in Tab", action: #selector(contextOpenInTab), keyEquivalent: "")
            menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename...", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")

        case .folder:
            menu.addItem(withTitle: "New Query", action: #selector(contextNewQuery), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename...", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
        }
    }
}

// MARK: - SavedQueryCellEditingDelegate

extension SavedQueriesVC: SavedQueryCellEditingDelegate {
    func cellView(_ cellView: SavedQueryCellView, didFinishEditingWithText text: String) {
        guard let node = editingFolderNode, case .folder(let oldName) = node.kind else {
            editingFolderNode = nil
            return
        }
        editingFolderNode = nil

        // If the name didn't change, nothing to do
        guard text != oldName else { return }

        // Rename all queries in this folder from oldName to the new name
        let folderQueries = allQueries.filter { $0.folder == oldName }
        for q in folderQueries {
            do {
                let update = UpdateSavedQuery(id: q.id, name: q.name, folder: text, sql: q.sql)
                _ = try PharosCore.updateSavedQuery(update)
            } catch {
                NSLog("Failed to rename folder query: \(error)")
            }
        }
        reload()
        NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
    }
}

// MARK: - Compact Cell View

class SavedQueryCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private weak var editingDelegate: SavedQueryCellEditingDelegate?

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init()
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: NSImage?, tint: NSColor, title: String) {
        iconView.image = icon
        iconView.contentTintColor = tint
        titleLabel.stringValue = title
    }

    /// Makes the title label editable and selects all text for immediate renaming.
    func beginEditing(delegate: SavedQueryCellEditingDelegate) {
        editingDelegate = delegate
        titleLabel.isEditable = true
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.delegate = self
        titleLabel.selectText(nil)
        window?.makeFirstResponder(titleLabel)
    }

    fileprivate func endEditing() {
        titleLabel.isEditable = false
        titleLabel.delegate = nil
        editingDelegate = nil
    }
}

protocol SavedQueryCellEditingDelegate: AnyObject {
    func cellView(_ cellView: SavedQueryCellView, didFinishEditingWithText text: String)
}

extension SavedQueryCellView: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        let newName = fieldEditor.string.trimmingCharacters(in: .whitespaces)
        let delegate = editingDelegate
        endEditing()
        if !newName.isEmpty {
            delegate?.cellView(self, didFinishEditingWithText: newName)
        }
        return true
    }
}
