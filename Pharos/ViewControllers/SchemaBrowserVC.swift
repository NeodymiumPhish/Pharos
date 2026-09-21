import AppKit
import Combine
import os

extension Notification.Name {
    static let runQueryInCurrentTab = Notification.Name("PharosRunQueryInCurrentTab")
    static let insertTextInEditor = Notification.Name("PharosInsertTextInEditor")
    static let connectionMetadataRefreshRequested = Notification.Name("PharosConnectionMetadataRefreshRequested")
}

// MARK: - SchemaBrowserVC

class SchemaBrowserVC: NSViewController {

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
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
    private let stateManager = AppStateManager.shared
    private var settingsCancellable: AnyCancellable?
    /// Separate from `settingsCancellable`: this one throws the metadata
    /// cache away, which the sort modes must never do.
    private var systemSchemasCancellable: AnyCancellable?

    /// Imports currently in progress: `(connectionId, schema, table)`.
    private var activeImports: Set<ImportKey> = []
    private var importPollTimer: Timer?

    private struct ImportKey: Hashable {
        let connectionId: String
        let schema: String
        let table: String
    }

    /// The settings that change the SHAPE of the tree, and so need it built
    /// again. Nothing else in `AppSettings` belongs here: the double-click
    /// action, the limit presets and the auto-expand pair are all read where
    /// they are used, so changing one must not throw the tree away.
    private struct TreeShape: Equatable {
        let showLeafPartitions: Bool
        let showSystemSchemas: Bool
        let schemaSort: SchemaSortMode
        let objectSort: ObjectSortMode
        let partitionSort: PartitionSortMode
        let inheritanceGrouping: Bool

        init(_ settings: AppSettings) {
            showLeafPartitions = settings.showLeafPartitions
            showSystemSchemas = settings.navigator.showSystemSchemas
            schemaSort = settings.navigator.schemaSort
            objectSort = settings.navigator.objectSort
            partitionSort = settings.navigator.partitionSort
            inheritanceGrouping = settings.navigator.inheritanceGrouping
        }
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
        // A system source list: the rounded selection, the sidebar insets and
        // the row height the user picked in System Settings > Appearance >
        // Sidebar icon size, instead of a height this app invented.
        outlineView.style = .sourceList
        // `.default` asks AppKit for that standard height. It is still a FIXED
        // height — the variable-height delegate (`heightOfRowByItem`) is what
        // costs: it is queried for every row on reload, and on a connection
        // with 18k+ tables that single query was a ~2-second main-thread block.
        // The rows are one line each now (see SchemaTreeCellView), so nothing
        // needs a custom height any more.
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
        // Transparent, so the sidebar's own material is the only thing behind
        // the list. The clip view is a separate NSClipView with its own
        // background flag — setting the scroll view alone still leaves an
        // opaque plate. Row selection and group rows are drawn by
        // NSTableRowView and are unaffected.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        outlineView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(emptyState)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyState.topAnchor.constraint(equalTo: container.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        updateEmptyState()
    }

    /// Show the "no connection" state whenever there is no connection to browse.
    /// A connection that simply has no matching rows is NOT this state — the
    /// filter field is still working and the user can see that it is.
    private func updateEmptyState() {
        if connectionId == nil {
            emptyState.show(
                symbol: "cylinder.split.1x2",
                title: String(localized: "No Connection"),
                message: String(localized: "Connect a tab to browse its schema.")
            )
        } else {
            emptyState.isHidden = true
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Refresh the tree when a setting that changes its SHAPE changes:
        // "Show Leaf Partitions" adds or removes the Partitions group, and
        // the three Settings ▸ Navigator sort modes change the order rows
        // are built in. `.map` + `.removeDuplicates()` keeps unrelated
        // settings changes (theme, editor font, the Navigator's own
        // double-click action — read at click time) from reloading;
        // `.dropFirst()` skips the initial value delivered on subscribe.
        settingsCancellable = AppStateManager.shared.$settings
            .map(TreeShape.init)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let cid = self.connectionId else { return }
                self.loadSchemas(connectionId: cid, force: true)
            }

        // "Show system schemas" changes what the SERVER returns, not only how
        // the tree is drawn, so the tree's own `force: true` above is not
        // enough: `MetadataCache` holds a second copy of the schema list —
        // the one the schema pull-down and the completion list read — and it
        // would keep answering with the old answer until the connection
        // closed. Throw it away and fetch again, exactly as the Advanced
        // pane's "Clear Metadata Cache" button does.
        systemSchemasCancellable = AppStateManager.shared.$settings
            .map(\.navigator.showSystemSchemas)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MetadataCache.shared.clearAll()
                guard let self, let cid = self.connectionId else { return }
                MetadataCache.shared.load(connectionId: cid, force: true)
            }
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
            updateEmptyState()
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
        updateEmptyState()
        if force {
            refreshedSchemas.removeAll()
            treeCaches.removeValue(forKey: connectionId)
        }

