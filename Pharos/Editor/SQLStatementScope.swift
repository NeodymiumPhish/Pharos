import Foundation

/// The statement around the caret, read for completion: which tables it
/// names (with their aliases), which names it defines, and what the caret's
/// position expects next. Foundation only, so
/// `scripts/test-sql-statement-scope.sh` checks it directly.
///
/// This is a scanner, not a parser. It reads words and punctuation through
/// the lexer's state map — strings and comments are invisible to it — and
/// tracks parentheses. That is enough to know "the caret is after WHERE",
/// "orders is aliased o" and "this comma is in the select list", which is
/// what `CompletionResolver` asks. Anything it does not understand ends in
/// `.afterExpression` or `.none`, never in a wrong list.
struct SQLStatementScope: Equatable {

    /// A table the statement reads or writes.
    struct TableRef: Equatable {
        let schema: String?
        let table: String
        let alias: String?
        /// What a column of this table is qualified with when the statement
        /// has more than one source.
        var qualifier: String { alias ?? table }
    }

    /// The clause keyword that governs the caret's position. It decides
    /// which keywords may follow a finished expression, and what a comma
    /// continues.
    enum Governing: Equatable {
        case statement, select, from, join, on, condition, groupBy, orderBy, window
        case set, values, insertInto, returning, limit, ddl, insert, delete, update
    }

    /// What can come next at the caret.
    enum Clause: Equatable {
        /// Nothing yet, or after `;` / `(` / UNION: a statement begins.
        case start
        /// After SELECT, DISTINCT, RETURNING, or a comma in the select list.
        case select
        /// After FROM, JOIN, INTO, UPDATE, TRUNCATE: a table is named.
        case from
        /// A table reference is complete; a clause keyword or alias follows.
        /// The governing clause says which (FROM → WHERE…, UPDATE → SET).
        case afterTableRef(Governing)
        /// Inside a condition or expression. `valuePosition` is right after
        /// an operator, IN, BETWEEN, THEN…: a value is expected.
        case condition(valuePosition: Bool)
        /// After GROUP BY, ORDER BY, PARTITION BY, or a comma in one.
        case groupOrOrder
        /// After a column in ORDER BY: ASC, DESC, NULLS, LIMIT.
        case afterOrderColumn
        /// After SET, or a comma in the SET list.
        case set
        /// After `=` in SET, in VALUES (…), after LIMIT / OFFSET.
        case value
        /// Inside `INSERT INTO t (`: the target's columns.
        case insertColumns
        /// An expression is complete; the governing clause's keywords follow.
        case afterExpression(Governing)
        /// Only these keywords can follow (`GROUP` → BY, `DELETE` → FROM).
        case keywords([String])
        /// After `qualifier.`: the members of an alias, table or schema.
        case member(qualifier: String)
        /// Nothing belongs here (AS, WITH, inside a string or comment).
        case none
    }

    let tables: [TableRef]
    /// Aliases of derived tables: `(SELECT …) AS x`. Table-like, no columns.
    let derivedAliases: [String]
    /// Names defined by WITH. Table-like, no columns.
    let cteNames: [String]
    /// `expr AS name` in the select list, for ORDER BY / GROUP BY / HAVING.
    let selectAliases: [String]
    /// The table an UPDATE, INSERT or DELETE writes.
    let target: TableRef?
    let clause: Clause
    /// The identifier characters typed before the caret: the filter.
    let typed: String

    /// Every table-like name the statement has: tables by qualifier, then
    /// derived aliases, then CTEs.
    var sourceCount: Int { tables.count + derivedAliases.count + cteNames.count }

    // MARK: - Tokens

    enum TokenKind: Equatable { case word, quoted, number, string, variable, punct }

    struct Token: Equatable {
        let kind: TokenKind
        /// A word as typed, a quoted identifier without its quotes, an
        /// operator's text; empty for strings and variables.
        let text: String
        /// The word upper-cased, for keyword tests; empty otherwise.
        let upper: String
        let range: NSRange

