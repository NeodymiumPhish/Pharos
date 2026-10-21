import AppKit
import UniformTypeIdentifiers

// DuckDB data files: New Table from File… (D3). The work runs as cards, so
// the user sees the SQL, can cancel it, sees its progress and finds it in
// history, and can edit it (delimiter, header, a VIEW instead).
extension ContentViewController {

    /// The tab can make a table from a file: a connected DuckDB tab that is
    /// not open read-only.
    var canMakeTableFromFile: Bool {
        guard let id = session.activeTab?.connectionId,
              let config = stateManager.connections.first(where: { $0.id == id }), config.isDuckDB,
              stateManager.status(for: id) == .connected else { return false }
        return !config.readOnly && stateManager.readOnlyReasons[id] == nil
    }

    /// Query ▸ New Table from File…
    @objc func menuNewTableFromFile(_: Any?) {
        beginNewTableFromFile(url: nil, schema: nil)
    }

    @objc func handleNewTableFromFileRequested(_ notification: Notification) {
        guard ownsBroadcast(notification) else { return }
        beginNewTableFromFile(url: notification.userInfo?["url"] as? URL,
                              schema: notification.userInfo?["schema"] as? String)
    }

    /// Choose the file (unless it was dropped), ask for the table's name,
    /// then add two cards after the focused one and run them in order:
    /// `CREATE TABLE "schema"."name" AS FROM read_csv('<path>')` and a
    /// `SELECT … LIMIT 100` preview. The CREATE card marks the tab for a
    /// catalog refresh (N1), so the navigator and completion show the table.
    func beginNewTableFromFile(url: URL?, schema: String?) {
        guard canMakeTableFromFile, let window = view.window, let tab = session.activeTab else { return }
        let target = schema ?? tab.schemaName ?? DatabaseEngine.duckdb.defaultSchema
        // An attached database (a PostgreSQL attach) is not this file's.
        guard DuckDBAttachRules.attachedDatabase(ofSchema: target) == nil else { return }
        guard let url else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Choose")
            panel.message = String(localized: "Choose a CSV, JSON, Parquet or Excel file to make a table from.")
            panel.allowedContentTypes = DataFiles.dataExtensions.compactMap { UTType(filenameExtension: $0) }
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let chosen = panel.url else { return }
                self?.beginNewTableFromFile(url: chosen, schema: target)
            }
            return
        }
        guard DataFiles.isDataFile(url) else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "New Table from “\(DisplayEscape.escaped(url.lastPathComponent))”")
        alert.informativeText = String(localized: "Pharos adds a card that creates the table in “\(DisplayEscape.escaped(target))”, and a card that shows its first rows. Edit the first card to change how the file is read.")
        let field = NSTextField(string: DataFiles.tableName(for: url))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel(String(localized: "Table name"))
        field.placeholderString = String(localized: "Table name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create Table"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.addNewTableCards(url: url, schema: target, table: name)
        }
    }

    private func addNewTableCards(url: URL, schema: String, table: String) {
        guard let tabId = session.activeTabId else { return }
        let dialect = stateManager.settings.dataImport.dialect
        let encoding: String? = switch dialect.encoding {
        case .utf8, .utf8Bom: nil
        case .utf16le: "utf-16"
        case .latin1: "latin-1"
        }
        guard let create = DataFiles.createTableSQL(for: url, schema: schema, table: table,
                                                    nullString: dialect.nullLiteral, encoding: encoding) else { return }
        let preview = "SELECT * FROM \(DataFiles.quoted(schema)).\(DataFiles.quoted(table)) LIMIT 100"
        var createId = "", previewId = ""
        session.updateTab(id: tabId) { tab in
            let after = tab.document.focusedCardId ?? tab.document.cards.last?.id
            createId = tab.document.insertCard(after: after, sql: create, name: String(localized: "New table \(table)"))
            previewId = tab.document.insertCard(after: createId, sql: preview, name: table)
        }
        if editorPane.showsTab(tabId) {
            editorPane.reloadCards(anchor: previewId)
            editorPane.cardStack.scrollToCard(createId)
        }
        // Run All semantics: the preview runs only when the CREATE worked.
        runBatch([createId, previewId], inTab: tabId)
    }

    // MARK: - D4: keep a DuckDB result

    /// The result's own exports on a DuckDB tab: every row, written by DuckDB
    /// (COPY), and a card that saves the result as a table. Each runs the
    /// query again, on the tab's own connection (its temp tables and search
    /// path apply).
    func duckDBResultExportActions() -> [ResultsCopyExport.EngineAction] {
        guard isDuckDBTab, let result = displayedResult, result.queryResult != nil,
              let statement = Self.lastStatement(of: result.sql),
              RunPathRule.returnsRows(sql: statement, engine: .duckdb) else { return [] }
        let again = String(localized: "Runs the query again. Grid filters, sort and tags do not apply.")
        let cardId = result.id
        let name = session.activeTab?.document.card(cardId)?.name
        var actions = [
            ResultsCopyExport.EngineAction(title: String(localized: "Export All Rows as Parquet…"), help: again) { [weak self] in
                self?.exportAllRows(statement, cardId: cardId, name: name, format: .parquet)
            },
            ResultsCopyExport.EngineAction(title: String(localized: "Export All Rows as Excel…"), help: again) { [weak self] in
                self?.exportAllRows(statement, cardId: cardId, name: name, format: .xlsx)
            },
        ]
        if canMakeTableFromFile {
            actions.append(ResultsCopyExport.EngineAction(
                title: String(localized: "Save Result as Table…"),
                help: String(localized: "Adds a card that creates a table from this query. Edit its name, then run it.")) { [weak self] in
                    self?.addSaveAsTableCard(statement, after: cardId, name: name)
                })
        }
        return actions
    }

    enum EngineExportFormat {
        case parquet, xlsx
        var fileExtension: String { self == .parquet ? "parquet" : "xlsx" }
        var copyOptions: String { self == .parquet ? "FORMAT parquet, COMPRESSION zstd" : "FORMAT xlsx, HEADER true" }
    }

    /// The statement whose rows a card shows: its last one, without the `;`.
    static func lastStatement(of sql: String) -> String? {
        let last = (SQLSegmentParser.parse(sql).last?.sql ?? sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = last.hasSuffix(";") ? String(last.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : last
        return trimmed.isEmpty ? nil : trimmed
    }

    private func exportAllRows(_ statement: String, cardId: String, name: String?, format: EngineExportFormat) {
        guard let window = view.window, let tabId = session.activeTabId else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        let base = DataFiles.identifier(from: name ?? "", fallback: "export")
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let sql = "COPY (\(statement)) TO \(DataFiles.literal(url)) (\(format.copyOptions))"
            self.runGeneratedCard(sql: sql, name: String(localized: "Export \(url.lastPathComponent)"),
                                  inTab: tabId, after: cardId)
        }
    }

    private func addSaveAsTableCard(_ statement: String, after cardId: String, name: String?) {
        guard let tab = session.activeTab else { return }
        let schema = tab.schemaName ?? DatabaseEngine.duckdb.defaultSchema
        let table = DataFiles.identifier(from: name ?? "", fallback: "result")
        let sql = "CREATE TABLE \(DataFiles.quoted(schema)).\(DataFiles.quoted(table)) AS\n\(statement)"
        var newId = ""
        session.updateTab(id: tab.id) { tab in
            newId = tab.document.insertCard(after: cardId, sql: sql, name: String(localized: "Save as \(table)"))
            tab.document.focusedCardId = newId
        }
        editorPane.reloadCards(anchor: newId)
        editorPane.cardStack.scrollToCard(newId)
    }
}
