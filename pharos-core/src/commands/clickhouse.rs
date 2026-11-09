//! ClickHouse reached through its PostgreSQL-compatible port.
//!
//! ClickHouse speaks the PostgreSQL wire protocol, but two things a
//! PostgreSQL connection relies on are missing or coarse there:
//!
//! - **Result column types.** ClickHouse describes a result column with a
//!   PostgreSQL type OID, and it has none for most of its own types: every
//!   `DateTime`, `DateTime64`, `String`, `Enum`, `Array`, `Map` … column
//!   arrives as `varchar` (OID 1043), and no column names a source table. The
//!   grid would then offer text filters on a timestamp. `DESCRIBE TABLE
//!   (<query>)` answers with ClickHouse's own type for each result column,
//!   without running the query, so `apply_result_types` swaps those in.
//! - **The catalogue.** ClickHouse emulates only part of `pg_catalog`
//!   (`pg_attrdef`, `pg_constraint` … do not exist), so the reconstructed
//!   DDL cannot be built. `SHOW CREATE TABLE` gives the real statement.
//!
//! A statement that fails on ClickHouse's PostgreSQL port also ENDS the
//! connection (the server resets it without a ReadyForQuery). Everything here
//! that may fail runs on a pooled connection of its own, which is closed
//! instead of returned when it does.
//!
//! Whether a connection's server is ClickHouse is asked once per pool and
//! cached in `AppState` (cleared when the pool is replaced or removed).

use std::time::Duration;

use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgPool, PgRow};
use sqlx::{Executor, Postgres, Row};

use super::ddl::{TableDdl, TableShape};
use super::row_identity::ColumnDef;
use crate::state::AppState;

/// How long the extra DESCRIBE of a result may take, the wait for a pooled
/// connection included. Past it the result keeps the wire's types.
const DESCRIBE_BUDGET: Duration = Duration::from_secs(5);

// MARK: - Detection

/// Whether the server behind this pool is ClickHouse. Asked once per pool;
/// a probe that could not reach the server is not cached, so the next call
/// asks again.
pub async fn is_clickhouse(state: &AppState, pool: &PgPool, connection_id: &str) -> bool {
    if let Some(known) = state.server_is_clickhouse(connection_id) {
        return known;
    }
    match probe(pool).await {
        Ok(answer) => {
            state.set_server_is_clickhouse(connection_id, answer);
            answer
        }
        Err(_) => false,
    }
}

/// `SELECT version()` runs everywhere. PostgreSQL answers `PostgreSQL 16.4 on
/// …`, CockroachDB `CockroachDB CCL v23…`, ClickHouse a bare `25.5.1.8`. Only
/// a bare version is checked further, with a query only ClickHouse answers —
/// so a PostgreSQL server never sees a statement that fails.
async fn probe(pool: &PgPool) -> Result<bool, sqlx::Error> {
    let mut conn = pool.acquire().await?;
    let row = (&mut *conn).fetch_one(sqlx::raw_sql("SELECT version()")).await?;
    if !is_bare_version(&cell(&row, 0).unwrap_or_default()) {
        return Ok(false);
    }
    let confirm = (&mut *conn)
        .fetch_optional(sqlx::raw_sql("SELECT value FROM system.build_options WHERE name = 'VERSION_FULL'"))
        .await;
    match confirm {
        Ok(Some(row)) => Ok(cell(&row, 0).is_some_and(|v| v.starts_with("ClickHouse"))),
        Ok(None) => Ok(false),
        Err(_) => {
            // Some other server with a bare version. The failed query may
            // have ended the connection: never hand it back to the pool.
            conn.close_on_drop();
            Ok(false)
        }
    }
}

/// `25.5.1.8`: three or more dot-separated runs of digits, nothing else.
pub(crate) fn is_bare_version(version: &str) -> bool {
    let parts: Vec<&str> = version.trim().split('.').collect();
    parts.len() >= 3 && parts.iter().all(|p| !p.is_empty() && p.bytes().all(|c| c.is_ascii_digit()))
}

// MARK: - Result column types