        func isKeyword(_ keyword: String) -> Bool { kind == .word && upper == keyword }
        func isPunct(_ p: String) -> Bool { kind == .punct && text == p }
        var isName: Bool { kind == .word || kind == .quoted }
        var end: Int { range.location + range.length }
    }

    private static let operators = ["->>", "<>", "!=", "<=", ">=", "||", "::", "->", "=>"]

    /// The tokens of `range` in `snapshot`, strings and comments collapsed
    /// or dropped.
    static func tokens(in snapshot: SQLLexSnapshot, range: NSRange) -> [Token] {
        let chars = snapshot.chars
        let states = snapshot.stateMap
        let end = min(range.location + range.length, snapshot.length)
        var tokens: [Token] = []
        var i = max(0, range.location)

        func text(_ r: NSRange) -> String {
            String(utf16CodeUnits: Array(chars[r.location..<(r.location + r.length)]), count: r.length)
        }

        while i < end {
            switch states[i] {
            case .lineComment, .blockComment:
                i += 1
            case .singleQuote, .dollarQuote:
                let start = i
                let kind = states[i]
                while i < end, states[i] == kind { i += 1 }
                tokens.append(Token(kind: .string, text: "", upper: "", range: NSRange(location: start, length: i - start)))
            case .doubleQuote:
                let start = i
                while i < end, states[i] == .doubleQuote { i += 1 }
                var inner = text(NSRange(location: start, length: i - start))
                if inner.hasPrefix("\"") { inner.removeFirst() }
                if inner.hasSuffix("\"") { inner.removeLast() }
                tokens.append(Token(kind: .quoted, text: inner.replacingOccurrences(of: "\"\"", with: "\""),
                                    upper: "", range: NSRange(location: start, length: i - start)))
            case .normal:
                let c = chars[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                    i += 1
                } else if c == 0x7B, i + 1 < end, chars[i + 1] == 0x7B {  // {{
                    let start = i
                    i += 2
                    while i < end, !(chars[i] == 0x7D && i + 1 < end && chars[i + 1] == 0x7D) { i += 1 }
                    i = min(end, i + 2)
                    tokens.append(Token(kind: .variable, text: "", upper: "", range: NSRange(location: start, length: i - start)))
                } else if SQLLexer.isIdentChar(c) {
                    let start = i
                    let isNumber = c >= 0x30 && c <= 0x39
                    while i < end, SQLLexer.isIdentChar(chars[i]) || (isNumber && chars[i] == 0x2E) { i += 1 }
                    let r = NSRange(location: start, length: i - start)
                    let t = text(r)
                    tokens.append(isNumber
                        ? Token(kind: .number, text: t, upper: "", range: r)
                        : Token(kind: .word, text: t, upper: t.uppercased(), range: r))
                } else {
                    let start = i
                    var length = 1
                    for op in operators {
                        let u = Array(op.utf16)
                        if SQLLexer.matchesAt(chars: chars, offset: i, pattern: u, length: end) { length = u.count; break }
                    }
                    i += length
                    let r = NSRange(location: start, length: length)
                    tokens.append(Token(kind: .punct, text: text(r), upper: "", range: r))
                }
            }
        }
        return tokens
    }

    // MARK: - Analysis

    /// Words that end a table reference: what cannot be an alias.
    private static let notAnAlias: Set<String> = [
        "WHERE", "ON", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "USING",
        "GROUP", "ORDER", "LIMIT", "OFFSET", "SET", "VALUES", "RETURNING", "HAVING", "WINDOW",
        "UNION", "INTERSECT", "EXCEPT", "AS", "FOR", "TABLESAMPLE", "SELECT", "FROM", "INTO",
        "AND", "OR", "NOT", "IN", "IS", "LIKE", "WHEN", "THEN", "ELSE", "END", "ONLY", "LATERAL",
        "FETCH", "DEFAULT", "DO", "CONFLICT", "NOTHING",
    ]

