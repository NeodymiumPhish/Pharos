import AppKit

// MARK: - Schema Tree Node

/// A node in the schema browser outline view.
/// NSOutlineView requires reference-type items, so this is a class.
class SchemaTreeNode: NSObject {

    enum Kind {
        // Top level
        case schema(SchemaInfo)
        // Category folders
        case tablesCategory
        case viewsCategory
        case functionsCategory
        // Items
        case table(TableInfo)
        case view(TableInfo)
        case function(FunctionInfo)
        // Sub-categories under table/view
        case columnsCategory
        case indexesCategory
        case constraintsCategory
        // Leaf items
        case column(ColumnInfo)
        case index(IndexInfo)
        case constraint(ConstraintInfo)
        // Placeholder while loading
        case loading
    }

    let kind: Kind
    var children: [SchemaTreeNode] = []
    var isLoaded = false
    weak var parent: SchemaTreeNode?

    init(_ kind: Kind, parent: SchemaTreeNode? = nil) {
        self.kind = kind
        self.parent = parent
    }

    func addChild(_ child: SchemaTreeNode) {
        child.parent = self
        children.append(child)
    }

    func removeAllChildren() {
        children.removeAll()
    }

    // MARK: - Display Properties

    var title: String {
        switch kind {
        case .schema(let info): return info.name
        case .tablesCategory: return "Tables"
        case .viewsCategory: return "Views"
        case .functionsCategory: return "Functions"
        case .table(let info): return info.name
        case .view(let info): return info.name
        case .function(let info): return info.name
        case .columnsCategory: return "Columns"
        case .indexesCategory: return "Indexes"
        case .constraintsCategory: return "Constraints"
        case .column(let info): return info.name
        case .index(let info): return info.name
        case .constraint(let info): return info.name
        case .loading: return "Loading…"
        }
    }

    var subtitle: String? {
        switch kind {
        case .table(let info):
            if let count = info.rowCountEstimate, count >= 0 {
                return formatCount(count)
            }
            return nil
        case .view(let info):
            if let count = info.rowCountEstimate, count >= 0 {
                return formatCount(count)
            }
            return nil
        case .column(let info):
            var parts = [info.dataType]
            if info.isPrimaryKey { parts.append("PK") }
            if !info.isNullable { parts.append("NOT NULL") }
            return parts.joined(separator: ", ")
        case .index(let info):
            var parts = [info.indexType]
            if info.isUnique { parts.append("unique") }
            return parts.joined(separator: ", ")
        case .constraint(let info):
            return info.constraintType
        case .function(let info):
            return "(\(info.argumentTypes)) → \(info.returnType)"
        case .tablesCategory, .viewsCategory, .functionsCategory:
            let count = children.count(where: { if case .loading = $0.kind { return false }; return true })
            return count > 0 ? "\(count)" : nil
        default:
            return nil
        }
    }

    var icon: NSImage? {
        let name: String
        switch kind {
        case .schema: name = "cylinder.split.1x2"
        case .tablesCategory: name = "tablecells"
        case .viewsCategory: name = "eye"
        case .functionsCategory: name = "function"
        case .table: name = "tablecells"
        case .view: name = "eye"
        case .function: name = "function"
        case .columnsCategory: name = "list.bullet"
        case .indexesCategory: name = "bolt.horizontal"
        case .constraintsCategory: name = "lock"
        case .column(let info):
            name = info.isPrimaryKey ? "key.fill" : "textformat"
        case .index: name = "bolt.horizontal"
        case .constraint: name = "lock"
        case .loading: return nil
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: title)
    }

    var tintColor: NSColor {
        switch kind {
        case .column(let info) where info.isPrimaryKey: return .systemYellow
        case .constraint: return .systemOrange
        case .loading: return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .schema, .tablesCategory, .viewsCategory, .functionsCategory,
             .table, .view,
             .columnsCategory, .indexesCategory, .constraintsCategory:
            return true
        default:
            return false
        }
    }

    // MARK: - Navigation helpers

    /// Walk up the tree to find the schema name.
    var schemaName: String? {
        switch kind {
        case .schema(let info): return info.name
        default: return parent?.schemaName
        }
    }

    /// Walk up to find the table/view name.
    var tableName: String? {
        switch kind {
        case .table(let info), .view(let info): return info.name
        default: return parent?.tableName
        }
    }

    private func formatCount(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM rows", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK rows", Double(count) / 1_000)
        } else {
            return "\(count) rows"
        }
    }
}

