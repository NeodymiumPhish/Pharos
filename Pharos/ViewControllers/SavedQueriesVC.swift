import AppKit

// MARK: - Notification Names

extension Notification.Name {
    static let openSavedQuery = Notification.Name("PharosOpenSavedQuery")
    static let savedQueriesDidChange = Notification.Name("PharosSavedQueriesDidChange")
}

// MARK: - Saved Query Tree Node

class SavedQueryNode: NSObject {
    enum Kind {
        case section(String)     // "Connection: mydb" or "General"
        case folder(String)      // user-created folder
        case query(SavedQuery)   // saved query with SQL
    }

    let kind: Kind
    var children: [SavedQueryNode] = []
    /// For section nodes: whether this is the connection section (true) or general (false).
    var isConnectionSection = false

    init(_ kind: Kind) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case .section(let name): return name
        case .folder(let name): return name
        case .query(let q): return q.name
        }
    }

    var icon: NSImage? {
        switch kind {
        case .section: return nil
        case .folder:
            return NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        case .query:
            return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Query")
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .section, .folder: return true
        case .query: return false
        }
    }

    /// First non-empty line of SQL, trimmed and truncated for preview.
    var sqlSnippet: String? {
        guard case .query(let q) = kind else { return nil }
        let sql = q.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return nil }
        // Take first line, trim, truncate
        let firstLine = sql.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? sql
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 60 {
            return String(trimmed.prefix(60)) + "…"
        }
        return trimmed
    }
}

// MARK: - SavedQueriesVC