    /// The scope at `caret` in `text`.
    static func analyze(_ text: String, caret rawCaret: Int) -> SQLStatementScope {
        let snapshot = SQLLexSnapshot.shared(for: text)
        let caret = min(max(0, rawCaret), snapshot.length)
        let chars = snapshot.chars

        // The statement: the segment at the caret, or all the text.
        let segments = SQLSegmentParser.parse(text)
        let range: NSRange
        if let index = SQLSegmentParser.segmentIndex(forCursorAt: caret, in: segments) {
            range = segments[index].range
        } else {
            range = NSRange(location: 0, length: snapshot.length)
        }

        // The word being typed is context for nothing: it is the filter.
        var wordStart = caret
        while wordStart > range.location, SQLLexer.isIdentChar(chars[wordStart - 1]) { wordStart -= 1 }
        let typed = String(utf16CodeUnits: Array(chars[wordStart..<caret]), count: caret - wordStart)

        let all = tokens(in: snapshot, range: range)
        let cteNames = collectCTEs(all)
        let (tables, derived, target) = collectTables(all)
        let tableAliases = Set(tables.compactMap(\.alias) + derived)
        let selectAliases = collectSelectAliases(all, excluding: tableAliases)

        let before = all.filter { $0.end <= wordStart }
        let clause = self.clause(before: before, wordStart: wordStart, snapshot: snapshot, all: all)

        return SQLStatementScope(
            tables: tables, derivedAliases: derived, cteNames: cteNames,
            selectAliases: selectAliases, target: target, clause: clause, typed: typed)
    }

    // MARK: Names the statement defines

    private static func collectCTEs(_ tokens: [Token]) -> [String] {
        var names: [String] = []
        var i = 0
        while i < tokens.count {
            guard tokens[i].isKeyword("WITH") else { i += 1; continue }
            var j = i + 1
            if j < tokens.count, tokens[j].isKeyword("RECURSIVE") { j += 1 }
            while j < tokens.count, tokens[j].isName {
                names.append(tokens[j].text)
                j += 1
                if j < tokens.count, tokens[j].isPunct("(") { j = skipGroup(tokens, from: j) }
                guard j < tokens.count, tokens[j].isKeyword("AS") else { break }
                j += 1
                if j < tokens.count, tokens[j].isKeyword("NOT") { j += 1 }
                if j < tokens.count, tokens[j].isKeyword("MATERIALIZED") { j += 1 }
                guard j < tokens.count, tokens[j].isPunct("(") else { break }
                j = skipGroup(tokens, from: j)
                guard j < tokens.count, tokens[j].isPunct(",") else { break }
                j += 1
            }
            i = max(j, i + 1)
        }
        return names
    }

    /// The index after the group that opens at `open`, or the count when it
    /// never closes.
    private static func skipGroup(_ tokens: [Token], from open: Int) -> Int {
        var depth = 0
        var j = open
        while j < tokens.count {
            if tokens[j].isPunct("(") { depth += 1 }
            if tokens[j].isPunct(")") { depth -= 1; if depth == 0 { return j + 1 } }
            j += 1
        }
        return tokens.count
    }

