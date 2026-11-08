import Foundation

/// The tools Pharos offers MCP clients, with their JSON schemas.
///
/// Foundation only: the stdio bridge answers `tools/list` from this same list
/// while Pharos is not reachable, and scripts/test-mcp-protocol.sh checks it.
/// The handlers are `MCPToolHandlers` (app only).
enum MCPToolCatalog {

    struct Tool {
        let name: String
        let title: String
        let description: String
        let properties: [String: JSONValue]
        let required: [String]
        /// Reads only: no card, tab or Session changes.
        let readOnly: Bool
        /// Can change data in a database (behind the confirmation).
        let destructive: Bool

        var inputSchema: JSONValue {
            .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": false,
            ])
        }

        var definition: JSONValue {
            .object([
                "name": .string(name),
                "title": .string(title),
                "description": .string(description),
                "inputSchema": inputSchema,
                "annotations": .object([
                    "title": .string(title),
                    "readOnlyHint": .bool(readOnly),
                    "destructiveHint": .bool(destructive),
                    "idempotentHint": .bool(readOnly),
                    "openWorldHint": .bool(false),
                ]),
            ])
        }
    }

    // MARK: - Limits

    /// Rows a result page holds when the client does not say.
    static let defaultRowLimit = 50
    static let maxRowLimit = 500
    /// Characters of one cell before it is cut, when the client does not say.
    static let defaultMaxCellChars = 200
    static let maxCellChars = 10_000
    /// Roughly how much row text one response carries. A page stops early
    /// rather than hand a model's context a megabyte of rows.
    static let rowByteBudget = 100_000
    /// How long `run_card` waits for the run to end, when the client does not say.
    static let defaultWaitSeconds = 30
    static let maxWaitSeconds = 300

    // MARK: - Schema pieces

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default value: Int) -> JSONValue {
        ["type": "integer", "description": .string(description),
         "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(value)]
    }

    private static let tabId = string("A query tab's id, from list_tabs, create_tab or open_session.")
    private static let cardId = string("A card's id, from list_cards or create_card.")

    private static let pageProperties: [String: JSONValue] = [
        "offset": integer("First row to return (0-based).", minimum: 0, maximum: Int(Int32.max), default: 0),
        "limit": integer("Rows to return.", minimum: 1, maximum: maxRowLimit, default: defaultRowLimit),
        "max_cell_chars": integer("Characters of a cell before it is cut short.",
                                  minimum: 1, maximum: maxCellChars, default: defaultMaxCellChars),
    ]

    // MARK: - The tools

    static let tools: [Tool] = [
        Tool(name: "list_connections", title: "List connections",
             description: "The database connections saved in Pharos: id, name, engine (postgres or duckdb), database, default schema and whether Pharos is connected. Passwords and hosts are not included.",
             properties: [:], required: [], readOnly: true, destructive: false),

        Tool(name: "connect", title: "Connect",
             description: "Connect Pharos to a saved connection and wait for the attempt to finish. Pharos may ask the user for a password.",
             properties: ["connection_id": string("A connection id from list_connections.")],
             required: ["connection_id"], readOnly: false, destructive: false),

        Tool(name: "list_tabs", title: "List open tabs",
             description: "The query tabs open in Pharos, in every window: id, name, connection, the saved Session it is bound to, its card count and whether it has unsaved changes.",
             properties: [:], required: [], readOnly: true, destructive: false),

        Tool(name: "list_saved_sessions", title: "List saved Sessions",
             description: "The saved Sessions (saved queries) in the Pharos library: id, name, folder, connection and when each was last saved.",
             properties: ["search": string("Only Sessions whose name or folder contains this text (case-insensitive).")],
             required: [], readOnly: true, destructive: false),

        Tool(name: "list_workspaces", title: "List recent workspaces",
             description: "Recent workspaces from the Pharos Results History: id, name, connection, number of queries and last activity, newest first.",
             properties: [
                "search": string("Only workspaces whose SQL or name matches this text."),
                "limit": integer("Workspaces to return.", minimum: 1, maximum: 200, default: 25),
             ],
             required: [], readOnly: true, destructive: false),

        Tool(name: "search_history", title: "Search query history",
             description: "Search the queries Pharos has run (Results History), newest first: the SQL, when it ran, how long it took, its row count or its error. search is a full-text match on the SQL. Use status \"failed\" to find errors. An entry's SQL longer than max_sql_chars is cut short.",
             properties: [
                "search": string("Words the SQL must contain (full-text, so whole words and prefixes such as orders*)."),
                "connection_id": string("Only queries run on this connection (from list_connections)."),
                "status": ["type": "string", "enum": ["all", "succeeded", "failed"], "default": "all",
                           "description": "Which runs: all of them, those that succeeded, or those that failed or were cancelled."],
                "limit": integer("Entries to return.", minimum: 1, maximum: 200, default: 25),
                "offset": integer("Entries to skip, for the next page.", minimum: 0, maximum: Int(Int32.max), default: 0),
                "max_sql_chars": integer("Characters of an entry's SQL before it is cut short.",
                                         minimum: 50, maximum: maxCellChars, default: 2_000),
             ],
             required: [], readOnly: true, destructive: false),

        Tool(name: "list_variables", title: "List query variables",
             description: "The query variables a card can use as {{name}}: each one's name, type (literal, text, number, bool, date, timestamp, timestamptz, list_text or list_number) and whether it is global or linked to particular connections. Give connection_id for the variables a tab on that connection sees. Values are included only if the user allows it in Pharos's settings; run_card fills them in either way.",
             properties: ["connection_id": string("Only the variables available on this connection (global ones and those linked to it).")],
             required: [], readOnly: true, destructive: false),

        Tool(name: "open_session", title: "Open a Session or workspace",
             description: "Open a saved Session (with the results saved with it) or a Results History workspace in a Pharos tab, and return the tab. Nothing is run. A Session that is already open is not opened twice.",
             properties: [
                "saved_session_id": string("A saved Session id from list_saved_sessions."),
                "workspace_id": string("A workspace id from list_workspaces. Give this or saved_session_id."),
             ],
             required: [], readOnly: false, destructive: false),

        Tool(name: "create_tab", title: "Create a tab",
             description: "Open a new, empty query tab in Pharos, bound to a connection.",
             properties: [
                "connection_id": string("A connection id from list_connections."),
                "name": string("The tab's name. Default: Pharos names it after the connection."),
             ],
             required: ["connection_id"], readOnly: false, destructive: false),

        Tool(name: "list_cards", title: "List cards",
             description: "The query cards of a tab, top to bottom: id, name, version, whether it is locked, its SQL and notes, its run status (idle, queued, running, awaiting_confirmation) and its last run's summary or error.",
             properties: ["tab_id": tabId], required: ["tab_id"], readOnly: true, destructive: false),

        Tool(name: "get_card", title: "Get a card",
             description: "One card of a tab, as list_cards describes it. Use it to follow a run that run_card left running.",
             properties: ["tab_id": tabId, "card_id": cardId],
             required: ["tab_id", "card_id"], readOnly: true, destructive: false),

        Tool(name: "create_card", title: "Create a card",
             description: "Add a query card holding SQL to a tab and show it in Pharos. Give tab_id to add to an open tab, or connection_id to open a new tab on that connection. The card is not run: call run_card. Write one statement per card; Pharos query variables ({{name}}) are allowed.",
             properties: [
                "sql": string("The card's SQL."),
                "name": string("The card's name: two to four words in Title Case, saying what it returns."),
                "notes": string("Notes about the query, shown beside it."),
                "tab_id": tabId,
                "connection_id": string("Open a new tab on this connection (from list_connections) instead of using tab_id."),
                "after_card_id": string("Insert after this card. Default: at the end."),
             ],
             required: ["sql"], readOnly: false, destructive: false),

        Tool(name: "update_card", title: "Edit a card",
             description: "Change a card's SQL, name or notes. A locked card (an earlier version that has run) cannot change its SQL. Running an edited card that has run before keeps the old version and puts the edit in a new version below it.",
             properties: [
                "tab_id": tabId, "card_id": cardId,
                "sql": string("The new SQL."),
                "name": string("The new name. An empty string clears it."),
                "notes": string("The new notes. An empty string clears them."),
             ],
             required: ["tab_id", "card_id"], readOnly: false, destructive: false),

        Tool(name: "run_card", title: "Run a card",
             description: "Run a card on its tab's connection, wait for it to finish (up to wait_seconds), and return its status with the first page of rows. Statements that change data (INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE, GRANT) are refused unless the user allows them in Pharos's settings, and even then the user confirms each one in Pharos; the status is awaiting_confirmation meanwhile. If the card had run before and its SQL changed, the result goes on a new version of the card: use the card_id this returns.",
             properties: [
                "tab_id": tabId, "card_id": cardId,
                "replace": ["type": "boolean", "default": false,
                            "description": "Replace the card's results in place instead of making a new version after an edit."],
                "wait_seconds": integer("How long to wait for the run to end before returning its status.",
                                        minimum: 0, maximum: maxWaitSeconds, default: defaultWaitSeconds),
                "limit": integer("Rows to return with the result.", minimum: 0, maximum: maxRowLimit, default: 20),
                "max_cell_chars": pageProperties["max_cell_chars"]!,
             ],
             required: ["tab_id", "card_id"], readOnly: false, destructive: true),

        Tool(name: "get_card_result", title: "Get a card's rows",
             description: "A page of the rows a card's last run returned: columns with their types, rows as text or null. Pages through the rows Pharos has loaded (its row limit, Settings ▸ Query); server_has_more says the database has more than that. Long cells are cut to max_cell_chars, and a page stops early when it grows too large: continue from next_offset.",
             properties: ["tab_id": tabId, "card_id": cardId].merging(pageProperties) { a, _ in a },
             required: ["tab_id", "card_id"], readOnly: true, destructive: false),

        Tool(name: "cancel_card", title: "Cancel a run",
             description: "Cancel a card's run: a queued card leaves the queue, a running one is cancelled on the server.",
             properties: ["tab_id": tabId, "card_id": cardId],
             required: ["tab_id", "card_id"], readOnly: false, destructive: false),

        Tool(name: "save_session", title: "Save a tab as a Session",
             description: "Save a tab's cards, and the results they hold, as a saved Session in the Pharos library. A tab already bound to a Session (or a .sql file) is saved in place; otherwise a new Session is created with the name given.",
             properties: [
                "tab_id": tabId,
                "name": string("The new Session's name. Default: the tab's name. Ignored for a tab already bound to a Session."),
                "folder": string("The library folder for a new Session. Default: none."),
             ],
             required: ["tab_id"], readOnly: false, destructive: false),
    ]

    static func tool(named name: String) -> Tool? { tools.first { $0.name == name } }

    static var listResult: JSONValue { ["tools": .array(tools.map(\.definition))] }

    /// What the server tells the client's model about working with Pharos.
    static let instructions = """
    Pharos is a SQL client for PostgreSQL and DuckDB. Its query tabs hold query cards: one SQL statement each, with a name, notes and the result of its last run. \
    Start with list_connections and list_tabs. To query, create_card (with connection_id for a new tab, or tab_id), then run_card, then page through get_card_result. \
    search_history finds queries the user ran before, and list_variables the {{name}} variables a card can use. \
    Everything you do appears in the user's Pharos window. Statements that change data need the user's permission in Pharos and their confirmation for each run. \
    Results are paged and long cells are cut short; prefer aggregates and LIMIT over reading many rows.
    """
}

