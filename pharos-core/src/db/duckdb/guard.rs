//! What an AI app's statement may do on DuckDB before the user has allowed
//! it to change data: read the database, and nothing else.
//!
//! DuckDB reaches outside the database from an ordinary SELECT:
//! `read_text('/Users/…/.ssh/id_ed25519')`, `FROM '/path/x.csv'`,
//! `read_csv('https://…')`, `ATTACH` of another file, `COPY … TO` a file.
//! Pharos is not sandboxed, so that is every file the user can read, and
//! Pharos's own store with it. The setting that turns this off
//! (`enable_external_access`) belongs to the whole database, which the user's
//! own tabs share, so it cannot be turned off for one statement.
//!
//! So a guarded statement is read the way DuckDB reads it, not as text:
//! `json_serialize_sql` gives the parsed tree (and refuses anything that is
//! not one SELECT), and every table in it must be a table: one that is in
//! the catalog, or a plain unqualified name, which no file reader claims.
//! A table function must be one of the few that read nothing outside the
//! database.
//!
//! What the statement names is looked through as well. A view is checked by
//! the query it stands for, and the views in that, so `SELECT * FROM v` is
//! refused when `v` reads a file. A macro the user defined is refused
//! outright: its body can hold a subquery that reads one, and a macro is
//! rare enough in a read that asking the user costs little.
//!
//! A statement that fails is not run; the app is told why, and the
//! user can allow it (Settings ▸ Security & Privacy ▸ AI apps that can change
//! data), after which Pharos asks them about each such run.

use std::collections::HashSet;

use duckdb::Connection;
use serde_json::Value;

/// The start of every refusal, for the app that asked.
pub const REFUSAL: &str = "Pharos runs a statement for an AI app without asking the user only when it reads the database and nothing else.";

/// How the user lets the statement through.
const ALLOW: &str = "The user can allow it in Pharos: Settings ▸ Security & Privacy ▸ AI apps that can change data. Pharos then asks them about each run.";

/// Table functions that read nothing outside the database.
const TABLE_FUNCTIONS: &[&str] = &["range", "generate_series", "unnest", "generate_subscripts", "repeat", "repeat_row"];

/// Scalar functions that change something or read the process.
const SCALAR_FUNCTIONS: &[&str] = &["nextval", "getenv"];

/// The kinds of table reference a guarded statement may hold. Anything
/// DuckDB adds later is refused until it is looked at.
const TABLE_REFS: &[&str] =
    &["BASE_TABLE", "SUBQUERY", "JOIN", "TABLE_FUNCTION", "EXPRESSION_LIST", "EMPTY", "SHOW_REF", "PIVOT", "CTE"];

fn refusal(why: &str) -> String {
    format!("{REFUSAL} This one {why}. {ALLOW}")
}

/// Refuse `sql` unless it is one statement that reads the database only.
pub fn check(conn: &Connection, sql: &str) -> Result<(), String> {
    let stmts = super::exec::statements(sql);
    let [statement] = stmts.as_slice() else {
        return Err(refusal("holds more than one statement"));
    };
    let tree = parse(conn, explained(statement))?;
    let mut guard = Guard { conn, views: HashSet::new(), functions: HashSet::new(), depth: 0 };
    guard.walk(&tree)
}

/// Views inside views inside views: deeper than this is refused.
const MAX_VIEW_DEPTH: usize = 16;

/// One statement's check: the connection, and what it has already looked up.
struct Guard<'a> {
    conn: &'a Connection,
    /// The view definitions already checked (or being checked).
    views: HashSet<String>,
    /// The function names already found not to be the user's macros.
    functions: HashSet<String>,
    depth: usize,
}

/// The statement an `EXPLAIN [ANALYZE] [(options)]` explains: it is what
/// runs, or would. Any other statement is itself.
fn explained(statement: &str) -> &str {
    let rest = statement.trim_start();
    let Some(mut rest) = strip_word(rest, "EXPLAIN") else { return statement };
    if let Some(after) = strip_word(rest, "ANALYZE") {
        rest = after;
    }
    if rest.starts_with('(') {
        // Options hold no parentheses of their own: `(FORMAT json)`.
        if let Some(end) = rest.find(')') {
            rest = rest[end + 1..].trim_start();
        }
    }
    rest
}

