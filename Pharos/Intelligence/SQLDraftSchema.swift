import Foundation

/// What the drafting model is allowed to know about the connected database.
///
/// Names and types. Nothing else. No row, no cell, no estimate of how many
/// rows a table holds — the two tools below can only read this value, so
/// "the model never sees your data" is a property of the TYPE rather than a
/// promise about the prompt text.
///
/// Pure Foundation on purpose: the tools that wrap it live next to a
/// `LanguageModelSession` and cannot be unit-tested, while every string the
/// model actually receives is produced here and is asserted in
/// `PharosTests/SQLDraftPolicyTests.swift`.

// MARK: - Table

/// One table, as the model sees it.
struct TableSummary: Sendable, Equatable {

    let name: String

    /// Column names with their PostgreSQL types, in catalogue order.
    let columns: [(name: String, type: String)]

    init(name: String, columns: [(name: String, type: String)]) {
        self.name = name
        self.columns = columns
    }

    static func == (lhs: TableSummary, rhs: TableSummary) -> Bool {
        lhs.name == rhs.name
            && lhs.columns.count == rhs.columns.count
            && zip(lhs.columns, rhs.columns).allSatisfy { $0.name == $1.name && $0.type == $1.type }
    }
}

// MARK: - Snapshot

/// Every visible table, by schema.
struct SchemaSnapshot: Sendable, Equatable {

    /// Schema name → its tables.
    let schemas: [String: [TableSummary]]

    init(schemas: [String: [TableSummary]] = [:]) {
        self.schemas = schemas
    }

    /// The most tables one `list_tables` answer will name.
    ///
    /// A large database has thousands, and the whole list would fill the
    /// model's context with names it does not need for one question. The
    /// model can narrow by schema instead — that is what the tool's `schema`
    /// argument is for, and the truncation note below says so.
    static let tableLineLimit = 200

    // MARK: - Tool output: list tables

    /// `schema.table`, one per line, sorted, capped at `tableLineLimit`.
    ///
    /// `schema` narrows the answer to one schema; nil answers across all of
    /// them. An unknown schema and an empty database give the same short
    /// sentence — the model reads it and asks a different question.
    func tableLines(schema: String? = nil) -> String {
        let wanted: [String]
        if let schema, !schema.isEmpty {
            let folded = schema.lowercased()
            wanted = schemas.keys.filter { $0.lowercased() == folded }.sorted()
        } else {
            wanted = schemas.keys.sorted()
        }

        var lines: [String] = []
        for schemaName in wanted {
            let tables = schemas[schemaName] ?? []
            for table in tables.map(\.name).sorted() {
                lines.append("\(schemaName).\(table)")
            }
        }

        guard !lines.isEmpty else { return Self.noTables }

        if lines.count > Self.tableLineLimit {
            lines = Array(lines.prefix(Self.tableLineLimit))
            lines.append(Self.truncationNote)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool output: describe a table

    /// `column type`, one per line, in catalogue order.
    ///
    /// `table` is either `schema.table` or a bare name. A bare name is looked
    /// for in `defaultSchema` first — the schema the analyst's tab is pointed
    /// at is the one they meant — and then in the rest, alphabetically, so
    /// the same input always gives the same answer.
    func columnLines(table: String, defaultSchema: String? = nil) -> String {
        guard let found = resolve(table: table, defaultSchema: defaultSchema) else {
            return Self.noSuchTable
        }
        guard !found.columns.isEmpty else { return Self.noColumns }
        return found.columns.map { "\($0.name) \($0.type)" }.joined(separator: "\n")
    }

    /// The table a `describe_table` argument names, or nil.
    func resolve(table: String, defaultSchema: String? = nil) -> TableSummary? {
        let cleaned = table
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard !cleaned.isEmpty else { return nil }

        // A schema prefix is split at the LAST dot, so `public.a.b` asks the
        // `public.a` schema — a table name may not contain a dot, a schema
        // name may.
        if let dot = cleaned.lastIndex(of: ".") {
            let schemaPart = String(cleaned[cleaned.startIndex..<dot])
            let tablePart = String(cleaned[cleaned.index(after: dot)...])
            return find(tablePart, inSchema: schemaPart)
        }

        var order = schemas.keys.sorted()
        if let defaultSchema, let at = order.firstIndex(where: { $0.lowercased() == defaultSchema.lowercased() }) {
            order.insert(order.remove(at: at), at: 0)
        }
        for schemaName in order {
            if let found = find(cleaned, inSchema: schemaName) { return found }
        }
        return nil
    }

    private func find(_ name: String, inSchema schemaName: String) -> TableSummary? {
        let foldedSchema = schemaName.lowercased()
        guard let key = schemas.keys.first(where: { $0.lowercased() == foldedSchema }) else { return nil }
        let foldedTable = name.lowercased()
        return schemas[key]?.first { $0.name.lowercased() == foldedTable }
    }

    // MARK: - Fixed answers

    /// The model is the only reader of these three, so they are not localized
    /// — and none of them echoes the argument back, which keeps "the tool
    /// output holds names and types only" true even for a miss.
    static let noTables = "No tables are visible."
    static let noSuchTable = "No such table."
    static let noColumns = "No columns are visible."
    static let truncationNote = "(list truncated; ask for one schema)"
}
