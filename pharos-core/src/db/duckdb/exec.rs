//! Running user SQL on a DuckDB connection and reading the result as text.
//!
//! The text comes from DuckDB itself. A statement that returns rows is run as
//!
//! ```sql
//! SELECT COLUMNS(*)::VARCHAR FROM (<statement>) AS _pharos_q LIMIT n OFFSET m
//! ```
//!
//! so every cell is DuckDB's own `CAST(… AS VARCHAR)` — nested values, BLOBs,
//! HUGEINTs and time zones included — and the column names and types come
//! from `DESCRIBE <statement>`, which binds the statement without running it.
//! The LIMIT also bounds what DuckDB materialises for the first page.
//!
//! A statement DuckDB will not take as a subquery (`INSERT … RETURNING`,
//! `PRAGMA`, `CALL`, `SHOW`, `EXPLAIN`, DDL) is run as written, ONCE, and its
//! rows are formatted by `text::value_text`.
//!
//! Nothing here uses `Statement::stream_arrow`: its iterator panics when a
//! fetch fails after execution started, which is exactly what an interrupt
//! does. `Statement::query` returns errors as values.

use std::sync::Arc;
use std::time::Duration;

use duckdb::types::Value;
use duckdb::{Connection, InterruptHandle};

use super::text::{type_name, value_text};
use crate::commands::row_identity::ColumnDef;
use crate::commands::sql_lexer::{split_chunks, ChunkKind};
use crate::state::QueryCancel;

/// The rows of one statement, as text.
#[derive(Debug, Clone, PartialEq)]
pub struct TextRows {
    pub columns: Vec<ColumnDef>,
    /// Each row a JSON array of strings and nulls, in column order.
    pub rows: Vec<serde_json::Value>,
    /// A row past `limit` exists.
    pub has_more: bool,
    /// True when the rows came from the `COLUMNS(*)::VARCHAR` wrapper, so
    /// Load More can re-run the statement with an OFFSET. False for a
    /// statement that ran as written: running it again would repeat it.
    pub pageable: bool,
}

/// The statements of `sql`, without their `;`, comment-only pieces dropped.
/// psql meta-commands and `COPY … FROM STDIN` data are refused by the caller
/// before this is reached.
pub fn statements(sql: &str) -> Vec<String> {
    split_chunks(sql)
        .into_iter()
        .filter(|c| c.kind == ChunkKind::Statement)
        .map(|c| c.body(sql).trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// A statement kind that matters to Pharos's own bookkeeping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TxnEffect {
    Begin,
    End,
    None,
}

/// What a statement does to the transaction state. DuckDB keeps no flag a
/// client can read (`Connection::is_autocommit` is duckdb-rs's own flag for
/// its `Transaction` wrapper), so the tab session tracks it from the
/// statements it runs.
pub fn txn_effect(statement: &str) -> TxnEffect {
    let words: Vec<String> = statement
        .split_whitespace()
        .take(2)
        .map(|w| w.trim_end_matches(';').to_ascii_uppercase())
        .collect();
    match words.first().map(String::as_str) {
        Some("BEGIN") => TxnEffect::Begin,
        Some("START") if words.get(1).map(String::as_str) == Some("TRANSACTION") => TxnEffect::Begin,
        Some("COMMIT") | Some("END") | Some("ROLLBACK") | Some("ABORT") => TxnEffect::End,
        _ => TxnEffect::None,
    }
}

/// The first word of a statement, upper-cased.
pub fn first_word(statement: &str) -> String {
    statement
        .split(|c: char| c.is_whitespace() || c == '(' || c == ';')
        .find(|w| !w.is_empty())
        .unwrap_or("")
        .to_ascii_uppercase()
}

/// Run every statement of `sql` but the last as written, and read the last
/// one's rows: the first `limit` after `offset` (all of them for None).
///
/// The result describes the LAST statement, as psql shows the last result.
pub fn query_text(conn: &Connection, sql: &str, limit: Option<usize>, offset: usize) -> Result<TextRows, String> {
    let stmts = statements(sql);
    let Some((last, before)) = stmts.split_last() else {
        return Ok(TextRows { columns: vec![], rows: vec![], has_more: false, pageable: false });
    };
    for s in before {
        conn.execute_batch(s).map_err(|e| e.to_string())?;
    }
    rows_of(conn, last, limit, offset)
}

/// The rows of ONE statement.
pub fn rows_of(conn: &Connection, statement: &str, limit: Option<usize>, offset: usize) -> Result<TextRows, String> {
    if let Some(columns) = describe(conn, statement) {
        let mut wrapped = format!("SELECT COLUMNS(*)::VARCHAR FROM (\n{}\n) AS _pharos_q", statement);
        if let Some(limit) = limit {
            wrapped.push_str(&format!(" LIMIT {}", limit + 1));
        }
        if offset > 0 {
            wrapped.push_str(&format!(" OFFSET {}", offset));
        }
        // A statement DESCRIBE accepts but a subquery does not falls through
        // to the as-written path. Only a PREPARE failure does: once the
        // wrapper runs, its error is the statement's error.
        if let Ok(mut stmt) = conn.prepare(&wrapped) {
            let width = columns.len();
            let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
            let mut out = Vec::new();
            while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let mut cells = Vec::with_capacity(width);
                for i in 0..width {
                    let cell: Option<String> = row.get(i).map_err(|e| e.to_string())?;
                    cells.push(cell.map(serde_json::Value::String).unwrap_or(serde_json::Value::Null));
                }
                out.push(serde_json::Value::Array(cells));
            }
            return Ok(page(columns, out, limit, true));
        }
    }
    if offset > 0 {
        return Err("This statement cannot be paged: running it again would repeat it.".to_string());
    }
    run_as_written(conn, statement, limit)
}

