import Foundation

/// Step 5 of drafting: does the draft name only what exists?
///
/// Local and read-only. Nothing is sent to the server — the analyst chose a
/// draft that never touches the database — so this is a scan, not a parse.
/// It reads the statement through `SQLStatementScope` and checks:
///
/// - every table reference resolves in the catalogue (CTEs and derived
///   tables excepted);
/// - every `qualifier.column` names a column of the table the qualifier
///   stands for;
/// - a mixed-case name is written with its double quotes, because
///   PostgreSQL folds an unquoted name to lower case;
/// - an enum column compared with `=`, `<>` or `IN` uses listed labels.
///
/// An unqualified column is not checked: the instructions ask for every
/// column to be qualified, and an unqualified word could as well be a
/// function, a select alias or a key word. What the scan cannot tell, it
/// lets through. Pure Foundation; asserted in
/// `PharosTests/SQLDraftPipelineTests.swift`.
enum SQLDraftChecker {

    struct Problem: Equatable, CustomStringConvertible {
        /// One sentence for the repair prompt and the popover.
        let description: String
    }

    static func check(
        _ sql: String, in catalog: DraftCatalog, defaultSchema: String?
    ) -> [Problem] {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let scope = SQLStatementScope.analyze(sql, caret: (sql as NSString).length)
        var searchPath: [String] = []
        if let defaultSchema, !defaultSchema.isEmpty { searchPath.append(defaultSchema) }
        if !searchPath.contains("public") { searchPath.append("public") }

        var problems: [Problem] = []
        func add(_ text: String) {
            let p = Problem(description: text)
            if !problems.contains(p) { problems.append(p) }
        }

        // CTEs and derived tables have columns the catalogue cannot know,
        // and so does an alias given to a CTE.
        var tableLike = Set((scope.cteNames + scope.derivedAliases).map { $0.lowercased() })
        var byQualifier: [String: DraftCatalog.Table] = [:]
        for ref in scope.tables {
            if ref.schema == nil, tableLike.contains(ref.table.lowercased()) {
                if let alias = ref.alias { tableLike.insert(alias.lowercased()) }
                continue
            }
            guard let table = catalog.resolve(schema: ref.schema, table: ref.table, searchPath: searchPath) else {
                let name = ref.schema.map { "\($0).\(ref.table)" } ?? ref.table
                add("Table \(name) does not exist.")
                // Its alias is still an alias: one wrong table name is one
                // problem, not one more for every column read through it.
                tableLike.insert(ref.qualifier.lowercased())
                continue
            }
            byQualifier[ref.qualifier.lowercased()] = table
            if ref.alias == nil {
                // `sales.orders` with no alias is also reachable as `orders`.
                byQualifier[table.key.name.lowercased()] = table
            }
        }

        let snapshot = SQLLexSnapshot.shared(for: sql)
        let tokens = SQLStatementScope.tokens(in: snapshot, range: NSRange(location: 0, length: snapshot.length))
        let schemas = Set(catalog.schemas.map { $0.lowercased() })

        checkQuoting(tokens, scope: scope, byQualifier: byQualifier, catalog: catalog, add: add)

        if tokens.contains(where: { $0.isPunct("{") || $0.isPunct("}") }) {
            add("PostgreSQL has no { } lists; write IN ('a', 'b').")
        }

        // The names the statement may qualify with, for the hints below.
        let qualifiers = scope.tables.map(\.qualifier) + scope.derivedAliases

        var i = 0
        while i + 2 < tokens.count {
            guard tokens[i].isName, tokens[i + 1].isPunct("."), tokens[i + 2].isName || tokens[i + 2].isPunct("*") else {
                i += 1
                continue
            }
            // `schema.table.column`: the qualifier is the middle part.
            var q = i
            if i + 4 < tokens.count, tokens[i + 3].isPunct("."), tokens[i + 4].isName,
               schemas.contains(tokens[i].text.lowercased()) {
                q = i + 2
            }
            let qualifier = tokens[q].text.lowercased()
            let member = tokens[q + 2]
            // Preceded by `.` or `::`, or followed by `(` or `.`: a schema-qualified
            // table, function or type, not a column.
            let previous = i > 0 ? tokens[i - 1] : nil
            let next = q + 3 < tokens.count ? tokens[q + 3] : nil
            let notAColumn = previous?.isPunct("::") == true || previous?.isPunct(".") == true
                || next?.isPunct("(") == true || next?.isPunct(".") == true

            if !notAColumn, !member.isPunct("*"), let table = byQualifier[qualifier] {
                if !table.columns.isEmpty,
                   let column = table.columns.first(where: { $0.name.lowercased() == member.text.lowercased() }) {
                    checkEnum(column: column, table: table, after: q + 3, tokens: tokens, sql: sql, add: add)
                } else if !table.columns.isEmpty {
                    let wanted = member.text.lowercased()
                    let owners = scope.tables.filter { ref in
                        guard let other = byQualifier[ref.qualifier.lowercased()], other.key != table.key else { return false }
                        return other.columns.contains { $0.name.lowercased() == wanted }
                    }.map(\.qualifier)
                    if !owners.isEmpty {
                        add("Column \(tokens[q].text).\(member.text) does not exist; \(member.text) is a column of \(owners.joined(separator: " and ")).")
                    } else {
                        let known = table.columns.prefix(25).map(\.name).joined(separator: ", ")
                        add("Column \(tokens[q].text).\(member.text) does not exist; \(table.key) has: \(known).")
                    }
                }
            } else if !notAColumn, byQualifier[qualifier] == nil, !tableLike.contains(qualifier),
                      !schemas.contains(qualifier) {
                let list = qualifiers.isEmpty ? "" : "; the aliases are: " + qualifiers.joined(separator: ", ")
                add("\(tokens[q].text) is not a table or alias in the FROM clause\(list).")
            }
            i = q + 3
        }
        return problems
    }