/// `text` after `word` and the space behind it, when it starts with `word`.
fn strip_word<'a>(text: &'a str, word: &str) -> Option<&'a str> {
    let head = text.get(..word.len())?;
    let rest = &text[word.len()..];
    (head.eq_ignore_ascii_case(word) && rest.starts_with(|c: char| c.is_whitespace() || c == '('))
        .then(|| rest.trim_start())
}

/// DuckDB's own parse of one SELECT.
fn parse(conn: &Connection, statement: &str) -> Result<Value, String> {
    let json: String = conn
        .query_row("SELECT json_serialize_sql(?::VARCHAR)", [statement], |row| row.get(0))
        .map_err(|e| format!("{REFUSAL} Pharos could not read this one: {e}"))?;
    let tree: Value = serde_json::from_str(&json).map_err(|e| format!("{REFUSAL} Pharos could not read this one: {e}"))?;
    if tree.get("error").and_then(Value::as_bool) != Some(false) {
        return Err(match tree.get("error_type").and_then(Value::as_str) {
            // A syntax error is the app's to fix; DuckDB's words say where.
            Some("parser") => tree.get("error_message").and_then(Value::as_str).unwrap_or("syntax error").to_string(),
            _ => refusal("is not a SELECT"),
        });
    }
    match tree.get("statements").and_then(Value::as_array).map(Vec::as_slice) {
        Some([only]) => Ok(only.clone()),
        _ => Err(refusal("holds more than one statement")),
    }
}

fn text<'a>(node: &'a serde_json::Map<String, Value>, key: &str) -> &'a str {
    node.get(key).and_then(Value::as_str).unwrap_or("")
}

impl Guard<'_> {
fn walk(&mut self, value: &Value) -> Result<(), String> {
    match value {
        Value::Array(items) => items.iter().try_for_each(|v| self.walk(v)),
        Value::Object(node) => {
            let kind = text(node, "type");
            // A table reference carries `sample` and `alias`; a query node
            // has `sample` alone, an expression `alias` and a `class`.
            let table_ref = node.contains_key("sample") && node.contains_key("alias") && !node.contains_key("class");
            if table_ref || kind == "SHOW_REF" {
                if !TABLE_REFS.contains(&kind) {
                    return Err(refusal(&format!("uses a kind of table Pharos does not know ({kind})")));
                }
                match kind {
                    "BASE_TABLE" => self.check_table(node)?,
                    "TABLE_FUNCTION" => check_table_function(node)?,
                    _ => {}
                }
            }
            if text(node, "class") == "FUNCTION" {
                let name = text(node, "function_name").to_ascii_lowercase();
                if SCALAR_FUNCTIONS.contains(&name.as_str()) {
                    return Err(refusal(&format!("calls {name}()")));
                }
                self.check_not_a_macro(&name)?;
            }
            node.values().try_for_each(|v| self.walk(v))
        }
        _ => Ok(()),
    }
}

/// Refuse a macro the user (or an app, with their leave) defined. DuckDB's
/// own macros (`internal`) are part of the engine.
fn check_not_a_macro(&mut self, name: &str) -> Result<(), String> {
    if name.is_empty() || self.functions.contains(name) {
        return Ok(());
    }
    let is_macro: bool = self
        .conn
        .query_row(
            "SELECT count(*) > 0 FROM duckdb_functions() \
             WHERE lower(function_name) = ?1 AND function_type IN ('macro', 'table_macro') AND NOT internal",
            [name],
            |row| row.get(0),
        )
        .map_err(|e| format!("{REFUSAL} Pharos could not look up a function of this one: {e}"))?;
    if is_macro {
        return Err(refusal(&format!("calls the macro {name}(), and what a macro does is in its definition")));
    }
    self.functions.insert(name.to_string());
    Ok(())
}

