import AppKit

extension Notification.Name {
    static let runQueryInNewTab = Notification.Name("PharosRunQueryInNewTab")
    static let runQueryInCurrentTab = Notification.Name("PharosRunQueryInCurrentTab")
    static let insertTextInEditor = Notification.Name("PharosInsertTextInEditor")
    static let connectionMetadataRefreshRequested = Notification.Name("PharosConnectionMetadataRefreshRequested")
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

    /// Imports currently in progress: `(connectionId, schema, table)`.
    private var activeImports: Set<ImportKey> = []
    private var importPollTimer: Timer?

    private struct ImportKey: Hashable {
        let connectionId: String
        let schema: String
        let table: String
    }

    /// Per-connection tree state cache for instant tab switching
    private struct CachedTreeState {
        var unfilteredRootNodes: [SchemaTreeNode]
        var refreshedSchemas: Set<String>
    }
    private var treeCaches: [String: CachedTreeState] = [:]

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
        // Fixed row height: switching from the variable-height delegate
        // (heightOfRowByItem) to a fixed value moves NSOutlineView onto its
        // fast path. With variable heights it queries the delegate (and runs
        // layout bookkeeping) for every row on reload — on a connection with
        // 18k+ tables that single query is a ~2-second main-thread block.
        // 38px gives the stacked title + row-count subtitle a small amount of
        // vertical breathing room between rows; at 34 the subtitle of one row
        // sat right against the title of the next.
        outlineView.rowHeight = 38

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