    private static func collectTables(_ tokens: [Token]) -> (tables: [TableRef], derived: [String], target: TableRef?) {
        var tables: [TableRef] = []
        var derived: [String] = []
        var target: TableRef?
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            let opensList = t.isKeyword("FROM") || t.isKeyword("JOIN") || t.isKeyword("UPDATE")
                || t.isKeyword("INTO") || t.isKeyword("TRUNCATE")
                || (t.isKeyword("TABLE") && i > 0 && (tokens[i - 1].isKeyword("ALTER") || tokens[i - 1].isKeyword("DROP")))
            guard opensList else { i += 1; continue }
            let isTarget = t.isKeyword("UPDATE") || t.isKeyword("INTO")
                || (t.isKeyword("FROM") && i > 0 && tokens[i - 1].isKeyword("DELETE"))
            let allowsList = t.isKeyword("FROM") || t.isKeyword("UPDATE") || t.isKeyword("TRUNCATE")

            var j = i + 1
            repeat {
                while j < tokens.count, tokens[j].isKeyword("ONLY") || tokens[j].isKeyword("LATERAL") { j += 1 }
                guard j < tokens.count else { break }
                if tokens[j].isPunct("(") {
                    // A derived table: skip its body, take its alias.
                    j = skipGroup(tokens, from: j)
                    if j < tokens.count, tokens[j].isKeyword("AS") { j += 1 }
                    if j < tokens.count, tokens[j].isName, !notAnAlias.contains(tokens[j].upper) {
                        derived.append(tokens[j].text)
                        j += 1
                    }
                } else if tokens[j].isName, !notAnAlias.contains(tokens[j].upper) {
                    var parts = [tokens[j].text]
                    j += 1
                    while j + 1 < tokens.count, tokens[j].isPunct("."), tokens[j + 1].isName {
                        parts.append(tokens[j + 1].text)
                        j += 2
                    }
                    var alias: String?
                    if j < tokens.count, tokens[j].isKeyword("AS") { j += 1 }
                    if j < tokens.count, tokens[j].isName, !notAnAlias.contains(tokens[j].upper) {
                        alias = tokens[j].text
                        j += 1
                    }
                    let ref = TableRef(schema: parts.count > 1 ? parts[parts.count - 2] : nil,
                                       table: parts[parts.count - 1], alias: alias)
                    tables.append(ref)
                    if isTarget, target == nil { target = ref }
                } else {
                    break
                }
                guard allowsList, j < tokens.count, tokens[j].isPunct(",") else { break }
                j += 1
            } while true
            // One step, not past what was parsed: a derived table's body has
            // its own FROM, and a superset of tables is the safe answer.
            i += 1
        }
        return (tables, derived, target)
    }

    private static func collectSelectAliases(_ tokens: [Token], excluding tableAliases: Set<String>) -> [String] {
        var aliases: [String] = []
        for i in 1..<max(1, tokens.count - 1) where tokens[i].isKeyword("AS") {
            let name = tokens[i + 1]
            guard name.isName, !notAnAlias.contains(name.upper), !tableAliases.contains(name.text) else { continue }
            let follower = i + 2 < tokens.count ? tokens[i + 2] : nil
            if follower == nil || follower!.isPunct(",") || follower!.isKeyword("FROM") {
                aliases.append(name.text)
            }
        }
        return aliases
    }

    // MARK: The clause at the caret

    private static let clauseKeywords: Set<String> = [
        "SELECT", "FROM", "JOIN", "ON", "WHERE", "HAVING", "BY", "SET", "VALUES", "INTO",
        "RETURNING", "LIMIT", "OFFSET", "UPDATE", "DELETE", "INSERT", "CREATE", "ALTER", "DROP", "USING",
    ]

    private static func clause(before: [Token], wordStart: Int, snapshot: SQLLexSnapshot, all: [Token]) -> Clause {
        // In a string or a comment nothing belongs.
        if wordStart > 0, wordStart - 1 < snapshot.length {
            switch snapshot.stateMap[wordStart - 1] {
            case .singleQuote, .dollarQuote, .lineComment, .blockComment: return .none
            case .doubleQuote:
                // Typing inside "quotes" — an identifier, unless the quote is
                // closed and the caret is after it.
                if snapshot.chars[wordStart - 1] != 0x22 { return .none }
            case .normal: break
            }
        }

        // `qualifier.` — members, whatever the clause.
        if wordStart > 0, snapshot.chars[wordStart - 1] == 0x2E {
            var parts: [String] = []
            var k = before.count - 1
            guard k >= 0, before[k].isPunct("."), before[k].end == wordStart else { return .none }
            k -= 1
            while k >= 0, before[k].isName, !(before[k].kind == .word && (clauseKeywords.contains(before[k].upper) || notAnAlias.contains(before[k].upper))) {
                parts.insert(before[k].text, at: 0)
                guard k >= 1, before[k - 1].isPunct(".") else { break }
                k -= 2
            }
            return parts.isEmpty ? .none : .member(qualifier: parts.suffix(2).joined(separator: "."))
        }

        // The tokens at the caret's depth, and the paren that encloses it.
        var atDepth: [Int] = []
        var openIndex: Int?
        var skip = 0
        var i = before.count - 1
        while i >= 0 {
            let t = before[i]
            if t.isPunct(")") {
                // A closed group is one expression at this depth.
                if skip == 0 { atDepth.append(i) }
                skip += 1; i -= 1; continue
            }
            if t.isPunct("(") {
                if skip > 0 { skip -= 1; i -= 1; continue }
                openIndex = i
                break
            }
            if t.isPunct(";") { break }
            if skip == 0 { atDepth.append(i) }
            i -= 1
        }
        atDepth.reverse()

        guard let lastIndex = atDepth.last else {
            // Right after `(`, or at the start of the statement.
            guard let openIndex else { return .start }
            guard openIndex > 0 else { return .start }
            let opener = before[openIndex - 1]
            if opener.isKeyword("VALUES") { return .value }
            if opener.isKeyword("IN") || opener.isKeyword("ANY") || opener.isKeyword("ALL") || opener.isKeyword("SOME")
                || opener.isKeyword("EXISTS") || isOperator(opener) {
                return .condition(valuePosition: true)
            }
            if opener.isKeyword("OVER") { return .afterExpression(.window) }
            if opener.isKeyword("USING") || opener.isKeyword("WHERE") || opener.isKeyword("AND") || opener.isKeyword("OR")
                || opener.isKeyword("ON") || opener.isKeyword("NOT") || opener.isKeyword("WHEN") || opener.isPunct(",") {
                return .condition(valuePosition: false)
            }
            if opener.isName {
                // `INSERT INTO t (` names columns; `f(` takes arguments.
                var k = openIndex - 1
                while k >= 2, before[k - 1].isPunct(".") { k -= 2 }
                if k >= 1, before[k - 1].isKeyword("INTO") { return .insertColumns }
                if opener.kind == .word, !clauseKeywords.contains(opener.upper), !opener.isKeyword("AS") {
                    return .condition(valuePosition: false)
                }
            }
            return .start
        }

        let last = before[lastIndex]
        let governing = self.governing(before, atDepth: atDepth, openIndex: openIndex)

        if last.kind == .word {
            switch last.upper {
            case "SELECT", "DISTINCT", "RETURNING": return .select
            case "ALL" where governing == .select: return .select
            case "FROM", "JOIN", "INTO", "UPDATE", "TRUNCATE", "ONLY", "LATERAL": return .from
            case "ON" where self.governing(before, atDepth: Array(atDepth.dropLast()), openIndex: openIndex) == .values:
                return .keywords(["CONFLICT"])
            case "TABLE": return governing == .ddl && !(atDepth.count >= 2 && before[atDepth[atDepth.count - 2]].isKeyword("CREATE")) ? .from : .none
            case "WHERE", "AND", "OR", "NOT", "ON", "HAVING", "WHEN", "CASE", "USING": return .condition(valuePosition: false)
            case "IN", "LIKE", "ILIKE", "BETWEEN", "THEN", "ELSE", "IS": return .condition(valuePosition: true)
            case "BY": return .groupOrOrder
            case "GROUP", "ORDER", "PARTITION": return .keywords(["BY"])
            case "SET": return governing == .set ? .set : .none
            case "VALUES", "AS", "WITH", "RECURSIVE", "OVER": return .none
            case "LIMIT", "OFFSET": return .value
            case "CREATE", "ALTER", "DROP":
                return .keywords(["TABLE", "INDEX", "VIEW", "MATERIALIZED VIEW", "SCHEMA", "FUNCTION", "SEQUENCE", "TYPE", "EXTENSION"])
            case "EXPLAIN", "ANALYZE", "VERBOSE", "UNION", "INTERSECT", "EXCEPT": return .start
            case "DELETE": return .keywords(["FROM"])
            case "INSERT": return .keywords(["INTO"])
            case "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER": return .keywords(["JOIN", "OUTER JOIN"])
            case "NULLS": return .keywords(["FIRST", "LAST"])
            case "ASC", "DESC": return .afterExpression(.orderBy)
            case "NULL", "TRUE", "FALSE", "DEFAULT", "END": return .afterExpression(governing)
            default: break  // an identifier
            }
        }

        if last.kind == .punct {
            switch last.text {
            case ",":
                switch governing {
                case .select, .returning: return .select
                case .from, .join, .update: return .from
                case .set: return .set
                case .groupBy, .orderBy, .window: return .groupOrOrder
                case .insertInto: return .insertColumns
                case .values: return .value
                case .on, .condition: return .condition(valuePosition: false)
                default: return .none
                }
            case "*":
                // `SELECT *` is an expression; `a * ` is an operator.
                if atDepth.count >= 2 {
                    let prev = before[atDepth[atDepth.count - 2]]
                    if prev.isKeyword("SELECT") || prev.isPunct(",") { return .afterExpression(governing) }
                }
                return .condition(valuePosition: true)
            case "::": return .none
            default:
                return isOperator(last) ? .condition(valuePosition: true) : .afterExpression(governing)
            }
        }

        // An identifier, a number, a string, a variable, or `)`: the
        // expression is complete.
        switch governing {
        case .from, .join, .update: return last.isName ? .afterTableRef(governing) : .afterExpression(governing)
        case .orderBy: return .afterOrderColumn
        default: return .afterExpression(governing)
        }
    }

    private static func isOperator(_ t: Token) -> Bool {
        guard t.kind == .punct else { return false }
        switch t.text {
        case "=", "<", ">", "<>", "!=", "<=", ">=", "||", "+", "-", "/", "%", "->", "->>", "^", "&", "|", "~", "!", "*":
            return true
        default:
            return false
        }
    }

    private static func governing(_ before: [Token], atDepth: [Int], openIndex: Int?) -> Governing {
        for index in atDepth.reversed() {
            let t = before[index]
            guard t.kind == .word, clauseKeywords.contains(t.upper) else { continue }
            switch t.upper {
            case "SELECT": return .select
            case "FROM": return .from
            case "JOIN": return .join
            case "ON", "USING": return .on
            case "WHERE", "HAVING": return .condition
            case "BY":
                guard index > 0 else { return .groupBy }
                if before[index - 1].isKeyword("ORDER") { return .orderBy }
                if before[index - 1].isKeyword("PARTITION") { return .window }
                return .groupBy
            case "SET": return .set
            case "VALUES": return .values
            case "INTO": return .insertInto
            case "RETURNING": return .returning
            case "LIMIT", "OFFSET": return .limit
            case "UPDATE": return .update
            case "DELETE": return .delete
            case "INSERT": return .insert
            case "CREATE", "ALTER", "DROP": return .ddl
            default: continue
            }
        }
        // Nothing at this depth governs: what opened the group does.
        // `VALUES (1, |`, `INSERT INTO t (a, |`, `lower(a, |`.
        guard let openIndex, openIndex > 0 else { return .statement }
        let opener = before[openIndex - 1]
        if opener.isKeyword("VALUES") { return .values }
        if opener.isKeyword("OVER") { return .window }
        if opener.isName {
            var k = openIndex - 1
            while k >= 2, before[k - 1].isPunct(".") { k -= 2 }
            if k >= 1, before[k - 1].isKeyword("INTO") { return .insertInto }
            return .condition
        }
        if opener.isKeyword("IN") || opener.isKeyword("EXISTS") || opener.isKeyword("ANY") || opener.isKeyword("ALL")
            || opener.isKeyword("USING") || opener.isKeyword("WHERE") || opener.isKeyword("AND") || opener.isKeyword("OR")
            || opener.isKeyword("ON") || opener.isKeyword("NOT") || isOperator(opener) || opener.isPunct(",") {
            return .condition
        }
        return .statement
    }
}