/// A tool's arguments, read with the errors a model can act on.
struct MCPArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    /// A required, non-blank string.
    func string(_ key: String) throws -> String {
        guard let value = optionalString(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError.invalidArgument("“\(key)” is required.")
        }
        return value
    }

    /// A string, nil when absent or null. A non-string throws.
    func optionalString(_ key: String) -> String? {
        values[key]?.stringValue
    }

    func has(_ key: String) -> Bool {
        guard let v = values[key] else { return false }
        return !v.isNull
    }

    /// A whole number in `range`, `defaultValue` when absent.
    func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[key], !raw.isNull else { return defaultValue }
        guard let n = raw.intValue else { throw MCPToolError.invalidArgument("“\(key)” must be a whole number.") }
        guard range.contains(n) else {
            throw MCPToolError.invalidArgument("“\(key)” must be from \(range.lowerBound) to \(range.upperBound).")
        }
        return n
    }

    func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw = values[key], !raw.isNull else { return defaultValue }
        guard let b = raw.boolValue else { throw MCPToolError.invalidArgument("“\(key)” must be true or false.") }
        return b
    }

    /// Names not in the tool's schema: a misspelt argument should not be
    /// silently ignored.
    func unknownKeys(for tool: MCPToolCatalog.Tool) -> [String] {
        values.keys.filter { tool.properties[$0] == nil }.sorted()
    }
}

/// A tool call that did not do what was asked. The message goes back to the
/// client's model as an `isError` result, so it says what to do instead.
enum MCPToolError: Error, Equatable {
    case invalidArgument(String)
    case notFound(String)
    case refused(String)
    case failed(String)

    var message: String {
        switch self {
        case let .invalidArgument(m), let .notFound(m), let .refused(m), let .failed(m): return m
        }
    }
}
