import Foundation

/// Which path a card runs on: the row path (a grid of rows) or the statement
/// path (a count of changed rows). Pure and Foundation-only (it needs
/// `Models/Connection.swift`), so `scripts/test-run-path-rule.sh` pins it.
enum RunPathRule {

    /// Words that start a statement returning rows, on every engine.
    static let rowWords: Set<String> = ["SELECT", "WITH", "EXPLAIN", "SHOW", "TABLE", "VALUES"]
    /// DuckDB's own row-returning statements: FROM-first queries, DESCRIBE,
    /// SUMMARIZE, PIVOT / UNPIVOT, PRAGMA and CALL (table functions). The
    /// statement path showed "0 rows affected" for them. Paging never runs one
    /// again (the core refuses what it cannot wrap in LIMIT/OFFSET).
    static let duckDBRowWords: Set<String> = ["FROM", "DESCRIBE", "SUMMARIZE", "PIVOT", "UNPIVOT", "PRAGMA", "CALL"]

    /// - Parameters:
    ///   - sql: the card's text.
    ///   - lastStatement: for DuckDB, the card's last statement: the core runs
    ///     every statement and shows the LAST one's result, so that is the one
    ///     to judge. nil judges `sql` itself (PostgreSQL, or one statement).
    static func returnsRows(sql: String, engine: DatabaseEngine, lastStatement: String? = nil) -> Bool {
        switch engine {
        case .postgres:
            return rowWords.contains(firstWord(sql))
        case .duckdb:
            let word = firstWord(lastStatement ?? sql)
            return rowWords.contains(word) || duckDBRowWords.contains(word)
        }
    }

    /// Statements that change what the Database Navigator and completion
    /// show (N1). A comment or a string never counts: each statement is
    /// judged by its first word, after comments.
    static let catalogWords: Set<String> = ["CREATE", "DROP", "ALTER", "ATTACH", "DETACH", "IMPORT", "COMMENT"]

    /// Does any of these statements (a card's, split by `SQLSegmentParser`)
    /// change the catalog? `COPY FROM DATABASE` copies tables in, so it
    /// counts; any other COPY does not.
    static func changesCatalog(statements: [String]) -> Bool {
        statements.contains { statement in
            let word = firstWord(statement)
            if catalogWords.contains(word) { return true }
            guard word == "COPY" else { return false }
            let words = stripLeadingComments(statement).uppercased()
                .split(whereSeparator: { $0.isWhitespace }).prefix(4).map(String.init)
            return words.count >= 3 && words[1] == "FROM" && words[2] == "DATABASE"
        }
    }

    /// The first word of `sql`, upper-cased, after comments and whitespace.
    static func firstWord(_ sql: String) -> String {
        String(stripLeadingComments(sql).prefix { $0.isLetter || $0 == "_" }).uppercased()
    }

    static func stripLeadingComments(_ sql: String) -> String {
        var s = sql[sql.startIndex...]
        while !s.isEmpty {
            if s.first?.isWhitespace == true {
                s = s.drop(while: { $0.isWhitespace })
                continue
            }
            if s.hasPrefix("--") {
                if let newline = s.firstIndex(of: "\n") {
                    s = s[s.index(after: newline)...]
                } else {
                    return ""
                }
                continue
            }
            if s.hasPrefix("/*") {
                var depth = 1
                var i = s.index(s.startIndex, offsetBy: 2)
                while i < s.endIndex && depth > 0 {
                    if s[i] == "/" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "*" {
                        depth += 1
                        i = s.index(i, offsetBy: 2)
                    } else if s[i] == "*" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "/" {
                        depth -= 1
                        i = s.index(i, offsetBy: 2)
                    } else {
                        i = s.index(after: i)
                    }
                }
                s = s[i...]
                continue
            }
            break
        }
        return String(s)
    }
}