/// The statement's column names and DuckDB type names, from `DESCRIBE`, or
/// None when DuckDB cannot describe it (it is not a query).
pub fn describe(conn: &Connection, statement: &str) -> Option<Vec<ColumnDef>> {
    let mut stmt = conn.prepare(&format!("DESCRIBE {}", statement)).ok()?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .ok()?;
    let mut columns = Vec::new();
    for row in rows {
        let (name, data_type) = row.ok()?;
        columns.push(ColumnDef { name, data_type, relation_oid: None, relation_attno: None });
    }
    Some(columns)
}

fn run_as_written(conn: &Connection, statement: &str, limit: Option<usize>) -> Result<TextRows, String> {
    let mut stmt = conn.prepare(statement).map_err(|e| e.to_string())?;
    let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    let mut columns: Option<Vec<ColumnDef>> = None;
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let stmt_ref = row.as_ref();
        let width = stmt_ref.column_count();
        if columns.is_none() {
            columns = Some(columns_of(stmt_ref));
        }
        let mut cells = Vec::with_capacity(width);
        for i in 0..width {
            let value: Value = row.get(i).map_err(|e| e.to_string())?;
            cells.push(value_text(&value).map(serde_json::Value::String).unwrap_or(serde_json::Value::Null));
        }
        out.push(serde_json::Value::Array(cells));
        // Everything is already materialised by DuckDB; stop at the page.
        if let Some(limit) = limit {
            if out.len() > limit {
                break;
            }
        }
    }
    drop(rows);
    let columns = match columns {
        Some(c) => c,
        // No rows: the executed statement still has its schema.
        None => columns_of(&stmt),
    };
    // A statement that ran as written cannot be paged, so the page holds
    // what was read; `has_more` still says when it was cut.
    Ok(page(columns, out, limit, false))
}

fn columns_of(stmt: &duckdb::Statement<'_>) -> Vec<ColumnDef> {
    let names = stmt.column_names();
    names
        .into_iter()
        .enumerate()
        .map(|(i, name)| ColumnDef {
            name,
            data_type: type_name(&stmt.column_logical_type(i)),
            relation_oid: None,
            relation_attno: None,
        })
        .collect()
}

fn page(columns: Vec<ColumnDef>, mut rows: Vec<serde_json::Value>, limit: Option<usize>, pageable: bool) -> TextRows {
    let has_more = matches!(limit, Some(l) if rows.len() > l);
    if let Some(l) = limit {
        rows.truncate(l);
    }
    TextRows { columns, rows, has_more, pageable }
}

