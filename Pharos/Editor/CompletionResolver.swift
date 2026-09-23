import Foundation

/// Turns a `SQLStatementScope` and the catalog into the rows the completion
/// list shows, in the order it shows them. Pure: the catalog is a value, so
/// `scripts/test-editor-completion.sh` feeds it a made-up one.
///
/// The order inside a list is always: what the statement itself names
/// (aliases, CTEs, columns of the tables in scope), then the current schema,
/// then the rest of the database, then keywords. Typed text filters that
/// order; it does not reorder it (see `SQLCompletionProvider.filterCompletions`).
enum CompletionResolver {

    typealias Row = SQLCompletionProvider.Completion

    /// A snapshot of what the connection has. Names keep the catalog's case;
    /// lookups ignore case, as Postgres does for unquoted identifiers.
    struct Catalog: Equatable {
        struct Table: Equatable {
            let name: String
            let isView: Bool
        }
        struct Column: Equatable {
            let name: String
            let type: String
            let isPrimaryKey: Bool
        }
        var schemas: [String] = []
        /// Tables by schema name.
        var tables: [String: [Table]] = [:]
        /// Columns by `schema.table`.
        var columns: [String: [Column]] = [:]

        func schema(matching name: String) -> String? {
            let lower = name.lowercased()
            return schemas.first { $0.lowercased() == lower } ?? tables.keys.first { $0.lowercased() == lower }
        }

        func table(_ name: String, in schema: String) -> Table? {
            let lower = name.lowercased()
            return tables[schema]?.first { $0.name.lowercased() == lower }
        }

        func columns(of table: String, in schema: String) -> [Column] {
            columns["\(schema).\(table)"] ?? []
        }
    }

    struct Environment {
        var catalog: Catalog
        /// The toolbar's schema, or the connection's default; nil when
        /// neither is set.
        var currentSchema: String?
        /// The query variables, for value positions.
        var variables: [SQLCompletionProvider.VariableEntry] = []

        /// Where an unqualified table is looked for, in order.
        var searchPath: [String] {
            var path: [String] = []
            if let currentSchema, let real = catalog.schema(matching: currentSchema) { path.append(real) }
            if let pub = catalog.schema(matching: "public"), !path.contains(pub) { path.append(pub) }
            return path
        }
    }

    /// A table in scope, resolved to the catalog.
    struct ResolvedTable: Equatable {
        let schema: String
        let table: String
        let qualifier: String
    }

    // MARK: - Resolution

    /// `schema.table` for a reference, by the search path; nil when the
    /// catalog does not have it.
    static func resolve(_ ref: SQLStatementScope.TableRef, in env: Environment) -> ResolvedTable? {
        let catalog = env.catalog
        if let schema = ref.schema {
            guard let real = catalog.schema(matching: schema), let table = catalog.table(ref.table, in: real) else { return nil }
            return ResolvedTable(schema: real, table: table.name, qualifier: ref.qualifier)
        }
        for schema in env.searchPath {
            if let table = catalog.table(ref.table, in: schema) {
                return ResolvedTable(schema: schema, table: table.name, qualifier: ref.qualifier)
            }
        }
        // Anywhere, when the name is unique across the database.
        let hits = catalog.tables.compactMap { schema, _ in
            catalog.table(ref.table, in: schema).map { ResolvedTable(schema: schema, table: $0.name, qualifier: ref.qualifier) }
        }
        return hits.count == 1 ? hits.first : nil
    }

    /// The schemas the statement's tables live in — what the metadata cache
    /// should have loaded for the columns to appear.
    static func referencedSchemas(_ scope: SQLStatementScope, in env: Environment) -> [String] {
        var out: [String] = []
        for ref in scope.tables {
            let schema = ref.schema.flatMap { env.catalog.schema(matching: $0) } ?? resolve(ref, in: env)?.schema
            if let schema, !out.contains(schema) { out.append(schema) }
        }
        for schema in env.searchPath where !out.contains(schema) { out.append(schema) }
        return out
    }

    // MARK: - Rows

