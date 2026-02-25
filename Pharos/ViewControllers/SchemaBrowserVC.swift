import AppKit

extension Notification.Name {
    static let runQueryInNewTab = Notification.Name("PharosRunQueryInNewTab")
    static let insertTextInEditor = Notification.Name("PharosInsertTextInEditor")
}

// MARK: - SchemaBrowserVC

class SchemaBrowserVC: NSViewController {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var schemaDataSource: SchemaDataSource!
    private var contextMenuHandler: SchemaContextMenu!

    private var rootNodes: [SchemaTreeNode] = [] {
        didSet { schemaDataSource?.rootNodes = rootNodes }
    }
    private var unfilteredRootNodes: [SchemaTreeNode] = []
    private var filterText: String?
    private var activeSchemaFilter: String?
    private var connectionId: String?
    private var refreshedSchemas: Set<String> = []

    override func loadView() {
        let container = NSView()
        self.view = container

        // Outline view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Schema"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.autoresizesOutlineColumn = true
        outlineView.indentationPerLevel = 16

        schemaDataSource = SchemaDataSource(outlineView: outlineView)
        schemaDataSource.delegate = self

        contextMenuHandler = SchemaContextMenu(outlineView: outlineView)
        contextMenuHandler.delegate = self
        outlineView.menu = contextMenuHandler.buildMenu()

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
                let schemas = try await PharosCore.getSchemas(connectionId: connectionId)

                var schemaNodes: [SchemaTreeNode] = []
                for info in schemas {
                    let schemaNode = SchemaTreeNode(.schema(info))
                    schemaNode.addChild(SchemaTreeNode(.loading, parent: schemaNode))
                    schemaNodes.append(schemaNode)
                }

                await MainActor.run {
                    self.unfilteredRootNodes = schemaNodes
                    self.rootNodes = schemaNodes
                    self.outlineView.reloadData()
                    if let pub = self.rootNodes.first(where: { $0.schemaName == "public" }) {
                        self.outlineView.expandItem(pub)
                    }
                }

                // Load ALL schemas' tables concurrently (tables only — columns are lazy)
                await withTaskGroup(of: Void.self) { group in
                    for schemaNode in schemaNodes {
                        group.addTask { [weak self] in
                            await self?.loadTablesForSchema(schemaNode, connectionId: connectionId)
                        }
                    }
                }

                // Auto-refresh row counts for the initially visible schema
                await MainActor.run {
                    if self.unfilteredRootNodes.contains(where: { $0.schemaName == "public" }) {
                        self.refreshRowCounts(for: "public")
                    }
                }
            } catch {
                NSLog("Failed to load schemas: \(error)")
            }
        }
    }

    /// Phase 2: Load tables only (no columns) and display immediately.
    /// Columns are lazy-loaded when a table is expanded.
    private func loadTablesForSchema(_ schemaNode: SchemaTreeNode, connectionId: String) async {
        guard let schemaName = schemaNode.schemaName else { return }
        do {
            let tables = try await PharosCore.getTables(connectionId: connectionId, schema: schemaName)

            await MainActor.run {
                schemaNode.removeAllChildren()
                schemaNode.isLoaded = true

                let tableItems = tables
                    .filter { $0.tableType == .table || $0.tableType == .foreignTable }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let viewItems = tables
                    .filter { $0.tableType == .view }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                for t in tableItems {
                    let tableNode = SchemaTreeNode(.table(t), parent: schemaNode)
                    tableNode.addChild(SchemaTreeNode(.loading, parent: tableNode))
                    // Show row count immediately if pg_class already has one
                    if t.rowCountEstimate != nil {
                        tableNode.hasRowCount = true
                    }
                    schemaNode.addChild(tableNode)
                }
                for v in viewItems {
                    let viewNode = SchemaTreeNode(.view(v), parent: schemaNode)
                    viewNode.addChild(SchemaTreeNode(.loading, parent: viewNode))
                    if v.rowCountEstimate != nil {
                        viewNode.hasRowCount = true
                    }
                    schemaNode.addChild(viewNode)
                }

                self.refreshAfterLoad()
            }
        } catch {
            NSLog("Failed to load tables for schema \(schemaName): \(error)")
        }
    }

    /// Background: ANALYZE unanalyzed tables in a schema, then update row counts.
    /// Uses the purpose-built analyzeSchema command (single FFI call, handles permissions).
    private func refreshRowCounts(for schemaName: String) {
        guard let connectionId, !refreshedSchemas.contains(schemaName) else { return }
        guard let schemaNode = unfilteredRootNodes.first(where: { $0.schemaName == schemaName }) else { return }

        refreshedSchemas.insert(schemaName)

        Task {
            // ANALYZE unanalyzed tables (fire-and-forget — don't block UI update)
            _ = try? await PharosCore.analyzeSchema(connectionId: connectionId, schema: schemaName)

            // Re-fetch tables to get fresh row counts (works even if ANALYZE was a no-op)
            guard let updatedTables = try? await PharosCore.getTables(connectionId: connectionId, schema: schemaName) else {
                NSLog("Failed to refresh row counts for \(schemaName)")
                return
            }

            let countMap = Dictionary(uniqueKeysWithValues: updatedTables.map { ($0.name, $0) })

            await MainActor.run {
                for child in schemaNode.children {
                    switch child.kind {
                    case .table(let info):
                        if let updated = countMap[info.name] {
                            child.kind = .table(updated)
                        }
                        child.hasRowCount = true
                    case .view(let info):
                        if let updated = countMap[info.name] {
                            child.kind = .view(updated)
                        }
                        child.hasRowCount = true
                    default: break
                    }
                }
                self.outlineView.reloadData()
            }
        }
    }

    func clear() {
        connectionId = nil
        activeSchemaFilter = nil
        refreshedSchemas.removeAll()
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
        refreshRowCounts(for: name)
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

    // MARK: - Lazy Column Loading

    private func lazyLoadColumnsIfNeeded(for node: SchemaTreeNode) {
        guard !node.isLoaded else { return }

        switch node.kind {
        case .table, .view: break
        default: return
        }

        guard let connectionId, let schemaName = node.schemaName, let tableName = node.tableName else { return }

        // Mark as loaded to prevent duplicate fetches
        node.isLoaded = true

        Task {
            do {
                let columns = try await PharosCore.getColumns(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    node.removeAllChildren()
                    for col in columns {
                        node.addChild(SchemaTreeNode(.column(col), parent: node))
                    }
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
            } catch {
                await MainActor.run {
                    node.removeAllChildren()
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
                NSLog("Failed to load columns for \(schemaName).\(tableName): \(error)")
            }
        }
    }

}

// MARK: - SchemaDataSourceDelegate

extension SchemaBrowserVC: SchemaDataSourceDelegate {
    func schemaDataSourceItemWillExpand(_ node: SchemaTreeNode) {
        lazyLoadColumnsIfNeeded(for: node)
    }
}

// MARK: - SchemaContextMenuDelegate

extension SchemaBrowserVC: SchemaContextMenuDelegate {
    var contextConnectionId: String? { connectionId }

    func contextMenuDidRequestReload() {
        guard let connectionId else { return }
        loadSchemas(connectionId: connectionId)
    }

    func contextMenuPresentSheet(_ viewController: NSViewController) {
        presentAsSheet(viewController)
    }

    func contextMenuWindow() -> NSWindow? {
        view.window
    }
}
