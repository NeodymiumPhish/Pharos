import AppIntents
import AppKit
import Foundation
import UniformTypeIdentifiers

// Every intent here runs the app, not a background extension: Pharos keeps its
// connections, its editor tabs and its confirmation sheets in the app process,
// and an intent that skipped them would be a second, weaker way to do the same
// thing. Hence `openAppWhenRun = true` and `@MainActor perform()` throughout.

// MARK: - Open Connection

struct OpenConnectionIntent: AppIntent {

    static var title: LocalizedStringResource = "Open Connection"

    static var description = IntentDescription(
        "Opens a new query tab in Pharos bound to one of your saved connections, and connects it.",
        categoryName: "Connections"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    init() {}

    init(connection: ConnectionEntity) {
        self.connection = connection
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try PharosIntentBridge.showMainWindow()

        let state = AppStateManager.shared
        guard state.connections.contains(where: { $0.id == connection.id }) else {
            throw PharosIntentError.unknownConnection
        }

        let tab = state.createTab()
        state.useConnection(connection.id, forTabId: tab.id)
        try await PharosIntentBridge.ensureConnected(connection.id)

        Log.ui.info("Intent opened connection \(self.connection.id, privacy: .public)")
        return .result(dialog: IntentDialog("Connected to \(connection.name)."))
    }
}

// MARK: - New Query Tab

struct NewQueryTabIntent: AppIntent {

    static var title: LocalizedStringResource = "New Query Tab"

    static var description = IntentDescription(
        "Opens a new query tab in Pharos with the text you supply. The query is not run.",
        categoryName: "Queries"
    )

    static var openAppWhenRun = true

    // Smart quotes and autocorrect would corrupt SQL on its way in.
    @Parameter(title: "SQL", inputOptions: String.IntentInputOptions(
        capitalizationType: .none, multiline: true,
        autocorrect: false, smartQuotes: false, smartDashes: false
    ))
    var sql: String

    init() {}

    init(sql: String) {
        self.sql = sql
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try PharosIntentBridge.showMainWindow()
        let state = AppStateManager.shared
        let tab = state.createTab(sql: sql)
        state.selectTab(id: tab.id)
        Log.ui.info("Intent opened a new query tab")
        // Deliberately NOT run: an intent fires from an automation, where a
        // DELETE would have nothing in front of it. This mirrors the "Run in
        // Pharos" service, which also only opens the text.
        return .result(dialog: IntentDialog("Opened a new query tab."))
    }
}

// MARK: - Open Saved Query

/// `OpenIntent` — not merely an `AppIntent` — because that is what associates a
/// Spotlight result with the entity behind it. Tapping an indexed saved query in
/// Spotlight runs this, so the app opens the right tab without the activity
/// handler having to guess. `OpenIntent` names its parameter `target`.
struct OpenSavedQueryIntent: OpenIntent {

    static var title: LocalizedStringResource = "Open Saved Query"

    static var description = IntentDescription(
        "Opens one of your saved queries in a Pharos query tab. The query is not run.",
        categoryName: "Queries"
    )

    @Parameter(title: "Saved Query")
    var target: SavedQueryEntity

    init() {}

    init(target: SavedQueryEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stored = try SavedQueryOpener.open(id: target.id)
        return .result(dialog: IntentDialog("Opened “\(stored.name)”."))
    }
}

// MARK: - Run Saved Query

struct RunSavedQueryIntent: AppIntent {

    static var title: LocalizedStringResource = "Run Saved Query"