/// Replace a ClickHouse result's wire types with ClickHouse's own, or fill in
/// the columns of an empty result (which the wire never described: `describe`
/// needs the extended protocol, which ClickHouse lacks).
///
/// Does nothing — and sends nothing — unless the result has a text-typed or
/// no column at all, the statement is one plain query that `DESCRIBE` accepts,
/// and the server is ClickHouse. Any failure leaves `columns` as it was.
pub async fn apply_result_types(
    state: &AppState,
    pool: &PgPool,
    connection_id: &str,
    sql: &str,
    columns: &mut Vec<ColumnDef>,
) {
    let wire_is_vague = columns.is_empty() || columns.iter().any(|c| is_text_wire_type(&c.data_type));
    if !wire_is_vague {
        return;
    }
    let Some(describe) = describe_statement(sql) else { return };
    if !is_clickhouse(state, pool, connection_id).await {
        return;
    }
    if let Some(described) = describe_result(pool, &describe).await {
        merge_described(columns, described);
    }
}

/// The type names sqlx gives the OIDs ClickHouse uses for "no better type".
fn is_text_wire_type(data_type: &str) -> bool {
    data_type.eq_ignore_ascii_case("VARCHAR") || data_type.eq_ignore_ascii_case("TEXT")
}

/// Run the DESCRIBE on a connection of its own. None on any failure or past
/// the budget; the connection is then closed rather than reused.
async fn describe_result(pool: &PgPool, describe: &str) -> Option<Vec<(String, String)>> {
    let deadline = tokio::time::Instant::now() + DESCRIBE_BUDGET;
    let mut conn: PoolConnection<Postgres> = tokio::time::timeout_at(deadline, pool.acquire()).await.ok()?.ok()?;
    let read = tokio::time::timeout_at(deadline, (&mut *conn).fetch_all(sqlx::raw_sql(describe))).await;
    match read {
        Ok(Ok(rows)) => Some(rows.iter().filter_map(|r| Some((cell(r, 0)?, cell(r, 1)?))).collect()),
        _ => {
            conn.close_on_drop();
            None
        }
    }
}

/// Put DESCRIBE's types on the result's columns. They must be the same
/// columns, in the same order, by name; otherwise nothing changes. An empty
/// result takes DESCRIBE's columns as they are.
pub(crate) fn merge_described(columns: &mut Vec<ColumnDef>, described: Vec<(String, String)>) {
    if described.is_empty() {
        return;
    }
    if columns.is_empty() {
        *columns = described
            .into_iter()
            .map(|(name, data_type)| ColumnDef { name, data_type, relation_oid: None, relation_attno: None })
            .collect();
        return;
    }
    let same_columns = columns.len() == described.len()
        && columns.iter().zip(&described).all(|(c, (name, _))| &c.name == name);
    if !same_columns {
        return;
    }
    for (column, (_, data_type)) in columns.iter_mut().zip(described) {
        column.data_type = data_type;
    }
}