// MARK: - SchemaBrowserVC

class SchemaBrowserVC: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()

    private var rootNodes: [SchemaTreeNode] = []
    private var connectionId: String?

    override func loadView() {
        let container = NSView()
        self.view = container

        // Search field
        searchField.placeholderString = "Filter"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        // Outline view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Schema"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .default
        outlineView.autoresizesOutlineColumn = true
        outlineView.indentationPerLevel = 16
        outlineView.menu = buildContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Public API

    func loadSchemas(connectionId: String) {
        self.connectionId = connectionId
        Task {
            do {
                let schemas = try await PharosCore.getSchemas(connectionId: connectionId)
                await MainActor.run {
                    self.rootNodes = schemas.map { info in
                        let node = SchemaTreeNode(.schema(info))
                        // Add category stubs with loading placeholders
                        let tables = SchemaTreeNode(.tablesCategory, parent: node)
                        tables.addChild(SchemaTreeNode(.loading, parent: tables))
                        node.addChild(tables)

                        let views = SchemaTreeNode(.viewsCategory, parent: node)
                        views.addChild(SchemaTreeNode(.loading, parent: views))
                        node.addChild(views)

                        let funcs = SchemaTreeNode(.functionsCategory, parent: node)
                        funcs.addChild(SchemaTreeNode(.loading, parent: funcs))
                        node.addChild(funcs)

                        return node
                    }
                    self.outlineView.reloadData()
                    // Auto-expand "public" schema
                    if let pub = self.rootNodes.first(where: { $0.schemaName == "public" }) {
                        self.outlineView.expandItem(pub)
                    }
                }
            } catch {
                NSLog("Failed to load schemas: \(error)")
            }
        }
    }

    func clear() {
        connectionId = nil
        rootNodes.removeAll()
        outlineView.reloadData()
    }

    // MARK: - Lazy Loading

    private func loadChildren(for node: SchemaTreeNode) {
        guard let connectionId, let schemaName = node.schemaName else { return }
        node.isLoaded = true

        switch node.kind {
        case .tablesCategory:
            Task {
                do {
                    let tables = try await PharosCore.getTables(connectionId: connectionId, schema: schemaName)
                    await MainActor.run {
                        node.removeAllChildren()
                        for t in tables where t.tableType == .table {
                            let tableNode = SchemaTreeNode(.table(t), parent: node)
                            let cols = SchemaTreeNode(.columnsCategory, parent: tableNode)
                            cols.addChild(SchemaTreeNode(.loading, parent: cols))
                            tableNode.addChild(cols)
                            let idxs = SchemaTreeNode(.indexesCategory, parent: tableNode)
                            idxs.addChild(SchemaTreeNode(.loading, parent: idxs))
                            tableNode.addChild(idxs)
                            let cons = SchemaTreeNode(.constraintsCategory, parent: tableNode)
                            cons.addChild(SchemaTreeNode(.loading, parent: cons))
                            tableNode.addChild(cons)
                            node.addChild(tableNode)
                        }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                } catch {
                    NSLog("Failed to load tables: \(error)")
                }
            }

        case .viewsCategory:
            Task {
                do {
                    let tables = try await PharosCore.getTables(connectionId: connectionId, schema: schemaName)
                    await MainActor.run {
                        node.removeAllChildren()
                        for t in tables where t.tableType == .view || t.tableType == .foreignTable {
                            let viewNode = SchemaTreeNode(.view(t), parent: node)
                            let cols = SchemaTreeNode(.columnsCategory, parent: viewNode)
                            cols.addChild(SchemaTreeNode(.loading, parent: cols))
                            viewNode.addChild(cols)
                            node.addChild(viewNode)
                        }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                } catch {
                    NSLog("Failed to load views: \(error)")
                }
            }

        case .functionsCategory:
            Task {
                do {
                    let funcs = try await PharosCore.getSchemaFunctions(connectionId: connectionId, schema: schemaName)
                    await MainActor.run {
                        node.removeAllChildren()
                        for f in funcs {
                            node.addChild(SchemaTreeNode(.function(f), parent: node))
                        }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                } catch {
                    NSLog("Failed to load functions: \(error)")
                }
            }

        case .columnsCategory:
            guard let tableName = node.tableName else { return }
            Task {
                do {
                    let cols = try await PharosCore.getColumns(connectionId: connectionId, schema: schemaName, table: tableName)
                    await MainActor.run {
                        node.removeAllChildren()
                        for c in cols {
                            node.addChild(SchemaTreeNode(.column(c), parent: node))
                        }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                } catch {
                    NSLog("Failed to load columns: \(error)")
                }
            }

        case .indexesCategory:
            guard let tableName = node.tableName else { return }
            Task {
                do {
                    let idxs = try await PharosCore.getTableIndexes(connectionId: connectionId, schema: schemaName, table: tableName)
                    await MainActor.run {
                        node.removeAllChildren()
                        for i in idxs {
                            node.addChild(SchemaTreeNode(.index(i), parent: node))
                        }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                } catch {
                    NSLog("Failed to load indexes: \(error)")
                }
            }

        case .constraintsCategory:
            guard let tableName = node.tableName else { return }
            Task {
                do {
                    let cons = try await PharosCore.getTableConstraints(connectionId: connectionId, schema: schemaName, table: tableName)
                    await MainActor.run {
                        node.removeAllChildren()
                        for c in cons {
                            node.addChild(SchemaTreeNode(.constraint(c), parent: node))
                        }
                        self.outlineView.reloadItem(node, reloadChildren: true)
                    }
                } catch {
                    NSLog("Failed to load constraints: \(error)")
                }
            }

        default:
            break
        }
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
        let cell = outlineView.makeView(withIdentifier: cellId, owner: self) as? SchemaTreeCellView
            ?? SchemaTreeCellView(identifier: cellId)

        cell.configure(node: node)
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SchemaTreeNode,
              !node.isLoaded else { return }
        loadChildren(for: node)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SchemaTreeNode else { return 22 }
        return node.subtitle != nil ? 32 : 22
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    @objc private func contextViewRows(_ sender: Any?) {
        guard let node = clickedNode(), let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t), .view(let t): tableName = t.name
        default: return
        }
        let sql = "SELECT * FROM \"\(schemaName)\".\"\(tableName)\" LIMIT 1000"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
        // TODO: Open query tab with this SQL when QueryEditor is implemented
    }

    @objc private func contextCopyDDL(_ sender: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t), .view(let t): tableName = t.name
        default: return
        }
        Task {
            do {
                let ddl = try await PharosCore.generateTableDDL(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ddl, forType: .string)
                }
            } catch {
                NSLog("Failed to generate DDL: \(error)")
            }
        }
    }

    @objc private func contextCopySelectStar(_ sender: Any?) {
        guard let node = clickedNode(), let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t), .view(let t): tableName = t.name
        default: return
        }
        let sql = "SELECT * FROM \"\(schemaName)\".\"\(tableName)\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }

    @objc private func contextCopyName(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.title, forType: .string)
    }

    private func clickedNode() -> SchemaTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SchemaTreeNode
    }

    // MARK: - Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        // TODO: Implement tree filtering
    }
}

