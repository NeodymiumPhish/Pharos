import Foundation

/// What the drafting model is allowed to know about the connected database.
///
/// Names, types, keys, enum labels and short comments. Nothing else: no row,
/// no cell, no row count, no column default and no CHECK clause. Every
/// string the model receives is built from this value by `SQLDraftPrompt`,
/// so "the model never sees your data" is a property of the TYPE rather than
/// a promise about the prompt text.
///
/// Pure Foundation on purpose: the session that reads the prompts lives in
/// `SQLDraft.swift` and cannot be unit-tested, while every string the model
/// actually receives is produced from here and asserted in
/// `PharosTests/SQLDraftPipelineTests.swift`.
struct DraftCatalog: Sendable, Equatable {

    // MARK: - Types

    /// `schema.table`, in the catalogue's own case.
    struct TableKey: Hashable, Sendable, Comparable, CustomStringConvertible {
        let schema: String
        let name: String

        /// How the model is shown it and must write it: quoted where SQL
        /// needs quotes.
        var sql: String { DraftCatalog.quoted(schema) + "." + DraftCatalog.quoted(name) }
        var description: String { "\(schema).\(name)" }

        static func < (a: TableKey, b: TableKey) -> Bool {
            (a.schema, a.name) < (b.schema, b.name)
        }
    }

    /// A single-column foreign key, shown on the column it starts from.
    struct Reference: Equatable, Sendable {
        let table: TableKey
        let column: String
    }

    struct Column: Equatable, Sendable {
        let name: String
        /// Shortened: `timestamptz`, `varchar(80)`, `sales.order_status`.
        let type: String
        let isPrimaryKey: Bool
        let comment: String?
        /// Set for an enum column; at most 20 labels.
        let enumLabels: [String]?
        let reference: Reference?
    }

    struct Table: Equatable, Sendable {
        let key: TableKey
        let comment: String?
        /// Catalogue order. Empty when the cache has not loaded them yet.
        let columns: [Column]
    }

    /// A foreign key, single- or multi-column, as an edge between tables.
    struct Link: Equatable, Sendable {
        let from: TableKey
        let fromColumns: [String]
        let to: TableKey
        let toColumns: [String]
    }

    /// One column as the metadata cache holds it.
    struct SourceColumn: Equatable, Sendable {
        let name: String
        let type: String
        let isPrimaryKey: Bool
    }

    // MARK: - Contents

    /// Every table, sorted by key.
    let tables: [Table]
    /// Every foreign key whose both ends are in `tables`.
    let links: [Link]

    private let index: [TableKey: Int]

    init(tables: [Table], links: [Link]) {
        let sorted = tables.sorted { $0.key < $1.key }
        self.tables = sorted
        var index: [TableKey: Int] = [:]
        for (i, table) in sorted.enumerated() { index[table.key] = i }
        self.index = index
        self.links = links.filter { index[$0.from] != nil && index[$0.to] != nil }
    }

    static func == (a: DraftCatalog, b: DraftCatalog) -> Bool {
        a.tables == b.tables && a.links == b.links
    }

    /// The cache's tables and columns, with each schema's facts laid over
    /// them: real type names, comments, enum labels, foreign keys. A schema
    /// with no facts (not fetched, or the fetch failed) keeps the cache's
    /// information_schema types and has no keys.
    init(columns: [TableKey: [SourceColumn]], facts: [String: SchemaDraftFacts]) {
        var tables: [Table] = []
        var links: [Link] = []
        for (key, source) in columns {
            let schemaFacts = facts[key.schema]
            var factByColumn: [String: SchemaDraftFacts.Column] = [:]
            for fact in schemaFacts?.columns ?? [] where fact.table == key.name {
                factByColumn[fact.name] = fact
            }
            var labelsByType: [String: [String]] = [:]
            for e in schemaFacts?.enums ?? [] { labelsByType[e.type] = e.labels }
            var referenceByColumn: [String: Reference] = [:]
            for fk in schemaFacts?.foreignKeys ?? [] where fk.table == key.name {
                let target = TableKey(schema: fk.refSchema, name: fk.refTable)
                links.append(Link(from: key, fromColumns: fk.columns, to: target, toColumns: fk.refColumns))
                if fk.columns.count == 1, fk.refColumns.count == 1 {
                    referenceByColumn[fk.columns[0]] = Reference(table: target, column: fk.refColumns[0])
                }
            }
            let built = source.map { column -> Column in
                let fact = factByColumn[column.name]
                let rawType = fact?.type ?? column.type
                return Column(
                    name: column.name,
                    type: Self.shortType(rawType),
                    isPrimaryKey: column.isPrimaryKey,
                    comment: fact?.comment,
                    enumLabels: labelsByType[rawType],
                    reference: referenceByColumn[column.name])
            }
            tables.append(Table(key: key, comment: schemaFacts?.tableComments[key.name], columns: built))
        }
        self.init(tables: tables, links: links)
    }