class SavedQueriesVC: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    private var rootNodes: [SavedQueryNode] = []
    private var allQueries: [SavedQuery] = []
    private var filterText: String?
    private var activeConnectionId: String?

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

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Public API

    func reload(connectionId: String? = nil) {
        self.activeConnectionId = connectionId
        do {
            allQueries = try PharosCore.loadSavedQueries()
            rebuildTree()
            outlineView.reloadData()
            expandAllSections()
        } catch {
            NSLog("Failed to load saved queries: \(error)")
        }
    }

    // MARK: - Filter API (called by SidebarViewController)

    func applyFilter(_ text: String) {
        filterText = text.lowercased()
        rebuildTree()
        outlineView.reloadData()
        expandAllSections()
    }

    func clearFilter() {
        filterText = nil
        rebuildTree()
        outlineView.reloadData()
        expandAllSections()
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

        var sections: [SavedQueryNode] = []

        // Connection section (only if a connection is active)
        if let connId = activeConnectionId {
            let connName = AppStateManager.shared.activeConnection?.name ?? "Connection"
            let connQueries = queries.filter { $0.connectionId == connId }
            let section = buildSection(title: connName, queries: connQueries, isConnectionSection: true)
            if section != nil || (filterText == nil || filterText!.isEmpty) {
                // Always show connection section when no filter, even if empty
                let node = section ?? SavedQueryNode(.section(connName))
                node.isConnectionSection = true
                sections.append(node)
            }
        }

        // General section (always visible)
        let generalQueries = queries.filter { $0.connectionId == nil }
        let generalSection = buildSection(title: "General", queries: generalQueries, isConnectionSection: false)
        if let section = generalSection {
            sections.append(section)
        } else if filterText == nil || filterText!.isEmpty {
            // Show empty General section when no filter
            sections.append(SavedQueryNode(.section("General")))
        }

        rootNodes = sections
    }

    private func buildSection(title: String, queries: [SavedQuery], isConnectionSection: Bool) -> SavedQueryNode? {
        if queries.isEmpty && filterText != nil && !filterText!.isEmpty {
            return nil // Hide empty sections during filtering
        }

        let section = SavedQueryNode(.section(title))
        section.isConnectionSection = isConnectionSection

        // Group by folder
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
        section.children = sortedFolders + unfiled

        return section
    }

    private func expandAllSections() {
        for node in rootNodes {
            outlineView.expandItem(node)
            // Also expand folders
            for child in node.children {
                if child.isExpandable {
                    outlineView.expandItem(child)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func doubleClickedRow(_ sender: Any?) {
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

    @objc private func contextOpenInTab(_ sender: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        openQueryInTab(q)
    }

    @objc private func contextCopySQL(_ sender: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(q.sql, forType: .string)
    }

    @objc private func contextMoveToConnection(_ sender: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind,
              let connId = activeConnectionId else { return }
        do {
            let updated = CreateSavedQuery(name: q.name, folder: q.folder, sql: q.sql, connectionId: connId)
            _ = try PharosCore.deleteSavedQuery(id: q.id)
            _ = try PharosCore.createSavedQuery(updated)
            reload(connectionId: activeConnectionId)
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        } catch {
            NSLog("Failed to move query: \(error)")
        }
    }

    @objc private func contextMoveToGeneral(_ sender: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        do {
            let updated = CreateSavedQuery(name: q.name, folder: q.folder, sql: q.sql, connectionId: nil)
            _ = try PharosCore.deleteSavedQuery(id: q.id)
            _ = try PharosCore.createSavedQuery(updated)
            reload(connectionId: activeConnectionId)
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        } catch {
            NSLog("Failed to move query: \(error)")
        }
    }

    @objc private func contextRename(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        let currentName: String
        switch node.kind {
        case .query(let q): currentName = q.name
        case .folder(let name): currentName = name
        default: return
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
                reload(connectionId: activeConnectionId)
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
            reload(connectionId: activeConnectionId)
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        default: break
        }
    }

    @objc private func contextDelete(_ sender: Any?) {
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .query(let q):
            do {
                _ = try PharosCore.deleteSavedQuery(id: q.id)
                reload(connectionId: activeConnectionId)
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            } catch {
                NSLog("Failed to delete saved query: \(error)")
            }

        case .folder(let name):
            let count = node.children.count
            guard count > 0 else {
                // Empty folder — just reload (it'll disappear)
                reload(connectionId: activeConnectionId)
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
                for child in node.children {
                    if case .query(let q) = child.kind {
                        _ = try? PharosCore.deleteSavedQuery(id: q.id)
                    }
                }
                self?.reload(connectionId: self?.activeConnectionId)
                NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            }

        default: break
        }
    }

    @objc private func contextNewFolder(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Folder name"
        alert.accessoryView = textField

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self?.createEmptyFolder(name: name)
        }
    }

    private func createEmptyFolder(name: String) {
        // Determine scope from clicked section
        let connectionId: String?
        if let node = clickedNode(), case .section = node.kind, node.isConnectionSection {
            connectionId = activeConnectionId
        } else {
            connectionId = nil
        }

        // Create a placeholder query in the folder so the folder persists
        let query = CreateSavedQuery(name: "New Query", folder: name, sql: "", connectionId: connectionId)
        do {
            _ = try PharosCore.createSavedQuery(query)
            reload(connectionId: activeConnectionId)
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
        } catch {
            NSLog("Failed to create folder: \(error)")
        }
    }

    @objc private func contextNewQuery(_ sender: Any?) {
        // Determine scope from clicked section
        let connectionId: String?
        if let node = clickedNode(), case .section = node.kind, node.isConnectionSection {
            connectionId = activeConnectionId
        } else {
            connectionId = nil
        }

        let query = CreateSavedQuery(name: "Untitled Query", folder: nil, sql: "", connectionId: connectionId)
        do {
            let saved = try PharosCore.createSavedQuery(query)
            reload(connectionId: activeConnectionId)
            NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)
            // Open the new query in a tab
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

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SavedQueryNode else { return nil }

        switch node.kind {
        case .section:
            let cellId = NSUserInterfaceItemIdentifier("SectionCell")
            let cell: NSTextField
            if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
                cell = existing
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = cellId
                cell.font = .systemFont(ofSize: 10, weight: .bold)
                cell.textColor = .tertiaryLabelColor
            }
            cell.stringValue = node.title.uppercased()
            return cell

        case .folder:
            let cellId = NSUserInterfaceItemIdentifier("FolderCell")
            let cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? SavedQueryCellView
                ?? SavedQueryCellView(identifier: cellId)
            cell.configure(icon: node.icon, tint: .secondaryLabelColor, title: node.title, snippet: nil)
            return cell

        case .query:
            let cellId = NSUserInterfaceItemIdentifier("QueryCell")
            let cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? SavedQueryCellView
                ?? SavedQueryCellView(identifier: cellId)
            cell.configure(icon: node.icon, tint: .secondaryLabelColor, title: node.title, snippet: node.sqlSnippet)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SavedQueryNode else { return 22 }
        switch node.kind {
        case .section: return 22
        case .folder: return 22
        case .query: return node.sqlSnippet != nil ? 30 : 22
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let node = item as? SavedQueryNode else { return false }
        if case .section = node.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SavedQueryNode else { return false }
        if case .section = node.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        guard let node = item as? SavedQueryNode else { return true }
        // Hide disclosure triangle for section headers (always expanded)
        if case .section = node.kind { return false }
        return true
    }
}

// MARK: - NSMenuDelegate

extension SavedQueriesVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .query(let q):
            menu.addItem(withTitle: "Open in Tab", action: #selector(contextOpenInTab), keyEquivalent: "")
            menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
            menu.addItem(.separator())
            // Move options
            if q.connectionId != nil {
                menu.addItem(withTitle: "Move to General", action: #selector(contextMoveToGeneral), keyEquivalent: "")
            } else if activeConnectionId != nil {
                let connName = AppStateManager.shared.activeConnection?.name ?? "Connection"
                menu.addItem(withTitle: "Move to \(connName)", action: #selector(contextMoveToConnection), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")

        case .folder:
            menu.addItem(withTitle: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")

        case .section:
            menu.addItem(withTitle: "New Query", action: #selector(contextNewQuery), keyEquivalent: "")
            menu.addItem(withTitle: "New Folder…", action: #selector(contextNewFolder), keyEquivalent: "")
        }
    }
}

// MARK: - Compact Cell View

private class SavedQueryCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init()
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.font = .systemFont(ofSize: 10)
        snippetLabel.textColor = .tertiaryLabelColor
        snippetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        snippetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        labelStack.orientation = .vertical
        labelStack.spacing = 0
        labelStack.alignment = .leading
        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(snippetLabel)
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: NSImage?, tint: NSColor, title: String, snippet: String?) {
        iconView.image = icon
        iconView.contentTintColor = tint
        titleLabel.stringValue = title

        if let snippet {
            snippetLabel.stringValue = snippet
            snippetLabel.isHidden = false
        } else {
            snippetLabel.isHidden = true
        }
    }
}