    func loadSchemas(connectionId: String, force: Bool = false) {
        // Cache-hit: restore tree instantly with no FFI calls
        if !force, let cached = treeCaches[connectionId] {
            // Save current tree to cache before switching
            if let currentId = self.connectionId {
                treeCaches[currentId] = CachedTreeState(
                    unfilteredRootNodes: unfilteredRootNodes,
                    refreshedSchemas: refreshedSchemas
                )
            }
            self.connectionId = connectionId
            self.unfilteredRootNodes = cached.unfilteredRootNodes
            self.refreshedSchemas = cached.refreshedSchemas
            rebuildDisplayTree()
            return
        }

        // Save current tree to cache before switching (cache-miss or force path)
        if let currentId = self.connectionId, currentId != connectionId {
            treeCaches[currentId] = CachedTreeState(
                unfilteredRootNodes: unfilteredRootNodes,
                refreshedSchemas: refreshedSchemas
            )
        }

        self.connectionId = connectionId
        if force {
            refreshedSchemas.removeAll()
            treeCaches.removeValue(forKey: connectionId)
        }

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
                    // Only update display if this connection is still active
                    guard self.connectionId == connectionId else { return }
                    self.unfilteredRootNodes = schemaNodes
                    self.rootNodes = schemaNodes
                    self.outlineView.reloadData()
                    // Same threshold as rebuildDisplayTree: do not auto-expand
                    // schemas with thousands of tables — that single expandItem
                    // call blocks the main thread for seconds.
                    if let pub = self.rootNodes.first(where: { $0.schemaName == "public" }),
                       pub.children.count <= Self.autoExpandTableThreshold {
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

                // Store loaded tree in cache using the local schemaNodes
                // (self.unfilteredRootNodes may belong to a different connection now)
                await MainActor.run {
                    self.treeCaches[connectionId] = CachedTreeState(
                        unfilteredRootNodes: schemaNodes,
                        refreshedSchemas: self.connectionId == connectionId
                            ? self.refreshedSchemas : []
                    )
                    // Auto-refresh row counts if still active
                    if self.connectionId == connectionId,
                       schemaNodes.contains(where: { $0.schemaName == "public" }) {
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
            var partitionMap: [PartitionRef] = []
            do {
                partitionMap = try await PharosCore.getPartitionMap(connectionId: connectionId, schema: schemaName)
            } catch {
                NSLog("Failed to load partition map for schema \(schemaName): \(error)")
            }
            var namesByParent: [String: [String]] = [:]
            for ref in partitionMap { namesByParent[ref.parentName, default: []].append(ref.name) }

            await MainActor.run {
                schemaNode.removeAllChildren()
                schemaNode.isLoaded = true

                let tableItems = tables
                    .filter { $0.tableType == .table || $0.tableType == .foreignTable || $0.tableType == .partitionedTable }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let viewItems = tables
                    .filter { $0.tableType == .view }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                for t in tableItems {
                    let tableNode = SchemaTreeNode(.table(t), parent: schemaNode)
                    tableNode.knownPartitionNames = namesByParent[t.name] ?? []
                    if t.isPartitioned {
                        // Partitions group first, then columns — both lazy.
                        let group = SchemaTreeNode(.partitionGroup(t), parent: tableNode)
                        group.addChild(SchemaTreeNode(.loading, parent: group))
                        tableNode.addChild(group)
                    }
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

                // Only refresh display if this connection is still active.
                // During initial load this method fires once per schema; each
                // call used to trigger a full reloadData + collapse-all
                // + re-expand which made the schema browser flicker and
                // collapse user-expanded items as parallel schemas reported
                // in. We now refresh just the affected schema's subtree.
                if self.connectionId == connectionId {
                    self.refreshAfterLoad(schemaNode: schemaNode)
                }
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
        let capturedConnectionId = connectionId

        Task {
            // Single FFI call: analyze returns refreshed table info, avoiding
            // a follow-up getTables round-trip (was ~200–500ms per refresh on
            // large databases).
            guard let analyzeResult = try? await PharosCore.analyzeSchema(connectionId: capturedConnectionId, schema: schemaName) else {
                NSLog("Failed to refresh row counts for \(schemaName)")
                return
            }

            let countMap = Dictionary(uniqueKeysWithValues: analyzeResult.tables.map { ($0.name, $0) })

            await MainActor.run {
                // Update the schema node in-place (reference type — updates cache too)
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

                // Only refresh display if this connection is still active
                if self.connectionId == capturedConnectionId {
                    self.outlineView.reloadData()
                }

                // Update cache for the specific connection
                if var cached = self.treeCaches[capturedConnectionId] {
                    cached.refreshedSchemas.insert(schemaName)
                    self.treeCaches[capturedConnectionId] = cached
                }
            }
        }
    }

    func clear() {
        // Save current tree to cache before clearing display
        // (so switching back to this connection restores instantly)
        if let currentId = connectionId {
            treeCaches[currentId] = CachedTreeState(
                unfilteredRootNodes: unfilteredRootNodes,
                refreshedSchemas: refreshedSchemas
            )
        }
        connectionId = nil
        activeSchemaFilter = nil
        refreshedSchemas.removeAll()
        unfilteredRootNodes.removeAll()
        rootNodes.removeAll()
        outlineView.reloadData()
    }

    /// Clear a specific connection's cached tree (e.g. on disconnect).
    /// If it's the active connection, also clears the display.
    func clearConnection(_ id: String) {
        treeCaches.removeValue(forKey: id)
        if id == connectionId {
            connectionId = nil
            activeSchemaFilter = nil
            refreshedSchemas.removeAll()
            unfilteredRootNodes.removeAll()
            rootNodes.removeAll()
            outlineView.reloadData()
        }
    }

    // MARK: - Import Progress API

    /// Begin tracking an in-progress CSV import. Starts the polling timer if needed.
    func beginImportTracking(connectionId: String, schema: String, table: String) {
        let key = ImportKey(connectionId: connectionId, schema: schema, table: table)
        activeImports.insert(key)
        if let node = findTableNode(connectionId: connectionId, schema: schema, table: table) {
            node.importingRowCount = 0
            reloadDisplayNode(matching: node)
        }
        startImportPollTimer()
    }

    /// Stop tracking an import. Clears the row counter and stops the timer when none remain.
    func endImportTracking(connectionId: String, schema: String, table: String) {
        let key = ImportKey(connectionId: connectionId, schema: schema, table: table)
        activeImports.remove(key)
        if let node = findTableNode(connectionId: connectionId, schema: schema, table: table) {
            node.importingRowCount = nil
            reloadDisplayNode(matching: node)
        }
        if activeImports.isEmpty {
            importPollTimer?.invalidate()
            importPollTimer = nil
        }
    }

    private func startImportPollTimer() {
        guard importPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollImportProgress()
        }
        // .common ensures the timer keeps firing during menu tracking, scrolling, etc.
        RunLoop.main.add(timer, forMode: .common)
        importPollTimer = timer
    }

    private func pollImportProgress() {
        for key in activeImports {
            let count = PharosCore.getImportProgress(
                connectionId: key.connectionId, schema: key.schema, table: key.table
            )
            guard let node = findTableNode(connectionId: key.connectionId, schema: key.schema, table: key.table) else { continue }
            // Only update display if the value changed.
            let newValue: Int64 = count ?? 0
            if node.importingRowCount != newValue {
                node.importingRowCount = newValue
                reloadDisplayNode(matching: node)
            }
        }
    }

    /// Locate the unfiltered table node for the given connection/schema/table.
    /// Only returns a node when the requested connection is the active one (otherwise the
    /// node belongs to a cached, off-screen tree).
    private func findTableNode(connectionId: String, schema: String, table: String) -> SchemaTreeNode? {
        guard self.connectionId == connectionId else { return nil }
        guard let schemaNode = unfilteredRootNodes.first(where: { $0.schemaName == schema }) else { return nil }
        return schemaNode.children.first(where: { $0.tableName == table })
    }

    /// Reload the row that currently displays the same table as `unfilteredNode`.
    /// The displayed `rootNodes` may be filtered copies, so match by schema + table name.
    private func reloadDisplayNode(matching unfilteredNode: SchemaTreeNode) {
        guard let schemaName = unfilteredNode.schemaName,
              let tableName = unfilteredNode.tableName else { return }

        // Walk the displayed tree to find the matching node.
        let candidates: [SchemaTreeNode]
        if activeSchemaFilter != nil {
            // Tables are root-level when a schema is selected.
            candidates = rootNodes
        } else {
            candidates = rootNodes.flatMap { $0.children }
        }
        guard let displayed = candidates.first(where: {
            $0.schemaName == schemaName && $0.tableName == tableName
        }) else { return }

        // Mirror import state onto the displayed (possibly filtered) copy.
        displayed.importingRowCount = unfilteredNode.importingRowCount
        outlineView.reloadItem(displayed)
    }

    // MARK: - Filter API (called by SidebarViewController)

    func applyFilter(_ text: String) {
        let lowered = text.lowercased()
        guard filterText != lowered else { return }
        filterText = lowered
        rebuildDisplayTree()
    }

    func clearFilter() {
        guard filterText != nil else { return }
        filterText = nil
        rebuildDisplayTree()
    }

    // MARK: - Schema Filter API (called by SidebarViewController)

    func showSchema(_ name: String) {
        guard activeSchemaFilter != name else { return }
        activeSchemaFilter = name
        rebuildDisplayTree()
        refreshRowCounts(for: name)
    }

    func showAllSchemas() {
        guard activeSchemaFilter != nil else { return }
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

        // Step 2: Apply text filter on top. We collect the nodes that should
        // be auto-expanded inline during the recursive walk so we don't have
        // to re-traverse the filtered tree afterward (was a separate
        // expandFilteredItems pass — doubled the visit count on large schemas).
        var toExpand: [SchemaTreeNode] = []
        if let filter = filterText, !filter.isEmpty {
            nodes = nodes.compactMap { filterNode($0, text: filter, expandList: &toExpand) }
        }

        rootNodes = nodes
        outlineView.reloadData()

        // reloadData() preserves expansion state for same-object items. We
        // used to collapse-all then re-expand `public` here — that destroyed
        // the user's prior expansion AND paid the full expandItem cost on
        // every rebuild, which is multi-second for schemas with thousands of
        // tables. Preserving prior state makes tab switches feel instant on
        // large databases.

        // Step 3: Auto-expand based on context.
        if activeSchemaFilter != nil {
            // Flattened: tables/views are already root-level, no expansion needed.
        } else if filterText?.isEmpty == false {
            for node in toExpand {
                outlineView.expandItem(node)
            }
        } else if let pub = rootNodes.first(where: { $0.schemaName == "public" }),
                  !outlineView.isItemExpanded(pub),
                  pub.children.count <= Self.autoExpandTableThreshold {
            // Auto-expand `public` as a convenience for typical sized
            // schemas — but skip it for huge ones where expandItem itself
            // would block the main thread for seconds. The user can still
            // expand explicitly by clicking the disclosure triangle.
            outlineView.expandItem(pub)
        }
    }

    /// Maximum direct children a schema may have for `rebuildDisplayTree` to
    /// auto-expand it. Above this threshold, expanding a single NSOutlineView
    /// item becomes a multi-second main-thread operation; users opt in by
    /// clicking the disclosure triangle explicitly.
    private static let autoExpandTableThreshold = 500

    /// Recursively filter tree. Returns a filtered copy of the node if it or
    /// any descendant matches. Appends schemas/tables/views that have visible
    /// children to `expandList` so the caller can expand them in a single
    /// post-walk pass — saves a second recursion over the (potentially huge)
    /// filtered tree.
    private func filterNode(_ node: SchemaTreeNode, text: String, expandList: inout [SchemaTreeNode]) -> SchemaTreeNode? {
        let titleMatches = node.title.lowercased().contains(text)

        switch node.kind {
        case .loading:
            return nil

        case .schema:
            let matchingChildren = node.children.compactMap { filterNode($0, text: text, expandList: &expandList) }
            if matchingChildren.isEmpty && !titleMatches { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            for child in matchingChildren { filtered.addChild(child) }
            if !filtered.children.isEmpty {
                expandList.append(filtered)
            }
            return filtered

        case .table, .view:
            let matchingChildren = node.children.compactMap { filterNode($0, text: text, expandList: &expandList) }
            // Partition-name matches from the lightweight index (group stays collapsed).
            let partitionMatches = node.knownPartitionNames.filter { $0.lowercased().contains(text) }.count
            if !titleMatches && matchingChildren.isEmpty && partitionMatches == 0 { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            filtered.knownPartitionNames = node.knownPartitionNames
            filtered.partitionMatchCount = titleMatches ? 0 : partitionMatches
            if titleMatches {
                for child in node.children { filtered.addChild(child) }
            } else {
                for child in matchingChildren { filtered.addChild(child) }
            }
            // Auto-expand only when there are matching children to reveal. A
            // partition-name-only match leaves children empty (collapsed group's
            // placeholder recurses to nil), so the parent stays visible but collapsed.
            if !filtered.children.isEmpty {
                expandList.append(filtered)
            }
            return filtered

        case .partitionGroup:
            // Container, like .schema: keep it (and expand it) whenever any
            // child partition matches, even though its own title ("Partitions")
            // rarely matches the filter text itself.
            let matchingChildren = node.children.compactMap { filterNode($0, text: text, expandList: &expandList) }
            if matchingChildren.isEmpty { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            for child in matchingChildren { filtered.addChild(child) }
            return filtered

        case .partition:
            return titleMatches ? node : nil

        case .column:
            return titleMatches ? node : nil
        }
    }

    /// Called after a single schema's tables have been spliced into the
    /// unfiltered tree. When no filter is active we reload only that schema's
    /// subtree — outline expansion state for the rest of the browser is
    /// preserved, and parallel schema loads no longer collapse each other's
    /// recently-expanded tables. When a filter is active the cascade is more
    /// complex (the schema might not even be in `rootNodes`), so we fall back
    /// to the full rebuild path.
    private func refreshAfterLoad(schemaNode: SchemaTreeNode) {
        let hasFilter = (filterText?.isEmpty == false) || activeSchemaFilter != nil
        if !hasFilter, rootNodes.contains(where: { $0 === schemaNode }) {
            outlineView.reloadItem(schemaNode, reloadChildren: true)
            // Keep the initial-load auto-expand of the public schema.
            if schemaNode.schemaName == "public" {
                outlineView.expandItem(schemaNode)
            }
            return
        }
        rebuildDisplayTree()
    }

    // MARK: - Lazy Column Loading

    private func lazyLoadColumnsIfNeeded(for node: SchemaTreeNode) {
        guard !node.isLoaded else { return }

        switch node.kind {
        case .table, .view, .partition:
            loadColumns(for: node)
        case .partitionGroup(let parent):
            loadPartitions(for: node, parent: parent)
        default:
            return
        }
    }

    /// Load columns for a `.table` / `.view` / `.partition` node. A partitioned
    /// `.table` or `.partition` node already has a `.partitionGroup` child (added
    /// eagerly when its own parent was populated) — that child must survive this
    /// reload, so we detect it before clearing children and re-add it first.
    private func loadColumns(for node: SchemaTreeNode) {
        guard let connectionId, let schemaName = node.schemaName, let tableName = node.tableName else { return }

        // Mark as loaded to prevent duplicate fetches
        node.isLoaded = true

        let isPartitionedParent: Bool
        switch node.kind {
        case .table(let info), .partition(let info): isPartitionedParent = info.isPartitioned
        default: isPartitionedParent = false
        }
        // Capture the eagerly-added Partitions group (if any) up front so both the
        // success and failure paths can preserve it across removeAllChildren().
        let existingGroup: SchemaTreeNode? = isPartitionedParent
            ? node.children.first(where: {
                if case .partitionGroup = $0.kind { return true }
                return false
            })
            : nil

        Task {
            do {
                let columns = try await PharosCore.getColumns(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    node.removeAllChildren()
                    if let group = existingGroup {
                        node.addChild(group)
                    }
                    for col in columns {
                        node.addChild(SchemaTreeNode(.column(col), parent: node))
                    }
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
            } catch {
                await MainActor.run {
                    node.removeAllChildren()
                    // Preserve the Partitions subtree on failure and allow a retry:
                    // re-add the group and reset isLoaded so a later expand refetches.
                    if let group = existingGroup {
                        node.addChild(group)
                    }
                    node.isLoaded = false
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
                NSLog("Failed to load columns for \(schemaName).\(tableName): \(error)")
            }
        }
    }

    /// Load a partitioned parent's direct child partitions into its `.partitionGroup`
    /// node, ordered by name. Sub-partitioned partitions get their own nested (lazy)
    /// `.partitionGroup` child — the recursive case — handled identically by
    /// `lazyLoadColumnsIfNeeded`/`loadColumns` when that nested group or partition
    /// is itself expanded.
    private func loadPartitions(for group: SchemaTreeNode, parent: TableInfo) {
        guard let connectionId else { return }
        group.isLoaded = true
        Task {
            do {
                let partitions = try await PharosCore.getPartitions(
                    connectionId: connectionId, schema: parent.schemaName, parent: parent.name)
                await MainActor.run {
                    let sorted = PartitionOrdering.sorted(partitions, by: .name)
                    group.removeAllChildren()
                    for p in sorted {
                        let node = SchemaTreeNode(.partition(p), parent: group)
                        node.hasRowCount = p.rowCountEstimate != nil
                        // Sub-partitioned partition → nested Partitions group (recursion).
                        if p.isPartitioned {
                            let sub = SchemaTreeNode(.partitionGroup(p), parent: node)
                            sub.addChild(SchemaTreeNode(.loading, parent: sub))
                            node.addChild(sub)
                        }
                        node.addChild(SchemaTreeNode(.loading, parent: node))
                        group.addChild(node)
                    }
                    self.outlineView.reloadItem(group, reloadChildren: true)
                }
            } catch {
                await MainActor.run {
                    group.removeAllChildren()
                    // Allow a retry: reset isLoaded so re-expanding refetches
                    // instead of stranding an empty group forever.
                    group.isLoaded = false
                    self.outlineView.reloadItem(group, reloadChildren: true)
                }
                NSLog("Failed to load partitions for \(parent.schemaName).\(parent.name): \(error)")
            }
        }
    }

}

// MARK: - SchemaDataSourceDelegate

extension SchemaBrowserVC: SchemaDataSourceDelegate {
    func schemaDataSourceItemWillExpand(_ node: SchemaTreeNode) {
        lazyLoadColumnsIfNeeded(for: node)
    }

    /// Forward partition-relevant selections to the Inspector. Only the three
    /// partition-aware kinds are handled here — a partitioned `.table`, a
    /// `.partitionGroup`, and a `.partition` leaf/sub-parent. Other schema
    /// browser selections (plain tables, views, columns, schemas, or an empty
    /// selection) are intentionally left alone: the inspector may currently be
    /// showing results-grid row detail driven by `ContentViewController`, and
    /// this path has no way to know whether that's still relevant, so it
    /// avoids clobbering it.
    func schemaDataSourceSelectionDidChange(_ node: SchemaTreeNode?) {
        guard let splitVC = parent?.parent as? PharosSplitViewController else { return }
        guard let node else { return }

        switch node.kind {
        case .table(let info) where info.isPartitioned:
            splitVC.inspectorVC.showPartitionedTableDetail(info)
        case .partitionGroup(let parentInfo):
            splitVC.inspectorVC.showPartitionedTableDetail(parentInfo)
        case .partition(let info):
            splitVC.inspectorVC.showPartitionDetail(info, parentName: node.parent?.tableName)
        default:
            break
        }
    }
}

// MARK: - SchemaContextMenuDelegate

extension SchemaBrowserVC: SchemaContextMenuDelegate {
    var contextConnectionId: String? { connectionId }

    func contextMenuDidRequestReload() {
        guard let connectionId else { return }
        loadSchemas(connectionId: connectionId, force: true)
    }

    func contextMenuPresentSheet(_ viewController: NSViewController) {
        presentAsSheet(viewController)
    }

    func contextMenuWindow() -> NSWindow? {
        view.window
    }

    func contextMenuDidStartImport(connectionId: String, schema: String, table: String) {
        beginImportTracking(connectionId: connectionId, schema: schema, table: table)
    }

    func contextMenuDidEndImport(connectionId: String, schema: String, table: String) {
        endImportTracking(connectionId: connectionId, schema: schema, table: table)
    }
}