/// Check the query behind every view this name can mean. A name with no
/// schema is looked up in every schema: which one the search path picks is
/// not worth guessing, and a view that reads a file is refused either way.
fn check_views(&mut self, catalog: &str, schema: &str, table: &str) -> Result<(), String> {
    let definitions: Vec<String> = {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT sql FROM duckdb_views() \
                 WHERE NOT internal AND lower(view_name) = lower(?1) \
                   AND CASE WHEN ?3 <> '' THEN lower(database_name) = lower(?3) AND lower(schema_name) = lower(?2) \
                            WHEN ?2 <> '' THEN lower(schema_name) = lower(?2) OR lower(database_name) = lower(?2) \
                            ELSE true END",
            )
            .map_err(|e| format!("{REFUSAL} Pharos could not look up a view of this one: {e}"))?;
        let rows = stmt
            .query_map([table, schema, catalog], |row| row.get::<_, Option<String>>(0))
            .map_err(|e| format!("{REFUSAL} Pharos could not look up a view of this one: {e}"))?;
        rows.filter_map(|r| r.ok().flatten()).collect()
    };
    for definition in definitions {
        if !self.views.insert(definition.clone()) {
            continue;
        }
        if self.depth >= MAX_VIEW_DEPTH {
            return Err(refusal(&format!("reads the view “{table}”, whose views go too deep to check")));
        }
        let Some(query) = view_query(&definition) else {
            return Err(refusal(&format!("reads the view “{table}”, whose definition Pharos could not read")));
        };
        let tree = parse(self.conn, query)
            .map_err(|_| refusal(&format!("reads the view “{table}”, whose definition Pharos could not read")))?;
        self.depth += 1;
        let inner = self.walk(&tree);
        self.depth -= 1;
        inner.map_err(|why| match why.strip_prefix(REFUSAL) {
            Some(rest) => format!("{REFUSAL} This one reads the view “{table}”, and that view’s query is refused:{rest}"),
            None => why,
        })?;
    }
    Ok(())
}
}

/// The query of a view's stored definition: what follows the first `AS`
/// that is outside quotes and parentheses in
/// `CREATE VIEW name [(columns)] AS query;`.
fn view_query(definition: &str) -> Option<&str> {
    let bytes = definition.as_bytes();
    let (mut depth, mut quoted, mut i) = (0usize, false, 0usize);
    while i < bytes.len() {
        let b = bytes[i];
        if quoted {
            quoted = b != b'"';
        } else {
            match b {
                b'"' => quoted = true,
                b'(' => depth += 1,
                b')' => depth = depth.saturating_sub(1),
                b'A' | b'a' if depth == 0 => {
                    let word = bytes.get(i + 1).is_some_and(|c| c.eq_ignore_ascii_case(&b'S'));
                    let before = i > 0 && bytes[i - 1].is_ascii_whitespace();
                    let after = bytes.get(i + 2).is_some_and(|c| c.is_ascii_whitespace() || *c == b'(');
                    if word && before && after {
                        return Some(definition[i + 2..].trim().trim_end_matches(';').trim_end());
                    }
                }
                _ => {}
            }
        }
        i += 1;
    }
    None
}

fn check_table_function(node: &serde_json::Map<String, Value>) -> Result<(), String> {
    let name = node
        .get("function")
        .and_then(Value::as_object)
        .map(|f| text(f, "function_name").to_ascii_lowercase())
        .unwrap_or_default();
    // DuckDB's own catalog and storage readers: `duckdb_tables()`,
    // `pragma_table_info('t')`. Stored secrets are not for an app to list.
    let catalog_reader = (name.starts_with("duckdb_") && name != "duckdb_secrets") || name.starts_with("pragma_");
    if TABLE_FUNCTIONS.contains(&name.as_str()) || catalog_reader {
        return Ok(());
    }
    let shown = if name.is_empty() { "a table function".to_string() } else { format!("{name}()") };
    Err(refusal(&format!("calls {shown}, which can read outside the database")))
}

