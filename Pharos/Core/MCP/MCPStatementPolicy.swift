import Foundation

/// Whether a statement an AI app asked to run is a plain read of the
/// database. One that is runs without asking the user; anything else needs
/// "AI apps that can change data" (Settings ▸ Security & Privacy) and, unless
/// the user also chose "without asking", their confirmation of each run.
///
/// This is an ALLOWLIST: the statement must be one statement, start with a
/// word that reads (SELECT, WITH, …), and hold nothing known to write or to
/// reach outside the database. `DestructiveSQLScanner`'s seven keywords are
/// right for the user's own mis-click and wrong for an app: `DO $$ … $$`,
/// `CREATE TABLE … AS`, `COPY … TO`, `CALL`, `ATTACH` and DuckDB's
/// `read_text('/Users/…')` hold none of them.
///
/// Text is still only text: a function can write whatever it is called. So
/// a run that passes here is sent GUARDED (`SessionRunBody.guarded`), and the
/// core holds it to a read: PostgreSQL in a read-only transaction, DuckDB by
/// checking the parsed statement for files and addresses
/// (`pharos-core/src/db/duckdb/guard.rs`). What the core refuses comes back
/// starting with `guardRefusal`.
///
/// Foundation and `SQLLexer` only (scripts/test-mcp-statement-policy.sh).
enum MCPStatementPolicy {

    /// The first sentence of the core's refusal of a guarded run
    /// (`GUARD_REFUSAL` in tab_session.rs, `REFUSAL` in duckdb/guard.rs).
    static let guardRefusal = "Pharos runs a statement for an AI app without asking the user only when it reads the database and nothing else."

    /// What the confirmation says of a statement the core refused: the text
    /// held nothing this file knows, so there is no word to name.
    static let unnamedReason = "more than a read of the database"

    /// The words a read starts with, on every engine.
    private static let heads: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE", "EXPLAIN", "SHOW"]
    /// DuckDB's own: FROM-first queries, DESCRIBE, SUMMARIZE.
    private static let duckDBHeads: Set<String> = ["FROM", "DESCRIBE", "DESC", "SUMMARIZE"]

    /// Words that make a statement write wherever they stand: a
    /// data-modifying CTE, `SELECT … INTO`, `FOR UPDATE`, and what
    /// `EXPLAIN ANALYZE` can run.
    private static let writingWords: Set<String> = [
        "DROP", "DELETE", "TRUNCATE", "UPDATE", "ALTER", "INSERT", "GRANT",
        "MERGE", "INTO", "CREATE", "EXECUTE", "REFRESH", "DECLARE", "REVOKE",
    ]

    /// PostgreSQL functions a read-only transaction does not stop: they
    /// reach the server's files, other sessions, other servers, or change
    /// what outlives the transaction.
    private static let postgresFunctions: Set<String> = [
        "pg_terminate_backend", "pg_cancel_backend", "pg_reload_conf", "pg_rotate_logfile", "pg_switch_wal",
        "pg_promote", "pg_read_file", "pg_read_binary_file", "pg_stat_file", "set_config", "setval", "nextval",
        "pg_notify", "pg_logical_emit_message",
    ]
    private static let postgresFunctionPrefixes = [
        "pg_ls_", "lo_", "dblink", "pg_advisory_", "pg_replication_", "pg_create_", "pg_drop_", "pg_backup_",
        "pg_wal_replay_", "pg_file_", "query_to_xml", "cursor_to_xml",
    ]

    /// DuckDB functions that read files, addresses or other databases. The
    /// core's check of the parsed statement is the one that decides; these
    /// let the user be asked instead of the app being refused.
    private static let duckDBFunctions: Set<String> = [
        "glob", "sniff_csv", "st_read", "query", "query_table", "nextval", "getenv", "duckdb_secrets", "which_secret",
    ]
    private static let duckDBFunctionPrefixes = [
        "read_", "parquet_", "sqlite_", "postgres_", "mysql_", "iceberg_", "delta_", "http_",
    ]

    private enum Token: Equatable {
        case word(String)        // upper-cased
        case punctuation(unichar)
        case string
        case quoted(String)      // a "quoted identifier", without the quotes
    }

    /// First words that reach outside the database or change how the engine
    /// behaves: files (`COPY`, `EXPORT`, `IMPORT`), other databases
    /// (`ATTACH`), code (`INSTALL`, `LOAD`), settings (`SET`, `PRAGMA`).
    private static let outsideHeads: Set<String> = [
        "COPY", "ATTACH", "DETACH", "INSTALL", "LOAD", "EXPORT", "IMPORT", "SET", "RESET", "PRAGMA", "USE",
    ]

    /// Guarded functions that write to the database and reach nowhere else.
    private static let writingFunctions: Set<String> = ["nextval", "setval"]

    /// What `finding(in:duckDB:)` found.
    struct Finding: Equatable {
        /// Why the statement is not a plain read, for the refusal and the
        /// confirmation: keywords in capitals, functions as `name()`, in
        /// first-seen order. Empty when it is one.
        var reasons: [String] = []
        /// Those of `reasons` that reach outside the database: a file,
        /// another server or database, the engine's settings. The user is
        /// asked about these even for an app that changes data without
        /// asking; that choice is for changes to the database.
        var outside: [String] = []
    }

