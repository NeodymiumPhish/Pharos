import Foundation

/// Between the check and the model's repair: the fixes Pharos can make
/// itself, because the catalogue knows the right answer.
///
/// Measured with `scripts/eval-sql-draft.sh` on the macOS 27 model, the
/// commonest wrong name is a join on a column that does not exist
/// (`e.employee_id = es.employee_id`, where the key is `es.employee_id ->
/// e.id`), and the model's own repair, shown the exact error and the right
/// alias, wrote the same join again. So:
///
/// 1. A JOIN whose ON condition names a column that does not exist gets the
///    foreign-key condition between that table and the tables before it —
///    only when exactly one key joins them, and never for a self-join, whose
///    direction a key cannot tell.
/// 2. A column read through an alias whose table lacks it moves to the one
///    other alias in scope that has it. Not inside an ON condition: there it
///    could turn a join into `x = x`.
/// 3. An unquoted mixed-case name gets its double quotes.
///
/// Every fix is reported, and the popover says what was changed. What none
/// of these can fix is left to the model's repair and then to the analyst.
/// Pure Foundation; asserted in `PharosTests/SQLDraftPipelineTests.swift`.
enum SQLDraftFixer {

    struct Outcome: Equatable {
        let sql: String
        /// One sentence per fix, for the popover.
        let fixes: [String]
    }

    static func fix(_ sql: String, in catalog: DraftCatalog, defaultSchema: String?) -> Outcome {
        var fixes: [String] = []
        var text = sql
        if let joined = fixJoins(text, in: catalog, defaultSchema: defaultSchema) {
            text = joined.sql
            fixes += joined.fixes
        }
        if let moved = fixQualifiers(text, in: catalog, defaultSchema: defaultSchema) {
            text = moved.sql
            fixes += moved.fixes
        }
        if let quoted = fixQuoting(text, in: catalog) {
            text = quoted.sql
            fixes += quoted.fixes
        }
        return Outcome(sql: text, fixes: fixes)
    }

    // MARK: - The statement, bound to the catalogue

    private struct Bound {
        let scope: SQLStatementScope
        let tokens: [SQLStatementScope.Token]
        /// Lower-cased qualifier → its table.
        let byQualifier: [String: DraftCatalog.Table]
        /// The ON conditions, as token index ranges.
        let conditions: [Range<Int>]
    }

    private static func bind(_ sql: String, in catalog: DraftCatalog, defaultSchema: String?) -> Bound {
        let scope = SQLStatementScope.analyze(sql, caret: (sql as NSString).length)
        let snapshot = SQLLexSnapshot.shared(for: sql)
        let tokens = SQLStatementScope.tokens(in: snapshot, range: NSRange(location: 0, length: snapshot.length))
        var path: [String] = []
        if let defaultSchema, !defaultSchema.isEmpty { path.append(defaultSchema) }
        if !path.contains("public") { path.append("public") }
        var byQualifier: [String: DraftCatalog.Table] = [:]
        for ref in scope.tables {
            if let table = catalog.resolve(schema: ref.schema, table: ref.table, searchPath: path) {
                byQualifier[ref.qualifier.lowercased()] = table
                if ref.alias == nil { byQualifier[table.key.name.lowercased()] = table }
            }
        }
        return Bound(scope: scope, tokens: tokens, byQualifier: byQualifier, conditions: onConditions(tokens))
    }

    private static let clauseEnders: Set<String> = [
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "WHERE", "GROUP", "ORDER",
        "LIMIT", "OFFSET", "HAVING", "UNION", "INTERSECT", "EXCEPT", "WINDOW", "FETCH",
    ]

    /// Every `ON …` condition: from the token after ON to the clause that
    /// ends it at the same depth.
    private static func onConditions(_ tokens: [SQLStatementScope.Token]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (i, token) in tokens.enumerated() where token.isKeyword("ON") {
            var depth = 0
            var j = i + 1
            while j < tokens.count {
                let t = tokens[j]
                if t.isPunct("(") { depth += 1 }
                if t.isPunct(")") { if depth == 0 { break }; depth -= 1 }
                if depth == 0, t.isPunct(";") { break }
                if depth == 0, t.kind == .word, clauseEnders.contains(t.upper) { break }
                j += 1
            }
            if j > i + 1 { out.append((i + 1)..<j) }
        }
        return out
    }

    /// `qualifier.column` references: the index of the qualifier token.
    /// Skips schema-qualified names, function calls and casts, as the
    /// checker does.
    private static func columnRefs(_ tokens: [SQLStatementScope.Token]) -> [Int] {
        var out: [Int] = []
        var i = 0
        while i + 2 < tokens.count {
            defer { i += 1 }
            guard tokens[i].isName, tokens[i + 1].isPunct("."), tokens[i + 2].isName else { continue }
            if i > 0, tokens[i - 1].isPunct(".") || tokens[i - 1].isPunct("::") { continue }
            if i + 3 < tokens.count, tokens[i + 3].isPunct(".") || tokens[i + 3].isPunct("(") { continue }
            out.append(i)
        }
        return out
    }

    private static func has(_ table: DraftCatalog.Table, _ column: String) -> Bool {
        let lower = column.lowercased()
        return table.columns.contains { $0.name.lowercased() == lower }
    }