    // MARK: - What it reads

    /// The catalogue tables `sql` reads, in the order it names them, each
    /// once. CTEs, derived tables and names the catalogue does not have are
    /// left out.
    static func tablesRead(_ sql: String, in catalog: DraftCatalog, defaultSchema: String?) -> [DraftCatalog.TableKey] {
        let scope = SQLStatementScope.analyze(sql, caret: (sql as NSString).length)
        var path: [String] = []
        if let defaultSchema, !defaultSchema.isEmpty { path.append(defaultSchema) }
        if !path.contains("public") { path.append("public") }
        let ctes = Set(scope.cteNames.map { $0.lowercased() })
        var out: [DraftCatalog.TableKey] = []
        for ref in scope.tables {
            if ref.schema == nil, ctes.contains(ref.table.lowercased()) { continue }
            if let table = catalog.resolve(schema: ref.schema, table: ref.table, searchPath: path), !out.contains(table.key) {
                out.append(table.key)
            }
        }
        return out
    }

    // MARK: - Quoting

    /// An unquoted word that only matches a mixed-case catalogue name is a
    /// different name to PostgreSQL: `ReturnRequests` reads as
    /// `returnrequests`.
    private static func checkQuoting(
        _ tokens: [SQLStatementScope.Token],
        scope: SQLStatementScope,
        byQualifier: [String: DraftCatalog.Table],
        catalog: DraftCatalog,
        add: (String) -> Void
    ) {
        var mixed: [String: String] = [:]
        var plain = Set<String>()
        for table in catalog.tables {
            for name in [table.key.name] + table.columns.map(\.name) {
                if DraftCatalog.needsQuotes(name), name.lowercased() != name {
                    mixed[name.lowercased()] = name
                } else {
                    plain.insert(name.lowercased())
                }
            }
        }
        let aliases = Set(scope.tables.compactMap { $0.alias?.lowercased() } + scope.selectAliases.map { $0.lowercased() })
        for token in tokens where token.kind == .word {
            let lower = token.text.lowercased()
            guard let real = mixed[lower], !plain.contains(lower), !aliases.contains(lower) else { continue }
            add("\(token.text) must be written \(DraftCatalog.quoted(real)), with the double quotes.")
        }
    }

    // MARK: - Enum values

    /// `x.status = 'done'` against an enum whose labels are all known.
    private static func checkEnum(
        column: DraftCatalog.Column,
        table: DraftCatalog.Table,
        after start: Int,
        tokens: [SQLStatementScope.Token],
        sql: String,
        add: (String) -> Void
    ) {
        // Twenty is the cap the facts query applies: past it the list is
        // not complete and a missing label proves nothing.
        guard let labels = column.enumLabels, !labels.isEmpty, labels.count < 20 else { return }
        var literals: [String] = []
        var j = start
        if j < tokens.count, tokens[j].isPunct("=") || tokens[j].isPunct("<>") || tokens[j].isPunct("!=") {
            j += 1
            if j < tokens.count, tokens[j].kind == .string { literals.append(literal(tokens[j], in: sql)) }
        } else {
            if j < tokens.count, tokens[j].isKeyword("NOT") { j += 1 }
            if j + 1 < tokens.count, tokens[j].isKeyword("IN"), tokens[j + 1].isPunct("(") {
                j += 2
                while j < tokens.count, !tokens[j].isPunct(")") {
                    if tokens[j].kind == .string { literals.append(literal(tokens[j], in: sql)) }
                    j += 1
                }
            }
        }
        for value in literals where !labels.contains(value) {
            add("'\(value)' is not a value of \(table.key).\(column.name); use one of: \(labels.joined(separator: ", ")).")
        }
    }

    /// A single-quoted string token's value; dollar-quoted bodies come back
    /// as written.
    private static func literal(_ token: SQLStatementScope.Token, in sql: String) -> String {
        var text = (sql as NSString).substring(with: token.range)
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
            text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return text
    }
}
