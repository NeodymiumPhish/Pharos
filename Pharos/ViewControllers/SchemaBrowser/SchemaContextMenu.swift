import AppKit
import os

// MARK: - SchemaContextMenu Delegate

protocol SchemaContextMenuDelegate: AnyObject {
    var contextConnectionId: String? { get }
    func contextMenuDidRequestReload()
    func contextMenuPresentSheet(_ viewController: NSViewController)
    func contextMenuWindow() -> NSWindow?
    func contextMenuDidStartImport(connectionId: String, schema: String, table: String)
    func contextMenuDidEndImport(connectionId: String, schema: String, table: String)
}

// MARK: - SchemaContextMenu

@MainActor
class SchemaContextMenu: NSObject, NSMenuDelegate {

    private let outlineView: NSOutlineView
    private let stateManager = AppStateManager.shared

    weak var delegate: SchemaContextMenuDelegate?

    init(outlineView: NSOutlineView) {
        self.outlineView = outlineView
        super.init()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // MARK: - Helpers

    private func clickedNode() -> SchemaTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SchemaTreeNode
    }

    private func tableNameFromNode(_ node: SchemaTreeNode) -> String? {
        tableInfoFromNode(node)?.name
    }

    private func tableInfoFromNode(_ node: SchemaTreeNode) -> TableInfo? {
        switch node.kind {
        case .table(let t), .view(let t), .partition(let t): return t
        default: return nil
        }
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = delegate?.contextMenuWindow() {
            alert.beginSheetModal(for: window)
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        if let window = delegate?.contextMenuWindow() {
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

        guard let window = delegate?.contextMenuWindow() else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }

    // MARK: - Query Actions

    /// SELECT everything `node` holds, `limit` rows of it when a limit is
    /// given, into a named result tab.
    ///
    /// Node-taking and internal so the double-click action of Settings ▸
    /// Navigator runs the SAME query the context menu runs. `false` means the
    /// row is not something you can select from — a schema or a column — so
    /// the caller can fall back to expanding it.
    @discardableResult
    func viewContents(node: SchemaTreeNode, limit: Int?) -> Bool {
        guard let schemaName = node.schemaName, let tableName = tableNameFromNode(node) else { return false }
        var sql = "SELECT * FROM \(quotedQualifiedName(schema: schemaName, table: tableName))"
        var resultName = tableName
        if let limit {
            sql += " LIMIT \(limit)"
            resultName = "\(tableName) (\(formatLimit(limit)))"
        }
        NotificationCenter.default.post(name: .runQueryInCurrentTab, object: nil,
            userInfo: ["sql": sql, "resultName": resultName])
        return true
    }

    @objc private func contextViewAllContents(_: Any?) {
        guard let node = clickedNode() else { return }
        viewContents(node: node, limit: nil)
    }

    @objc private func contextViewContentsWithLimit(_ sender: NSMenuItem) {
        guard let node = clickedNode() else { return }
        viewContents(node: node, limit: sender.tag)
    }

    // MARK: - Clipboard Actions

    @objc private func contextCopyName(_: Any?) {
        guard let node = clickedNode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.title, forType: .string)
    }

    /// Put `node`'s qualified name into the editor at the cursor. Node-taking
    /// and internal for the same reason as `viewContents`.
    @discardableResult
    func insertName(node: SchemaTreeNode) -> Bool {
        guard let schemaName = node.schemaName, let tableName = tableNameFromNode(node) else { return false }
        let qualifiedName = quotedQualifiedName(schema: schemaName, table: tableName)
        NotificationCenter.default.post(name: .insertTextInEditor, object: nil, userInfo: ["text": qualifiedName])
        return true
    }

    @objc private func contextPasteToEditor(_: Any?) {
        guard let node = clickedNode() else { return }
        insertName(node: node)
    }

    // MARK: - Clone / Import / Export

    /// Open `node`'s DDL sheet — how this app describes an object's
    /// structure, and what Settings ▸ Navigator's "Describe" double-click
    /// runs.
    ///
    /// A partition describes as well as a table does, whichever kind it is: an
    /// INHERITS child is an ordinary table that happens to have a parent, and
    /// a declarative partition's DDL names the parent it attaches to and the
    /// bound it takes. Everything else — a schema, a column, the folder
    /// itself — gives `false`, and the caller falls back to expanding the row.
    @discardableResult
    func describe(node: SchemaTreeNode) -> Bool {
        switch node.kind {
        case .table, .partition:
            presentTableDDLSheet(for: node)
            return true
        default:
            return false
        }
    }

    @objc private func contextViewTableDDL(_: Any?) {
        guard let node = clickedNode() else { return }
        presentTableDDLSheet(for: node)
    }

    private func presentTableDDLSheet(for node: SchemaTreeNode) {
        guard let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        Task { [weak self] in
            do {
                let ddl = try await PharosCore.generateTableDDL(
                    connectionId: connectionId, schema: schemaName, table: tableName
                )
                await MainActor.run {
                    guard let self else { return }
                    let sheet = TableDDLSheet(schema: schemaName, table: tableName, ddl: ddl) { [weak self] targetName, includeData, rowScope in
                        Task {
                            do {
                                let options = CloneTableOptions(
                                    sourceSchema: schemaName, sourceTable: tableName,
                                    targetSchema: schemaName, targetTable: targetName,
                                    includeData: includeData, rowScope: rowScope
                                )
                                let result = try await PharosCore.cloneTable(connectionId: connectionId, options: options)
                                await MainActor.run {
                                    // A partitioned copy is the one outcome that
                                    // is not what it looks like: it has the shape
                                    // and none of the partitions, so say so here
                                    // rather than leave it to be discovered.
                                    let msg = CloneOutcomeText.message(
                                        rowsCopied: result.rowsCopied,
                                        partitionBy: ddl.shape.partitionBy
                                    )
                                    self?.showInfoAlert(title: "Clone Successful", message: msg)
                                    self?.delegate?.contextMenuDidRequestReload()
                                }
                            } catch {
                                await MainActor.run {
                                    self?.showErrorAlert(title: "Clone Failed", message: error.localizedDescription)
                                }
                            }
                        }
                    }
                    self.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                await MainActor.run {
                    self?.showErrorAlert(title: "Could Not Load DDL", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func contextImportData(_: Any?) {
        guard let node = clickedNode() else { return }
        presentImportSheet(for: node, preselectedFileURL: nil)
    }

    /// Opens the import sheet for `node`, optionally with the file a drop on
    /// the table already supplied.
    ///
    /// Internal so the drop path (`SchemaDataSource` → `SchemaBrowserVC`) runs
    /// the SAME import as the context menu: one sheet, one progress-tracking
    /// pair, one error alert.
    func presentImportSheet(for node: SchemaTreeNode, preselectedFileURL: URL?) {
        guard let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        let sheet = ImportDataSheet(schema: schemaName, table: tableName,
                                    preselectedFileURL: preselectedFileURL,
                                    settings: AppStateManager.shared.settings.dataImport) { [weak self] options in
            Task { @MainActor in
                self?.delegate?.contextMenuDidStartImport(
                    connectionId: connectionId, schema: schemaName, table: tableName
                )
                defer {
                    self?.delegate?.contextMenuDidEndImport(
                        connectionId: connectionId, schema: schemaName, table: tableName
                    )
                }
                do {
                    let result = try await PharosCore.importCsv(connectionId: connectionId, options: options)
                    self?.showInfoAlert(title: "Import Successful",
                                        message: ImportOutcomeText.message(for: result))
                    self?.delegate?.contextMenuDidRequestReload()
                } catch {
                    self?.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
                }
            }
        }
        delegate?.contextMenuPresentSheet(sheet)
    }

    @objc private func contextExportData(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        // Fetch columns for the column picker
        // Weak all the way down. The sheet STORES its completion closure and
        // calls it whenever the user confirms, which can be long after this
        // task has returned, so that closure must not hold this menu. An
        // implicit strong capture out here would contradict it.
        Task { [weak self] in
            do {
                let columns = try await PharosCore.getColumns(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run { [weak self] in
                    let sheet = ExportDataSheet(schema: schemaName, table: tableName, columns: columns,
                                                settings: AppStateManager.shared.settings.dataExport) { [weak self] options in
                        DataExportSettings.rememberIfAsked(options)
                        Task {
                            do {
                                let result = try await PharosCore.exportTable(connectionId: connectionId, options: options)
                                await MainActor.run {
                                    self?.showInfoAlert(title: "Export Successful",
                                                        message: ExportOutcomeText.message(for: result))
                                }
                            } catch {
                                await MainActor.run {
                                    self?.showErrorAlert(title: "Export Failed", message: error.localizedDescription)
                                }
                            }
                        }
                    }
                    self?.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                Log.schema.error("Failed to load columns for export: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Destructive Actions

    @objc private func contextTruncateTable(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        guard let tableName = tableNameFromNode(node) else { return }

        let execute: () -> Void = { [weak self] in
            Task {
                do {
                    let sql = "TRUNCATE TABLE \(quotedQualifiedName(schema: schemaName, table: tableName))"
                    _ = try await PharosCore.executeStatement(connectionId: connectionId, sql: sql)
                    await MainActor.run {
                        self?.showInfoAlert(title: "Table Truncated", message: DestructiveConfirmationText.truncatedInfoMessage(table: tableName))
                        self?.delegate?.contextMenuDidRequestReload()
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Truncate Failed", message: error.localizedDescription)
                    }
                }
            }
        }

        if stateManager.settings.query.confirmDestructive {
            // TRUNCATE carries no ONLY, so a table other tables inherit from
            // takes its whole tree with it. The dialog has to say so.
            let inherited = tableInfoFromNode(node)?.hasChildTables ?? false
            showDestructiveConfirmation(
                title: DestructiveConfirmationText.truncateConfirmTitle(table: tableName),
                message: DestructiveConfirmationText.truncateConfirmMessage(
                    hasInheritedChildren: inherited),
                buttonTitle: "Truncate",
                onConfirm: execute
            )
        } else {
            execute()
        }
    }

    @objc private func contextDropTable(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        let isView: Bool
        let tableName: String
        switch node.kind {
        // `.partition` is here for an INHERITS child, which is the only kind
        // the menu offers this on — a declarative partition gets no Drop item.
        case .table(let t), .partition(let t): tableName = t.name; isView = false
        case .view(let t): tableName = t.name; isView = true
        default: return
        }
        let objectType = isView ? "VIEW" : "TABLE"
        let objectLabel = isView ? "view" : "table"

        let execute: () -> Void = { [weak self] in
            Task {
                do {
                    let sql = "DROP \(objectType) \(quotedQualifiedName(schema: schemaName, table: tableName))"
                    _ = try await PharosCore.executeStatement(connectionId: connectionId, sql: sql)
                    await MainActor.run {
                        self?.showInfoAlert(title: "\(isView ? "View" : "Table") Dropped", message: DestructiveConfirmationText.droppedInfoMessage(name: tableName))
                        self?.delegate?.contextMenuDidRequestReload()
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
                title: DestructiveConfirmationText.dropConfirmTitle(name: tableName),
                message: "This will permanently delete the \(objectLabel) and all its data. This cannot be undone.",
                buttonTitle: "Drop",
                onConfirm: execute
            )
        } else {
            execute()
        }
    }

    // MARK: - Schema Inspection

    @objc private func contextViewIndexes(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t), .partition(let t): tableName = t.name
        default: return
        }
        Task {
            do {
                let indexes = try await PharosCore.getTableIndexes(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    let sheet = SchemaDetailSheet.forIndexes(schema: schemaName, table: tableName, items: indexes)
                    self.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                Log.schema.error("Failed to load indexes: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc private func contextViewConstraints(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        let tableName: String
        switch node.kind {
        case .table(let t), .view(let t), .partition(let t): tableName = t.name
        default: return
        }
        Task {
            do {
                let constraints = try await PharosCore.getTableConstraints(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    let sheet = SchemaDetailSheet.forConstraints(schema: schemaName, table: tableName, items: constraints)
                    self.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                Log.schema.error("Failed to load constraints: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc private func contextViewFunctions(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
        Task {
            do {
                let functions = try await PharosCore.getSchemaFunctions(connectionId: connectionId, schema: schemaName)
                await MainActor.run {
                    let sheet = SchemaDetailSheet.forFunctions(schema: schemaName, items: functions)
                    self.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                Log.schema.error("Failed to load functions: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .table:
            addTableItems(to: menu)

        case .view:
            // Query actions
            let viewAll = NSMenuItem(title: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")
            viewAll.target = self
            menu.addItem(viewAll)

            menu.addItem(limitSubmenuItem())

            let copyName = NSMenuItem(title: "Copy Table Name", action: #selector(contextCopyName), keyEquivalent: "")
            copyName.target = self
            menu.addItem(copyName)

            let pasteName = NSMenuItem(title: "Paste Name to Query Editor", action: #selector(contextPasteToEditor), keyEquivalent: "")
            pasteName.target = self
            menu.addItem(pasteName)

            // Data operations
            menu.addItem(.separator())

            let exportItem = NSMenuItem(title: "Export Data\u{2026}", action: #selector(contextExportData), keyEquivalent: "")
            exportItem.target = self
            menu.addItem(exportItem)

            // Destructive
            menu.addItem(.separator())

            let dropView = NSMenuItem(title: "Drop View", action: #selector(contextDropTable), keyEquivalent: "")
            dropView.target = self
            menu.addItem(dropView)

            // Inspection
            menu.addItem(.separator())

            let constraints = NSMenuItem(title: "View Constraints", action: #selector(contextViewConstraints), keyEquivalent: "")
            constraints.target = self
            menu.addItem(constraints)

        // The Partitions folder holds two different objects. An INHERITS
        // child is an ordinary table that happens to have a parent — with
        // Group inherited tables OFF the SAME row lists at the top level with
        // the full menu, and a display toggle must not take actions away. A
        // declarative partition is storage owned by its parent and keeps the
        // read-only subset.
        case .partition(let info):
            if info.offersFullTableActions {
                addTableItems(to: menu)
            } else {
                addPartitionItems(to: menu)
            }

        case .schema:
            let functions = NSMenuItem(title: "View Functions", action: #selector(contextViewFunctions), keyEquivalent: "")
            functions.target = self
            menu.addItem(functions)

            menu.addItem(.separator())

            let copyName = NSMenuItem(title: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")
            copyName.target = self
            menu.addItem(copyName)

        case .column:
            let copyName = NSMenuItem(title: "Copy Name", action: #selector(contextCopyName), keyEquivalent: "")
            copyName.target = self
            menu.addItem(copyName)

        default:
            break
        }
    }

    /// The full table menu: query, clipboard, data operations, destructive,
    /// inspection. Shared by a `.table` row and by an INHERITS child inside
    /// the Partitions folder, which is the same object seen from a different
    /// place in the tree.
    private func addTableItems(to menu: NSMenu) {
        // Query actions
        let viewAll = NSMenuItem(title: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")
        viewAll.target = self
        menu.addItem(viewAll)

        menu.addItem(limitSubmenuItem())

        let copyName = NSMenuItem(title: "Copy Table Name", action: #selector(contextCopyName), keyEquivalent: "")
        copyName.target = self
        menu.addItem(copyName)

        let pasteName = NSMenuItem(title: "Paste Name to Query Editor", action: #selector(contextPasteToEditor), keyEquivalent: "")
        pasteName.target = self
        menu.addItem(pasteName)

        // Data operations
        menu.addItem(.separator())

        let viewDDL = NSMenuItem(title: "View Table DDL\u{2026}", action: #selector(contextViewTableDDL), keyEquivalent: "")
        viewDDL.target = self
        menu.addItem(viewDDL)

        let importItem = NSMenuItem(title: "Import Data\u{2026}", action: #selector(contextImportData), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let exportItem = NSMenuItem(title: "Export Data\u{2026}", action: #selector(contextExportData), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        // Destructive
        menu.addItem(.separator())

        let truncate = NSMenuItem(title: "Truncate Table", action: #selector(contextTruncateTable), keyEquivalent: "")
        truncate.target = self
        menu.addItem(truncate)

        let drop = NSMenuItem(title: "Drop Table", action: #selector(contextDropTable), keyEquivalent: "")
        drop.target = self
        menu.addItem(drop)

        // Inspection
        menu.addItem(.separator())

        let indexes = NSMenuItem(title: "View Indexes", action: #selector(contextViewIndexes), keyEquivalent: "")
        indexes.target = self
        menu.addItem(indexes)

        let constraints = NSMenuItem(title: "View Constraints", action: #selector(contextViewConstraints), keyEquivalent: "")
        constraints.target = self
        menu.addItem(constraints)
    }

    /// A declarative partition's menu: everything that reads, nothing that
    /// writes. It is a real, queryable table, so it describes, exports and
    /// inspects — its DDL names the parent it attaches to and the bound it
    /// takes. Truncate, Drop and Import stay off it: they are the parent's to
    /// offer, and dropping a partition silently changes what the parent
    /// returns. The partitioned PARENT is a `.table` node and keeps the lot.
    private func addPartitionItems(to menu: NSMenu) {
        // Query actions
        let viewAll = NSMenuItem(title: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")
        viewAll.target = self
        menu.addItem(viewAll)

        menu.addItem(limitSubmenuItem())

        let copyName = NSMenuItem(title: "Copy Table Name", action: #selector(contextCopyName), keyEquivalent: "")
        copyName.target = self
        menu.addItem(copyName)

        let pasteName = NSMenuItem(title: "Paste Name to Query Editor", action: #selector(contextPasteToEditor), keyEquivalent: "")
        pasteName.target = self
        menu.addItem(pasteName)

        // Data operations
        menu.addItem(.separator())

        let viewDDL = NSMenuItem(title: "View Table DDL\u{2026}", action: #selector(contextViewTableDDL), keyEquivalent: "")
        viewDDL.target = self
        menu.addItem(viewDDL)

        let exportItem = NSMenuItem(title: "Export Data\u{2026}", action: #selector(contextExportData), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        // Inspection
        menu.addItem(.separator())

        let indexes = NSMenuItem(title: "View Indexes", action: #selector(contextViewIndexes), keyEquivalent: "")
        indexes.target = self
        menu.addItem(indexes)

        let constraints = NSMenuItem(title: "View Constraints", action: #selector(contextViewConstraints), keyEquivalent: "")
        constraints.target = self
        menu.addItem(constraints)
    }

    /// The "View Contents (Limit\u{2026})" item, with one row per preset from
    /// Settings ▸ Navigator. The presets used to be the literal
    /// `[10, 100, 1_000, 10_000]` written out at each of the three places
    /// this item was built, which is still the default set.
    private func limitSubmenuItem() -> NSMenuItem {
        let limitItem = NSMenuItem(title: "View Contents (Limit\u{2026})", action: nil, keyEquivalent: "")
        let limitSubmenu = NSMenu()
        for preset in stateManager.settings.navigator.limitPresets {
            let limit = Int(preset)
            let item = NSMenuItem(title: formatLimit(limit), action: #selector(contextViewContentsWithLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            limitSubmenu.addItem(item)
        }
        limitItem.submenu = limitSubmenu
        return limitItem
    }

    private func formatLimit(_ limit: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: limit)) ?? "\(limit)"
    }
}