    /// Applies `(range, replacement)` edits, last first, so earlier ranges
    /// stay valid.
    private static func apply(_ edits: [(NSRange, String)], to sql: String) -> String {
        let text = NSMutableString(string: sql)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            text.replaceCharacters(in: range, with: replacement)
        }
        return text as String
    }

    // MARK: - 1. Joins

    private static func fixJoins(_ sql: String, in catalog: DraftCatalog, defaultSchema: String?) -> Outcome? {
        let bound = bind(sql, in: catalog, defaultSchema: defaultSchema)
        let tokens = bound.tokens
        var edits: [(NSRange, String)] = []
        var fixes: [String] = []

        for condition in bound.conditions {
            // Which table does this ON belong to? The reference right before
            // it: `JOIN schema.table [AS] alias ON`.
            let on = condition.lowerBound - 1
            guard let refIndex = joinedRef(before: on, tokens: tokens, scope: bound.scope),
                  let joined = bound.byQualifier[bound.scope.tables[refIndex].qualifier.lowercased()] else { continue }

            let broken = columnRefs(tokens).filter { condition.contains($0) }.contains { q in
                guard let table = bound.byQualifier[tokens[q].text.lowercased()] else { return true }
                return !has(table, tokens[q + 2].text)
            }
            guard broken else { continue }

            // The keys between the joined table and every table before it.
            var candidates: [(DraftCatalog.Link, own: String, other: String)] = []
            for earlier in bound.scope.tables[..<refIndex] {
                guard let table = bound.byQualifier[earlier.qualifier.lowercased()], table.key != joined.key else { continue }
                for link in catalog.links {
                    if link.from == joined.key, link.to == table.key {
                        candidates.append((link, bound.scope.tables[refIndex].qualifier, earlier.qualifier))
                    } else if link.from == table.key, link.to == joined.key {
                        candidates.append((link, earlier.qualifier, bound.scope.tables[refIndex].qualifier))
                    }
                }
            }
            guard candidates.count == 1, let only = candidates.first else { continue }
            let pairs = zip(only.0.fromColumns, only.0.toColumns).map { from, to in
                "\(only.own).\(DraftCatalog.quoted(from)) = \(only.other).\(DraftCatalog.quoted(to))"
            }
            let first = tokens[condition.lowerBound].range
            let last = tokens[condition.upperBound - 1].range
            let range = NSRange(location: first.location, length: last.location + last.length - first.location)
            edits.append((range, pairs.joined(separator: " AND ")))
            fixes.append("The join to \(joined.key) now uses its foreign key.")
        }
        guard !edits.isEmpty else { return nil }
        return Outcome(sql: apply(edits, to: sql), fixes: fixes)
    }

    /// The index in `scope.tables` of the reference an ON at `on` belongs
    /// to: the alias (or name) right before ON.
    private static func joinedRef(before on: Int, tokens: [SQLStatementScope.Token], scope: SQLStatementScope) -> Int? {
        guard on > 0, tokens[on - 1].isName else { return nil }
        let name = tokens[on - 1].text.lowercased()
        // The last reference with that qualifier before this point: aliases
        // are unique in a well-formed statement, and a repeated one resolves
        // to the latest.
        return scope.tables.lastIndex { $0.qualifier.lowercased() == name }
    }

    // MARK: - 2. Qualifiers

    private static func fixQualifiers(_ sql: String, in catalog: DraftCatalog, defaultSchema: String?) -> Outcome? {
        let bound = bind(sql, in: catalog, defaultSchema: defaultSchema)
        let tokens = bound.tokens
        var edits: [(NSRange, String)] = []
        var fixes: [String] = []
        for q in columnRefs(tokens) where !bound.conditions.contains(where: { $0.contains(q) }) {
            guard let table = bound.byQualifier[tokens[q].text.lowercased()], !table.columns.isEmpty else { continue }
            let column = tokens[q + 2].text
            guard !has(table, column) else { continue }
            let owners = bound.scope.tables.filter { ref in
                guard let other = bound.byQualifier[ref.qualifier.lowercased()] else { return false }
                return other.key != table.key && has(other, column)
            }
            guard owners.count == 1 else { continue }
            edits.append((tokens[q].range, owners[0].qualifier))
            let fix = "\(column) is read through \(owners[0].qualifier), the table that has it."
            if !fixes.contains(fix) { fixes.append(fix) }
        }
        guard !edits.isEmpty else { return nil }
        return Outcome(sql: apply(edits, to: sql), fixes: fixes)
    }

    // MARK: - 3. Quoting

    private static func fixQuoting(_ sql: String, in catalog: DraftCatalog) -> Outcome? {
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
        guard !mixed.isEmpty else { return nil }
        let scope = SQLStatementScope.analyze(sql, caret: (sql as NSString).length)
        let aliases = Set(scope.tables.compactMap { $0.alias?.lowercased() } + scope.selectAliases.map { $0.lowercased() })
        let snapshot = SQLLexSnapshot.shared(for: sql)
        let tokens = SQLStatementScope.tokens(in: snapshot, range: NSRange(location: 0, length: snapshot.length))
        var edits: [(NSRange, String)] = []
        var fixes: [String] = []
        for token in tokens where token.kind == .word {
            let lower = token.text.lowercased()
            guard let real = mixed[lower], !plain.contains(lower), !aliases.contains(lower) else { continue }
            edits.append((token.range, DraftCatalog.quoted(real)))
            let fix = "\(real) is written with its double quotes."
            if !fixes.contains(fix) { fixes.append(fix) }
        }
        guard !edits.isEmpty else { return nil }
        return Outcome(sql: apply(edits, to: sql), fixes: fixes)
    }
}