    static var description = IntentDescription(
        "Opens one of your saved queries in Pharos, runs it, and hands back the rows as a CSV file.",
        categoryName: "Queries"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Saved Query")
    var query: SavedQueryEntity

    init() {}

    init(query: SavedQueryEntity) {
        self.query = query
    }

    /// How long to wait for the run to land. It is generous on purpose: the
    /// editor's destructive-SQL confirmation is a sheet, so a `DELETE` started
    /// from a Shortcut waits here until somebody answers it.
    private static let resultTimeout: TimeInterval = 60

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let stored = try await MainActor.run { try SavedQueryOpener.open(id: query.id) }

        // Bind and dial the connection. The tab may already carry one (the
        // sidebar's open path seeds it from the active connection); the saved
        // query's own connection wins only when the tab has none.
        let connectionId = try await MainActor.run { () -> String in
            let state = AppStateManager.shared
            guard let tab = state.tabs.first(where: { $0.savedQueryId == stored.id }) else {
                throw PharosIntentError.unknownSavedQuery
            }
            guard let connId = tab.connectionId ?? stored.connectionId else {
                throw PharosIntentError.noConnectionForQuery
            }
            state.useConnection(connId, forTabId: tab.id)
            state.selectTab(id: tab.id)
            return connId
        }
        try await PharosIntentBridge.ensureConnected(connectionId)

        // The history rows that already exist, so the one this run writes can be
        // told apart. Reading the result back out of history — rather than off
        // the grid — keeps the intent clear of the controller's private result
        // store, and it is the same cached blob a reopened workspace restores.
        let before = Set(Self.recentHistoryIds(connectionId: connectionId))

        // Run through the editor's own Run command, so the variable
        // substitution, the segment parsing and the destructive-SQL
        // confirmation all apply exactly as they do for a keystroke.
        try await MainActor.run {
            let content = try PharosIntentBridge.contentViewController()
            content.menuRunQuery(nil)
        }

        var landed: QueryHistoryEntry?
        let deadline = Date().addingTimeInterval(Self.resultTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let entries = (try? PharosCore.loadQueryHistory(
                filter: QueryHistoryFilter(connectionId: connectionId, limit: 60)
            )) ?? []
            if let fresh = entries.first(where: { !before.contains($0.id) }) {
                landed = fresh
                break
            }
        }
        guard let entry = landed else { throw PharosIntentError.queryTimedOut }

        let rowCount: Int
        let file: IntentFile
        if let data = try? PharosCore.getQueryHistoryResult(id: entry.id) {
            let result = QueryResult.fromHistory(
                data, historyEntryId: entry.id, executionTimeMs: UInt64(entry.executionTimeMs)
            )
            rowCount = result.rowCount
            file = IntentResultCSV.file(from: result, named: stored.name)
        } else {
            // A statement with nothing cached (an UPDATE, or a result too big to
            // cache). The count the history row recorded is still honest; the
            // file is then just the header-less empty CSV.
            rowCount = Int(entry.rowCount ?? 0)
            file = IntentFile(
                data: Data(),
                filename: "\(IntentResultCSV.sanitizedFilename(stored.name)).csv",
                type: .commaSeparatedText
            )
        }

        Log.query.info("Intent ran saved query \(stored.id, privacy: .public), \(rowCount) rows")
        let counted = CountedNounText.phrase(rowCount, "row")
        return .result(value: file, dialog: IntentDialog("“\(stored.name)” returned \(counted)."))
    }

    /// The most recent history ids for a connection — the "before" snapshot.
    private static func recentHistoryIds(connectionId: String) -> [String] {
        let entries = (try? PharosCore.loadQueryHistory(
            filter: QueryHistoryFilter(connectionId: connectionId, limit: 60)
        )) ?? []
        return entries.map(\.id)
    }
}

// MARK: - Export Table

struct ExportTableIntent: AppIntent {

    static var title: LocalizedStringResource = "Export Table"

    static var description = IntentDescription(
        "Opens Pharos's export panel for a table, with the format, columns and destination ready to choose.",
        categoryName: "Tables"
    )

    static var openAppWhenRun = true

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @Parameter(title: "Schema", default: "public")
    var schema: String

    @Parameter(title: "Table")
    var table: String

    init() {}

    init(connection: ConnectionEntity, schema: String, table: String) {
        self.connection = connection
        self.schema = schema
        self.table = table
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await MainActor.run { try PharosIntentBridge.showMainWindow() }
        let connectionId = connection.id
        try await PharosIntentBridge.ensureConnected(connectionId)

        let columns: [ColumnInfo]
        do {
            columns = try await PharosCore.getColumns(
                connectionId: connectionId, schema: schema, table: table
            )
        } catch {
            throw PharosIntentError.columnsUnavailable(error.localizedDescription)
        }

        let schemaName = schema
        let tableName = table
        try await MainActor.run {
            let content = try PharosIntentBridge.contentViewController()
            // The same sheet, built the same way, as the schema browser's
            // "Export Data…" — format, columns and destination are the user's to
            // choose. An intent must not write a file on its own behalf.
            let sheet = ExportDataSheet(schema: schemaName, table: tableName, columns: columns) { options in
                Task {
                    do {
                        let result = try await PharosCore.exportTable(connectionId: connectionId, options: options)
                        Log.ui.info("Intent export wrote \(result.rowsExported) rows")
                    } catch {
                        Log.ui.error("Intent export failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            content.presentAsSheet(sheet)
        }

        return .result(dialog: IntentDialog("Choose the export options for \(schema).\(table)."))
    }
}

// MARK: - Shared open path

/// Opening a saved query in a tab, the one way the sidebar does it.
///
/// The record is re-read from the core first: a Shortcut can hold an entity for
/// weeks, and the SQL and variables the user expects are the stored ones, not
/// the copy the entity was made from.
enum SavedQueryOpener {

    @MainActor
    @discardableResult
    static func open(id: String) throws -> SavedQuery {
        guard let stored = SavedQueryEntity.stored(id: id) else {
            throw PharosIntentError.unknownSavedQuery
        }
        try PharosIntentBridge.showMainWindow()
        // `.openSavedQuery` is what "Open in Tab" posts. Its handler focuses an
        // already-open tab instead of making a second one, which is the
        // behaviour an automation wants too.
        NotificationCenter.default.post(
            name: .openSavedQuery, object: nil, userInfo: ["query": stored]
        )
        Log.ui.info("Intent opened saved query \(id, privacy: .public)")
        return stored
    }
}