    /// `finding(in:duckDB:).reasons`.
    static func reasons(in sql: String, duckDB: Bool) -> [String] {
        finding(in: sql, duckDB: duckDB).reasons
    }

    static func finding(in sql: String, duckDB: Bool) -> Finding {
        var found = Finding()
        func add(_ reason: String, outside: Bool = false) {
            if !found.reasons.contains(reason) { found.reasons.append(reason) }
            if outside, !found.outside.contains(reason) { found.outside.append(reason) }
        }
        func addFunction(_ name: String) {
            add("\(name)()", outside: !writingFunctions.contains(name))
        }

        let statements = tokens(of: sql).split(separator: .punctuation(0x3B), omittingEmptySubsequences: true)
        if statements.count > 1 { add("more than one statement") }

        for statement in statements {
            let tokens = Array(statement)
            switch tokens.first {
            case let .word(word):
                if !(heads.contains(word) || (duckDB && duckDBHeads.contains(word))) {
                    add(word, outside: outsideHeads.contains(word))
                }
            case .punctuation(0x28):   // "(": a parenthesised SELECT
                break
            default:
                add("a statement that does not start with a word")
            }

            for (i, token) in tokens.enumerated() {
                let next = i + 1 < tokens.count ? tokens[i + 1] : nil
                switch token {
                case let .word(word):
                    if writingWords.contains(word) { add(word) }
                    // U&"…" and U&'…' spell a name in escapes this cannot read.
                    if word == "U", next == .punctuation(0x26), i + 2 < tokens.count {
                        switch tokens[i + 2] {
                        case .string, .quoted: add("a Unicode-escaped name", outside: true)
                        case .word, .punctuation: break
                        }
                    }
                    if next == .punctuation(0x28), isGuardedFunction(word.lowercased(), duckDB: duckDB) {
                        addFunction(word.lowercased())
                    }
                    if duckDB, ["FROM", "JOIN", "DESCRIBE", "DESC", "SUMMARIZE"].contains(word) {
                        // `FROM 'x.csv'`, `FROM "/tmp/x.parquet"`: DuckDB reads a file.
                        if next == .string { add("a file or address read as a table", outside: true) }
                        if case let .quoted(name)? = next, name.contains(where: { "./:\\*".contains($0) }) {
                            add("a file or address read as a table", outside: true)
                        }
                    }
                case let .quoted(name):
                    if next == .punctuation(0x28), isGuardedFunction(name.lowercased(), duckDB: duckDB) {
                        addFunction(name.lowercased())
                    }
                case .punctuation, .string:
                    break
                }
            }
        }
        return found
    }

    private static func isGuardedFunction(_ name: String, duckDB: Bool) -> Bool {
        if duckDB {
            return duckDBFunctions.contains(name) || duckDBFunctionPrefixes.contains(where: name.hasPrefix)
        }
        return postgresFunctions.contains(name) || postgresFunctionPrefixes.contains(where: name.hasPrefix)
    }

    /// `sql` as words, punctuation, strings and quoted identifiers, by the
    /// shared lexer's state map: a comment is nothing, a string (dollar-quoted
    /// too) is one token whatever it holds.
    private static func tokens(of sql: String) -> [Token] {
        let chars = Array(sql.utf16)
        let states = SQLLexer.buildStateMap(chars: chars, length: chars.count)
        var tokens: [Token] = []
        var word = ""
        var quoted: [unichar]?
        var inString = false

        func flushWord() {
            if !word.isEmpty { tokens.append(.word(word.uppercased())) }
            word = ""
        }
        func flushQuoted() {
            guard let units = quoted else { return }
            // The state map marks both quotes as part of the identifier.
            var name = String(utf16CodeUnits: units, count: units.count)
            if name.hasPrefix("\"") { name.removeFirst() }
            if name.hasSuffix("\"") { name.removeLast() }
            tokens.append(.quoted(name.replacingOccurrences(of: "\"\"", with: "\"")))
            quoted = nil
        }

        for (i, ch) in chars.enumerated() {
            switch states[i] {
            case .normal:
                flushQuoted()
                inString = false
                if isWordChar(ch) {
                    word.append(Character(Unicode.Scalar(ch) ?? " "))
                } else {
                    flushWord()
                    if !isSpace(ch) { tokens.append(.punctuation(ch)) }
                }
            case .doubleQuote:
                flushWord()
                inString = false
                quoted = (quoted ?? []) + [ch]
            case .singleQuote, .dollarQuote:
                flushWord()
                flushQuoted()
                if !inString { tokens.append(.string) }
                inString = true
            case .lineComment, .blockComment:
                flushWord()
                flushQuoted()
                inString = false
            }
        }
        flushWord()
        flushQuoted()
        return tokens
    }

    /// A character of an unquoted name. Anything outside ASCII counts: a
    /// keyword must not be cut out of `é_delete` and left standing.
    private static func isWordChar(_ ch: unichar) -> Bool {
        (ch >= 0x30 && ch <= 0x39) || (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
            || ch == 0x5F || ch == 0x24 || ch >= 0x80
    }

    private static func isSpace(_ ch: unichar) -> Bool {
        ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x0C || ch == 0x0B
    }
}