/// Run every statement of `sql`; the rows the LAST one changed (DuckDB
/// reports a `Count` for INSERT, UPDATE and DELETE; 0 for the rest).
pub fn execute_text(conn: &Connection, sql: &str) -> Result<u64, String> {
    let stmts = statements(sql);
    let Some((last, before)) = stmts.split_last() else { return Ok(0) };
    for s in before {
        conn.execute_batch(s).map_err(|e| e.to_string())?;
    }
    let mut stmt = conn.prepare(last).map_err(|e| e.to_string())?;
    let changed = stmt.execute([]).map_err(|e| e.to_string())?;
    Ok(changed as u64)
}

/// `EXPLAIN` / `EXPLAIN ANALYZE` of one statement, as DuckDB's text tree.
pub fn explain_text(conn: &Connection, statement: &str, analyze: bool) -> Result<String, String> {
    let prefix = if analyze { "EXPLAIN ANALYZE " } else { "EXPLAIN " };
    let mut stmt = conn.prepare(&format!("{}{}", prefix, statement)).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(1))
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| e.to_string())?);
    }
    Ok(out.join("\n"))
}

/// EXPLAIN as a plan the app's plan view reads: DuckDB's JSON tree mapped
/// onto PostgreSQL's `EXPLAIN (FORMAT JSON)` keys, so one viewer serves both
/// engines.
///
/// - `EXPLAIN (FORMAT json)` gives `[{name, children, extra_info}]`.
/// - `EXPLAIN (ANALYZE, FORMAT json)` gives a profile: `latency` (seconds)
///   at the root, then an `EXPLAIN_ANALYZE` operator whose child is the plan;
///   each operator has `operator_name`, `operator_timing` (seconds, its own
///   time) and `operator_cardinality` (rows out).
///
/// DuckDB has no cost model, so `Total Cost` is absent (0 in the viewer);
/// `Estimated Cardinality` becomes `Plan Rows`.
pub fn explain_plan_json(conn: &Connection, statement: &str, analyze: bool) -> Result<String, String> {
    let options = if analyze { "(ANALYZE, FORMAT json)" } else { "(FORMAT json)" };
    let mut stmt = conn.prepare(&format!("EXPLAIN {} {}", options, statement)).map_err(|e| e.to_string())?;
    let text: String = stmt
        .query_row([], |r| r.get::<_, String>(1))
        .map_err(|e| e.to_string())?;
    let raw: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("DuckDB's plan is not JSON: {}", e))?;
    let envelope = plan_envelope(&raw, analyze).ok_or_else(|| "DuckDB returned an empty plan.".to_string())?;
    Ok(serde_json::Value::Array(vec![envelope]).to_string())
}

