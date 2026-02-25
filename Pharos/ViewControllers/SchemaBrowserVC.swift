import AppKit

extension Notification.Name {
    static let runQueryInNewTab = Notification.Name("PharosRunQueryInNewTab")
    static let insertTextInEditor = Notification.Name("PharosInsertTextInEditor")
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
    private var refreshedSchemas: Set<String> = []

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

    @objc private func outlineDoubleClicked(_: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SchemaTreeNode else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if outlineView.isExpandable(item) {
            outlineView.expandItem(item)
        }
    }

    // MARK: - Lazy Column Loading

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SchemaTreeNode else { return }
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

    // MARK: - Context Menu

    private let stateManager = AppStateManager.shared

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // MARK: Context Menu — Query Actions

    @objc private func contextViewAllContents(_: Any?) {
        guard let node = clickedNode(), let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }
        let sql = "SELECT * FROM \"\(schemaName)\".\"\(tableName)\""
        NotificationCenter.default.post(name: .runQueryInNewTab, object: nil, userInfo: ["sql": sql])
    }

    @objc private func contextViewContentsWithLimit(_ sender: NSMenuItem) {
        guard let node = clickedNode(), let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }
        let limit = sender.tag
        let sql = "SELECT * FROM \"\(schemaName)\".\"\(tableName)\" LIMIT \(limit)"
        NotificationCenter.default.post(name: .runQueryInNewTab, object: nil, userInfo: ["sql": sql])
    }

    // MARK: Context Menu — Clipboard Actions

    @objc private func contextCopyName(_: Any?) {
        guard let node = clickedNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.title, forType: .string)
    }

    @objc private func contextPasteToEditor(_: Any?) {
        guard let node = clickedNode(), let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }
        let qualifiedName = "\"\(schemaName)\".\"\(tableName)\""
        NotificationCenter.default.post(name: .insertTextInEditor, object: nil, userInfo: ["text": qualifiedName])
    }

    // MARK: Context Menu — Clone / Import / Export

    @objc private func contextCloneTable(_: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        let sheet = CloneTableSheet(schema: schemaName, table: tableName) { [weak self] targetName, includeData in
            Task {
                do {
                    let options = CloneTableOptions(
                        sourceSchema: schemaName, sourceTable: tableName,
                        targetSchema: schemaName, targetTable: targetName,
                        includeData: includeData
                    )
                    let result = try await PharosCore.cloneTable(connectionId: connectionId, options: options)
                    await MainActor.run {
                        let msg = result.rowsCopied.map { "Table cloned with \($0) rows." } ?? "Table structure cloned."
                        self?.showInfoAlert(title: "Clone Successful", message: msg)
                        self?.loadSchemas(connectionId: connectionId)
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Clone Failed", message: error.localizedDescription)
                    }
                }
            }
        }
        presentAsSheet(sheet)
    }

    @objc private func contextImportData(_: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        let sheet = ImportDataSheet(schema: schemaName, table: tableName) { [weak self] filePath, hasHeaders in
            Task {
                do {
                    let options = ImportCsvOptions(
                        schemaName: schemaName, tableName: tableName,
                        filePath: filePath, hasHeaders: hasHeaders
                    )
                    let result = try await PharosCore.importCsv(connectionId: connectionId, options: options)
                    await MainActor.run {
                        self?.showInfoAlert(title: "Import Successful", message: "\(result.rowsImported) rows imported.")
                        self?.loadSchemas(connectionId: connectionId)
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
                    }
                }
            }
        }
        presentAsSheet(sheet)
    }

    @objc private func contextExportData(_: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        // Fetch columns for the column picker
        Task {
            do {
                let columns = try await PharosCore.getColumns(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    let sheet = ExportDataSheet(schema: schemaName, table: tableName, columns: columns) { [weak self] options in
                        Task {
                            do {
                                let result = try await PharosCore.exportTable(connectionId: connectionId, options: options)
                                await MainActor.run {
                                    self?.showInfoAlert(title: "Export Successful", message: "\(result.rowsExported) rows exported.")
                                }
                            } catch {
                                await MainActor.run {
                                    self?.showErrorAlert(title: "Export Failed", message: error.localizedDescription)
                                }
                            }
                        }
                    }
                    self.presentAsSheet(sheet)
                }
            } catch {
                NSLog("Failed to load columns for export: \(error)")
            }
        }
    }

    // MARK: Context Menu — Destructive Actions

    @objc private func contextTruncateTable(_: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        let execute: () -> Void = { [weak self] in
            Task {
                do {
                    let sql = "TRUNCATE TABLE \"\(schemaName)\".\"\(tableName)\""
                    _ = try await PharosCore.executeStatement(connectionId: connectionId, sql: sql)
                    await MainActor.run {
                        self?.showInfoAlert(title: "Table Truncated", message: "\"\(tableName)\" has been truncated.")
                        self?.loadSchemas(connectionId: connectionId)
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Truncate Failed", message: error.localizedDescription)
                    }
                }
            }
        }

        if stateManager.settings.query.confirmDestructive {
            showDestructiveConfirmation(
                title: "Truncate \"\(tableName)\"?",
                message: "This will permanently delete all rows in the table. This cannot be undone.",
                buttonTitle: "Truncate",
                onConfirm: execute
            )
        } else {
            execute()
        }
    }

    @objc private func contextDropTable(_: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        let isView: Bool
        let tableName: String
        switch node.kind {
        case .table(let t): tableName = t.name; isView = false
        case .view(let t): tableName = t.name; isView = true
        default: return
        }
        let objectType = isView ? "VIEW" : "TABLE"
        let objectLabel = isView ? "view" : "table"

        let execute: () -> Void = { [weak self] in
            Task {
                do {
                    let sql = "DROP \(objectType) \"\(schemaName)\".\"\(tableName)\""
                    _ = try await PharosCore.executeStatement(connectionId: connectionId, sql: sql)
                    await MainActor.run {
                        self?.showInfoAlert(title: "\(isView ? "View" : "Table") Dropped", message: "\"\(tableName)\" has been dropped.")
                        self?.loadSchemas(connectionId: connectionId)
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Drop Failed", message: error.localizedDescription)
                    }
                }
            }
        }

        if stateManager.settings.query.confirmDestructive {
            showDestructiveConfirmation(
                title: "Drop \"\(tableName)\"?",
                message: "This will permanently delete the \(objectLabel) and all its data. This cannot be undone.",
                buttonTitle: "Drop",
                onConfirm: execute
            )
        } else {
            execute()
        }
    }

    // MARK: Context Menu — Schema Inspection (existing)

    @objc private func contextViewIndexes(_: Any?) {
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

    @objc private func contextViewConstraints(_: Any?) {
        guard let node = clickedNode(),
              let connectionId, let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t), .view(let t): tableName = t.name
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

    @objc private func contextViewFunctions(_: Any?) {
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

    // MARK: Context Menu — Helpers

    private func clickedNode() -> SchemaTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SchemaTreeNode
    }

    private func tableNameFromNode(_ node: SchemaTreeNode) -> String? {
        switch node.kind {
        case .table(let t), .view(let t): return t.name
        default: return nil
        }
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        }
    }

    private func showDestructiveConfirmation(title: String, message: String, buttonTitle: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")
        // Style the destructive button
        alert.buttons.first?.hasDestructiveAction = true

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }
}