/// A name no file reader claims: DuckDB reads `'x.csv'`, `data.csv`,
/// `'/tmp/x'` and `'s3://…'` as files when no table has the name, and each
/// of those has a dot, a slash or a colon in it.
fn is_plain(name: &str) -> bool {
    !name.is_empty() && !name.chars().any(|c| matches!(c, '.' | '/' | '\\' | ':' | '*' | '?' | '[' | ']' | '~' | '{' | '}'))
}

impl Guard<'_> {
fn check_table(&mut self, node: &serde_json::Map<String, Value>) -> Result<(), String> {
    let conn = self.conn;
    let (catalog, schema, table) = (text(node, "catalog_name"), text(node, "schema_name"), text(node, "table_name"));
    // A view is what its query reads.
    self.check_views(catalog, schema, table)?;
    if catalog.is_empty() && schema.is_empty() && is_plain(table) {
        // A table, a view or a CTE; if it is none of them the run fails.
        return Ok(());
    }
    // A qualified or unusual name is a table only if the catalog has it:
    // `data.csv` is the file data.csv unless schema `data` holds table `csv`.
    // `a.b` may be schema.table or database.table.
    let found: bool = conn
        .query_row(
            "SELECT count(*) > 0 FROM ( \
                 SELECT database_name AS d, schema_name AS s, table_name AS t FROM duckdb_tables() \
                 UNION ALL SELECT database_name, schema_name, view_name FROM duckdb_views()) \
             WHERE lower(t) = lower(?1) \
               AND CASE WHEN ?3 <> '' THEN lower(d) = lower(?3) AND lower(s) = lower(?2) \
                        WHEN ?2 <> '' THEN lower(s) = lower(?2) OR lower(d) = lower(?2) \
                        ELSE true END",
            [table, schema, catalog],
            |row| row.get(0),
        )
        .map_err(|e| format!("{REFUSAL} Pharos could not look up a table of this one: {e}"))?;
    if found {
        return Ok(());
    }
    let name = [catalog, schema, table].iter().filter(|p| !p.is_empty()).copied().collect::<Vec<_>>().join(".");
    Err(refusal(&format!("reads “{name}”, which is not a table in this database and may be a file or an address")))
}
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::duckdb::{DuckDbInstance, OpenOptions, IN_MEMORY};

    fn conn() -> Connection {
        let instance = DuckDbInstance::open(IN_MEMORY, false, &OpenOptions::default()).unwrap();
        let conn = instance.connect().unwrap();
        conn.execute_batch(
            "CREATE TABLE t(i INTEGER); INSERT INTO t VALUES (1), (2); \
             CREATE SCHEMA s; CREATE TABLE s.u(i INTEGER); \
             CREATE SCHEMA data; CREATE TABLE data.csv(i INTEGER); \
             CREATE TABLE \"odd.name\"(i INTEGER); CREATE VIEW v AS SELECT * FROM t; \
             CREATE SEQUENCE seq; CREATE TEMP TABLE tmp(i INTEGER);",
        )
        .unwrap();
        // The instance must outlive the connection for the test's length.
        std::mem::forget(instance);
        conn
    }

    fn allowed(c: &Connection, sql: &str) {
        if let Err(e) = check(c, sql) {
            panic!("refused: {sql}\n{e}");
        }
    }

    fn refused(c: &Connection, sql: &str) -> String {
        match check(c, sql) {
            Ok(()) => panic!("allowed: {sql}"),
            Err(e) => e,
        }
    }

    #[test]
    fn reads_of_the_database_pass() {
        let c = conn();
        for sql in [
            "SELECT * FROM t",
            "select i, count(*) from t group by all order by 1 limit 5;",
            "-- how many\nSELECT count(*) FROM t",
            "FROM t",
            "TABLE t",
            "VALUES (1), (2)",
            "WITH c AS (SELECT i FROM t) SELECT * FROM c JOIN v USING (i)",
            "SELECT * FROM s.u",
            "SELECT * FROM memory.s.u",
            "SELECT * FROM memory.t",
            "SELECT * FROM data.csv",
            "SELECT * FROM \"odd.name\"",
            "SELECT * FROM tmp",
            "SELECT * FROM information_schema.tables",
            "SELECT * FROM pg_catalog.pg_class",
            "SELECT * FROM duckdb_tables()",
            "SELECT * FROM pragma_table_info('t')",
            "SELECT * FROM range(3) r, generate_series(1, 2) g",
            "SELECT unnest([1, 2])",
            "SELECT (SELECT max(i) FROM t), i IN (SELECT i FROM s.u) FROM t",
            "DESCRIBE t",
            "SHOW TABLES",
            "SHOW ALL TABLES",
            "SUMMARIZE t",
            "SUMMARIZE SELECT * FROM t",
            "EXPLAIN SELECT * FROM t",
            "EXPLAIN ANALYZE SELECT * FROM t",
            "explain (format json) select * from t",
        ] {
            allowed(&c, sql);
        }
    }

    #[test]
    fn files_and_addresses_are_refused() {
        let c = conn();
        for sql in [
            "SELECT content FROM read_text('/etc/hosts')",
            "SELECT * FROM read_csv('/tmp/x.csv')",
            "SELECT * FROM READ_BLOB('/tmp/x')",
            "SELECT * FROM glob('/Users/*')",
            "SELECT * FROM '/tmp/x.csv'",
            "SELECT * FROM \"/tmp/x.parquet\"",
            "FROM 'x.json'",
            "SELECT * FROM nothere.csv",
            "SELECT * FROM 'https://example.com/x.parquet'",
            "SELECT * FROM 's3://bucket/x.parquet'",
            "SELECT * FROM t WHERE i IN (SELECT i FROM '/tmp/x.csv')",
            "SELECT (SELECT content FROM read_text('/etc/hosts'))",
            "WITH c AS (SELECT * FROM read_text('/etc/hosts')) SELECT * FROM c",
            "SELECT * FROM t JOIN 'x.csv' USING (i)",
            "SELECT * FROM (WITH \"x.csv\" AS (SELECT 1) SELECT 1), \"x.csv\"",
            "DESCRIBE '/tmp/x.csv'",
            "SUMMARIZE 'x.parquet'",
            "SUMMARIZE SELECT * FROM '/tmp/x.csv'",
            "EXPLAIN ANALYZE SELECT * FROM read_text('/etc/hosts')",
            "SELECT * FROM query('SELECT 1')",
            "SELECT * FROM sqlite_scan('/tmp/pharos.db', 'query_variables')",
            "SELECT * FROM duckdb_secrets()",
        ] {
            let why = refused(&c, sql);
            assert!(why.starts_with(REFUSAL), "{sql}\n{why}");
        }
    }

    #[test]
    fn anything_but_one_select_is_refused() {
        let c = conn();
        for sql in [
            "COPY t TO '/tmp/out.csv'",
            "COPY (SELECT 1) TO '/tmp/out.csv'",
            "ATTACH '/tmp/other.duckdb' AS o",
            "ATTACH '/tmp/pharos.db' AS p (TYPE sqlite, READ_ONLY)",
            "CREATE OR REPLACE TABLE t AS SELECT 1",
            "CREATE TABLE x AS SELECT 1",
            "INSERT INTO t VALUES (3)",
            "DELETE FROM t",
            "SET enable_external_access = true",
            "INSTALL httpfs",
            "LOAD httpfs",
            "EXPORT DATABASE '/tmp/out'",
            "PRAGMA database_size",
            "CALL pragma_table_info('t')",
            "BEGIN",
            "SELECT 1; SELECT 2",
            "SELECT 1; DELETE FROM t",
            "EXPLAIN ANALYZE DELETE FROM t",
            "EXPLAIN COPY t TO '/tmp/out.csv'",
            "PIVOT t ON i USING count(*)",
        ] {
            let why = refused(&c, sql);
            assert!(why.starts_with(REFUSAL), "{sql}\n{why}");
        }
    }

    #[test]
    fn a_select_that_changes_something_is_refused() {
        let c = conn();
        assert!(refused(&c, "SELECT nextval('seq')").contains("nextval()"));
        assert!(refused(&c, "SELECT i, NEXTVAL('seq') FROM t").contains("nextval()"));
        assert!(refused(&c, "SELECT getenv('HOME')").contains("getenv()"));
    }

    #[test]
    fn a_view_is_what_its_query_reads() {
        let c = conn();
        c.execute_batch(
            "CREATE VIEW plain AS SELECT i FROM t WHERE i > 0; \
             CREATE VIEW named (n) AS SELECT i FROM t; \
             CREATE VIEW over_plain AS SELECT * FROM plain JOIN v USING (i); \
             CREATE VIEW s.sv AS SELECT * FROM s.u; \
             CREATE VIEW hosts AS SELECT * FROM read_text('/etc/hosts'); \
             CREATE VIEW over_hosts AS SELECT content FROM hosts; \
             CREATE VIEW \"as it is\" AS SELECT * FROM over_hosts; \
             CREATE VIEW s.hidden AS SELECT * FROM glob('/Users/*');",
        )
        .unwrap();
        for sql in ["SELECT * FROM plain", "SELECT * FROM named", "SELECT * FROM over_plain", "SELECT * FROM s.sv",
                    "SELECT * FROM v", "DESCRIBE over_plain", "WITH c AS (SELECT * FROM plain) SELECT * FROM c"] {
            allowed(&c, sql);
        }
        for sql in ["SELECT * FROM hosts", "SELECT * FROM over_hosts", "SELECT * FROM \"as it is\"",
                    "SELECT * FROM s.hidden", "SELECT * FROM memory.s.hidden", "SELECT * FROM t WHERE i IN (SELECT 1 FROM hosts)",
                    "SUMMARIZE over_hosts", "EXPLAIN ANALYZE SELECT * FROM hosts"] {
            let why = refused(&c, sql);
            assert!(why.starts_with(REFUSAL), "{sql}\n{why}");
            assert!(why.contains("view"), "{sql}\n{why}");
        }
    }

    #[test]
    fn a_users_macro_is_refused_and_duckdbs_own_are_not() {
        let c = conn();
        c.execute_batch(
            "CREATE MACRO peek(p) AS (SELECT content FROM read_text(p)); \
             CREATE MACRO twice(x) AS x * 2; \
             CREATE MACRO files(p) AS TABLE SELECT * FROM glob(p);",
        )
        .unwrap();
        assert!(refused(&c, "SELECT peek('/etc/hosts')").contains("macro peek()"));
        assert!(refused(&c, "SELECT PEEK('/etc/hosts') FROM t").contains("macro peek()"));
        assert!(refused(&c, "SELECT twice(i) FROM t").contains("macro twice()"));
        refused(&c, "SELECT * FROM files('/Users/*')");
        // Built-in functions, and DuckDB's own macros.
        for sql in ["SELECT upper('a'), abs(-1), coalesce(i, 0) FROM t", "SELECT list_reverse([1, 2])", "SELECT count(*), max(i) FROM t"] {
            allowed(&c, sql);
        }
    }

    #[test]
    fn the_query_of_a_view_definition() {
        assert_eq!(view_query("CREATE VIEW v AS SELECT * FROM t;"), Some("SELECT * FROM t"));
        assert_eq!(view_query("CREATE VIEW main.v (a, b) AS SELECT 1, 2;"), Some("SELECT 1, 2"));
        assert_eq!(view_query("CREATE VIEW \"x AS y\" AS SELECT 1 AS n;"), Some("SELECT 1 AS n"));
        assert_eq!(view_query("create view v as(select 1)"), Some("(select 1)"));
        assert_eq!(view_query("CREATE VIEW v"), None);
    }

    #[test]
    fn a_syntax_error_is_reported_as_one() {
        let c = conn();
        let why = refused(&c, "SELEC 1");
        assert!(!why.starts_with(REFUSAL), "{why}");
    }

    #[test]
    fn the_refusal_does_not_run_the_statement() {
        let c = conn();
        refused(&c, "DELETE FROM t");
        refused(&c, "SELECT 1; DELETE FROM t");
        let left: i64 = c.query_row("SELECT count(*) FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 2);
    }
}