/// `{"Plan": …, "Execution Time": ms}` from DuckDB's own JSON.
pub fn plan_envelope(raw: &serde_json::Value, analyze: bool) -> Option<serde_json::Value> {
    use serde_json::{json, Map, Value};
    let root = if analyze {
        // Skip the EXPLAIN_ANALYZE wrapper operator(s): the plan starts below.
        let mut node = raw.get("children")?.get(0)?;
        while node.get("operator_type").and_then(Value::as_str) == Some("EXPLAIN_ANALYZE") {
            node = node.get("children")?.get(0)?;
        }
        node
    } else {
        raw.get(0)?
    };
    fn convert(node: &Value, analyze: bool) -> Value {
        let mut out = Map::new();
        let name = node
            .get(if analyze { "operator_name" } else { "name" })
            .or_else(|| node.get("operator_type"))
            .and_then(Value::as_str)
            .unwrap_or("Node");
        out.insert("Node Type".into(), Value::String(pretty_operator(name)));
        if let Some(extra) = node.get("extra_info").and_then(Value::as_object) {
            let text = |v: &Value| match v {
                Value::String(s) => s.clone(),
                Value::Array(a) => a.iter().map(|x| x.as_str().map(String::from).unwrap_or_else(|| x.to_string())).collect::<Vec<_>>().join(", "),
                other => other.to_string(),
            };
            for (key, value) in extra {
                let mapped = match key.as_str() {
                    "Table" => Some("Relation Name"),
                    "Filters" => Some("Filter"),
                    "Join Type" => Some("Join Type"),
                    "Conditions" => Some("Hash Cond"),
                    "Estimated Cardinality" => {
                        if let Ok(n) = text(value).replace(',', "").parse::<f64>() {
                            out.insert("Plan Rows".into(), json!(n));
                        }
                        None
                    }
                    _ => None,
                };
                if let Some(k) = mapped {
                    out.insert(k.into(), Value::String(text(value)));
                }
            }
        }
        if analyze {
            if let Some(seconds) = node.get("operator_timing").and_then(Value::as_f64) {
                out.insert("Actual Total Time".into(), json!(seconds * 1000.0));
            }
            if let Some(rows) = node.get("operator_cardinality").and_then(Value::as_f64) {
                out.insert("Actual Rows".into(), json!(rows));
                out.insert("Actual Loops".into(), json!(1));
            }
        }
        let children: Vec<Value> = node
            .get("children")
            .and_then(Value::as_array)
            .map(|c| c.iter().map(|n| convert(n, analyze)).collect())
            .unwrap_or_default();
        if !children.is_empty() {
            out.insert("Plans".into(), Value::Array(children));
        }
        Value::Object(out)
    }
    let mut envelope = Map::new();
    envelope.insert("Plan".into(), convert(root, analyze));
    if analyze {
        if let Some(latency) = raw.get("latency").and_then(Value::as_f64) {
            envelope.insert("Execution Time".into(), json!(latency * 1000.0));
        }
    }
    Some(Value::Object(envelope))
}

/// `PERFECT_HASH_GROUP_BY` → `Perfect Hash Group By`, `SEQ_SCAN` → `Seq Scan`.
fn pretty_operator(name: &str) -> String {
    name.split(|c| c == '_' || c == ' ')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let lower = w.to_ascii_lowercase();
            let mut chars = lower.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A connection's transaction state, as DuckDB has it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TxnProbe {
    Idle,
    Open,
    /// An error aborted the open transaction: only ROLLBACK works.
    Failed,
    /// The probe itself failed for another reason.
    Unknown,
}

/// Read the transaction state without changing it. In autocommit every
/// statement is its own transaction, so two `txid_current()` calls answer
/// two ids; inside `BEGIN` they answer the same one; in an aborted
/// transaction the first call fails with "transaction is aborted".
pub fn probe_transaction(conn: &Connection) -> TxnProbe {
    let id = |c: &Connection| c.query_row("SELECT txid_current()", [], |r| r.get::<_, i64>(0));
    match (id(conn), id(conn)) {
        (Ok(a), Ok(b)) if a == b => TxnProbe::Open,
        (Ok(_), Ok(_)) => TxnProbe::Idle,
        (Err(e), _) if e.to_string().contains("transaction is aborted") => TxnProbe::Failed,
        _ => TxnProbe::Unknown,
    }
}

/// After an error inside an explicit transaction: has DuckDB aborted it?
/// `SELECT 1` has no effect, and fails only in an aborted transaction.
pub fn transaction_failed(conn: &Connection) -> bool {
    match conn.execute_batch("SELECT 1") {
        Ok(()) => false,
        Err(e) => e.to_string().contains("transaction is aborted"),
    }
}

/// How a cancellable run ended without a value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunStop {
    Cancelled,
    TimedOut(u32),
    Failed(String),
}

impl RunStop {
    /// The message the front end shows, matching the PostgreSQL path's.
    pub fn message(self) -> String {
        match self {
            RunStop::Cancelled => crate::commands::query::QUERY_CANCELLED.to_string(),
            RunStop::TimedOut(secs) => format!("Query timed out after {} s (Settings ▸ Query ▸ Timeout).", secs),
            RunStop::Failed(m) => tag_read_only(m),
        }
    }
}

