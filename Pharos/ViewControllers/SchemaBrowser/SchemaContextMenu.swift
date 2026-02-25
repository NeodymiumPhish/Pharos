import AppKit

// MARK: - SchemaContextMenu Delegate

protocol SchemaContextMenuDelegate: AnyObject {
    var contextConnectionId: String? { get }
    func contextMenuDidRequestReload()
    func contextMenuPresentSheet(_ viewController: NSViewController)
    func contextMenuWindow() -> NSWindow?
}

// MARK: - SchemaContextMenu

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

    // MARK: - Clipboard Actions

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

    // MARK: - Clone / Import / Export

    @objc private func contextCloneTable(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
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
                        self?.delegate?.contextMenuDidRequestReload()
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Clone Failed", message: error.localizedDescription)
                    }
                }
            }
        }
        delegate?.contextMenuPresentSheet(sheet)
    }

    @objc private func contextImportData(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
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
                        self?.delegate?.contextMenuDidRequestReload()
                    }
                } catch {
                    await MainActor.run {
                        self?.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
                    }
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
                    self.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                NSLog("Failed to load columns for export: \(error)")
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
                    let sql = "TRUNCATE TABLE \"\(schemaName)\".\"\(tableName)\""
                    _ = try await PharosCore.executeStatement(connectionId: connectionId, sql: sql)
                    await MainActor.run {
                        self?.showInfoAlert(title: "Table Truncated", message: "\"\(tableName)\" has been truncated.")
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
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
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
                title: "Drop \"\(tableName)\"?",
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
        case .table(let t): tableName = t.name
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
                NSLog("Failed to load indexes: \(error)")
            }
        }
    }

    @objc private func contextViewConstraints(_: Any?) {
        guard let node = clickedNode(),
              let connectionId = delegate?.contextConnectionId, let schemaName = node.schemaName else { return }
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
                    self.delegate?.contextMenuPresentSheet(sheet)
                }
            } catch {
                NSLog("Failed to load constraints: \(error)")
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
                NSLog("Failed to load functions: \(error)")
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else { return }

        switch node.kind {
        case .table:
            // Query actions
            let viewAll = NSMenuItem(title: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")
            viewAll.target = self
            menu.addItem(viewAll)

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

            let copyName = NSMenuItem(title: "Copy Table Name", action: #selector(contextCopyName), keyEquivalent: "")
            copyName.target = self
            menu.addItem(copyName)

            let pasteName = NSMenuItem(title: "Paste Name to Query Editor", action: #selector(contextPasteToEditor), keyEquivalent: "")
            pasteName.target = self
            menu.addItem(pasteName)

            // Data operations
            menu.addItem(.separator())

            let clone = NSMenuItem(title: "Clone Table DDL\u{2026}", action: #selector(contextCloneTable), keyEquivalent: "")
            clone.target = self
            menu.addItem(clone)

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

        case .view:
            // Query actions
            let viewAll = NSMenuItem(title: "View All Contents", action: #selector(contextViewAllContents), keyEquivalent: "")
            viewAll.target = self
            menu.addItem(viewAll)

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

    private func formatLimit(_ limit: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: limit)) ?? "\(limit)"
    }
}
