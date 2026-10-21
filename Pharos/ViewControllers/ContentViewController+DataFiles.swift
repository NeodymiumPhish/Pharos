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
}