/// DuckDB's refusal of a write on a read-only database, tagged with the
/// marker the PostgreSQL path uses for SQLSTATE 25006, so the app shows the
/// same "This connection is read-only." for both engines.
pub fn tag_read_only(message: String) -> String {
    if message.contains("read-only mode") && !message.contains(crate::commands::query::READ_ONLY_MARKER) {
        format!("{} {}", crate::commands::query::READ_ONLY_MARKER, message)
    } else if message.contains("different Team IDs") {
        format!("{}\n\n{}", EXTENSION_BLOCKED_SENTENCE, message)
    } else {
        message
    }
}

/// What a DuckDB extension refused by macOS means, said before DuckDB's own
/// `dlopen` text. Measured 2026-10-20: the ad-hoc signed, hardened-runtime
/// app cannot load a downloaded `.duckdb_extension` ("mapping process and
/// mapped file (non-platform) have different Team IDs"). Pharos's own
/// extensions are linked in, so only a `LOAD '/path/x.duckdb_extension'`
/// gets here.
pub const EXTENSION_BLOCKED_SENTENCE: &str = "macOS did not let Pharos load this DuckDB extension: the app's code signature \
     only allows libraries it shipped with. Pharos has icu, inet, fts, excel, sqlite_scanner, json, parquet and \
     autocomplete built in; other extensions are not available.";

/// Run blocking DuckDB `work` off the runtime, and stop it with `interrupt`
/// when `cancel` fires or `timeout_seconds` (0 = none) runs out.
///
/// DuckDB clears a connection's interrupt flag when a query starts, so an
/// interrupt sent before the query began would be lost. The flag is raised
/// again every 50 ms until the work returns.
pub async fn run_cancellable<T, F>(
    interrupt: Arc<InterruptHandle>,
    cancel: &QueryCancel,
    timeout_seconds: u32,
    work: F,
) -> Result<T, RunStop>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    let mut handle = tokio::task::spawn_blocking(work);
    let deadline = async {
        if timeout_seconds == 0 {
            std::future::pending::<()>().await
        } else {
            tokio::time::sleep(Duration::from_secs(timeout_seconds as u64)).await
        }
    };
    let stop = tokio::select! {
        biased;
        joined = &mut handle => return finish(joined, None),
        _ = cancel.cancelled() => RunStop::Cancelled,
        _ = deadline => RunStop::TimedOut(timeout_seconds),
    };
    loop {
        interrupt.interrupt();
        tokio::select! {
            joined = &mut handle => return finish(joined, Some(stop)),
            _ = tokio::time::sleep(Duration::from_millis(50)) => {}
        }
    }
}