    // MARK: - Lookup

    func table(_ key: TableKey) -> Table? {
        index[key].map { tables[$0] }
    }

    var schemas: [String] {
        var seen: [String] = []
        for table in tables where seen.last != table.key.schema { seen.append(table.key.schema) }
        return seen
    }

    /// The table a reference names, resolved the way PostgreSQL would for an
    /// analyst on `searchPath`: an explicit schema, else the first schema on
    /// the path that has it, else the only table of that name anywhere.
    /// Case-insensitive, as the checker's job is "does it exist", and the
    /// quoting rule is checked on its own.
    func resolve(schema: String?, table name: String, searchPath: [String]) -> Table? {
        let lower = name.lowercased()
        func find(in schema: String) -> Table? {
            let s = schema.lowercased()
            return tables.first { $0.key.schema.lowercased() == s && $0.key.name.lowercased() == lower }
        }
        if let schema { return find(in: schema) }
        for schema in searchPath { if let hit = find(in: schema) { return hit } }
        let hits = tables.filter { $0.key.name.lowercased() == lower }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Tables one foreign key away, in either direction.
    func neighbours(of key: TableKey) -> [TableKey] {
        var out: [TableKey] = []
        for link in links {
            if link.from == key, link.to != key, !out.contains(link.to) { out.append(link.to) }
            if link.to == key, link.from != key, !out.contains(link.from) { out.append(link.from) }
        }
        return out
    }

    func isLinked(_ a: TableKey, _ b: TableKey) -> Bool {
        links.contains { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
    }

    // MARK: - Names as SQL

    /// PostgreSQL's reserved key words: a column named `order` or `user`
    /// has to be quoted to be read as a name.
    static let reservedWords: Set<String> = [
        "all", "analyse", "analyze", "and", "any", "array", "as", "asc", "asymmetric", "authorization",
        "binary", "both", "case", "cast", "check", "collate", "collation", "column", "concurrently",
        "constraint", "create", "cross", "current_catalog", "current_date", "current_role",
        "current_schema", "current_time", "current_timestamp", "current_user", "default", "deferrable",
        "desc", "distinct", "do", "else", "end", "except", "false", "fetch", "for", "foreign", "freeze",
        "from", "full", "grant", "group", "having", "ilike", "in", "initially", "inner", "intersect",
        "into", "is", "isnull", "join", "lateral", "leading", "left", "like", "limit", "localtime",
        "localtimestamp", "natural", "not", "notnull", "null", "offset", "on", "only", "or", "order",
        "outer", "overlaps", "placing", "primary", "references", "returning", "right", "select",
        "session_user", "similar", "some", "symmetric", "system_user", "table", "tablesample", "then",
        "to", "trailing", "true", "union", "unique", "user", "using", "variadic", "verbose", "when",
        "where", "window", "with",
    ]

    /// `name` as it must be written in SQL: bare when PostgreSQL would fold
    /// it to itself, double-quoted otherwise.
    static func quoted(_ name: String) -> String {
        if needsQuotes(name) {
            return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return name
    }

    static func needsQuotes(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return true }
        let isLower: (Unicode.Scalar) -> Bool = { $0 >= "a" && $0 <= "z" }
        let isDigit: (Unicode.Scalar) -> Bool = { $0 >= "0" && $0 <= "9" }
        guard isLower(first) || first == "_" else { return true }
        for s in name.unicodeScalars where !(isLower(s) || isDigit(s) || s == "_" || s == "$") {
            return true
        }
        return reservedWords.contains(name)
    }

    // MARK: - Types, shortened

    /// The type as fewer tokens: `timestamp with time zone` costs five,
    /// `timestamptz` costs two, and the model reads both the same way.
    static func shortType(_ type: String) -> String {
        var base = type
        var suffix = ""
        while base.hasSuffix("[]") {
            base.removeLast(2)
            suffix += "[]"
        }
        let phrases: [(String, String)] = [
            ("timestamp without time zone", "timestamp"),
            ("timestamp with time zone", "timestamptz"),
            ("time without time zone", "time"),
            ("time with time zone", "timetz"),
            ("character varying", "varchar"),
            ("double precision", "float8"),
        ]
        for (long, short) in phrases where base.contains(long) {
            base = base.replacingOccurrences(of: long, with: short)
        }
        // `timestamp(3) with time zone` keeps its precision on the short name.
        if let range = base.range(of: #"^timestamp\((\d+)\) with time zone$"#, options: .regularExpression) {
            let digits = base[range].filter(\.isNumber)
            base = "timestamptz(\(digits))"
        }
        switch base {
        case "integer": base = "int"
        case "boolean": base = "bool"
        case "character": base = "char"
        default:
            if base.hasPrefix("character(") { base = "char" + base.dropFirst("character".count) }
        }
        return base + suffix
    }
}