// MARK: - NSMenuDelegate

extension SchemaBrowserVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .table:
            // Query actions
            menu.addItem(withTitle: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")

            let limitItem = NSMenuItem(title: "View Contents (Limit\u{2026})", action: nil, keyEquivalent: "")
            let limitSubmenu = NSMenu()
            for limit in [10, 100, 1_000, 10_000] {
                let item = NSMenuItem(title: formatLimit(limit), action: #selector(contextViewContentsWithLimit(_:)), keyEquivalent: "")
                item.target = self
                item.tag = limit
                limitSubmenu.addItem(item)
            }
            limitItem.submenu = limitSubmenu
            menu.addItem(limitItem)

            menu.addItem(withTitle: "Copy Table Name", action: #selector(contextCopyName), keyEquivalent: "")
            menu.addItem(withTitle: "Paste Name to Query Editor", action: #selector(contextPasteToEditor), keyEquivalent: "")

            // Data operations
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clone Table DDL\u{2026}", action: #selector(contextCloneTable), keyEquivalent: "")
            menu.addItem(withTitle: "Import Data\u{2026}", action: #selector(contextImportData), keyEquivalent: "")
            menu.addItem(withTitle: "Export Data\u{2026}", action: #selector(contextExportData), keyEquivalent: "")

            // Destructive
            menu.addItem(.separator())
            menu.addItem(withTitle: "Truncate Table", action: #selector(contextTruncateTable), keyEquivalent: "")
            menu.addItem(withTitle: "Drop Table", action: #selector(contextDropTable), keyEquivalent: "")

            // Inspection
            menu.addItem(.separator())
            menu.addItem(withTitle: "View Indexes", action: #selector(contextViewIndexes), keyEquivalent: "")
            menu.addItem(withTitle: "View Constraints", action: #selector(contextViewConstraints), keyEquivalent: "")

        case .view:
            // Query actions
            menu.addItem(withTitle: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")

            let limitItem = NSMenuItem(title: "View Contents (Limit\u{2026})", action: nil, keyEquivalent: "")
            let limitSubmenu = NSMenu()
            for limit in [10, 100, 1_000, 10_000] {
                let item = NSMenuItem(title: formatLimit(limit), action: #selector(contextViewContentsWithLimit(_:)), keyEquivalent: "")
                item.target = self
                item.tag = limit
                limitSubmenu.addItem(item)
            }
            limitItem.submenu = limitSubmenu
            menu.addItem(limitItem)

            menu.addItem(withTitle: "Copy Table Name", action: #selector(contextCopyName), keyEquivalent: "")
            menu.addItem(withTitle: "Paste Name to Query Editor", action: #selector(contextPasteToEditor), keyEquivalent: "")

            // Data operations
            menu.addItem(.separator())
            menu.addItem(withTitle: "Export Data\u{2026}", action: #selector(contextExportData), keyEquivalent: "")

            // Destructive
            menu.addItem(.separator())
            menu.addItem(withTitle: "Drop View", action: #selector(contextDropTable), keyEquivalent: "")

            // Inspection
            menu.addItem(.separator())
            menu.addItem(withTitle: "View Constraints", action: #selector(contextViewConstraints), keyEquivalent: "")

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

    private func formatLimit(_ limit: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: limit)) ?? "\(limit)"
    }
}