/// `DESCRIBE TABLE (<sql>)`, or None when `sql` is not something DESCRIBE
/// accepts — a failed DESCRIBE costs the connection, so this only says yes to
/// what it has seen work:
///
/// - one statement (a trailing `;` is dropped; anything after one refuses);
/// - starting with `SELECT`, `WITH` or `(`;
/// - with no top-level `FORMAT <name>` or `INTO OUTFILE`, which DESCRIBE's
///   parentheses do not take.
///
/// The closing parenthesis goes on a line of its own so a trailing `--`
/// comment cannot swallow it. Strings follow ClickHouse's rules (backslash
/// escapes, `''`), and backquoted and double-quoted names are skipped whole.
pub(crate) fn describe_statement(sql: &str) -> Option<String> {
    let b = sql.as_bytes();
    let n = b.len();
    let mut i = 0;
    let mut depth = 0usize;
    let mut first_token: Option<String> = None;
    let mut body_end: Option<usize> = None;
    let mut previous_word: Option<String> = None;

    while i < n {
        let c = b[i];
        // Comments and whitespace: skipped, never a token.
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if c == b'-' && i + 1 < n && b[i + 1] == b'-' {
            while i < n && b[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'/' && i + 1 < n && b[i + 1] == b'*' {
            i = match sql[i + 2..].find("*/") {
                Some(at) => i + 2 + at + 2,
                None => n,
            };
            continue;
        }
        // Anything significant after the statement's `;` is a second one.
        if body_end.is_some() {
            if c == b';' {
                i += 1;
                continue;
            }
            return None;
        }
        match c {
            b'\'' | b'"' | b'`' => {
                if first_token.is_none() {
                    return None;
                }
                i = skip_quoted(b, i);
                previous_word = None;
            }
            b'(' => {
                first_token.get_or_insert_with(|| "(".to_string());
                depth += 1;
                i += 1;
                previous_word = None;
            }
            b')' => {
                depth = depth.saturating_sub(1);
                i += 1;
                previous_word = None;
            }
            b';' if depth == 0 => {
                body_end = Some(i);
                i += 1;
            }
            c if c.is_ascii_alphabetic() || c == b'_' => {
                let start = i;
                while i < n && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
                let word = sql[start..i].to_ascii_lowercase();
                if first_token.is_none() {
                    first_token = Some(word.clone());
                }
                if depth == 0 {
                    if previous_word.as_deref() == Some("into") && word == "outfile" {
                        return None;
                    }
                    // `FORMAT TSV` is the clause; `format(…)` is a function.
                    if word == "format" && next_significant(b, i).is_some_and(|c| c.is_ascii_alphabetic()) {
                        return None;
                    }
                }
                previous_word = Some(word);
            }
            _ => {
                i += 1;
                previous_word = None;
            }
        }
    }

    match first_token.as_deref() {
        Some("select") | Some("with") | Some("(") => {}
        _ => return None,
    }
    let body = sql[..body_end.unwrap_or(n)].trim();
    Some(format!("DESCRIBE TABLE (\n{}\n)", body))
}

/// Index just past the quoted run at `start` (`'…'`, `"…"` or `` `…` ``).
/// ClickHouse escapes the quote either by doubling it or with a backslash.
fn skip_quoted(b: &[u8], start: usize) -> usize {
    let quote = b[start];
    let n = b.len();
    let mut i = start + 1;
    while i < n {
        match b[i] {
            b'\\' if i + 1 < n => i += 2,
            c if c == quote && i + 1 < n && b[i + 1] == quote => i += 2,
            c if c == quote => return i + 1,
            _ => i += 1,
        }
    }
    n
}

/// The first byte at or after `from` that is not whitespace.
fn next_significant(b: &[u8], from: usize) -> Option<u8> {
    b[from..].iter().copied().find(|c| !c.is_ascii_whitespace())
}

// MARK: - DDL

/// The table's DDL as ClickHouse states it. "Columns only" is built from
/// `system.columns` for a table; for a view or dictionary it repeats the
/// stored statement. The other two variants are the stored statement, which
/// already carries ClickHouse's indexes, constraints and projections.
pub async fn table_ddl(pool: &PgPool, database: &str, table: &str) -> Result<TableDdl, String> {
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;
    let show = format!("SHOW CREATE TABLE {}.{}", quote_ident(database), quote_ident(table));
    let statement = match (&mut *conn).fetch_optional(sqlx::raw_sql(&show)).await {
        Ok(row) => row.and_then(|r| cell(&r, 0)),
        Err(e) => {
            conn.close_on_drop();
            return Err(e.to_string());
        }
    };
    let statement = statement.ok_or_else(|| format!("No DDL is stored for {}.{}", database, table))?;
    let stored = with_semicolon(&statement);

    let columns_only = if is_create_table(&statement) {
        let columns_sql = format!(
            "SELECT name, type FROM system.columns WHERE database = {} AND table = {} ORDER BY position",
            quote_literal(database),
            quote_literal(table)
        );
        match (&mut *conn).fetch_all(sqlx::raw_sql(&columns_sql)).await {
            Ok(rows) => {
                let columns: Vec<(String, String)> =
                    rows.iter().filter_map(|r| Some((cell(r, 0)?, cell(r, 1)?))).collect();
                columns_only_ddl(database, table, &columns).unwrap_or_else(|| stored.clone())
            }
            Err(_) => {
                conn.close_on_drop();
                stored.clone()
            }
        }
    } else {
        stored.clone()
    };

    Ok(TableDdl {
        columns_only,
        with_constraints: stored.clone(),
        full: stored,
        shape: TableShape { partition_by: None, inherits_from: vec![], has_child_tables: false, partition_of: None },
    })
}

fn is_create_table(statement: &str) -> bool {
    let words: Vec<String> = statement.split_whitespace().take(2).map(str::to_ascii_uppercase).collect();
    words == ["CREATE", "TABLE"]
}

/// `CREATE TABLE` with names and types only, in ClickHouse's own layout.
/// None for a table with no columns read.
pub(crate) fn columns_only_ddl(database: &str, table: &str, columns: &[(String, String)]) -> Option<String> {
    if columns.is_empty() {
        return None;
    }
    let lines: Vec<String> = columns.iter().map(|(name, ty)| format!("    {} {}", quote_ident(name), ty)).collect();
    Some(format!(
        "CREATE TABLE {}.{}\n(\n{}\n);",
        quote_ident(database),
        quote_ident(table),
        lines.join(",\n")
    ))
}

fn with_semicolon(s: &str) -> String {
    let t = s.trim();
    if t.ends_with(';') { t.to_string() } else { format!("{};", t) }
}

/// A ClickHouse identifier in backquotes. ClickHouse reads a backslash as an
/// escape inside them, so both it and the backquote are escaped.
pub(crate) fn quote_ident(name: &str) -> String {
    format!("`{}`", name.replace('\\', "\\\\").replace('`', "\\`"))
}

/// A ClickHouse string literal. Unlike PostgreSQL's standard strings, a
/// backslash is an escape here, so doubling the quote alone is not enough.
pub(crate) fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\\', "\\\\").replace('\'', "\\'"))
}

