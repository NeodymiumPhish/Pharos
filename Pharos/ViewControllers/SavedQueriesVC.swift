import AppKit

// MARK: - Saved Query Tree Node

class SavedQueryNode: NSObject {
    enum Kind {
        case folder(String)
        case query(SavedQuery)
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
            return NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        case .query:
            return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Query")
        }
    }

    var isExpandable: Bool {
        if case .folder = kind { return true }
        return false
    }
}

// MARK: - SavedQueriesVC

class SavedQueriesVC: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    private var rootNodes: [SavedQueryNode] = []
    private var allQueries: [SavedQuery] = []

    override func loadView() {
        let container = NSView()
        self.view = container

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SavedQueries"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .default
        outlineView.autoresizesOutlineColumn = true
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

    func reload() {
        do {
            allQueries = try PharosCore.loadSavedQueries()
            rebuildTree()
            outlineView.reloadData()
            // Expand all folders
            for node in rootNodes {
                outlineView.expandItem(node)
            }
        } catch {
            NSLog("Failed to load saved queries: \(error)")
        }
    }

    private func rebuildTree() {
        var folders: [String: SavedQueryNode] = [:]
        var unfiled: [SavedQueryNode] = []

        for query in allQueries {
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

        // Sort folders alphabetically, then append unfiled queries
        rootNodes = folders.keys.sorted().compactMap { folders[$0] } + unfiled
    }

    // MARK: - Actions

    @objc private func doubleClickedRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SavedQueryNode else { return }
        if case .query(let q) = node.kind {
            // TODO: Open query in editor tab
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(q.sql, forType: .string)
        }
    }

    @objc private func contextDelete(_ sender: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        do {
            _ = try PharosCore.deleteSavedQuery(id: q.id)
            reload()
        } catch {
            NSLog("Failed to delete saved query: \(error)")
        }
    }

    @objc private func contextCopySQL(_ sender: Any?) {
        guard let node = clickedNode(), case .query(let q) = node.kind else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(q.sql, forType: .string)
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

        let cellId = NSUserInterfaceItemIdentifier("SavedQueryCell")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .systemFont(ofSize: 13)

            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.imageView?.image = node.icon
        cell.imageView?.contentTintColor = .secondaryLabelColor
        cell.textField?.stringValue = node.title
        return cell
    }
}

// MARK: - NSMenuDelegate

extension SavedQueriesVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        if case .query = node.kind {
            menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
        }
    }
}
