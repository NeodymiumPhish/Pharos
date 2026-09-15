import Foundation
import FoundationModels

/// "Describe the query": a sentence in, one `SELECT` out.
///
/// The model is not told the schema up front. It is given two tools and asked
/// to look names up, which keeps the prompt short on a large database and —
/// the part that matters — means every name in the draft came from the
/// catalogue rather than from the model's imagination.
///
/// Both tools read a `SchemaSnapshot`, which holds names and types. No row
/// value, no cell, no row count can reach the model through this feature,
/// because there is no path by which one could enter the snapshot.
///
/// Nothing here runs SQL. `draft` returns text; `SQLDraftPolicy` reviews it
/// and the analyst decides.

// MARK: - The answer

@Generable
struct SQLDraft {

    @Guide(description: "one PostgreSQL SELECT statement; no DDL, no DML")
    var sql: String

    @Guide(description: "one sentence on assumptions made")
    var note: String
}

// MARK: - Tools

/// `list_tables` — what is there.
struct ListTablesTool: Tool {

    let name = "list_tables"
    let description = "Lists the tables in the connected database, one 'schema.table' per line."

    let snapshot: SchemaSnapshot

    @Generable
    struct Arguments {
        @Guide(description: "one schema to list; omit for every schema")
        var schema: String?
    }

    func call(arguments: Arguments) async throws -> String {
        snapshot.tableLines(schema: arguments.schema)
    }
}

/// `describe_table` — what a table holds.
struct DescribeTableTool: Tool {

    let name = "describe_table"
    let description = "Lists a table's columns, one 'column type' per line."

    let snapshot: SchemaSnapshot

    /// The tab's schema, so a bare table name resolves the way the analyst
    /// would read it.
    let defaultSchema: String?

    @Generable
    struct Arguments {
        @Guide(description: "a table name, optionally prefixed with its schema as schema.table")
        var table: String
    }

    func call(arguments: Arguments) async throws -> String {
        snapshot.columnLines(table: arguments.table, defaultSchema: defaultSchema)
    }
}

// MARK: - Drafter

/// One session, one interaction. A retry builds a new `SQLDrafter`, so the
/// model starts from the instructions rather than from its last answer.
@MainActor
final class SQLDrafter {

    private let session: LanguageModelSession

    init(snapshot: SchemaSnapshot, defaultSchema: String?) {
        let tools: [any Tool] = [
            ListTablesTool(snapshot: snapshot),
            DescribeTableTool(snapshot: snapshot, defaultSchema: defaultSchema),
        ]
        session = LanguageModelSession(
            tools: tools,
            instructions: Self.instructions(defaultSchema: defaultSchema))
    }

    /// The model's instruction text — English, and deliberately not localized:
    /// it is read by the model, never shown to the analyst.
    ///
    /// The last three sentences are not decoration. Measured against the
    /// on-device model on macOS 26.6: without them the session never
    /// terminates. It calls `list_tables`, then `describe_table`, then
    /// `list_tables` again with the same arguments, and goes round for as
    /// long as it is allowed to — 33 identical tool calls in two minutes,
    /// with no answer, whether the response is a `@Generable` type or plain
    /// text. With them, the same question converges in three tool calls.
    /// "Never invent names" is what starts the loop: the model keeps looking
    /// the same table up to be sure. It has to be told the answer it already
    /// has is final.
    private static func instructions(defaultSchema: String?) -> String {
        var text = IntelligenceInstructions.sqlSafety
        text += " Write one PostgreSQL SELECT statement for the analyst's request."
        text += " Use the tools to look up table and column names; never invent names."
        if let defaultSchema, !defaultSchema.isEmpty {
            text += " Prefer the default schema \(defaultSchema)."
        }
        text += " Return only the statement and a one-sentence note."
        text += " Call list_tables at most once and describe_table at most once per table."
        text += " Never repeat a tool call you have already made; the answer you were"
        text += " given is complete and final. As soon as you know the column names,"
        text += " stop calling tools and write the statement."
        return text
    }

    /// Ask for a draft.
    ///
    /// The description and the SQL are never logged: the description is the
    /// analyst's own words and the SQL carries their schema.
    func draft(_ description: String) async throws -> SQLDraft {
        Log.intelligence.info("draft-sql: asking the model")
        do {
            let response = try await session.respond(to: description, generating: SQLDraft.self)
            Log.intelligence.info("draft-sql: answered")
            return response.content
        } catch {
            Log.intelligence.error(
                "draft-sql: failed: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
    }
}

// MARK: - Building the snapshot

extension SchemaSnapshot {

    /// Everything the schema cache holds for the connection it is currently
    /// showing.
    ///
    /// `MetadataCache`'s published properties belong to the ACTIVE connection,
    /// which is the tab's own connection whenever a tab is in front — the
    /// caller checks that the tab has one before asking.
    ///
    /// Columns arrive keyed `"schema.table"`; a table whose columns have not
    /// been fetched yet contributes its name with no columns, so the model can
    /// still see that it exists and ask about it.
    @MainActor
    static func fromMetadataCache(_ cache: MetadataCache = .shared) -> SchemaSnapshot {
        var schemas: [String: [TableSummary]] = [:]
        for schema in cache.schemas {
            let tables = cache.tables[schema.name] ?? []
            schemas[schema.name] = tables.map { table in
                let columns = cache.columnsByTable["\(schema.name).\(table.name)"] ?? []
                return TableSummary(
                    name: table.name,
                    columns: columns.map { (name: $0.name, type: $0.dataType) })
            }
        }
        return SchemaSnapshot(schemas: schemas)
    }
}