fn finish<T>(joined: Result<Result<T, String>, tokio::task::JoinError>, stop: Option<RunStop>) -> Result<T, RunStop> {
    match joined {
        Err(e) => Err(RunStop::Failed(format!("DuckDB task failed: {}", e))),
        // The work finished before the interrupt took hold: its answer stands.
        Ok(Ok(value)) => Ok(value),
        Ok(Err(message)) => match stop {
            Some(stop) if super::is_interrupt(&message) => Err(stop),
            _ => Err(RunStop::Failed(message)),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn() -> Connection {
        Connection::open_in_memory().unwrap()
    }

    fn cells(r: &TextRows) -> Vec<Vec<Option<String>>> {
        r.rows
            .iter()
            .map(|row| row.as_array().unwrap().iter().map(|v| v.as_str().map(String::from)).collect())
            .collect()
    }

    #[test]
    fn a_query_reads_duckdbs_own_text_and_types() {
        let c = conn();
        let r = query_text(
            &c,
            "SELECT 1::INTEGER AS i, 1.5::DECIMAL(18,3) AS d, [1, 2] AS l, {'a': 'x y'} AS s, \
             '{\"k\": 1}'::JSON AS j, NULL::VARCHAR AS n, true AS b",
            Some(10),
            0,
        )
        .unwrap();
        let types: Vec<&str> = r.columns.iter().map(|c| c.data_type.as_str()).collect();
        assert_eq!(types, ["INTEGER", "DECIMAL(18,3)", "INTEGER[]", "STRUCT(a VARCHAR)", "JSON", "VARCHAR", "BOOLEAN"]);
        assert_eq!(
            cells(&r),
            vec![vec![
                Some("1".into()), Some("1.500".into()), Some("[1, 2]".into()), Some("{'a': x y}".into()),
                Some("{\"k\": 1}".into()), None, Some("true".into())
            ]]
        );
        assert!(r.pageable);
        assert!(!r.has_more);
    }

    #[test]
    fn the_wrapper_keeps_order_names_and_pages() {
        let c = conn();
        c.execute_batch("CREATE TABLE t AS SELECT range AS x FROM range(10)").unwrap();
        let sql = "SELECT x, x AS x FROM t ORDER BY x DESC;";
        let first = query_text(&c, sql, Some(3), 0).unwrap();
        assert_eq!(first.columns.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["x", "x"]);
        assert_eq!(cells(&first).iter().map(|r| r[0].clone().unwrap()).collect::<Vec<_>>(), ["9", "8", "7"]);
        assert!(first.has_more);
        let second = query_text(&c, sql, Some(3), 3).unwrap();
        assert_eq!(cells(&second).iter().map(|r| r[0].clone().unwrap()).collect::<Vec<_>>(), ["6", "5", "4"]);
    }

    #[test]
    fn friendly_sql_and_trailing_comments_wrap() {
        let c = conn();
        c.execute_batch("CREATE TABLE t AS SELECT 1 AS a, 2 AS b").unwrap();
        let r = query_text(&c, "FROM t SELECT * EXCLUDE (b) -- note", Some(5), 0).unwrap();
        assert!(r.pageable);
        assert_eq!(r.columns.len(), 1);
        assert_eq!(cells(&r), vec![vec![Some("1".into())]]);
    }

    #[test]
    fn earlier_statements_run_and_the_last_one_is_the_result() {
        let c = conn();
        let r = query_text(&c, "CREATE TEMP TABLE x(v INT); INSERT INTO x VALUES (5); SELECT v FROM x", Some(5), 0).unwrap();
        assert_eq!(cells(&r), vec![vec![Some("5".into())]]);
    }

    #[test]
    fn returning_runs_once_as_written() {
        let c = conn();
        c.execute_batch("CREATE TABLE t(id INT, name VARCHAR)").unwrap();
        let r = query_text(&c, "INSERT INTO t VALUES (1, 'a'), (2, 'b') RETURNING id, name", Some(10), 0).unwrap();
        assert!(!r.pageable);
        assert_eq!(cells(&r).len(), 2);
        assert_eq!(r.columns[0].data_type, "INTEGER");
        let n: i64 = c.query_row("SELECT count(*) FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 2, "the INSERT ran exactly once");
        assert!(query_text(&c, "INSERT INTO t VALUES (3, 'c') RETURNING id", Some(10), 1).is_err());
    }

    #[test]
    fn pragma_and_show_return_rows() {
        let c = conn();
        c.execute_batch("CREATE TABLE t(a INT)").unwrap();
        for sql in ["PRAGMA table_info('t')", "SHOW TABLES", "DESCRIBE t", "SUMMARIZE t", "PRAGMA version"] {
            let r = query_text(&c, sql, Some(10), 0).unwrap_or_else(|e| panic!("{sql}: {e}"));
            assert!(!r.columns.is_empty(), "{sql}");
        }
    }

    #[test]
    fn an_empty_result_keeps_its_columns() {
        let c = conn();
        let r = query_text(&c, "SELECT 1 AS a WHERE false", Some(10), 0).unwrap();
        assert_eq!(r.columns.len(), 1);
        assert!(r.rows.is_empty());
    }

    #[test]
    fn errors_are_duckdbs_messages() {
        let c = conn();
        let e = query_text(&c, "SELECT * FROM nope", Some(10), 0).unwrap_err();
        assert!(e.contains("Catalog Error") && e.contains("nope"), "{e}");
        let e = query_text(&c, "SELEC 1", Some(10), 0).unwrap_err();
        assert!(e.contains("Parser Error"), "{e}");
    }

    #[test]
    fn execute_reports_rows_changed() {
        let c = conn();
        c.execute_batch("CREATE TABLE t(a INT)").unwrap();
        assert_eq!(execute_text(&c, "INSERT INTO t SELECT range FROM range(4)").unwrap(), 4);
        assert_eq!(execute_text(&c, "UPDATE t SET a = a + 1 WHERE a > 1").unwrap(), 2);
        assert_eq!(execute_text(&c, "CREATE TABLE u(b INT)").unwrap(), 0);
    }

    #[test]
    fn explain_is_a_text_tree() {
        let c = conn();
        let plan = explain_text(&c, "SELECT 1", false).unwrap();
        assert!(!plan.trim().is_empty());
    }

    #[test]
    fn plans_map_onto_postgres_keys() {
        let c = conn();
        c.execute_batch("CREATE TABLE t AS SELECT range AS x FROM range(1000)").unwrap();
        let sql = "SELECT x, count(*) FROM t WHERE x > 5 GROUP BY x";
        let plain: serde_json::Value = serde_json::from_str(&explain_plan_json(&c, sql, false).unwrap()).unwrap();
        let root = &plain[0]["Plan"];
        assert_eq!(root["Node Type"], "Projection");
        let mut node = root;
        while let Some(child) = node.get("Plans").and_then(|p| p.get(0)) {
            node = child;
        }
        assert_eq!(node["Node Type"], "Seq Scan");
        assert_eq!(node["Relation Name"], "memory.main.t");
        assert_eq!(node["Filter"], "x>5");
        assert!(node["Plan Rows"].as_f64().unwrap() > 0.0);

        let analyzed: serde_json::Value = serde_json::from_str(&explain_plan_json(&c, sql, true).unwrap()).unwrap();
        assert!(analyzed[0]["Execution Time"].as_f64().unwrap() > 0.0);
        let root = &analyzed[0]["Plan"];
        assert_eq!(root["Node Type"], "Projection", "the EXPLAIN_ANALYZE wrapper is skipped");
        assert_eq!(root["Actual Rows"], 994.0);
        assert!(root.get("Actual Total Time").is_some());
        assert_eq!(pretty_operator("PERFECT_HASH_GROUP_BY"), "Perfect Hash Group By");
    }

    #[test]
    fn a_blocked_extension_is_explained() {
        let raw = "IO Error: Extension \"/x/icu.duckdb_extension\" could not be loaded: dlopen(...): tried: '...' (code signature ... not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs)";
        let shown = RunStop::Failed(raw.to_string()).message();
        assert!(shown.starts_with(EXTENSION_BLOCKED_SENTENCE), "{shown}");
        assert!(shown.ends_with(raw), "DuckDB's own text stays");
        assert_eq!(RunStop::Failed("Parser Error: x".into()).message(), "Parser Error: x");
    }

    #[test]
    fn transaction_statements_are_classified() {
        assert_eq!(txn_effect("begin"), TxnEffect::Begin);
        assert_eq!(txn_effect("BEGIN TRANSACTION"), TxnEffect::Begin);
        assert_eq!(txn_effect("start transaction"), TxnEffect::Begin);
        assert_eq!(txn_effect("commit"), TxnEffect::End);
        assert_eq!(txn_effect("END"), TxnEffect::End);
        assert_eq!(txn_effect("rollback"), TxnEffect::End);
        assert_eq!(txn_effect("abort"), TxnEffect::End);
        assert_eq!(txn_effect("SELECT 1"), TxnEffect::None);
        assert_eq!(txn_effect("start"), TxnEffect::None);
    }

    // ---- Phase 0 spike facts, kept as tests ----

    /// Interrupt from another thread: the query fails with an INTERRUPT
    /// error and the connection keeps working.
    #[tokio::test(flavor = "multi_thread")]
    async fn interrupt_stops_a_long_query_and_the_connection_survives() {
        let conn = Connection::open_in_memory().unwrap();
        let interrupt = conn.interrupt_handle();
        let conn = Arc::new(std::sync::Mutex::new(conn));
        let cancel = Arc::new(crate::state::QueryCancel::new());
        let canceller = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            canceller.cancel();
        });
        let worker = conn.clone();
        let started = std::time::Instant::now();
        let outcome = run_cancellable(interrupt, &cancel, 0, move || {
            let c = worker.lock().unwrap();
            query_text(&c, "SELECT count(*) FROM range(100000000000) a", Some(10), 0)
        })
        .await;
        assert_eq!(outcome, Err(RunStop::Cancelled));
        assert!(started.elapsed() < Duration::from_secs(10));
        let c = conn.lock().unwrap();
        let one: i32 = c.query_row("SELECT 1", [], |r| r.get(0)).unwrap();
        assert_eq!(one, 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_timeout_interrupts_too() {
        let conn = Connection::open_in_memory().unwrap();
        let interrupt = conn.interrupt_handle();
        let cancel = crate::state::QueryCancel::new();
        let outcome = run_cancellable(interrupt, &cancel, 1, move || {
            query_text(&conn, "SELECT count(*) FROM range(100000000000) a", Some(10), 0)
        })
        .await;
        assert_eq!(outcome, Err(RunStop::TimedOut(1)));
    }

    /// An error found before a statement runs (parser, binder, catalog)
    /// leaves an explicit transaction open and usable. An error while it
    /// runs (a constraint violation) aborts it: only ROLLBACK works then.
    /// `transaction_failed` tells the two apart.
    #[test]
    fn which_errors_fail_a_transaction() {
        let c = conn();
        c.execute_batch("CREATE TABLE t(a INT PRIMARY KEY); BEGIN; INSERT INTO t VALUES (1)").unwrap();
        assert!(c.execute_batch("SELECT * FROM nope").is_err());
        assert!(!transaction_failed(&c), "a catalog error keeps the transaction");
        c.execute_batch("INSERT INTO t VALUES (2)").unwrap();
        assert!(c.execute_batch("INSERT INTO t VALUES (2)").is_err());
        assert!(transaction_failed(&c), "a constraint error aborts it");
        c.execute_batch("ROLLBACK").unwrap();
        assert!(!transaction_failed(&c));
        let n: i64 = c.query_row("SELECT count(*) FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn the_probe_reads_the_transaction_state() {
        let c = conn();
        c.execute_batch("CREATE TABLE t(a INT PRIMARY KEY)").unwrap();
        assert_eq!(probe_transaction(&c), TxnProbe::Idle);
        c.execute_batch("BEGIN").unwrap();
        assert_eq!(probe_transaction(&c), TxnProbe::Open);
        c.execute_batch("INSERT INTO t VALUES (1)").unwrap();
        assert_eq!(probe_transaction(&c), TxnProbe::Open);
        let _ = c.execute_batch("INSERT INTO t VALUES (1)");
        assert_eq!(probe_transaction(&c), TxnProbe::Failed);
        c.execute_batch("ROLLBACK").unwrap();
        assert_eq!(probe_transaction(&c), TxnProbe::Idle);
        c.execute_batch("BEGIN; INSERT INTO t VALUES (5); COMMIT").unwrap();
        assert_eq!(probe_transaction(&c), TxnProbe::Idle);
        let n: i64 = c.query_row("SELECT count(*) FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1, "the probe never ends or undoes the user's work");
    }

    /// An interrupt inside an explicit transaction: record what DuckDB does.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_interrupt_inside_a_transaction_fails_it() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE t(a INT); BEGIN; INSERT INTO t VALUES (1)").unwrap();
        let interrupt = conn.interrupt_handle();
        let conn = Arc::new(std::sync::Mutex::new(conn));
        let cancel = Arc::new(crate::state::QueryCancel::new());
        let canceller = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            canceller.cancel();
        });
        let worker = conn.clone();
        let outcome = run_cancellable(interrupt, &cancel, 0, move || {
            let c = worker.lock().unwrap();
            query_text(&c, "SELECT count(*) FROM range(100000000000) a", Some(10), 0)
        })
        .await;
        assert_eq!(outcome, Err(RunStop::Cancelled));
        let c = conn.lock().unwrap();
        assert!(transaction_failed(&c), "an interrupt fails the open transaction");
        c.execute_batch("ROLLBACK").unwrap();
    }
}