    static func rows(for scope: SQLStatementScope, in env: Environment) -> [Row] {
        switch scope.clause {
        case .none:
            return []
        case .start:
            return keywords(statementKeywords)
        case .keywords(let words):
            return keywords(words)
        case .member(let qualifier):
            return members(of: qualifier, scope: scope, env: env)
        case .select:
            var rows = [Row(label: "*", detail: "all columns", insertText: "*", kind: .keyword)]
            rows += columnsInScope(scope, env: env, orCurrentSchema: true)
            rows += functions
            rows += keywords(["DISTINCT", "CASE", "CAST", "EXISTS", "NULL", "TRUE", "FALSE"])
            return rows
        case .from:
            return tablesRows(scope, env: env)
        case .afterTableRef(let governing):
            return keywords(followers(for: governing))
        case .condition(let valuePosition):
            var rows: [Row] = []
            if valuePosition { rows += variableRows(env) }
            rows += columnsInScope(scope, env: env, orCurrentSchema: false)
            rows += selectAliasRows(scope)
            if !valuePosition { rows += variableRows(env) }
            rows += functions
            rows += keywords(valuePosition
                ? ["NULL", "TRUE", "FALSE", "SELECT", "NOT", "EXISTS", "CASE"]
                : ["NOT", "EXISTS", "CASE", "AND", "OR", "IN", "LIKE", "ILIKE", "IS NULL", "IS NOT NULL", "BETWEEN"])
            return rows
        case .groupOrOrder:
            var rows = selectAliasRows(scope)
            rows += columnsInScope(scope, env: env, orCurrentSchema: false)
            rows += functions
            return rows
        case .afterOrderColumn:
            return keywords(["ASC", "DESC", "NULLS FIRST", "NULLS LAST", "LIMIT", "OFFSET"])
        case .set:
            return targetColumns(scope, env: env)
        case .value:
            var rows = variableRows(env)
            rows += keywords(["DEFAULT", "NULL", "TRUE", "FALSE", "SELECT"])
            rows += functions
            return rows
        case .insertColumns:
            return targetColumns(scope, env: env)
        case .afterExpression(let governing):
            return keywords(followers(for: governing))
        }
    }

    // MARK: Builders

    private static func keywords(_ words: [String]) -> [Row] {
        words.map { Row(label: $0, detail: "keyword", insertText: $0, kind: .keyword) }
    }

    private static func variableRows(_ env: Environment) -> [Row] {
        var seen = Set<String>()
        return env.variables.reversed().filter { !$0.name.isEmpty && seen.insert($0.name).inserted }.reversed().map {
            Row(label: "{{\($0.name)}}", detail: $0.preview, insertText: "{{\($0.name)}}", kind: .variable)
        }
    }

    private static func selectAliasRows(_ scope: SQLStatementScope) -> [Row] {
        scope.selectAliases.map { Row(label: $0, detail: "alias", insertText: $0, kind: .column) }
    }

    /// Every resolved table the statement names, in statement order.
    private static func resolvedTables(_ scope: SQLStatementScope, env: Environment) -> [ResolvedTable] {
        var out: [ResolvedTable] = []
        for ref in scope.tables {
            if let resolved = resolve(ref, in: env), !out.contains(resolved) { out.append(resolved) }
        }
        return out
    }

    /// Columns of the tables in scope. With more than one source they insert
    /// qualified (`u.email`) and say which table they belong to. With no
    /// table in scope and `orCurrentSchema`, the columns of every table in
    /// the current schema, each saying its table.
    private static func columnsInScope(_ scope: SQLStatementScope, env: Environment, orCurrentSchema: Bool) -> [Row] {
        let resolved = resolvedTables(scope, env: env)
        if !resolved.isEmpty || scope.sourceCount > 0 {
            let qualify = scope.sourceCount > 1
            return resolved.flatMap { table in
                env.catalog.columns(of: table.table, in: table.schema).map { column in
                    columnRow(column, qualifier: qualify ? table.qualifier : nil)
                }
            }
        }
        guard orCurrentSchema, let schema = env.searchPath.first else { return [] }
        return (env.catalog.tables[schema] ?? []).flatMap { table in
            env.catalog.columns(of: table.name, in: schema).map { column in
                Row(label: column.name, detail: "\(table.name) · \(column.type)\(column.isPrimaryKey ? " PK" : "")",
                    insertText: column.name, kind: .column)
            }
        }
    }

    private static func columnRow(_ column: Catalog.Column, qualifier: String?) -> Row {
        let type = "\(column.type)\(column.isPrimaryKey ? " PK" : "")"
        guard let qualifier else {
            return Row(label: column.name, detail: type, insertText: column.name, kind: .column)
        }
        return Row(label: column.name, detail: "\(qualifier) · \(type)", insertText: "\(qualifier).\(column.name)", kind: .column)
    }

    private static func targetColumns(_ scope: SQLStatementScope, env: Environment) -> [Row] {
        guard let target = scope.target ?? scope.tables.first, let resolved = resolve(target, in: env) else { return [] }
        return env.catalog.columns(of: resolved.table, in: resolved.schema).map { columnRow($0, qualifier: nil) }
    }

    /// FROM position: the statement's own names, the current schema's tables,
    /// the other schemas' tables (inserted qualified), then the schemas.
    private static func tablesRows(_ scope: SQLStatementScope, env: Environment) -> [Row] {
        var rows: [Row] = []
        rows += scope.cteNames.map { Row(label: $0, detail: "CTE", insertText: $0, kind: .table) }
        let path = env.searchPath
        for schema in path {
            rows += (env.catalog.tables[schema] ?? []).map { tableRow($0, schema: schema, qualified: false) }
        }
        for schema in env.catalog.tables.keys.sorted() where !path.contains(schema) {
            rows += (env.catalog.tables[schema] ?? []).map { tableRow($0, schema: schema, qualified: true) }
        }
        rows += env.catalog.schemas.map { Row(label: $0, detail: "schema", insertText: $0, kind: .schema) }
        return rows
    }