/// A cell as text, whatever OID ClickHouse sent for it.
fn cell(row: &PgRow, index: usize) -> Option<String> {
    let raw = row.try_get_raw(index).ok()?;
    if sqlx::ValueRef::is_null(&raw) {
        return None;
    }
    raw.as_str().ok().map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn col(name: &str, data_type: &str) -> ColumnDef {
        ColumnDef { name: name.into(), data_type: data_type.into(), relation_oid: None, relation_attno: None }
    }

    #[test]
    fn a_bare_version_is_clickhouses_and_a_described_one_is_not() {
        assert!(is_bare_version("25.5.1.8"));
        assert!(is_bare_version(" 24.8.14.39\n"));
        assert!(!is_bare_version("PostgreSQL 16.4 on aarch64-apple-darwin"));
        assert!(!is_bare_version("CockroachDB CCL v23.1.11"));
        assert!(!is_bare_version("16.4"));
        assert!(!is_bare_version("25.5..8"));
        assert!(!is_bare_version(""));
    }

    #[test]
    fn a_plain_query_is_wrapped_with_the_paren_on_its_own_line() {
        assert_eq!(
            describe_statement("SELECT created_date::timestamp FROM whois_registrar_weekly").as_deref(),
            Some("DESCRIBE TABLE (\nSELECT created_date::timestamp FROM whois_registrar_weekly\n)")
        );
        assert_eq!(
            describe_statement("  -- weekly\nWITH x AS (SELECT 1) SELECT * FROM x -- tail").as_deref(),
            Some("DESCRIBE TABLE (\n-- weekly\nWITH x AS (SELECT 1) SELECT * FROM x -- tail\n)")
        );
        assert!(describe_statement("(SELECT 1) UNION ALL (SELECT 2)").is_some());
        assert!(describe_statement("select 1 settings max_threads = 1").is_some());
    }

    #[test]
    fn a_trailing_semicolon_is_dropped() {
        assert_eq!(describe_statement("SELECT 1;").as_deref(), Some("DESCRIBE TABLE (\nSELECT 1\n)"));
        assert_eq!(describe_statement("SELECT 1 ;; -- done\n").as_deref(), Some("DESCRIBE TABLE (\nSELECT 1\n)"));
    }

    #[test]
    fn what_describe_rejects_is_never_sent() {
        assert_eq!(describe_statement("SELECT 1; SELECT 2"), None);
        assert_eq!(describe_statement("SHOW TABLES"), None);
        assert_eq!(describe_statement("INSERT INTO t SELECT 1"), None);
        assert_eq!(describe_statement("EXPLAIN SELECT 1"), None);
        assert_eq!(describe_statement("SELECT 1 FORMAT TSV"), None);
        assert_eq!(describe_statement("SELECT 1 INTO OUTFILE 'x.csv'"), None);
        assert_eq!(describe_statement("-- only a comment"), None);
        assert_eq!(describe_statement(""), None);
    }

    #[test]
    fn format_as_a_function_or_inside_quotes_is_not_the_clause() {
        assert!(describe_statement("SELECT format('{} FORMAT TSV', x) FROM t").is_some());
        assert!(describe_statement("SELECT `format` FROM t").is_some());
        assert!(describe_statement("SELECT (SELECT 1 FORMAT TSV)").is_some(), "only a top-level FORMAT refuses");
    }

    #[test]
    fn a_semicolon_in_a_string_or_name_does_not_end_the_statement() {
        assert!(describe_statement("SELECT 'a;b', 'it\\'s; fine', \"x;y\", `p;q` FROM t").is_some());
        assert!(describe_statement("SELECT 'it''s'; ").is_some());
        assert!(describe_statement("SELECT 1 /* ; */ + 1").is_some());
    }

    #[test]
    fn described_types_replace_the_wire_types_column_for_column() {
        let mut columns = vec![col("created_date", "VARCHAR"), col("CAST(created_date, 'timestamp')", "VARCHAR"), col("n", "INT2")];
        merge_described(
            &mut columns,
            vec![
                ("created_date".into(), "Nullable(DateTime64(0))".into()),
                ("CAST(created_date, 'timestamp')".into(), "DateTime".into()),
                ("n".into(), "UInt8".into()),
            ],
        );
        let types: Vec<&str> = columns.iter().map(|c| c.data_type.as_str()).collect();
        assert_eq!(types, ["Nullable(DateTime64(0))", "DateTime", "UInt8"]);
    }

    #[test]
    fn a_describe_that_does_not_match_changes_nothing() {
        let mut columns = vec![col("a", "VARCHAR"), col("b", "VARCHAR")];
        merge_described(&mut columns, vec![("a".into(), "DateTime".into())]);
        assert_eq!(columns[0].data_type, "VARCHAR");
        merge_described(&mut columns, vec![("a".into(), "DateTime".into()), ("c".into(), "DateTime".into())]);
        assert_eq!(columns[0].data_type, "VARCHAR");
        merge_described(&mut columns, vec![]);
        assert_eq!(columns.len(), 2);
    }

    #[test]
    fn an_empty_result_takes_describes_columns() {
        let mut columns = vec![];
        merge_described(&mut columns, vec![("ts".into(), "DateTime64(3)".into())]);
        assert_eq!(columns.len(), 1);
        assert_eq!((columns[0].name.as_str(), columns[0].data_type.as_str()), ("ts", "DateTime64(3)"));
        assert_eq!(columns[0].relation_oid, None);
    }

    #[test]
    fn names_and_strings_are_escaped_the_clickhouse_way() {
        assert_eq!(quote_ident("whois"), "`whois`");
        assert_eq!(quote_ident("a`b\\c"), "`a\\`b\\\\c`");
        assert_eq!(quote_literal("it's"), "'it\\'s'");
        assert_eq!(quote_literal("a\\'b"), "'a\\\\\\'b'");
    }

    #[test]
    fn columns_only_ddl_lists_names_and_types() {
        let ddl = columns_only_ddl(
            "whois",
            "whois_registrar_weekly",
            &[("domain_name".into(), "String".into()), ("created_date".into(), "Nullable(DateTime64(0))".into())],
        );
        assert_eq!(
            ddl.as_deref(),
            Some("CREATE TABLE `whois`.`whois_registrar_weekly`\n(\n    `domain_name` String,\n    `created_date` Nullable(DateTime64(0))\n);")
        );
        assert_eq!(columns_only_ddl("d", "t", &[]), None);
        assert!(is_create_table("CREATE TABLE whois.t\n(\n)"));
        assert!(!is_create_table("CREATE VIEW whois.v AS SELECT 1"));
        assert!(!is_create_table("CREATE MATERIALIZED VIEW whois.mv TO t AS SELECT 1"));
    }

    /// End to end against a real ClickHouse on its PostgreSQL port, e.g.
    /// `PHAROS_TEST_CLICKHOUSE_URL=postgres://default:pw@127.0.0.1:9005/default`.
    /// Skips when the variable is unset. Creates and drops the database
    /// `pharos_ch_test`.
    #[test]
    #[ignore = "needs a live ClickHouse; set PHAROS_TEST_CLICKHOUSE_URL"]
    fn a_live_clickhouse_reports_real_types_and_its_own_ddl() {
        let Ok(url) = std::env::var("PHAROS_TEST_CLICKHOUSE_URL") else {
            eprintln!("SKIP: PHAROS_TEST_CLICKHOUSE_URL is not set");
            return;
        };
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let pool = sqlx::postgres::PgPoolOptions::new()
                .max_connections(2)
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| panic!("cannot connect to {}: {}", url, e));
            for sql in [
                "DROP DATABASE IF EXISTS pharos_ch_test",
                "CREATE DATABASE pharos_ch_test",
                "CREATE TABLE pharos_ch_test.weekly (domain_name String, created_date Nullable(DateTime64(0)), \
                 updated_date DateTime('UTC'), n UInt8) ENGINE = MergeTree ORDER BY domain_name",
                "INSERT INTO pharos_ch_test.weekly VALUES ('a.example', '2024-03-01 12:34:56', '2024-03-02 00:00:00', 7)",
            ] {
                (&pool).execute(sqlx::raw_sql(sql)).await.unwrap_or_else(|e| panic!("{sql}: {e}"));
            }
            let state = AppState::new(rusqlite::Connection::open_in_memory().expect("sqlite"));
            state.add_pool("ch".to_string(), pool.clone());

            // The user's query shape: a cast with no alias, plus the plain column.
            let result = super::super::query::execute_query(
                "ch".into(),
                "SELECT domain_name, created_date, created_date::timestamp, updated_date, n \
                 FROM pharos_ch_test.weekly;"
                    .into(),
                None, None, None, None, &state,
            )
            .await
            .expect("query");
            let got: Vec<(&str, &str)> =
                result.columns.iter().map(|c| (c.name.as_str(), c.data_type.as_str())).collect();
            assert_eq!(
                got,
                [
                    ("domain_name", "String"),
                    ("created_date", "Nullable(DateTime64(0))"),
                    ("CAST(created_date, 'timestamp')", "DateTime"),
                    ("updated_date", "DateTime('UTC')"),
                    ("n", "UInt8"),
                ]
            );
            assert_eq!(state.server_is_clickhouse("ch"), Some(true));

            // An empty result now has its columns.
            let empty = super::super::query::execute_query(
                "ch".into(),
                "SELECT created_date FROM pharos_ch_test.weekly WHERE 0".into(),
                None, None, None, None, &state,
            )
            .await
            .expect("empty query");
            assert_eq!(empty.columns.len(), 1);
            assert_eq!(empty.columns[0].data_type, "Nullable(DateTime64(0))");

            // A statement DESCRIBE cannot take keeps the wire's types, and the
            // pool still works afterwards.
            let show = super::super::query::execute_query(
                "ch".into(), "SHOW TABLES FROM pharos_ch_test".into(), None, None, None, None, &state,
            )
            .await
            .expect("show tables");
            assert_eq!(show.columns[0].data_type, "VARCHAR");

            let ddl = super::super::table::generate_table_ddl(
                "ch".into(), "pharos_ch_test".into(), "weekly".into(), &state,
            )
            .await
            .expect("ddl");
            assert!(ddl.full.starts_with("CREATE TABLE pharos_ch_test.weekly"), "{}", ddl.full);
            assert!(ddl.full.contains("ENGINE = MergeTree"), "{}", ddl.full);
            assert!(ddl.columns_only.contains("`created_date` Nullable(DateTime64(0))"), "{}", ddl.columns_only);

            let columns = crate::db::postgres::get_columns(&pool, "pharos_ch_test", "weekly").await.expect("columns");
            let nullable: Vec<(&str, bool)> = columns.iter().map(|c| (c.name.as_str(), c.is_nullable)).collect();
            assert_eq!(nullable, [("domain_name", false), ("created_date", true), ("updated_date", false), ("n", false)]);

            (&pool).execute(sqlx::raw_sql("DROP DATABASE pharos_ch_test")).await.expect("drop");
        });
    }

    /// A PostgreSQL server is never taken for ClickHouse, is never sent the
    /// ClickHouse-only probe (it would log an ERROR on the server), and its
    /// results keep sqlx's type names.
    #[test]
    #[ignore = "needs a live PostgreSQL; set PHAROS_TEST_DATABASE_URL"]
    fn a_live_postgres_is_not_taken_for_clickhouse() {
        let Ok(url) = std::env::var("PHAROS_TEST_DATABASE_URL") else {
            eprintln!("SKIP: PHAROS_TEST_DATABASE_URL is not set");
            return;
        };
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let pool = sqlx::postgres::PgPoolOptions::new()
                .max_connections(2)
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| panic!("cannot connect to {}: {}", url, e));
            let state = AppState::new(rusqlite::Connection::open_in_memory().expect("sqlite"));
            state.add_pool("pg".to_string(), pool.clone());

            let result = super::super::query::execute_query(
                "pg".into(),
                "SELECT 'x'::varchar AS v, now()::timestamp AS ts".into(),
                None, None, None, None, &state,
            )
            .await
            .expect("query");
            let types: Vec<&str> = result.columns.iter().map(|c| c.data_type.as_str()).collect();
            assert_eq!(types, ["VARCHAR", "TIMESTAMP"]);
            assert_eq!(state.server_is_clickhouse("pg"), Some(false));
            assert!(!is_clickhouse(&state, &pool, "pg").await);
        });
    }
}
