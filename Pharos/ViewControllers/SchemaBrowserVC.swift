import AppKit

// MARK: - Schema Tree Node

/// A node in the schema browser outline view.
/// NSOutlineView requires reference-type items, so this is a class.
class SchemaTreeNode: NSObject {

    enum Kind {
        case schema(SchemaInfo)
        case table(TableInfo)
        case view(TableInfo)
        case column(ColumnInfo)
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
        case .table(let info): return info.name
        case .view(let info): return info.name
        case .column(let info): return info.name
        case .loading: return "Loading…"
        }
    }

    var subtitle: String? {
        switch kind {
        case .table(let info), .view(let info):
            if let count = info.rowCountEstimate {
                return formatCount(count)
            }
            return "– rows"
        case .column(let info):
            var parts = [info.dataType]
            if info.isPrimaryKey { parts.append("PK") }
            if !info.isNullable { parts.append("NOT NULL") }
            return parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    var icon: NSImage? {
        let name: String
        switch kind {
        case .schema: name = "cylinder.split.1x2"
        case .table: name = "tablecells"
        case .view: name = "eye"
        case .column(let info):
            name = info.isPrimaryKey ? "key.fill" : "textformat"
        case .loading: return nil
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: title)
    }

    var tintColor: NSColor {
        switch kind {
        case .column(let info) where info.isPrimaryKey: return .systemYellow
        case .loading: return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    var isExpandable: Bool {
        switch kind {
        case .schema, .table, .view: return true
        default: return false
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

    private var rootNodes: [SchemaTreeNode] = []
    private var unfilteredRootNodes: [SchemaTreeNode] = []
    private var filterText: String?
    private var activeSchemaFilter: String?
    private var connectionId: String?

    override func loadView() {
        let container = NSView()
        self.view = container

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
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))
        outlineView.target = self

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

    func loadSchemas(connectionId: String) {
        self.connectionId = connectionId
        Task {
            do {
                // Step 1: Get all schemas
                let schemas = try await PharosCore.getSchemas(connectionId: connectionId)

                // Step 2: Build schema nodes with loading placeholders
                var schemaNodes: [SchemaTreeNode] = []
                for info in schemas {
                    let schemaNode = SchemaTreeNode(.schema(info))
                    schemaNode.addChild(SchemaTreeNode(.loading, parent: schemaNode))
                    schemaNodes.append(schemaNode)
                }

                // Show initial tree with loading placeholders
                await MainActor.run {
                    self.unfilteredRootNodes = schemaNodes
                    self.rootNodes = schemaNodes
                    self.outlineView.reloadData()
                    if let pub = self.rootNodes.first(where: { $0.schemaName == "public" }) {
                        self.outlineView.expandItem(pub)
                    }
                }

                // Step 3: Eagerly load tables + columns for each schema
                for schemaNode in schemaNodes {
                    guard let schemaName = schemaNode.schemaName else { continue }
                    do {
                        async let tablesResult = PharosCore.getTables(connectionId: connectionId, schema: schemaName)
                        async let columnsResult = PharosCore.getSchemaColumns(connectionId: connectionId, schema: schemaName)

                        var tables = try await tablesResult
                        let allColumns = try await columnsResult

                        // Analyze unanalyzed tables, then reload to get updated row counts
                        let hasUnanalyzed = tables.contains { $0.rowCountEstimate == nil }
                        if hasUnanalyzed {
                            let result = try? await PharosCore.analyzeSchema(connectionId: connectionId, schema: schemaName)
                            if result?.hadUnanalyzed == true {
                                tables = (try? await PharosCore.getTables(connectionId: connectionId, schema: schemaName)) ?? tables
                            }
                        }

                        // Group columns by table name
                        var columnsByTable: [String: [SchemaColumnInfo]] = [:]
                        for col in allColumns {
                            columnsByTable[col.tableName, default: []].append(col)
                        }

                        await MainActor.run {
                            schemaNode.removeAllChildren()
                            schemaNode.isLoaded = true

                            // Tables (regular + foreign) first, then views — each alphabetical
                            let tableItems = tables
                                .filter { $0.tableType == .table || $0.tableType == .foreignTable }
                                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            let viewItems = tables
                                .filter { $0.tableType == .view }
                                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                            for t in tableItems {
                                let tableNode = SchemaTreeNode(.table(t), parent: schemaNode)
                                self.addColumnChildren(to: tableNode, from: columnsByTable[t.name])
                                schemaNode.addChild(tableNode)
                            }

                            for v in viewItems {
                                let viewNode = SchemaTreeNode(.view(v), parent: schemaNode)
                                self.addColumnChildren(to: viewNode, from: columnsByTable[v.name])
                                schemaNode.addChild(viewNode)
                            }

                            self.refreshAfterLoad()
                        }
                    } catch {
                        NSLog("Failed to load tables/columns for schema \(schemaName): \(error)")
                    }
                }
            } catch {
                NSLog("Failed to load schemas: \(error)")
            }
        }
    }

    private func addColumnChildren(to parentNode: SchemaTreeNode, from cols: [SchemaColumnInfo]?) {
        parentNode.isLoaded = true
        guard let cols else { return }
        for c in cols {
            let colInfo = ColumnInfo(
                name: c.name, dataType: c.dataType,
                isNullable: c.isNullable, isPrimaryKey: c.isPrimaryKey,
                ordinalPosition: c.ordinalPosition, columnDefault: c.columnDefault
            )
            parentNode.addChild(SchemaTreeNode(.column(colInfo), parent: parentNode))
        }
    }

    func clear() {
        connectionId = nil
        activeSchemaFilter = nil
        unfilteredRootNodes.removeAll()
        rootNodes.removeAll()
        outlineView.reloadData()
    }

    // MARK: - Filter API (called by SidebarViewController)

    func applyFilter(_ text: String) {
        filterText = text.lowercased()
        rebuildDisplayTree()
    }

    func clearFilter() {
        filterText = nil
        rebuildDisplayTree()
    }

    // MARK: - Schema Filter API (called by SidebarViewController)

    func showSchema(_ name: String) {
        activeSchemaFilter = name
        rebuildDisplayTree()
    }

    func showAllSchemas() {
        activeSchemaFilter = nil
        rebuildDisplayTree()
    }

    /// Rebuild the display tree from unfiltered data, applying schema filter then text filter.
    private func rebuildDisplayTree() {
        // Step 1: Apply schema filter (flatten when single schema selected)
        var nodes: [SchemaTreeNode]
        if let schemaName = activeSchemaFilter {
            if let schemaNode = unfilteredRootNodes.first(where: { $0.schemaName == schemaName }) {
                nodes = schemaNode.children
            } else {
                nodes = []
            }
        } else {
            nodes = unfilteredRootNodes
        }

        // Step 2: Apply text filter on top
        if let filter = filterText, !filter.isEmpty {
            nodes = nodes.compactMap { filterNode($0, text: filter) }
        }

        rootNodes = nodes
        outlineView.reloadData()

        // Collapse everything first — reloadData() preserves expansion state for same-object items
        for node in rootNodes {
            outlineView.collapseItem(node, collapseChildren: true)
        }

        // Step 3: Auto-expand based on context
        if activeSchemaFilter != nil {
            // Flattened: tables/views are already root-level, no expansion needed
        } else if let filter = filterText, !filter.isEmpty {
            expandFilteredItems(rootNodes)
        } else {
            if let pub = rootNodes.first(where: { $0.schemaName == "public" }) {
                outlineView.expandItem(pub)
            }
        }
    }

    /// Recursively filter tree. Returns a filtered copy of the node if it or any descendant matches.
    private func filterNode(_ node: SchemaTreeNode, text: String) -> SchemaTreeNode? {
        let titleMatches = node.title.lowercased().contains(text)

        switch node.kind {
        case .loading:
            return nil

        case .schema:
            let matchingChildren = node.children.compactMap { filterNode($0, text: text) }
            if matchingChildren.isEmpty && !titleMatches { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            for child in matchingChildren { filtered.addChild(child) }
            return filtered

        case .table, .view:
            let matchingChildren = node.children.compactMap { filterNode($0, text: text) }
            if !titleMatches && matchingChildren.isEmpty { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            if titleMatches {
                for child in node.children { filtered.addChild(child) }
            } else {
                for child in matchingChildren { filtered.addChild(child) }
            }
            return filtered

        case .column:
            return titleMatches ? node : nil
        }
    }

    /// Expand schemas and tables so filtered results are visible.
    private func expandFilteredItems(_ nodes: [SchemaTreeNode]) {
        for node in nodes {
            switch node.kind {
            case .schema:
                if !node.children.isEmpty {
                    outlineView.expandItem(node)
                    expandFilteredItems(node.children)
                }
            case .table, .view:
                // Expand table/view if it has matching column children
                if !node.children.isEmpty {
                    outlineView.expandItem(node)
                }
            default:
                break
            }
        }
    }

    /// After loading children into the unfiltered tree, refresh display.
    private func refreshAfterLoad() {
        rebuildDisplayTree()
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

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SchemaTreeNode else { return 22 }
        return node.subtitle != nil ? 32 : 22
    }

    // MARK: - Double Click

    @objc private func outlineDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SchemaTreeNode else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if outlineView.isExpandable(item) {
            outlineView.expandItem(item)
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
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

    @objc private func contextCopyName(_ sender: Any?) {
        guard let node = clickedNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.title, forType: .string)
    }

    @objc private func contextViewIndexes(_ sender: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t): tableName = t.name
        default: return
        }
        Task {
            do {
                let indexes = try await PharosCore.getTableIndexes(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    let sheet = SchemaDetailSheet.forIndexes(schema: schemaName, table: tableName, items: indexes)
                    self.presentAsSheet(sheet)
                }
            } catch {
                NSLog("Failed to load indexes: \(error)")
            }
        }
    }

    @objc private func contextViewConstraints(_ sender: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t): tableName = t.name
        default: return
        }
        Task {
            do {
                let constraints = try await PharosCore.getTableConstraints(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    let sheet = SchemaDetailSheet.forConstraints(schema: schemaName, table: tableName, items: constraints)
                    self.presentAsSheet(sheet)
                }
            } catch {
                NSLog("Failed to load constraints: \(error)")
            }
        }
    }

    @objc private func contextViewFunctions(_ sender: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        Task {
            do {
                let functions = try await PharosCore.getSchemaFunctions(connectionId: connectionId, schema: schemaName)
                await MainActor.run {
                    let sheet = SchemaDetailSheet.forFunctions(schema: schemaName, items: functions)
                    self.presentAsSheet(sheet)
                }
            } catch {
                NSLog("Failed to load functions: \(error)")
            }
        }
    }

    private func clickedNode() -> SchemaTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SchemaTreeNode
    }
}

// MARK: - NSMenuDelegate

extension SchemaBrowserVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .table:
            menu.addItem(withTitle: "Copy SELECT *", action: #selector(contextCopySelectStar), keyEquivalent: "")
            menu.addItem(withTitle: "Copy DDL", action: #selector(contextCopyDDL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "View Indexes", action: #selector(contextViewIndexes), keyEquivalent: "")
            menu.addItem(withTitle: "View Constraints", action: #selector(contextViewConstraints), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")

        case .view:
            menu.addItem(withTitle: "Copy SELECT *", action: #selector(contextCopySelectStar), keyEquivalent: "")
            menu.addItem(withTitle: "Copy DDL", action: #selector(contextCopyDDL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")

        case .schema:
            menu.addItem(withTitle: "View Functions", action: #selector(contextViewFunctions), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")

        case .column:
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