// MARK: - NSMenuDelegate

extension SchemaBrowserVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .table, .view:
            menu.addItem(withTitle: "Copy SELECT *", action: #selector(contextCopySelectStar), keyEquivalent: "")
            menu.addItem(withTitle: "Copy DDL", action: #selector(contextCopyDDL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")

        case .column, .index, .constraint, .function, .schema:
            menu.addItem(withTitle: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")

        default:
            break
        }
    }
}

// MARK: - Custom Cell View

private class SchemaTreeCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let labelStack = NSStackView()

    private var singleLineConstraint: NSLayoutConstraint!
    private var multiLineConstraint: NSLayoutConstraint!

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init()
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.font = .systemFont(ofSize: 13)
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .systemFont(ofSize: 10)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        labelStack.orientation = .vertical
        labelStack.spacing = 0
        labelStack.alignment = .leading
        labelStack.addArrangedSubview(primaryLabel)
        labelStack.addArrangedSubview(secondaryLabel)
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(node: SchemaTreeNode) {
        iconView.image = node.icon
        iconView.contentTintColor = node.tintColor
        primaryLabel.stringValue = node.title

        if let sub = node.subtitle {
            secondaryLabel.stringValue = sub
            secondaryLabel.isHidden = false
        } else {
            secondaryLabel.isHidden = true
        }

        if case .loading = node.kind {
            primaryLabel.textColor = .tertiaryLabelColor
            primaryLabel.font = .systemFont(ofSize: 12)
        } else {
            primaryLabel.textColor = .labelColor
            primaryLabel.font = .systemFont(ofSize: 13)
        }
    }
}
