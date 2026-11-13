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
/// 3. An unquoted mixed-case name gets its double quotes, and so does a
///    key word used as a name after a dot (`o.order`).
///
/// Every fix is reported, and the card's strip says what was changed. What none
/// of these can fix is left to the model's repair and then to the analyst.
/// Pure Foundation; asserted in `PharosTests/SQLDraftPipelineTests.swift`.
enum SQLDraftFixer {

    struct Outcome: Equatable {
        let sql: String
        /// One sentence per fix, for the card's strip.
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
        /// The statement's tables, bound to the catalogue, and which of
        /// them each place can name: a correction may only name a table
        /// that the place it is made at can see.
        let bindings: SQLDraftChecker.Bindings
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
        let bindings = SQLDraftChecker.Bindings(tokens) { ref in
            catalog.resolve(schema: ref.schema, table: ref.table, searchPath: path)
        }
        return Bound(scope: scope, tokens: tokens, bindings: bindings, conditions: onConditions(tokens))
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
            let references = bound.bindings.references
            guard let refIndex = joinedRef(before: on, tokens: tokens, references: references),
                  let joined = bound.bindings.tables[refIndex] else { continue }

            let broken = columnRefs(tokens).filter { condition.contains($0) }.contains { q in
                guard let table = bound.bindings.table(tokens[q].text, at: q) else { return true }
                return !has(table, tokens[q + 2].text)
            }
            guard broken else { continue }

            // The keys between the joined table and every table before it
            // that this ON can name: a table of an earlier subquery is
            // before it too, and cannot be joined on here.
            let joinedQualifier = references[refIndex].ref.qualifier
            var candidates: [(DraftCatalog.Link, own: String, other: String)] = []
            for index in bound.bindings.visible(from: on) where index < refIndex {
                guard let table = bound.bindings.tables[index], table.key != joined.key else { continue }
                let earlier = references[index].ref.qualifier
                for link in catalog.links {
                    if link.from == joined.key, link.to == table.key {
                        candidates.append((link, joinedQualifier, earlier))
                    } else if link.from == table.key, link.to == joined.key {
                        candidates.append((link, earlier, joinedQualifier))
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

    /// The index in `references` of the reference an ON at `on` belongs
    /// to: the alias (or name) right before ON.
    private static func joinedRef(
        before on: Int, tokens: [SQLStatementScope.Token],
        references: [(ref: SQLStatementScope.TableRef, at: Int)]
    ) -> Int? {
        guard on > 0, tokens[on - 1].isName else { return nil }
        let name = tokens[on - 1].text.lowercased()
        // The last reference with that qualifier declared before this ON:
        // the same alias in a later subquery is another table.
        return references.lastIndex { $0.at < on && $0.ref.qualifier.lowercased() == name }
    }

    // MARK: - 2. Qualifiers

    private static func fixQualifiers(_ sql: String, in catalog: DraftCatalog, defaultSchema: String?) -> Outcome? {
        let bound = bind(sql, in: catalog, defaultSchema: defaultSchema)
        let tokens = bound.tokens
        var edits: [(NSRange, String)] = []
        var fixes: [String] = []
        for q in columnRefs(tokens) where !bound.conditions.contains(where: { $0.contains(q) }) {
            guard let table = bound.bindings.table(tokens[q].text, at: q), !table.columns.isEmpty else { continue }
            let column = tokens[q + 2].text
            guard !has(table, column) else { continue }
            // The tables that have the column AND can be named here. One in
            // a subquery has it too, but the query around the subquery
            // cannot read through it: moving the column there would trade a
            // column that does not exist for a table that is not in FROM.
            var owners: [String] = []
            for index in bound.bindings.visible(from: q) {
                let qualifier = bound.bindings.references[index].ref.qualifier
                guard let other = bound.bindings.tables[index], other.key != table.key,
                      has(other, column), !owners.contains(qualifier) else { continue }
                owners.append(qualifier)
            }
            guard owners.count == 1 else { continue }
            edits.append((tokens[q].range, owners[0]))
            let fix = "\(column) is read through \(owners[0]), the table that has it."
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
        // A key word used as a name, where it can only be a name.
        for index in SQLDraftChecker.reservedNames(in: tokens, catalog: catalog) {
            let name = tokens[index].text.lowercased()
            edits.append((tokens[index].range, DraftCatalog.quoted(name)))
            let fix = "\(name) is written with its double quotes."
            if !fixes.contains(fix) { fixes.append(fix) }
        }
        guard !edits.isEmpty else { return nil }
        return Outcome(sql: apply(edits, to: sql), fixes: fixes)
    }
}