        Task {
            do {
                let fetched = try await PharosCore.getSchemas(connectionId: connectionId)
                // Settings ▸ Navigator ▸ Order schemas by. The server already
                // returns them by name (`ORDER BY schema_name`), so the
                // default mode re-states that order rather than changing it.
                let schemas = await MainActor.run { () -> [SchemaInfo] in
                    let byName = Dictionary(fetched.map { ($0.name, $0) },
                                            uniquingKeysWith: { first, _ in first })
                    let order = NavigatorOrdering.sortedSchemas(
                        fetched.map(\.name),
                        by: self.stateManager.settings.navigator.schemaSort,
                        defaultSchema: self.defaultSchemaName(for: connectionId))
                    return order.compactMap { byName[$0] }
                }

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
                    // Through rebuildDisplayTree, NOT by assigning rootNodes
                    // directly. A schema may already be pinned: the sidebar
                    // pins it as soon as the connection reports its schema,
                    // which is usually BEFORE this load returns. Assigning the
                    // unfiltered nodes here put every schema back on screen and
                    // the pin was only honoured again when that schema's tables
                    // happened to stream in. rebuildDisplayTree applies the
                    // pinned schema and the text filter, and carries the same
                    // auto-expand of `public` with the same size threshold.
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
                Log.schema.error("Failed to load schemas: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Phase 2: Load tables only (no columns) and display immediately.
    /// Columns are lazy-loaded when a table is expanded.
    private func loadTablesForSchema(_ schemaNode: SchemaTreeNode, connectionId: String) async {
        guard let schemaName = schemaNode.schemaName else { return }
        let showLeaf = await MainActor.run { self.stateManager.settings.showLeafPartitions }
        do {
            let tables = try await PharosCore.getTables(connectionId: connectionId, schema: schemaName)
            var partitionMap: [PartitionRef] = []
            if showLeaf {
                do {
                    partitionMap = try await PharosCore.getPartitionMap(connectionId: connectionId, schema: schemaName)
                } catch {
                    Log.schema.error("Failed to load partition map for schema \(schemaName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            var namesByParent: [String: [String]] = [:]
            for ref in partitionMap { namesByParent[ref.parentName, default: []].append(ref.name) }

            await MainActor.run {
                schemaNode.removeAllChildren()
                schemaNode.isLoaded = true

                // Settings ▸ Navigator ▸ Order objects by. `NavigatorOrdering`
                // holds the rules and is tested on its own; the default mode,
                // `kindThenName`, is the tables-then-views-each-by-name order
                // the two separate sorted filters used to produce here.
                let objects = tables.filter {
                    $0.tableType == .table || $0.tableType == .foreignTable
                        || $0.tableType == .partitionedTable || $0.tableType == .view
                }
                // A name is unique across tables and views in one Postgres
                // schema — they share a namespace — so the name is a safe key.
                let byName = Dictionary(objects.map { ($0.name, $0) },
                                        uniquingKeysWith: { first, _ in first })
                let ordered = NavigatorOrdering.sorted(
                    objects.map {
                        NavigatorOrdering.Object(
                            name: $0.name,
                            kindRank: $0.tableType == .view ? 1 : 0,
                            sizeBytes: $0.totalSizeBytes,
                            rowEstimate: $0.rowCountEstimate)
                    },
                    by: self.stateManager.settings.navigator.objectSort
                ).compactMap { byName[$0.name] }

                for t in ordered {
                    if t.tableType == .view {
                        let viewNode = SchemaTreeNode(.view(t), parent: schemaNode)
                        viewNode.addChild(SchemaTreeNode(.loading, parent: viewNode))
                        if t.rowCountEstimate != nil {
                            viewNode.hasRowCount = true
                        }
                        schemaNode.addChild(viewNode)
                        continue
                    }
                    let tableNode = SchemaTreeNode(.table(t), parent: schemaNode)
                    if showLeaf {
                        tableNode.knownPartitionNames = namesByParent[t.name] ?? []
                    }
                    if t.isPartitioned && showLeaf {
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
            Log.schema.error("Failed to load tables for schema \(schemaName, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                Log.schema.warning("Failed to refresh row counts for \(schemaName, privacy: .public)")
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
                    // Preserve the user's selection: this background row-count refresh
                    // fires once per schema during the first seconds after connecting,
                    // and a bare reloadData() cleared any table the user had just
                    // clicked (selection only "stuck" once loading settled).
                    self.reloadPreservingSelection {
                        self.outlineView.reloadData()
                    }
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
        updateEmptyState()
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
            updateEmptyState()
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
        } else if let target = rootNodes.first(where: { $0.schemaName == autoExpandSchemaName }),
                  !outlineView.isItemExpanded(target),
                  NavigatorOrdering.shouldAutoExpand(
                      childCount: target.children.count,
                      enabled: stateManager.settings.navigator.autoExpandDefaultSchema,
                      threshold: stateManager.settings.navigator.autoExpandThreshold) {
            // Open the default schema as a convenience for typical sized
            // schemas — but skip it for huge ones where expandItem itself
            // would block the main thread for seconds. The user can still
            // expand explicitly by clicking the disclosure triangle.
            // Settings ▸ Navigator holds both the switch and the ceiling; the
            // ceiling's default, 500, is the constant that used to live here.
            outlineView.expandItem(target)
        }
    }

    /// The schema `rebuildDisplayTree` opens for the user: the connection's
    /// own default schema, or `public`. The same fallback the rest of the app
    /// uses for a connection that names none (`AppStateManager`).
    private var autoExpandSchemaName: String {
        defaultSchemaName(for: connectionId) ?? "public"
    }

    /// The `defaultSchema` recorded on a connection, or nil.
    private func defaultSchemaName(for connectionId: String?) -> String? {
        guard let connectionId else { return nil }
        return stateManager.connections.first { $0.id == connectionId }?.defaultSchema
    }

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
    /// unfiltered tree. With no filter we reload only that schema's subtree, so
    /// expansion state elsewhere is preserved and parallel schema loads don't
    /// collapse each other's recently-expanded tables. With a schema filter
    /// pinned we only rebuild for the pinned schema (other schemas aren't shown);
    /// with a text filter we rebuild so newly-loaded matches surface. Rebuilds
    /// preserve the current selection.
    private func refreshAfterLoad(schemaNode: SchemaTreeNode) {
        // When a single schema is pinned (schema filter active), only that schema's
        // tables are on screen. Background table-loads for OTHER schemas change
        // nothing visible, so a full rebuildDisplayTree() for each is both wasted
        // work and actively harmful: its reloadData() wiped the user's selection
        // every time another schema streamed in. On databases with many schemas
        // (per-tenant UUID schemas plus pg_temp_*), that kept a just-clicked table
        // from ever staying selected for several seconds. Only rebuild for the
        // schema actually being displayed, and preserve selection when we do.
        if let active = activeSchemaFilter {
            if schemaNode.schemaName == active {
                reloadPreservingSelection { rebuildDisplayTree() }
            }
            return
        }
        let hasTextFilter = filterText?.isEmpty == false
        if !hasTextFilter, rootNodes.contains(where: { $0 === schemaNode }) {
            outlineView.reloadItem(schemaNode, reloadChildren: true)
            // Keep the initial-load auto-expand of the public schema.
            if schemaNode.schemaName == "public" {
                outlineView.expandItem(schemaNode)
            }
            return
        }
        // Text filter active: a newly-loaded schema may contain matching tables,
        // so a rebuild is needed to surface them — but keep the selection.
        reloadPreservingSelection { rebuildDisplayTree() }
    }

    /// Run a reload that would otherwise clear the outline's selection, then
    /// restore the previously selected node by object identity. Only re-selects
    /// when the reload actually dropped the selection, so selection-preserving
    /// reloads (e.g. `reloadItem`) don't fire a redundant change notification.
    private func reloadPreservingSelection(_ reload: () -> Void) {
        let selectedRow = outlineView.selectedRow
        let selectedItem = selectedRow >= 0 ? outlineView.item(atRow: selectedRow) : nil
        reload()
        guard let item = selectedItem, outlineView.selectedRow < 0 else { return }
        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
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
                Log.schema.error("Failed to load columns for \(schemaName, privacy: .public).\(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                    let showLeaf = self.stateManager.settings.showLeafPartitions
                    // Settings ▸ Navigator ▸ Order partitions by. `.name` was
                    // hard-coded here, and is the default.
                    let sorted = PartitionOrdering.sorted(
                        partitions, by: self.stateManager.settings.navigator.partitionSort)
                    group.removeAllChildren()
                    for p in sorted {
                        let node = SchemaTreeNode(.partition(p), parent: group)
                        node.hasRowCount = p.rowCountEstimate != nil
                        // Sub-partitioned partition → nested Partitions group (recursion).
                        if p.isPartitioned && showLeaf {
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
                Log.schema.error("Failed to load partitions for \(parent.schemaName, privacy: .public).\(parent.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

}

// MARK: - SchemaDataSourceDelegate

extension SchemaBrowserVC: SchemaDataSourceDelegate {
    func schemaDataSourceItemWillExpand(_ node: SchemaTreeNode) {
        lazyLoadColumnsIfNeeded(for: node)
    }

    /// Settings ▸ Navigator ▸ On double-click. Every action but `expand` is
    /// run by `SchemaContextMenu`, so a double-click and the matching menu
    /// item cannot drift apart. A `false` here — the action is `expand`, or
    /// the row is a schema or a column the action means nothing for — leaves
    /// the disclosure behaviour to the outline view.
    func schemaDataSourceDidDoubleClick(_ node: SchemaTreeNode) -> Bool {
        let navigator = stateManager.settings.navigator
        switch navigator.doubleClickAction {
        case .expand:
            return false
        case .viewContents:
            // The row limit is Settings ▸ Query's, so one number governs the
            // limit wherever the app applies one.
            let limit = navigator.viewContentsUsesRowLimit
                ? Int(stateManager.settings.query.defaultLimit) : nil
            return contextMenuHandler.viewContents(node: node, limit: limit)
        case .describe:
            return contextMenuHandler.describe(node: node)
        case .insertName:
            return contextMenuHandler.insertName(node: node)
        }
    }

    /// Forward every schema browser selection to the Inspector, rendering
    /// detail appropriate to the node's kind (partitioned table, plain
    /// table/view, partition group/leaf, column) or clearing it for a
    /// schema. A `nil` selection (nothing selected) is left alone: the
    /// inspector may currently be showing results-grid row detail driven by
    /// `ContentViewController`, and this path has no way to know whether
    /// that's still relevant, so it avoids clobbering it.
    func schemaDataSourceSelectionDidChange(_ node: SchemaTreeNode?) {
        guard let splitVC = parent?.parent as? PharosSplitViewController else { return }
        guard let node else { return }

        switch node.kind {
        case .table(let info) where info.isPartitioned:
            splitVC.inspectorVC.showPartitionedTableDetail(info)
        case .table(let info), .view(let info):
            splitVC.inspectorVC.showTableDetail(info)
        case .partitionGroup(let parentInfo):
            splitVC.inspectorVC.showPartitionedTableDetail(parentInfo)
        case .partition(let info):
            splitVC.inspectorVC.showPartitionDetail(info, parentName: node.parent?.tableName)
        case .column(let info):
            splitVC.inspectorVC.showColumnDetail(info, parentName: node.parent?.tableName)
        case .schema:
            splitVC.inspectorVC.showNoSelection()
        case .loading:
            break
        }
    }

    var schemaDataSourceConnectionId: String? { connectionId }

    /// A CSV/TSV dropped on a table opens the ordinary import sheet with that
    /// file already chosen — the drop replaces the "Choose…" panel, nothing
    /// else about the import.
    func schemaDataSourceDidDropFile(_ url: URL, onTable node: SchemaTreeNode) {
        contextMenuHandler.presentImportSheet(for: node, preselectedFileURL: url)
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