    private static func tableRow(_ table: Catalog.Table, schema: String, qualified: Bool) -> Row {
        let kind: Row.Kind = table.isView ? .view : .table
        let detail = qualified ? schema : (table.isView ? "view" : "table")
        return Row(label: table.name, detail: detail, insertText: qualified ? "\(schema).\(table.name)" : table.name, kind: kind)
    }

    /// `qualifier.` — an alias or table in scope gives its columns, a schema
    /// its tables, a bare table (by the search path) its columns, and
    /// `schema.table` its columns.
    private static func members(of qualifier: String, scope: SQLStatementScope, env: Environment) -> [Row] {
        let parts = qualifier.split(separator: ".").map(String.init)
        let catalog = env.catalog
        if parts.count == 2 {
            guard let schema = catalog.schema(matching: parts[0]), let table = catalog.table(parts[1], in: schema) else { return [] }
            return catalog.columns(of: table.name, in: schema).map { columnRow($0, qualifier: nil) }
        }
        let name = qualifier.lowercased()
        // An alias or table in scope. `FROM sales.|` also lands here, with
        // `sales` read as a table: when it resolves to nothing, it may be a
        // schema, so fall through.
        if let ref = scope.tables.first(where: { ($0.alias ?? $0.table).lowercased() == name })
            ?? scope.tables.first(where: { $0.table.lowercased() == name }),
           let resolved = resolve(ref, in: env) {
            return catalog.columns(of: resolved.table, in: resolved.schema).map { columnRow($0, qualifier: nil) }
        }
        if let schema = catalog.schema(matching: qualifier) {
            return (catalog.tables[schema] ?? []).map { tableRow($0, schema: schema, qualified: false) }
        }
        if let resolved = resolve(.init(schema: nil, table: qualifier, alias: nil), in: env) {
            return catalog.columns(of: resolved.table, in: resolved.schema).map { columnRow($0, qualifier: nil) }
        }
        return []
    }

    // MARK: Keywords

    /// What may follow a finished expression in each clause.
    static func followers(for governing: SQLStatementScope.Governing) -> [String] {
        switch governing {
        case .statement: return statementKeywords
        case .select: return ["FROM", "AS"]
        case .from, .join:
            return ["WHERE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
                    "ON", "USING", "GROUP BY", "ORDER BY", "LIMIT", "AS", "RETURNING"]
        case .on, .condition:
            return ["AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "IS NULL", "IS NOT NULL", "BETWEEN",
                    "GROUP BY", "ORDER BY", "LIMIT", "JOIN", "RETURNING"]
        case .groupBy: return ["HAVING", "ORDER BY", "LIMIT"]
        case .orderBy: return ["ASC", "DESC", "NULLS FIRST", "NULLS LAST", "LIMIT", "OFFSET"]
        case .window: return ["PARTITION BY", "ORDER BY"]
        case .set: return ["WHERE", "FROM", "RETURNING"]
        case .values: return ["RETURNING", "ON CONFLICT"]
        case .insertInto: return ["VALUES", "SELECT", "DEFAULT VALUES", "RETURNING"]
        case .returning: return []
        case .limit: return ["OFFSET"]
        case .ddl: return ["TABLE", "INDEX", "VIEW", "SCHEMA"]
        case .insert: return ["INTO"]
        case .delete: return ["FROM"]
        case .update: return ["SET"]
        }
    }

    static let statementKeywords = [
        "SELECT", "WITH", "INSERT INTO", "UPDATE", "DELETE FROM", "CREATE", "ALTER", "DROP",
        "TRUNCATE", "EXPLAIN", "EXPLAIN ANALYZE", "BEGIN", "COMMIT", "ROLLBACK", "GRANT", "REVOKE",
    ]

    static let functionNames = [
        "count", "sum", "avg", "min", "max", "array_agg", "string_agg",
        "length", "lower", "upper", "trim", "substring", "concat", "replace",
        "now", "current_date", "current_timestamp", "date_trunc", "extract",
        "abs", "ceil", "floor", "round", "random",
        "json_build_object", "jsonb_build_object", "json_agg", "jsonb_agg",
        "coalesce", "nullif", "greatest", "least", "generate_series",
        "row_number", "rank", "dense_rank", "lag", "lead",
    ]

    /// Built once: the list never changes.
    static let functions: [Row] = functionNames.map {
        Row(label: $0, detail: "function", insertText: "\($0)()", kind: .function)
    }
}
