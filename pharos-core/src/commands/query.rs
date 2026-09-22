use futures::StreamExt;
use serde::{Deserialize, Serialize};
use sqlx::{Column, Executor, Row, ValueRef};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

use crate::db::sqlite;
use crate::models::QueryHistoryEntry;
use crate::state::AppState;

/// Validate and set the search_path on a connection for a given schema.
/// Validates: non-empty, 1-63 chars, no null bytes. Escapes `"` as `""`.
/// The `SET search_path` statement for one schema, with the user's suffix
/// after it (Settings ▸ Connections ▸ `searchPathSuffix`).
///
/// Pure, so the quoting can be pinned without a server. It returns a Result
/// rather than the bare String the plan sketched, because the validation it
/// replaces is the only thing standing between a schema name and the
/// statement: dropping it to keep the signature tidy would weaken today's
/// behaviour.
///
/// Every element is double-quoted with `"` doubled, which is stricter than the
/// bare `, public` this replaces and identical in meaning for an ordinary
/// lower-case name. Quoting also makes `$user` work the way PostgreSQL itself
/// writes it (`"$user", public`).
///
/// An empty suffix means the schema alone. Commas separate several; blank
/// elements are dropped, so `"public,"` and `"public"` are the same suffix.
pub(crate) fn search_path_sql(schema_name: &str, suffix: &str) -> Result<String, String> {
    let mut parts = vec![quoted_search_path_element(schema_name)?];
    for element in suffix.split(',') {
        let element = element.trim();
        if element.is_empty() {
            continue;
        }
        parts.push(quoted_search_path_element(element)?);
    }
    Ok(format!("SET search_path TO {}", parts.join(", ")))
}

/// One `search_path` element, validated then quoted. The two rules are the
/// ones `set_search_path` has always applied to the schema name: 1–63
/// characters (PostgreSQL's `NAMEDATALEN - 1`) and no NUL.
fn quoted_search_path_element(name: &str) -> Result<String, String> {
    if name.is_empty() || name.len() > 63 {
        return Err("Invalid schema name: must be 1-63 characters".to_string());
    }
    if name.contains('\0') {
        return Err("Invalid schema name: must not contain null bytes".to_string());
    }
    Ok(format!("\"{}\"", name.replace('"', "\"\"")))
}

/// The user's `search_path` suffix, from the settings cache.
fn search_path_suffix(state: &AppState) -> String {
    state.settings().connections.search_path_suffix.clone()
}

pub(crate) async fn set_search_path(
    conn: &mut sqlx::pool::PoolConnection<sqlx::Postgres>,
    schema_name: &str,
    suffix: &str,
) -> Result<(), String> {
    let set_sql = search_path_sql(schema_name, suffix)?;
    (&mut **conn).execute(sqlx::raw_sql(&set_sql))
        .await
        .map_err(|e| format!("Failed to set schema: {}", e))?;
    Ok(())
}

/// How much history to keep, from the settings cache (Settings ▸ Library &
/// History). Both limits compose: whichever removes a row first wins.
pub(crate) fn history_prune_policy(state: &AppState) -> sqlite::HistoryPrunePolicy {
    let history = &state.settings().history;
    sqlite::HistoryPrunePolicy {
        retention_days: history.retention_days,
        max_entries: history.maximum_stored_entries,
    }
}

/// The user's statement timeout, in seconds, from the settings cache.
fn query_timeout_seconds(state: &AppState) -> u32 {
    state.settings().query.timeout_seconds
}

/// Apply the user's statement timeout on this connection. PostgreSQL-specific —
/// returns Err on servers that don't support it (e.g. ClickHouse), where the
/// caller should re-acquire since the failed SET may have killed the connection.
async fn apply_statement_timeout(
    conn: &mut sqlx::pool::PoolConnection<sqlx::Postgres>,
    timeout_seconds: u32,
) -> Result<(), sqlx::Error> {
    let ms = (timeout_seconds as u64).saturating_mul(1000);
    let set_sql = format!("SET statement_timeout = {}", ms);
    (&mut **conn).execute(sqlx::raw_sql(&set_sql)).await?;
    Ok(())
}

/// Reset statement_timeout before the connection returns to the pool so that
/// metadata queries and background ANALYZE on reused connections aren't capped
/// by the per-query timeout.
async fn reset_statement_timeout(conn: &mut sqlx::pool::PoolConnection<sqlx::Postgres>) {
    let _ = (&mut **conn)
        .execute(sqlx::raw_sql("RESET statement_timeout"))
        .await;
}

/// Format a database error, preserving PostgreSQL's character position if available.
/// sqlx's `.to_string()` drops the position field; this re-extracts it from PgDatabaseError.
pub(crate) fn format_db_error(e: &sqlx::Error) -> String {
    let code = e.as_database_error().and_then(|db| db.code());
    if let sqlx::Error::Database(db_err) = e {
        if let Some(pg_err) = db_err.try_downcast_ref::<sqlx::postgres::PgDatabaseError>() {
            if let Some(sqlx::postgres::PgErrorPosition::Original(pos)) = pg_err.position() {
                return tagged_db_message(code.as_deref(), &format!("{} at character {}", e, pos));
            }
        }
    }
    tagged_db_message(code.as_deref(), &e.to_string())
}

/// The SQLSTATE a session opened with `default_transaction_read_only=on`
/// answers every write with: `read_only_sql_transaction`.
pub(crate) const READ_ONLY_SQLSTATE: &str = "25006";

/// The marker a read-only refusal carries across the FFI.
///
/// The server's own wording — "cannot execute INSERT in a read-only
/// transaction" — never mentions Pharos's per-connection Read-only switch,
/// and it is localized by the server, so the front end cannot match on it.
/// The SQLSTATE can be matched, but sqlx's `Display` leaves it out, so it is
/// put in front of the message here and read back by
/// `ReadOnlyConnectionError` on the Swift side.
pub(crate) const READ_ONLY_MARKER: &str = "[SQLSTATE 25006]";

/// Tag a database error with its SQLSTATE when the front end needs to act on
/// it. Only 25006 is tagged today: every other message is passed through
/// byte-for-byte, so no existing error text changes.
pub(crate) fn tagged_db_message(code: Option<&str>, message: &str) -> String {
    match code {
        Some(READ_ONLY_SQLSTATE) => format!("{} {}", READ_ONLY_MARKER, message),
        _ => message.to_string(),
    }
}

// ColumnDef, KeySet and RowIdentity live in `row_identity`, beside the pure
// logic that fills them. A private `use` here is still visible to this module's
// descendants, so the test module below reaches them through `super::`.
use super::row_identity::{assemble_row_identity, ColumnDef, RowIdentity};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryResult {
    pub columns: Vec<ColumnDef>,
    pub rows: Vec<serde_json::Value>,
    pub row_count: usize,
    pub execution_time_ms: u64,
    pub has_more: bool,
    pub history_entry_id: Option<String>,
    /// The row identity of this result, or None when there is none to report:
    /// either no column carries a source table (a result of pure expressions),
    /// or the result has no rows, which leaves no keys to build. A result that
    /// HAS rows and at least one source table always carries a block, even when
    /// it holds no key candidate.
    pub row_identity: Option<RowIdentity>,
}

/// Build ColumnDef values from PgColumn metadata, keeping the source table OID
/// and attnum that PostgreSQL reports for each column.
fn pg_columns_to_defs(cols: &[sqlx::postgres::PgColumn]) -> Vec<ColumnDef> {
    cols.iter()
        .map(|col| ColumnDef {
            name: col.name().to_string(),
            data_type: col.type_info().to_string(),
            // Oid is a newtype over u32, so unwrap the .0.
            relation_oid: col.relation_id().map(|oid| oid.0),
            relation_attno: col.relation_attribute_no(),
        })
        .collect()
}

/// Fill the key cache for a result's source tables, then hand off to the pure
/// `assemble_row_identity`. This function owns only the I/O: everything that
/// decides what the block SAYS is pure and tested offline.
///
/// Returns None only when no column carries a source table. An empty
/// `candidates` array is the fingerprint case and still returns a block,
/// because Swift needs `table_keys` to test the table overlap.
async fn build_row_identity(
    pool: &sqlx::PgPool,
    connection_id: &str,
    columns: &[ColumnDef],
    json_rows: &[serde_json::Value],
    state: &AppState,
) -> Option<RowIdentity> {
    let column_oids: Vec<Option<u32>> = columns.iter().map(|c| c.relation_oid).collect();
    let primary_oid = crate::commands::primary_table_oid(&column_oids)?;

    // Every distinct source table, for the weak tier's overlap test.
    let mut all_oids: Vec<u32> = Vec::new();
    for oid in column_oids.iter().flatten() {
        if !all_oids.contains(oid) {
            all_oids.push(*oid);
        }
    }

    // Fetch only what the cache lacks, then read every entry from the cache.
    let missing = state.missing_key_cache_oids(connection_id, &all_oids);
    if !missing.is_empty() {
        match crate::db::postgres::get_table_key_info(pool, &missing).await {
            Ok(mut fetched) => {
                for oid in &missing {
                    match fetched.remove(oid) {
                        Some(info) => state.cache_table_key_info(connection_id, *oid, info),
                        None => {
                            // The catalogue answered, but this OID was not in
                            // the answer: the table was dropped between the
                            // query and this read. Cache a placeholder, or every
                            // later result from the same table would re-run both
                            // catalogue queries and find nothing again. An empty
                            // candidate list is the fingerprint tier, which is
                            // the honest answer for a table that is gone.
                            log::info!(
                                "No catalogue entry for oid {} on connection {}: \
                                 the table was dropped mid-query. This result \
                                 falls back to row fingerprints.",
                                oid,
                                connection_id
                            );
                            state.cache_table_key_info(
                                connection_id,
                                *oid,
                                crate::models::TableKeyInfo {
                                    display: crate::commands::unknown_table_display(*oid),
                                    candidates: Vec::new(),
                                },
                            );
                        }
                    }
                }
            }
            // A catalogue failure must not fail the query. Without key info the
            // result falls to the fingerprint tier, which is the honest result.
            // Nothing is cached here on purpose: a failure is usually transient,
            // so the next result should try again.
            Err(e) => log::warn!(
                "Failed to read table key info for connection {} oids {:?}: {}",
                connection_id,
                missing,
                e
            ),
        }
    }

    let info = state.get_table_key_info(connection_id, primary_oid);
    Some(assemble_row_identity(
        columns,
        json_rows,
        primary_oid,
        &all_oids,
        info.as_ref(),
    ))
}

/// Execute a SQL query and return results
pub async fn execute_query(
    connection_id: String,
    sql: String,
    query_id: Option<String>,
    limit: Option<u32>,
    schema: Option<String>,
    source: Option<String>,
    state: &AppState,
) -> Result<QueryResult, String> {
    let pool = state.require_pool(&connection_id)?;

    let limit = limit.unwrap_or(1000);
    let start = Instant::now();
    let query_id = query_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    // Acquire a dedicated connection from the pool so that SET search_path
    // and the query run on the same connection
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Get the backend PID for this connection so we can cancel it later.
    // Use raw_sql (simple protocol) and make it optional — non-PG servers
    // like ClickHouse don't have pg_backend_pid(). If the call fails and
    // kills the connection, re-acquire a fresh one.
    let backend_pid: i32 = {
        let mut stream = sqlx::raw_sql("SELECT pg_backend_pid()").fetch(&mut *conn);
        match stream.next().await {
            Some(Ok(row)) => {
                let pid = row.try_get::<i32, _>(0).unwrap_or(0);
                drop(stream);
                pid
            }
            _ => {
                drop(stream);
                // Connection may be dead — re-acquire
                drop(conn);
                conn = pool.acquire().await.map_err(|e| e.to_string())?;
                0
            }
        }
    };

    // Register this query for potential cancellation
    let cancelled = state.register_query(query_id.clone(), backend_pid);

    // Apply the user's query timeout on this connection. Non-PG servers don't
    // support it — re-acquire on failure (the failed SET may kill the connection).
    if apply_statement_timeout(&mut conn, query_timeout_seconds(state)).await.is_err() {
        drop(conn);
        conn = pool.acquire().await.map_err(|e| e.to_string())?;
    }

    // Set search_path if schema is specified. Non-PG servers like ClickHouse
    // don't support this — silently skip on failure rather than blocking the query.
    if let Some(ref schema_name) = schema {
        if let Err(_) = set_search_path(&mut conn, schema_name, &search_path_suffix(state)).await {
            // Connection may be dead — re-acquire
            drop(conn);
            conn = pool.acquire().await.map_err(|e| e.to_string())?;
        }
    }

    // Use simple query protocol (text format) — PostgreSQL formats all values as text,
    // so we get arrays as {1,2,3}, timestamps as 2024-01-15 12:34:56, etc.
    let mut stream = sqlx::raw_sql(&sql).fetch(&mut *conn);
    let mut rows: Vec<sqlx::postgres::PgRow> = Vec::with_capacity((limit + 1) as usize);
    let mut fetch_error: Option<String> = None;

    while let Some(row_result) = stream.next().await {
        // Check for cancellation
        if cancelled.load(Ordering::SeqCst) {
            drop(stream);
            state.unregister_query(&query_id);
            reset_statement_timeout(&mut conn).await;
            return Err("Query was cancelled".to_string());
        }

        match row_result {
            Ok(row) => {
                rows.push(row);
                if rows.len() > limit as usize {
                    break;
                }
            }
            Err(e) => {
                fetch_error = Some(format_db_error(&e));
                break;
            }
        }
    }

    drop(stream);
    state.unregister_query(&query_id);
    reset_statement_timeout(&mut conn).await;

    if let Some(err) = fetch_error {
        return Err(err);
    }

    let execution_time_ms = start.elapsed().as_millis() as u64;

    if rows.is_empty() {
        let columns = match (&mut *conn).describe(sql.as_str()).await {
            Ok(desc) => pg_columns_to_defs(desc.columns()),
            // describe() uses the extended query protocol, which non-PG
            // servers (ClickHouse) do not support. A clean empty list here
            // means a clean None for the identity block.
            Err(_) => vec![],
        };
        return Ok(QueryResult {
            columns,
            rows: vec![],
            row_count: 0,
            execution_time_ms,
            has_more: false,
            history_entry_id: None,
            // No identity block, even though describe() may have reported a
            // source table for every column. An identity exists to match ROWS,
            // and there are none. Building one here would cost a catalogue read
            // to produce a block with an empty key list in every candidate.
            row_identity: None,
        });
    }

    // Extract column information from the first row
    let first_row = &rows[0];
    let columns: Vec<ColumnDef> = pg_columns_to_defs(first_row.columns());

    // Determine if there are more rows
    let has_more = rows.len() > limit as usize;
    let row_limit = std::cmp::min(rows.len(), limit as usize);

    // Convert rows to JSON
    let json_rows: Vec<serde_json::Value> = rows
        .into_iter()
        .take(row_limit)
        .map(|row| {
            let values: Vec<serde_json::Value> = columns
                .iter()
                .enumerate()
                .map(|(i, col)| extract_value(&row, i, &col.data_type))
                .collect();
            serde_json::Value::Array(values)
        })
        .collect();

    // Return this connection to the pool BEFORE the identity block, which
    // acquires one of its own for the catalogue read. The pool is small — see
    // max_connections in db::postgres — so keeping this one would let enough
    // concurrent queries hold every connection while each waits for one more.
    drop(conn);

    let row_identity = build_row_identity(&pool, &connection_id, &columns, &json_rows, state).await;

    // Auto-save to query history. The ROW is inserted here, synchronously: Swift
    // attaches `history_entry_id` to a workspace the moment the callback fires,
    // so the id must already exist. The cached result blobs are attached by a
    // blocking task afterwards — the gzip and the blob write are the only part
    // of this path whose cost grows with the result, and the caller does not
    // need them to show the grid.
    let history_id = uuid::Uuid::new_v4().to_string();
    {
        let connection_name = state
            .get_config(&connection_id)
            .map(|c| c.name)
            .unwrap_or_else(|| connection_id.clone());
        let table_names = extract_table_names_for_history(&sql);
        let entry = QueryHistoryEntry {
            id: history_id.clone(),
            connection_id: connection_id.clone(),
            connection_name,
            sql: sql.clone(),
            row_count: Some(row_limit as i64),
            execution_time_ms: execution_time_ms as i64,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false, // Set by DB on load
            schema: schema.clone(),
            column_count: Some(columns.len() as i64),
            table_names,
            source: source.clone(),
            status: crate::models::HISTORY_STATUS_OK.to_string(),
            error_message: None,
        };

        // Serialize results for caching (skip if too large). The strings are
        // built here rather than in the task so the task owns plain text and
        // the row tree is moved into the result once, not cloned.
        let result_data = if !json_rows.is_empty() {
            let columns_json = serde_json::to_string(&columns).unwrap_or_default();
            let rows_json = serde_json::to_string(&json_rows).unwrap_or_default();
            let identity_json = row_identity
                .as_ref()
                .and_then(|id| serde_json::to_string(id).ok());
            // per-result cache cap: 10 MB uncompressed serialized JSON
            if columns_json.len() + rows_json.len() < 10_000_000 {
                Some((columns_json, rows_json, identity_json))
            } else {
                None
            }
        } else {
            None
        };

        let inserted = match state.metadata_db.lock() {
            Ok(db) => match sqlite::save_query_history_with_policy(
                &db,
                &entry,
                None,
                None,
                None,
                history_prune_policy(state),
            ) {
                Ok(()) => true,
                Err(e) => {
                    log::warn!("Failed to save query history: {}", e);
                    false
                }
            },
            Err(_) => false,
        };

        if let (true, Some((columns_json, rows_json, identity_json))) = (inserted, result_data) {
            let db = Arc::clone(&state.metadata_db);
            let entry_id = history_id.clone();
            tokio::task::spawn_blocking(move || {
                let Ok(db) = db.lock() else { return };
                if let Err(e) = sqlite::attach_query_history_result(
                    &db,
                    &entry_id,
                    &columns_json,
                    &rows_json,
                    identity_json.as_deref(),
                ) {
                    log::warn!("Failed to cache query history result: {}", e);
                }
            });
        }
    }

    Ok(QueryResult {
        columns,
        rows: json_rows,
        row_count: row_limit,
        execution_time_ms,
        has_more,
        history_entry_id: Some(history_id),
        row_identity,
    })
}

/// Extract a value from a row at the given index.
/// With simple query protocol (raw_sql), all values arrive in PostgreSQL text format.
/// We just read the text representation directly — no per-type decoding needed.
fn extract_value(row: &sqlx::postgres::PgRow, index: usize, _type_name: &str) -> serde_json::Value {
    match row.try_get_raw(index) {
        Ok(raw) => {
            if raw.is_null() {
                serde_json::Value::Null
            } else if let Ok(s) = raw.as_str() {
                serde_json::Value::String(s.to_string())
            } else {
                serde_json::Value::Null
            }
        }
        Err(_) => serde_json::Value::Null,
    }
}

/// Fetch more rows from an already-executed query using LIMIT/OFFSET
pub async fn fetch_more_rows(
    connection_id: String,
    sql: String,
    limit: i64,
    offset: i64,
    schema: Option<String>,
    state: &AppState,
) -> Result<QueryResult, String> {
    let pool = state.require_pool(&connection_id)?;

    let start = Instant::now();

    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Apply the user's query timeout (non-fatal for non-PG servers)
    if apply_statement_timeout(&mut conn, query_timeout_seconds(state)).await.is_err() {
        drop(conn);
        conn = pool.acquire().await.map_err(|e| e.to_string())?;
    }

    // Set search_path if schema is specified (non-fatal for non-PG servers)
    if let Some(ref schema_name) = schema {
        if let Err(_) = set_search_path(&mut conn, schema_name, &search_path_suffix(state)).await {
            drop(conn);
            conn = pool.acquire().await.map_err(|e| e.to_string())?;
        }
    }

    // Wrap the original SQL with LIMIT/OFFSET
    let wrapped_sql = format!(
        "SELECT * FROM ({}) AS _pharos_paginated LIMIT {} OFFSET {}",
        sql.trim().trim_end_matches(';'),
        limit + 1,
        offset
    );

    let mut stream = sqlx::raw_sql(&wrapped_sql).fetch(&mut *conn);
    let mut rows: Vec<sqlx::postgres::PgRow> = Vec::with_capacity((limit + 1) as usize);

    while let Some(row_result) = stream.next().await {
        match row_result {
            Ok(row) => {
                rows.push(row);
                if rows.len() > limit as usize {
                    break;
                }
            }
            Err(e) => {
                drop(stream);
                reset_statement_timeout(&mut conn).await;
                return Err(e.to_string());
            }
        }
    }
    drop(stream);
    reset_statement_timeout(&mut conn).await;

    let execution_time_ms = start.elapsed().as_millis() as u64;

    if rows.is_empty() {
        return Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            row_count: 0,
            execution_time_ms,
            has_more: false,
            history_entry_id: None,
            row_identity: None,
        });
    }

    let first_row = &rows[0];
    let columns: Vec<ColumnDef> = pg_columns_to_defs(first_row.columns());

    let has_more = rows.len() > limit as usize;
    let row_limit = std::cmp::min(rows.len(), limit as usize);

    let json_rows: Vec<serde_json::Value> = rows
        .into_iter()
        .take(row_limit)
        .map(|row| {
            let values: Vec<serde_json::Value> = columns
                .iter()
                .enumerate()
                .map(|(i, col)| extract_value(&row, i, &col.data_type))
                .collect();
            serde_json::Value::Array(values)
        })
        .collect();

    // As in execute_query: release this connection before the catalogue read
    // acquires one of its own.
    drop(conn);

    let row_identity = build_row_identity(&pool, &connection_id, &columns, &json_rows, state).await;

    Ok(QueryResult {
        columns,
        rows: json_rows,
        row_count: row_limit,
        execution_time_ms,
        has_more,
        history_entry_id: None,
        row_identity,
    })
}

/// Rows per FETCH in `fetch_all_rows_snapshot`. Bounds one round trip and
/// gives the cancel flag a place to be checked.
const SNAPSHOT_FETCH_CHUNK: i64 = 5_000;

/// Re-run a statement inside ONE transaction on ONE connection, read it
/// through a cursor from start to end, and return every row up to `max_rows`
/// as a single consistent snapshot.
///
/// `fetch_more_rows` re-executes the statement per page wrapped in
/// LIMIT/OFFSET. Without an outermost ORDER BY, PostgreSQL does not promise
/// the same order for two executions, so pages can repeat or skip rows. A
/// cursor reads one execution, so the rows line up.
///
/// It is a plain cursor, not WITH HOLD, on purpose. WITH HOLD materialises
/// the whole result on the server at commit — the load paging exists to
/// avoid — and is only needed when a cursor must outlive its transaction.
/// This transaction lasts exactly as long as the load, so the snapshot and
/// any locks it holds are released the moment the rows are in hand.
///
/// `has_more` is true when the statement has more rows than `max_rows`; the
/// caller then shows the first `max_rows` and says so. Cancel works as for
/// `execute_query`: the query is registered under `query_id`, and a
/// `pg_cancel_backend` aborts the running FETCH, which rolls back.
///
/// `on_progress` is called once per FETCH chunk with the RUNNING TOTAL of rows
/// held so far, so the caller can show a determinate bar instead of a spinner
/// that says nothing. It is called after the chunk is in hand and after the cap
/// has cut it, so the number it reports is never larger than `max_rows` and
/// never larger than the row count the result finally carries. It is not called
/// for a failed or cancelled chunk: the last number the caller saw stays the
/// last number that was true.
pub async fn fetch_all_rows_snapshot(
    connection_id: String,
    sql: String,
    query_id: String,
    max_rows: i64,
    schema: Option<String>,
    state: &AppState,
    on_progress: impl Fn(u64) + Send,
) -> Result<QueryResult, String> {
    let pool = state.require_pool(&connection_id)?;

    let start = Instant::now();
    let max_rows = max_rows.max(1);
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Backend PID for cancellation, as in execute_query. A server without
    // pg_backend_pid() cannot run a cursor either, so a failure here is an
    // error rather than a fallback.
    let backend_pid: i32 = {
        let mut stream = sqlx::raw_sql("SELECT pg_backend_pid()").fetch(&mut *conn);
        match stream.next().await {
            Some(Ok(row)) => row.try_get::<i32, _>(0).unwrap_or(0),
            Some(Err(e)) => return Err(format_db_error(&e)),
            None => return Err("Could not determine the backend PID".to_string()),
        }
    };
    let cancelled = state.register_query(query_id.clone(), backend_pid);

    // The per-statement timeout applies to the DECLARE and to each FETCH.
    let _ = apply_statement_timeout(&mut conn, query_timeout_seconds(state)).await;
    if let Some(ref schema_name) = schema {
        let _ = set_search_path(&mut conn, schema_name, &search_path_suffix(state)).await;
    }

    // One name per query id: two snapshots on the pool never share a
    // connection, but a distinct name keeps a stray CLOSE from being ambiguous.
    let cursor = format!(
        "_pharos_snapshot_{}",
        query_id.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>()
    );
    let statement = sql.trim().trim_end_matches(';').trim();

    // Every failure path below rolls back, resets the timeout and unregisters.
    // A macro, not a nested async fn: a helper borrowing `conn` and `state`
    // gives the spawned future a lifetime the `Executor`/`Send` bounds on
    // `ffi_spawn!` cannot prove ("implementation is not general enough").
    macro_rules! abort {
        () => {{
            let _ = (&mut *conn).execute(sqlx::raw_sql("ROLLBACK")).await;
            reset_statement_timeout(&mut conn).await;
            state.unregister_query(&query_id);
        }};
    }

    let open = format!("BEGIN; DECLARE {} NO SCROLL CURSOR FOR {}", cursor, statement);
    if let Err(e) = (&mut *conn).execute(sqlx::raw_sql(&open)).await {
        abort!();
        return Err(format_db_error(&e));
    }

    let mut rows: Vec<sqlx::postgres::PgRow> = Vec::new();
    let mut has_more = false;
    loop {
        if cancelled.load(Ordering::SeqCst) {
            abort!();
            return Err("Query was cancelled".to_string());
        }
        // Ask for one row past the cap so `has_more` is known without a
        // separate probe.
        let want = std::cmp::min(SNAPSHOT_FETCH_CHUNK, max_rows - rows.len() as i64 + 1);
        let fetch = format!("FETCH FORWARD {} FROM {}", want, cursor);
        let mut stream = sqlx::raw_sql(&fetch).fetch(&mut *conn);
        let mut got: i64 = 0;
        let mut fetch_error: Option<String> = None;
        while let Some(row_result) = stream.next().await {
            match row_result {
                Ok(row) => {
                    got += 1;
                    rows.push(row);
                }
                Err(e) => {
                    fetch_error = Some(format_db_error(&e));
                    break;
                }
            }
        }
        drop(stream);
        if let Some(err) = fetch_error {
            let was_cancelled = cancelled.load(Ordering::SeqCst);
            abort!();
            return Err(if was_cancelled { "Query was cancelled".to_string() } else { err });
        }
        // The cap is applied BEFORE the progress report, so the caller is never
        // told about a row the result does not keep.
        let capped = rows.len() as i64 > max_rows;
        if capped {
            has_more = true;
            rows.truncate(max_rows as usize);
        }
        on_progress(rows.len() as u64);
        if capped || got < want {
            break; // the cap cut it short, or the cursor is exhausted
        }
    }

    // Column metadata for an empty result, before the transaction ends.
    let empty_columns = if rows.is_empty() {
        match (&mut *conn).describe(statement).await {
            Ok(desc) => pg_columns_to_defs(desc.columns()),
            Err(_) => vec![],
        }
    } else {
        vec![]
    };

    let close = format!("CLOSE {}; COMMIT", cursor);
    if let Err(e) = (&mut *conn).execute(sqlx::raw_sql(&close)).await {
        abort!();
        return Err(format_db_error(&e));
    }
    reset_statement_timeout(&mut conn).await;
    state.unregister_query(&query_id);

    let execution_time_ms = start.elapsed().as_millis() as u64;

    if rows.is_empty() {
        return Ok(QueryResult {
            columns: empty_columns,
            rows: vec![],
            row_count: 0,
            execution_time_ms,
            has_more: false,
            history_entry_id: None,
            row_identity: None,
        });
    }

    let columns: Vec<ColumnDef> = pg_columns_to_defs(rows[0].columns());
    let json_rows: Vec<serde_json::Value> = rows
        .into_iter()
        .map(|row| {
            let values: Vec<serde_json::Value> = columns
                .iter()
                .enumerate()
                .map(|(i, col)| extract_value(&row, i, &col.data_type))
                .collect();
            serde_json::Value::Array(values)
        })
        .collect();
    let row_count = json_rows.len();

    // Release this connection before the identity block acquires one of its own.
    drop(conn);
    let row_identity = build_row_identity(&pool, &connection_id, &columns, &json_rows, state).await;

    Ok(QueryResult {
        columns,
        rows: json_rows,
        row_count,
        execution_time_ms,
        has_more,
        history_entry_id: None,
        row_identity,
    })
}

/// Execute a statement that doesn't return rows (INSERT, UPDATE, DELETE, etc.)
pub async fn execute_statement(
    connection_id: String,
    sql: String,
    schema: Option<String>,
    state: &AppState,
) -> Result<ExecuteResult, String> {
    let pool = state.require_pool(&connection_id)?;

    let start = Instant::now();

    // Acquire a dedicated connection so SET search_path and the statement
    // run on the same connection
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Apply the user's query timeout (non-fatal for non-PG servers)
    if apply_statement_timeout(&mut conn, query_timeout_seconds(state)).await.is_err() {
        drop(conn);
        conn = pool.acquire().await.map_err(|e| e.to_string())?;
    }

    // Set search_path if schema is specified (non-fatal for non-PG servers)
    if let Some(ref schema_name) = schema {
        if let Err(_) = set_search_path(&mut conn, schema_name, &search_path_suffix(state)).await {
            drop(conn);
            conn = pool.acquire().await.map_err(|e| e.to_string())?;
        }
    }

    let result = (&mut *conn).execute(sqlx::raw_sql(&sql)).await;
    reset_statement_timeout(&mut conn).await;
    let result = result.map_err(|e| format_db_error(&e))?;

    let execution_time_ms = start.elapsed().as_millis() as u64;

    let rows_affected = result.rows_affected();

    // Auto-save to query history (fire-and-forget, no results for statements)
    let statement_history_id = uuid::Uuid::new_v4().to_string();
    {
        let connection_name = state
            .get_config(&connection_id)
            .map(|c| c.name)
            .unwrap_or_else(|| connection_id.clone());
        let table_names = extract_table_names_for_history(&sql);
        let entry = QueryHistoryEntry {
            id: statement_history_id.clone(),
            connection_id: connection_id.clone(),
            connection_name,
            sql: sql.clone(),
            row_count: Some(rows_affected as i64),
            execution_time_ms: execution_time_ms as i64,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false,
            schema: schema.clone(),
            column_count: None,
            table_names,
            source: None,
            status: crate::models::HISTORY_STATUS_OK.to_string(),
            error_message: None,
        };
        if let Ok(db) = state.metadata_db.lock() {
            if let Err(e) = sqlite::save_query_history_with_policy(
                &db, &entry, None, None, None, history_prune_policy(state),
            ) {
                log::warn!("Failed to save query history: {}", e);
            }
        }
    }

    Ok(ExecuteResult {
        rows_affected,
        execution_time_ms,
        history_entry_id: Some(statement_history_id),
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteResult {
    pub rows_affected: u64,
    pub execution_time_ms: u64,
    // NOTE: this struct intentionally has NO `rename_all` — the Swift side maps
    // these via explicit snake_case CodingKeys, so fields must stay snake_case.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history_entry_id: Option<String>,
}

/// Cancel a running query
pub async fn cancel_query(
    connection_id: String,
    query_id: String,
    state: &AppState,
) -> Result<bool, String> {
    // Get the pool to send the cancel command
    let pool = state.require_pool(&connection_id)?;

    // Get the backend PID for the query we want to cancel
    let backend_pid = state
        .get_query_backend_pid(&query_id)
        .ok_or_else(|| format!("Query not found: {}", query_id))?;

    // Mark the query as cancelled
    state.mark_query_cancelled(&query_id);

    // Send cancel signal to PostgreSQL (pg_cancel_backend is PG-specific)
    let cancel_sql = format!("SELECT pg_cancel_backend({})", backend_pid);
    let cancelled: bool = {
        let mut stream = sqlx::raw_sql(&cancel_sql).fetch(&pool);
        match stream.next().await {
            Some(Ok(row)) => {
                let val = row.try_get::<bool, _>(0).unwrap_or(false);
                drop(stream);
                val
            }
            _ => {
                drop(stream);
                false
            }
        }
    };

    Ok(cancelled)
}

/// Result of SQL validation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    pub valid: bool,
    pub error: Option<ValidationError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationError {
    pub message: String,
    pub position: Option<usize>,
    pub line: Option<usize>,
    pub column: Option<usize>,
}

/// Validate SQL syntax without executing it
/// Uses PostgreSQL's PREPARE statement to check syntax
pub async fn validate_sql(
    connection_id: String,
    sql: String,
    schema: Option<String>,
    state: &AppState,
) -> Result<ValidationResult, String> {
    let pool = state.require_pool(&connection_id)?;

    // Skip validation for empty queries
    let sql_trimmed = sql.trim();
    if sql_trimmed.is_empty() {
        return Ok(ValidationResult {
            valid: true,
            error: None,
        });
    }

    // Calculate the offset of trimmed content from the start of the original SQL
    // This is how many characters of leading whitespace were removed
    let leading_whitespace_len = sql.len() - sql.trim_start().len();

    // Acquire a dedicated connection
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Set search_path if schema is specified (non-fatal for non-PG servers)
    if let Some(ref schema_name) = schema {
        if let Err(_) = set_search_path(&mut conn, schema_name, &search_path_suffix(state)).await {
            drop(conn);
            conn = pool.acquire().await.map_err(|e| e.to_string())?;
        }
    }

    // Generate a unique prepared statement name
    let stmt_name = format!("validate_{}", uuid::Uuid::new_v4().to_string().replace('-', "_"));

    // Build the PREPARE statement prefix - we need to know its length to adjust error positions
    let prepare_prefix = format!("PREPARE {} AS ", stmt_name);
    let prefix_len = prepare_prefix.len();

    // Try to prepare the statement - this validates the SQL without executing it
    let prepare_sql = format!("{}{}", prepare_prefix, sql_trimmed);

    match (&mut *conn).execute(sqlx::raw_sql(&prepare_sql)).await {
        Ok(_) => {
            // Clean up the prepared statement
            let deallocate_sql = format!("DEALLOCATE {}", stmt_name);
            let _ = (&mut *conn).execute(sqlx::raw_sql(&deallocate_sql)).await;

            Ok(ValidationResult {
                valid: true,
                error: None,
            })
        }
        Err(e) => {
            let error_msg = e.to_string();

            // Extract position directly from PgDatabaseError (e.to_string() drops it)
            let raw_position = if let sqlx::Error::Database(ref db_err) = e {
                if let Some(pg_err) = db_err.try_downcast_ref::<sqlx::postgres::PgDatabaseError>() {
                    if let Some(sqlx::postgres::PgErrorPosition::Original(pos)) = pg_err.position() {
                        Some(pos as usize)
                    } else {
                        None
                    }
                } else {
                    None
                }
            } else {
                None
            };

            // Adjust position: subtract PREPARE prefix, add back leading whitespace
            let position = raw_position.map(|p| {
                if p > prefix_len {
                    (p - prefix_len) + leading_whitespace_len
                } else {
                    1
                }
            });

            let (line, column) = if let Some(pos) = position {
                let (l, c) = char_position_to_line_col(&sql, pos);
                (Some(l), Some(c))
            } else {
                (None, None)
            };

            Ok(ValidationResult {
                valid: false,
                error: Some(ValidationError {
                    message: clean_error_message(&error_msg),
                    position,
                    line,
                    column,
                }),
            })
        }
    }
}

/// Convert a character position to line and column numbers
fn char_position_to_line_col(sql: &str, position: usize) -> (usize, usize) {
    let mut line = 1;
    let mut col = 1;

    for (i, c) in sql.chars().enumerate() {
        if i + 1 >= position {
            break;
        }
        if c == '\n' {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    (line, col)
}

/// Clean up PostgreSQL error message for display
fn clean_error_message(error_msg: &str) -> String {
    // Remove the "error returned from database:" prefix that sqlx adds
    let msg = error_msg
        .strip_prefix("error returned from database: ")
        .unwrap_or(error_msg);

    // Remove the "at character N" suffix since we're providing position separately
    if let Some(pos) = msg.rfind(" at character ") {
        msg[..pos].to_string()
    } else {
        msg.to_string()
    }
}

/// Extract table names from SQL for history display.
/// Scans for FROM and JOIN keywords, returns comma-separated table names.
pub fn extract_table_names_for_history(sql: &str) -> Option<String> {
    // Strip single-line comments and normalize whitespace
    let normalized: String = sql
        .lines()
        .map(|l| {
            if let Some(pos) = l.find("--") { &l[..pos] } else { l }
        })
        .collect::<Vec<_>>()
        .join(" ");
    let normalized: String = normalized.split_whitespace().collect::<Vec<_>>().join(" ");
    let upper = normalized.to_uppercase();

    let mut tables = Vec::new();
    let keywords = [" FROM ", " JOIN "];

    for keyword in &keywords {
        let mut search_from = 0;
        while let Some(pos) = upper[search_from..].find(keyword) {
            let abs_pos = search_from + pos + keyword.len();
            if abs_pos >= normalized.len() {
                break;
            }
            let after = normalized[abs_pos..].trim_start();
            // Skip subqueries
            if after.starts_with('(') {
                search_from = abs_pos;
                continue;
            }
            if let Some((ident, rest)) = parse_identifier(after) {
                let rest = rest.trim_start();
                let table_name = if rest.starts_with('.') {
                    // schema.table — take the table part
                    parse_identifier(rest[1..].trim_start())
                        .map(|(t, _)| t)
                        .unwrap_or(ident)
                } else {
                    ident
                };
                if !tables.contains(&table_name) {
                    tables.push(table_name);
                }
            }
            search_from = abs_pos;
        }
    }

    if tables.is_empty() { None } else { Some(tables.join(", ")) }
}

/// Parse a SQL identifier (quoted or unquoted) from the start of a string.
/// Returns (identifier, rest_of_string).
fn parse_identifier(s: &str) -> Option<(String, &str)> {
    if s.starts_with('"') {
        // Handle "" escaped quotes in identifiers
        let mut end = 1;
        loop {
            match s[end..].find('"') {
                Some(pos) => {
                    end += pos + 1;
                    if end < s.len() && s.as_bytes()[end] == b'"' {
                        end += 1; // skip escaped ""
                    } else {
                        break;
                    }
                }
                None => return None,
            }
        }
        let ident = s[1..end - 1].replace("\"\"", "\"");
        Some((ident, &s[end..]))
    } else {
        // Unquoted identifier
        let end = s.find(|c: char| !c.is_ascii_alphanumeric() && c != '_').unwrap_or(s.len());
        if end == 0 {
            return None;
        }
        Some((s[..end].to_string(), &s[end..]))
    }
}

// ---------------------------------------------------------------------------
// EXPLAIN
// ---------------------------------------------------------------------------

/// The `EXPLAIN (...)` statement Pharos runs for `sql`, or the reason it will
/// not run one.
///
/// Pure, so both rules it enforces are testable without a server:
///
/// - **One statement.** `EXPLAIN` takes a single statement, so a script is
///   refused rather than silently explaining only its first line. A semicolon
///   inside a string literal, a quoted identifier, a comment or a dollar-quoted
///   body is not a separator, so those do not trigger the refusal.
/// - **No trailing semicolon.** `EXPLAIN … select 1;` is a syntax error, and the
///   editor hands us the user's text with whatever punctuation they typed.
///
/// `BUFFERS false` is spelled out rather than omitted: PostgreSQL before 16
/// rejects a bare `BUFFERS` without `ANALYZE`, but accepts the explicit false
/// on every version.
pub fn explain_statement(sql: &str, analyze: bool) -> Result<String, String> {
    let body = single_statement(sql)?;
    let flag = if analyze { "true" } else { "false" };
    Ok(format!(
        "EXPLAIN (FORMAT JSON, COSTS, VERBOSE, BUFFERS {}, ANALYZE {}) {}",
        flag, flag, body
    ))
}

/// The one statement in `sql`, trimmed and without its trailing semicolon.
fn single_statement(sql: &str) -> Result<String, String> {
    let cuts = top_level_semicolons(sql);
    let mut parts: Vec<&str> = Vec::with_capacity(cuts.len() + 1);
    let mut start = 0usize;
    for cut in &cuts {
        parts.push(&sql[start..*cut]);
        start = cut + 1;
    }
    parts.push(&sql[start..]);

    // A part holding only whitespace and comments is not a statement: it is the
    // tail after the last semicolon, or a comment the user left at the end.
    let mut kept: Vec<&str> = parts.into_iter().filter(|p| !is_blank_or_comment(p)).collect();
    match kept.len() {
        0 => Err("Nothing to explain".to_string()),
        1 => Ok(kept.remove(0).trim().to_string()),
        _ => Err("Explain one statement at a time".to_string()),
    }
}

/// Byte offsets of the `;` characters that separate statements — those in
/// ordinary SQL text, never those inside a literal, an identifier, a comment or
/// a dollar-quoted body.
fn top_level_semicolons(sql: &str) -> Vec<usize> {
    let b = sql.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < n {
        match b[i] {
            b'\'' => i = skip_single_quoted(b, i),
            b'"' => i = skip_double_quoted(b, i),
            b'-' if i + 1 < n && b[i + 1] == b'-' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            b'$' => match dollar_tag_end(b, i) {
                Some(open_end) => i = skip_dollar_quoted(b, i, open_end),
                None => i += 1,
            },
            b';' => {
                out.push(i);
                i += 1;
            }
            _ => i += 1,
        }
    }
    out
}

/// True when the slice holds nothing but whitespace and comments.
fn is_blank_or_comment(sql: &str) -> bool {
    let b = sql.as_bytes();
    let n = b.len();
    let mut i = 0usize;
    while i < n {
        match b[i] {
            b'-' if i + 1 < n && b[i + 1] == b'-' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            c if c.is_ascii_whitespace() => i += 1,
            _ => return false,
        }
    }
    true
}

/// Index just past the closing quote of the single-quoted literal at `start`.
///
/// `''` is the doubled-quote escape. A backslash escapes the next character
/// only in an `E'…'` string, which is why the `E` prefix is detected here
/// rather than every backslash being treated as an escape — in a standard
/// string (`standard_conforming_strings` is on by default) a backslash is an
/// ordinary character and must not swallow a closing quote.
fn skip_single_quoted(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let escapes = start > 0
        && (b[start - 1] == b'E' || b[start - 1] == b'e')
        && (start < 2 || !is_ident_byte(b[start - 2]));
    let mut i = start + 1;
    while i < n {
        match b[i] {
            b'\\' if escapes && i + 1 < n => i += 2,
            b'\'' if i + 1 < n && b[i + 1] == b'\'' => i += 2,
            b'\'' => return i + 1,
            _ => i += 1,
        }
    }
    n
}

/// Index just past the closing quote of the quoted identifier at `start`.
/// `""` is the doubled-quote escape.
fn skip_double_quoted(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let mut i = start + 1;
    while i < n {
        match b[i] {
            b'"' if i + 1 < n && b[i + 1] == b'"' => i += 2,
            b'"' => return i + 1,
            _ => i += 1,
        }
    }
    n
}

fn skip_line_comment(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let mut i = start + 2;
    while i < n && b[i] != b'\n' {
        i += 1;
    }
    i
}

/// PostgreSQL nests block comments, so the depth is counted rather than
/// stopping at the first `*/`.
fn skip_block_comment(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let mut depth = 1usize;
    let mut i = start + 2;
    while i < n {
        if i + 1 < n && b[i] == b'/' && b[i + 1] == b'*' {
            depth += 1;
            i += 2;
        } else if i + 1 < n && b[i] == b'*' && b[i + 1] == b'/' {
            depth -= 1;
            i += 2;
            if depth == 0 {
                return i;
            }
        } else {
            i += 1;
        }
    }
    n
}

fn is_ident_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

/// Index just past the opening `$tag$` at `start`, or `None` when this `$` does
/// not open a dollar-quoted body. `$1` (a positional parameter) has no closing
/// `$`, and `$2x$` is not a tag because a tag may not start with a digit.
fn dollar_tag_end(b: &[u8], start: usize) -> Option<usize> {
    let n = b.len();
    let mut i = start + 1;
    while i < n && b[i] != b'$' {
        if !is_ident_byte(b[i]) {
            return None;
        }
        i += 1;
    }
    if i >= n {
        return None;
    }
    if i > start + 1 && b[start + 1].is_ascii_digit() {
        return None;
    }
    Some(i + 1)
}

/// Index just past the closing `$tag$` of the body opened at `start`.
fn skip_dollar_quoted(b: &[u8], start: usize, open_end: usize) -> usize {
    let tag = &b[start..open_end];
    let n = b.len();
    let mut i = open_end;
    while i + tag.len() <= n {
        if &b[i..i + tag.len()] == tag {
            return i + tag.len();
        }
        i += 1;
    }
    n
}

/// Run `EXPLAIN` (optionally `ANALYZE`) for one statement and return
/// PostgreSQL's `FORMAT JSON` plan as text.
///
/// Under `ANALYZE` the statement really runs, so the whole thing is wrapped in
/// a transaction on ONE connection that is always rolled back — an
/// INSERT/UPDATE explained this way leaves nothing behind. The rollback is a
/// safety net, not a licence: the UI refuses to explain-analyze a destructive
/// statement in the first place.
pub async fn explain_query(
    connection_id: String,
    sql: String,
    analyze: bool,
    state: &AppState,
) -> Result<String, String> {
    // Build the statement first: a refusal costs no connection.
    let statement = explain_statement(&sql, analyze)?;

    let pool = state.require_pool(&connection_id)?;

    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    if apply_statement_timeout(&mut conn, query_timeout_seconds(state)).await.is_err() {
        drop(conn);
        conn = pool.acquire().await.map_err(|e| e.to_string())?;
    }

    // BEGIN, the EXPLAIN and ROLLBACK all run on this one connection, so the
    // rollback is guaranteed to undo the work the ANALYZE did.
    let mut in_transaction = false;
    if analyze {
        match (&mut *conn).execute(sqlx::raw_sql("BEGIN")).await {
            Ok(_) => in_transaction = true,
            Err(e) => {
                let message = format_db_error(&e);
                reset_statement_timeout(&mut conn).await;
                return Err(message);
            }
        }
    }

    // The single row's single column. `FORMAT JSON` gives it the `json` type,
    // which `try_get::<String>` refuses; the simple protocol already carries
    // the value as text, so read the raw value the way `extract_value` does.
    let mut plan: Option<String> = None;
    let mut failure: Option<String> = None;
    {
        let mut stream = sqlx::raw_sql(&statement).fetch(&mut *conn);
        match stream.next().await {
            Some(Ok(row)) => match row.try_get_raw(0) {
                Ok(raw) => match raw.as_str() {
                    Ok(text) => plan = Some(text.to_string()),
                    Err(e) => failure = Some(e.to_string()),
                },
                Err(e) => failure = Some(e.to_string()),
            },
            Some(Err(e)) => failure = Some(format_db_error(&e)),
            None => failure = Some("EXPLAIN returned no plan".to_string()),
        }
        drop(stream);
    }

    if in_transaction {
        // Every path, including the failure path: after a failed EXPLAIN the
        // transaction is aborted, and ROLLBACK is what makes the connection
        // usable again for whoever takes it out of the pool next.
        let _ = (&mut *conn).execute(sqlx::raw_sql("ROLLBACK")).await;
    }
    reset_statement_timeout(&mut conn).await;

    if let Some(message) = failure {
        return Err(message);
    }
    plan.ok_or_else(|| "EXPLAIN returned no plan".to_string())
}

#[cfg(test)]
mod explain_statement_tests {
    use super::explain_statement;

    /// The option list, so a case below states only what it is about.
    const PLAIN: &str = "EXPLAIN (FORMAT JSON, COSTS, VERBOSE, BUFFERS false, ANALYZE false) ";
    const ANALYZED: &str = "EXPLAIN (FORMAT JSON, COSTS, VERBOSE, BUFFERS true, ANALYZE true) ";

    #[test]
    fn a_single_statement_is_wrapped_in_the_option_list() {
        assert_eq!(
            explain_statement("select 1", false).unwrap(),
            format!("{}select 1", PLAIN)
        );
        // ANALYZE flips BOTH options together — a fixture with only one of them
        // set could not tell the two apart.
        assert_eq!(
            explain_statement("select 1", true).unwrap(),
            format!("{}select 1", ANALYZED)
        );
    }

    #[test]
    fn a_trailing_semicolon_and_its_whitespace_are_stripped() {
        assert_eq!(
            explain_statement("  select 1 ;  \n", false).unwrap(),
            format!("{}select 1", PLAIN)
        );
        // A comment after the semicolon is not a second statement.
        assert_eq!(
            explain_statement("select 1; -- note", false).unwrap(),
            format!("{}select 1", PLAIN)
        );
    }

    #[test]
    fn two_statements_are_refused() {
        assert_eq!(
            explain_statement("select 1; select 2", false).unwrap_err(),
            "Explain one statement at a time"
        );
        // Empty text has nothing to explain, which is a different answer from
        // "too many" — the UI says so differently.
        assert_eq!(
            explain_statement("  \n -- just a comment\n", false).unwrap_err(),
            "Nothing to explain"
        );
    }

    #[test]
    fn a_semicolon_that_is_not_a_separator_does_not_refuse() {
        // One statement each: the semicolon sits inside a literal, a quoted
        // identifier, a comment and a dollar-quoted body. The wrong rule
        // ("split on every ;") refuses all four, so each case discriminates.
        for sql in [
            "select 'a;b'",
            "select * from \"we;ird\"",
            "select 1 /* a ; b */ + 2",
            "select $$a;b$$",
            "select $tag$a;b$tag$",
            // An E-string where a backslash escapes the quote that would
            // otherwise close it.
            "select E'a\\';b'",
        ] {
            let built = explain_statement(sql, false)
                .unwrap_or_else(|e| panic!("`{}` should be one statement, got: {}", sql, e));
            assert_eq!(built, format!("{}{}", PLAIN, sql), "for `{}`", sql);
        }
        // And the guard really bites: the same text with a top-level semicolon
        // between the two halves IS refused.
        assert!(explain_statement("select 'a';select 'b'", false).is_err());
    }
}

/// Live test of the row identity wiring.
///
///   cargo test --release query_identity -- --ignored --nocapture
///
/// This test is MANDATORY, not a nicety. `get_table_key_info` is public in a
/// public module of a staticlib crate, so rustc assumes an external C caller
/// and never warns that it is unused. If this file forgot to call it, or
/// discarded its result, the crate would compile clean, every offline test
/// would still pass, and every query would silently report no identity — the
/// weakest tier forever, with nothing anywhere reporting a fault. Only a real
/// connection proves the wiring.
///
/// Fixture: `scripts/tagtest-schema.sql`.
#[cfg(test)]
mod live_query_identity_tests {
    use super::{execute_query, QueryResult, RowIdentity, fetch_all_rows_snapshot};
    use crate::commands::row_identity::KeySet;
    use crate::state::AppState;
    use rusqlite::Connection as SqliteConnection;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";
    const CONN: &str = "live-identity-test";

    /// The `tagtest` relations present, tables and views alike. Empty means the
    /// fixture schema is absent.
    async fn tagtest_relations(pool: &sqlx::PgPool) -> Vec<String> {
        let sql = "SELECT c.relname AS name \
                   FROM pg_class c \
                   JOIN pg_namespace n ON n.oid = c.relnamespace \
                   WHERE n.nspname = 'tagtest' AND c.relkind IN ('r', 'v')";
        let rows = sqlx::raw_sql(sql).fetch_all(pool).await.expect("catalogue lookup failed");
        rows.iter().map(|r| r.try_get::<String, _>("name").expect("name decode")).collect()
    }

    /// The OID of one `tagtest` relation. The block's table_key must carry this
    /// exact number, so read it from the catalogue rather than trusting the
    /// block to agree with itself.
    async fn relation_oid(pool: &sqlx::PgPool, name: &str) -> u32 {
        let sql = format!(
            "SELECT c.oid AS oid FROM pg_class c \
             JOIN pg_namespace n ON n.oid = c.relnamespace \
             WHERE n.nspname = 'tagtest' AND c.relname = '{}'",
            name
        );
        let row = sqlx::raw_sql(&sql)
            .fetch_all(pool)
            .await
            .expect("oid lookup failed")
            .into_iter()
            .next()
            .unwrap_or_else(|| panic!("no tagtest relation named {}", name));
        row.try_get::<sqlx::postgres::types::Oid, _>("oid").expect("oid decode").0
    }

    /// The candidate of the named kind, or a panic showing the whole set. Never
    /// index by position: an ordering change must fail loudly, not silently
    /// assert against the wrong key.
    fn keyset<'a>(id: &'a RowIdentity, kind: &str) -> &'a KeySet {
        id.candidates.iter().find(|c| c.kind == kind).unwrap_or_else(|| {
            panic!("no `{}` candidate; got {:?}", kind, id.candidates)
        })
    }

    fn show(case: &str, sql: &str, result: &QueryResult) {
        println!("\n--- {} ------------------------------------------", case);
        println!("  sql: {}", sql);
        let cols: Vec<String> = result
            .columns
            .iter()
            .map(|c| {
                format!(
                    "{}[oid={:?} attno={:?}]",
                    c.name, c.relation_oid, c.relation_attno
                )
            })
            .collect();
        println!("  columns: {}", cols.join(", "));
        match &result.row_identity {
            None => println!("  row_identity: None"),
            Some(id) => {
                println!("  table_key:     {}", id.table_key);
                println!("  table_display: {}", id.table_display);
                println!("  table_keys:    {:?}", id.table_keys);
                if id.candidates.is_empty() {
                    println!("  candidates:    [] (fingerprint tier)");
                }
                for c in &id.candidates {
                    println!(
                        "  candidate {:>6}: columns {:?} keys {:?}",
                        c.kind, c.key_columns, c.keys
                    );
                }
            }
        }
    }

    #[test]
    #[ignore = "needs a live PostgreSQL with scripts/tagtest-schema.sql loaded"]
    fn query_identity_comes_back_from_a_live_result() {
        // Remember whether the caller NAMED a database. A missing fixture may
        // skip on the default URL only. If the caller named one, they meant that
        // one, and reporting `ok` for a test that never ran is worse than a
        // failure: it looks like proof.
        let explicit = std::env::var("PHAROS_TEST_DATABASE_URL").ok();
        let url = explicit.clone().unwrap_or_else(|| DEFAULT_URL.to_string());
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");

        rt.block_on(async move {
            let pool = PgPoolOptions::new()
                // execute_query releases its connection before the catalogue
                // read, so one would do; two gives headroom if that changes.
                .max_connections(2)
                // Without this a dead host takes the 30s default to fail.
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| {
                    panic!("cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.", url, e)
                });

            // Skip, or panic if the caller named the database. Returns true when
            // the caller should give up.
            let bail = |reason: String| -> bool {
                if explicit.is_some() {
                    panic!(
                        "{}\nPHAROS_TEST_DATABASE_URL named this database, so this \
                         is a failure, not a skip.",
                        reason
                    );
                }
                eprintln!("SKIP: {}", reason);
                true
            };

            let relations = tagtest_relations(&pool).await;
            if relations.is_empty()
                && bail(format!(
                    "schema `tagtest` not found in {}. Load the fixture first: \
                     psql -d <db> -f scripts/tagtest-schema.sql",
                    url
                ))
            {
                return;
            }
            for needed in ["users", "memberships", "active_users"] {
                if !relations.iter().any(|r| r == needed)
                    && bail(format!(
                        "schema `tagtest` is present but relation `{}` is missing. \
                         Reload scripts/tagtest-schema.sql",
                        needed
                    ))
                {
                    return;
                }
            }

            // The real OIDs, so the assertions below can name the exact table
            // key the block must carry.
            let users_oid = relation_oid(&pool, "users").await;
            let memberships_oid = relation_oid(&pool, "memberships").await;

            // An in-memory metadata DB has no settings and no history tables.
            // Both reads are non-fatal by design: the timeout falls back to its
            // default and the history save logs a warning.
            let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
            state.add_pool(CONN.to_string(), pool.clone());

            let run = |sql: &'static str| {
                let state = &state;
                async move {
                    execute_query(
                        CONN.to_string(),
                        sql.to_string(),
                        None,
                        None,
                        None,
                        None,
                        state,
                    )
                    .await
                    .unwrap_or_else(|e| panic!("execute_query failed for `{}`: {}", sql, e))
                }
            };

            // --- 1. SELECT * — both a primary key and a natural key ----------
            let sql = "SELECT * FROM tagtest.users ORDER BY id";
            let r = run(sql).await;
            show("case 1: SELECT * FROM tagtest.users", sql, &r);
            let id = r.row_identity.as_ref().expect("case 1: expected an identity block");
            assert_eq!(id.table_display, "tagtest.users", "case 1 table_display");
            assert_eq!(id.candidates.len(), 2, "case 1 should have 2 candidates");
            let pk = keyset(id, "pk");
            assert_eq!(pk.key_columns, vec!["id"], "case 1 pk columns");
            assert_eq!(pk.keys, vec!["V1:1", "V1:2", "V1:3"], "case 1 pk keys");
            let uq = keyset(id, "unique");
            assert_eq!(uq.key_columns, vec!["email"], "case 1 unique columns");
            assert_eq!(uq.keys[0], "V6:a@b.co", "case 1 first unique key");

            // --- 2. The primary key is absent; the natural key carries on ----
            // This is the case the whole feature exists for.
            let sql = "SELECT name, email FROM tagtest.users ORDER BY email";
            let r = run(sql).await;
            show("case 2: no pk column, unique column present", sql, &r);
            let id = r.row_identity.as_ref().expect("case 2: expected an identity block");
            assert_eq!(id.candidates.len(), 1, "case 2 should have exactly 1 candidate");
            let uq = keyset(id, "unique");
            assert_eq!(uq.key_columns, vec!["email"], "case 2 unique columns");

            // --- 3. No key column at all: the fingerprint tier ---------------
            let sql = "SELECT name, status FROM tagtest.users";
            let r = run(sql).await;
            show("case 3: no key column at all", sql, &r);
            let id = r.row_identity.as_ref().expect("case 3: a block is still required");
            assert!(id.candidates.is_empty(), "case 3 must be the fingerprint tier");
            assert_eq!(id.table_display, "tagtest.users", "case 3 table_display");
            // Check the keys against the catalogue's OID, not against each other.
            // `table_keys.contains(&table_key)` cannot fail: one function builds
            // both from one OID list, so it would pass even if every OID were
            // wrong. A single-table result must report exactly ONE source table.
            assert_eq!(
                id.table_key,
                format!("oid:{}", users_oid),
                "case 3 table_key must name tagtest.users"
            );
            assert_eq!(
                id.table_keys,
                vec![format!("oid:{}", users_oid)],
                "case 3: one source table means exactly one entry"
            );

            // --- 4. An aggregate has no source table -------------------------
            let sql = "SELECT count(*) FROM tagtest.users";
            let r = run(sql).await;
            show("case 4: aggregate", sql, &r);
            assert!(r.row_identity.is_none(), "case 4 must have no identity block");

            // --- 5. Two source tables ----------------------------------------
            let sql = "SELECT u.name, m.role FROM tagtest.users u \
                       LEFT JOIN tagtest.memberships m ON m.user_id = u.id";
            let r = run(sql).await;
            show("case 5: two source tables", sql, &r);
            let id = r.row_identity.as_ref().expect("case 5: expected an identity block");
            assert_eq!(
                id.table_keys,
                vec![format!("oid:{}", users_oid), format!("oid:{}", memberships_oid)],
                "case 5: both source tables, in column order"
            );
            // Each table owns one column, so this is a tie, and the LEFTMOST
            // table must win. Asserting the count alone would pass whichever
            // table won, which is the one thing worth checking here.
            assert_eq!(
                id.table_display, "tagtest.users",
                "case 5: a tie on column count must go to the leftmost table"
            );

            // --- 6. The NULL sentinel ----------------------------------------
            // memberships owns 2 of the 3 columns, so it is the primary table.
            // Cal has no membership, so that row's key values are both NULL and
            // its key must be the empty "no identity" string.
            let sql = "SELECT m.user_id, m.team_id, u.name FROM tagtest.users u \
                       LEFT JOIN tagtest.memberships m ON m.user_id = u.id \
                       ORDER BY u.id, m.team_id";
            let r = run(sql).await;
            show("case 6: outer join NULL sentinel", sql, &r);
            let id = r.row_identity.as_ref().expect("case 6: expected an identity block");
            assert_eq!(id.table_display, "tagtest.memberships", "case 6 primary table");
            let pk = keyset(id, "pk");
            assert_eq!(pk.key_columns, vec!["user_id", "team_id"], "case 6 pk columns");
            assert!(
                pk.keys.iter().any(|k| k.is_empty()),
                "case 6: the unmatched row must have an EMPTY key; got {:?}",
                pk.keys
            );
            assert!(
                pk.keys.iter().any(|k| !k.is_empty()),
                "case 6: the matched rows must have real keys; got {:?}",
                pk.keys
            );

            // --- 7. A view: A DESIGN ASSUMPTION, MEASURED AND DISPROVEN ------
            //
            // The design assumed a view's columns report the BASE table's OID,
            // so a view result would carry users' key candidates. Measured
            // against PostgreSQL on 2026-08-11, that is FALSE: every column of
            // `tagtest.active_users` reports the VIEW's own OID and the view's
            // own attnums. A view has no pg_index rows, so the catalogue read
            // returns a display name and NO candidates.
            //
            // The consequence is a real product limit, not a bug here: a result
            // read through a view falls to the fingerprint tier, so a tag set on
            // a base-table result does not follow into a view result, and the
            // reverse. The block is still honest — it names the view and reports
            // no candidate rather than inventing one.
            //
            // This assertion therefore pins the OBSERVED behaviour. It is not a
            // workaround: if PostgreSQL or sqlx ever started reporting the base
            // table, this test would fail and the limit could be lifted.
            let sql = "SELECT id, email FROM tagtest.active_users ORDER BY id";
            let r = run(sql).await;
            show("case 7: a view over users", sql, &r);
            let id = r.row_identity.as_ref().expect("case 7: expected an identity block");
            assert_eq!(
                id.table_display, "tagtest.active_users",
                "case 7: PostgreSQL reports the view's own OID, so the block \
                 names the view. columns = {:?}",
                r.columns
            );
            assert!(
                id.candidates.is_empty(),
                "case 7: a view has no indexes, so no candidate is possible; got {:?}",
                id.candidates
            );

            // --- 8. A SELF-JOIN: A MEASURED LIMIT, NOT A DEFECT --------------
            //
            // Both aliases of `tagtest.users` report the SAME base table OID and
            // the SAME attnums. `m.id` therefore satisfies the primary key, and
            // every row's key is built from m.id, which the join pins to 1. So
            // all three rows share the key "V1:1".
            //
            // That is the same rule a one-to-many join follows, and it is the
            // designed behaviour: one tag record covers every row holding the
            // key, and the tagged count counts rows. Duplicate keys are NOT a
            // fault to reject. Rejecting them would demote every one-to-many
            // join to the fingerprint tier.
            let sql = "SELECT m.id, e.name FROM tagtest.users e \
                       JOIN tagtest.users m ON m.id = 1 ORDER BY e.id";
            let r = run(sql).await;
            show("case 8: self-join, single-column key", sql, &r);
            let id = r.row_identity.as_ref().expect("case 8: expected an identity block");
            let pk = keyset(id, "pk");
            assert!(
                pk.keys.iter().all(|k| k == "V1:1"),
                "case 8: every key comes from m.id, which the join pins to 1; got {:?}",
                pk.keys
            );
            assert!(pk.keys.len() > 1, "case 8 needs several rows to be meaningful");

            // --- 9. A SELF-JOIN THAT SPLITS A COMPOUND KEY -------------------
            //
            // THE KNOWN HAZARD OF THIS DESIGN. Read before changing anything.
            //
            // `a.user_id` and `b.team_id` come from two DIFFERENT rows of
            // memberships, but both columns report the base table's OID and
            // their own attnums, so `present_attnos` becomes [1, 2] and the
            // compound primary key looks complete. Each key below is therefore
            // composed from two different rows, and such a fabricated key can
            // coincide with a real row's key. A tag saved against it would later
            // attach to the wrong row.
            //
            // NO CODE CAN DETECT THIS. In the protocol's metadata
            // `SELECT a.user_id, b.team_id FROM memberships a, memberships b` is
            // byte-identical to `SELECT user_id, team_id FROM memberships`.
            // PostgreSQL gives no way to tell the aliases apart. A uniqueness
            // check does not help either: these keys are a cross product, so
            // they are all distinct. Sniffing the SQL text for a repeated table
            // name was considered and rejected: it uses a fragile signal to
            // silently demote legitimate queries.
            //
            // So this case PINS the limit rather than fixing it. The assertion
            // says a candidate IS produced, which is exactly what makes the
            // hazard real and visible.
            let sql = "SELECT a.user_id, b.team_id \
                       FROM tagtest.memberships a, tagtest.memberships b ORDER BY 1, 2";
            let r = run(sql).await;
            show("case 9: self-join splitting a compound key", sql, &r);
            let id = r.row_identity.as_ref().expect("case 9: expected an identity block");
            assert_eq!(
                id.table_display, "tagtest.memberships",
                "case 9: both aliases report the base table"
            );
            let pk = keyset(id, "pk");
            assert_eq!(
                pk.key_columns,
                vec!["user_id", "team_id"],
                "case 9: the compound key looks complete, though its halves come \
                 from different rows"
            );
            assert_eq!(
                pk.keys.len(),
                9,
                "case 9: a 3x3 cross join; these keys are fabricated pairs"
            );

            // --- 10. A later page keeps the same identity --------------------
            //
            // Measured 2026-08-11: fetch_more_rows wraps the SQL as
            // `SELECT * FROM (...) AS _pharos_paginated`, and PostgreSQL passes
            // the source table OIDs straight through a plain SELECT * subquery.
            // So a later page carries the SAME identity as page 1, and Load More
            // keeps tags with no extra work.
            //
            // Asserted, not merely printed, for the same reason case 7 is: it is
            // a property of the server that this feature depends on, so a change
            // in it must fail here rather than surface as tags vanishing on
            // page 2.
            let page = super::fetch_more_rows(
                CONN.to_string(),
                "SELECT * FROM tagtest.users ORDER BY id".to_string(),
                2,
                1,
                None,
                &state,
            )
            .await
            .expect("fetch_more_rows failed");
            show("case 10: fetch_more_rows, offset 1", "(wrapped in a subquery)", &page);
            let id = page.row_identity.as_ref().expect("case 10: expected an identity block");
            assert_eq!(
                id.table_key,
                format!("oid:{}", users_oid),
                "case 10: a later page must name the same table as page 1"
            );
            let pk = keyset(id, "pk");
            assert_eq!(pk.key_columns, vec!["id"], "case 10 pk columns");
            assert!(
                pk.keys.iter().all(|k| !k.is_empty()),
                "case 10: every row of a later page must have a real key; got {:?}",
                pk.keys
            );
            assert_eq!(pk.keys, vec!["V1:2", "V1:3"], "case 10: rows 2 and 3, in order");
        });
    }

    /// The cursor path reads ONE execution: every row, in that execution's
    /// order, cut at the cap with `has_more` set, and the connection is left
    /// usable afterwards (the transaction is closed on every path).
    #[test]
    #[ignore = "needs a live PostgreSQL (any database; uses generate_series only)"]
    fn snapshot_reads_one_execution_end_to_end() {
        let url = std::env::var("PHAROS_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_URL.to_string());
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let pool = PgPoolOptions::new()
                .max_connections(2)
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| panic!("cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.", url, e));
            let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
            state.add_pool(CONN.to_string(), pool.clone());

            // 12,000 rows: more than two FETCH chunks, with an ORDER BY so the
            // expected order is exact.
            let sql = "SELECT g AS n, md5(g::text) AS h FROM generate_series(1, 12000) g ORDER BY g";
            // Every call the snapshot makes on its progress callback, in order.
            let ticks: std::sync::Mutex<Vec<u64>> = std::sync::Mutex::new(Vec::new());
            let snap = |max_rows: i64, sql: &'static str| {
                let state = &state;
                let ticks = &ticks;
                async move {
                    fetch_all_rows_snapshot(
                        CONN.to_string(), sql.to_string(), format!("snap-{}", max_rows), max_rows, None, state,
                        |rows| ticks.lock().expect("ticks").push(rows),
                    )
                    .await
                }
            };
            let drain_ticks = || std::mem::take(&mut *ticks.lock().expect("ticks"));

            // Whole result under the cap.
            let all = snap(100_000, sql).await.expect("snapshot under cap");
            assert_eq!(all.rows.len(), 12_000, "every row of one execution");
            assert!(!all.has_more, "nothing beyond the cap");
            assert_eq!(all.row_count, 12_000);
            assert_eq!(all.columns.len(), 2);
            assert_eq!(all.rows[0][0], serde_json::json!("1"), "first row is the first of the ORDER BY");
            assert_eq!(all.rows[11_999][0], serde_json::json!("12000"), "last row is the last of the ORDER BY");
            assert!(all.history_entry_id.is_none(), "a snapshot is not a new history entry");

            // One progress call per 5,000-row chunk, each carrying the running
            // total: 12,000 rows is three chunks (5,000 · 10,000 · 12,000).
            assert_eq!(
                drain_ticks(),
                vec![5_000_u64, 10_000, 12_000],
                "progress reports a running total, once per chunk"
            );

            // Cap inside the result: exactly the cap, and has_more says so.
            let capped = snap(5_000, sql).await.expect("snapshot at cap");
            assert_eq!(capped.rows.len(), 5_000);
            assert!(capped.has_more, "the cap cut the snapshot short");
            assert_eq!(capped.rows[4_999][0], serde_json::json!("5000"));
            // The cap is applied before the report, so no tick is larger than it.
            let capped_ticks = drain_ticks();
            assert!(
                capped_ticks.iter().all(|&n| n <= 5_000),
                "no progress call may claim more rows than the cap keeps; got {:?}",
                capped_ticks
            );
            assert_eq!(capped_ticks.last().copied(), Some(5_000), "the last tick is the row count");

            // Cap exactly at the row count: full result, no has_more.
            let exact = snap(12_000, sql).await.expect("snapshot at exact count");
            assert_eq!(exact.rows.len(), 12_000);
            assert!(!exact.has_more, "a cap equal to the row count is not a cut");

            // Empty result keeps its column metadata.
            let empty = snap(100, "SELECT 1 AS one WHERE false").await.expect("empty snapshot");
            assert!(empty.rows.is_empty());
            assert_eq!(empty.columns.len(), 1, "columns come from describe when there are no rows");
            assert_eq!(empty.columns[0].name, "one");

            // A failing statement is an error, and the connection is not left
            // inside an aborted transaction: a normal query on the pool works.
            let err = snap(100, "SELECT * FROM no_such_table_pharos_snapshot").await;
            assert!(err.is_err(), "a bad statement errors");
            assert!(err.unwrap_err().contains("no_such_table_pharos_snapshot"));
            let after = execute_query(CONN.to_string(), "SELECT 41 + 1 AS x".to_string(), None, None, None, None, &state)
                .await
                .expect("the pool is usable after a failed snapshot");
            assert_eq!(after.rows[0][0], serde_json::json!("42"));

            // Nothing left registered.
            for id in ["snap-100000", "snap-5000", "snap-12000", "snap-100"] {
                assert!(state.get_query_backend_pid(id).is_none(), "{} unregistered", id);
            }
        });
    }
}

/// Live test of the EXPLAIN wiring.
///
///   cargo test --release explain -- --ignored --nocapture
///
/// `explain_statement` is pure and fully covered offline, but nothing offline
/// can say whether PostgreSQL accepts the option list this crate builds, or
/// whether the `json` column it answers with can be read back as text. Only a
/// real connection settles either.
#[cfg(test)]
mod live_explain_tests {
    use super::explain_query;
    use crate::state::AppState;
    use rusqlite::Connection as SqliteConnection;
    use sqlx::postgres::PgPoolOptions;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn?sslmode=disable";
    const CONN: &str = "live-explain-test";

    #[test]
    #[ignore = "needs a live PostgreSQL (any database; explains `select 1`)"]
    fn explain_returns_a_json_plan_from_a_live_server() {
        let url = std::env::var("PHAROS_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_URL.to_string());
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let pool = PgPoolOptions::new()
                .max_connections(2)
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| panic!("cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.", url, e));
            let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
            state.add_pool(CONN.to_string(), pool.clone());

            // Plain EXPLAIN: a JSON array, with costs and no actuals.
            let plan = explain_query(CONN.to_string(), "select 1".to_string(), false, &state)
                .await
                .expect("plain explain");
            println!("plain plan: {}", plan);
            assert!(plan.trim_start().starts_with('['), "FORMAT JSON answers an array; got {}", plan);
            assert!(plan.contains("\"Node Type\""), "the plan names its node type");
            assert!(!plan.contains("\"Actual Total Time\""), "no ANALYZE means no actuals");

            // EXPLAIN ANALYZE: the same shape, with actuals and an execution time.
            let analyzed = explain_query(CONN.to_string(), "select 1;".to_string(), true, &state)
                .await
                .expect("explain analyze");
            assert!(analyzed.trim_start().starts_with('['));
            assert!(analyzed.contains("\"Actual Total Time\""), "ANALYZE reports actuals");
            assert!(analyzed.contains("\"Execution Time\""), "ANALYZE reports an execution time");

            // The ANALYZE ran inside a transaction that was rolled back, so a
            // write it performed left nothing behind. This is the claim the
            // rollback exists to make, so measure it rather than assume it.
            let table = "pharos_explain_rollback_probe";
            sqlx::raw_sql(&format!("DROP TABLE IF EXISTS {}", table))
                .execute(&pool).await.expect("drop probe table");
            sqlx::raw_sql(&format!("CREATE TABLE {} (n int)", table))
                .execute(&pool).await.expect("create probe table");
            let _ = explain_query(
                CONN.to_string(),
                format!("insert into {} values (1)", table),
                true,
                &state,
            )
            .await
            .expect("explain analyze of an insert");
            let after = sqlx::raw_sql(&format!("SELECT count(*)::text AS c FROM {}", table))
                .fetch_all(&pool).await.expect("count after rollback");
            let count: String = {
                use sqlx::Row;
                after[0].try_get("c").expect("count decode")
            };
            assert_eq!(count, "0", "EXPLAIN ANALYZE of an INSERT must be rolled back");
            sqlx::raw_sql(&format!("DROP TABLE {}", table))
                .execute(&pool).await.expect("drop probe table");

            // A connection that carried a failed ANALYZE is still usable: the
            // ROLLBACK runs on the failure path too.
            let err = explain_query(
                CONN.to_string(),
                "select * from no_such_table_pharos_explain".to_string(),
                true,
                &state,
            )
            .await;
            assert!(err.is_err(), "a bad statement errors");
            let again = explain_query(CONN.to_string(), "select 1".to_string(), true, &state)
                .await
                .expect("the pool is usable after a failed explain");
            assert!(again.trim_start().starts_with('['));

            // The refusal never reaches the server.
            assert_eq!(
                explain_query(CONN.to_string(), "select 1; select 2".to_string(), false, &state)
                    .await
                    .unwrap_err(),
                "Explain one statement at a time"
            );
        });
    }
}

/// `search_path_sql`: the quoting, the suffix, and the validation it must not
/// weaken (plan §2.8).
#[cfg(test)]
mod search_path_sql_tests {
    use super::search_path_sql;

    /// The default suffix reproduces what `set_search_path` has always sent,
    /// with the elements quoted. `"public"` and a bare `public` select the
    /// same schema, so this is the same statement in a stricter spelling.
    #[test]
    fn the_default_suffix_is_todays_statement() {
        assert_eq!(
            search_path_sql("analytics", "public").unwrap(),
            r#"SET search_path TO "analytics", "public""#
        );
    }

    /// An empty suffix means the schema alone — no `public` behind it, which
    /// is the whole reason the setting exists.
    #[test]
    fn an_empty_suffix_adds_nothing() {
        assert_eq!(
            search_path_sql("analytics", "").unwrap(),
            r#"SET search_path TO "analytics""#
        );
        assert_eq!(
            search_path_sql("analytics", "   ").unwrap(),
            r#"SET search_path TO "analytics""#,
            "spaces are not an element"
        );
        assert_eq!(
            search_path_sql("analytics", ",,").unwrap(),
            r#"SET search_path TO "analytics""#,
            "empty elements are dropped"
        );
    }

    #[test]
    fn a_multi_element_suffix_keeps_its_order() {
        assert_eq!(
            search_path_sql("app", "public, extensions,  pg_catalog").unwrap(),
            r#"SET search_path TO "app", "public", "extensions", "pg_catalog""#
        );
    }

    /// A double quote inside a name is doubled, in the schema and in every
    /// suffix element. Without this a crafted name could close the identifier
    /// and start a statement.
    #[test]
    fn a_double_quote_is_doubled_everywhere() {
        assert_eq!(
            search_path_sql(r#"we"ird"#, r#"pu"blic"#).unwrap(),
            r#"SET search_path TO "we""ird", "pu""blic""#
        );
    }

    /// `$user` is quoted, which is how PostgreSQL itself writes it.
    #[test]
    fn the_user_placeholder_is_quoted_the_way_postgres_writes_it() {
        assert_eq!(
            search_path_sql("app", "$user, public").unwrap(),
            r#"SET search_path TO "app", "$user", "public""#
        );
    }

    /// Today's validation, unchanged: 1–63 characters and no NUL. These are
    /// the assertions that would catch a refactor loosening the check.
    #[test]
    fn an_over_long_or_empty_schema_is_refused() {
        assert!(search_path_sql("", "public").is_err(), "empty");
        assert!(search_path_sql(&"a".repeat(63), "public").is_ok(), "63 is allowed");
        assert!(search_path_sql(&"a".repeat(64), "public").is_err(), "64 is refused");
    }

    #[test]
    fn a_null_byte_is_refused() {
        assert!(search_path_sql("we\0ird", "public").is_err(), "in the schema");
        assert!(search_path_sql("app", "pub\0lic").is_err(), "in the suffix too");
    }

    /// The suffix is held to the same rules as the schema, so a setting
    /// nobody validated cannot smuggle a name past the schema's check.
    #[test]
    fn an_over_long_suffix_element_is_refused() {
        assert!(search_path_sql("app", &"a".repeat(64)).is_err());
    }
}

/// The SQLSTATE tag a read-only refusal carries to the front end.
#[cfg(test)]
mod read_only_tag_tests {
    use super::{tagged_db_message, READ_ONLY_MARKER};

    /// 25006 is tagged, so Swift can say "This connection is read-only."
    /// without matching on a server message it cannot rely on.
    #[test]
    fn a_read_only_refusal_is_tagged() {
        let tagged = tagged_db_message(
            Some("25006"),
            "cannot execute INSERT in a read-only transaction",
        );
        assert!(tagged.starts_with(READ_ONLY_MARKER), "got {tagged}");
        assert!(
            tagged.contains("cannot execute INSERT in a read-only transaction"),
            "the server's own words must survive: {tagged}"
        );
    }

    /// Every other error is passed through unchanged. This is the assertion
    /// that keeps the change invisible to the error banner, the error sheet
    /// and the "at character N" location parser.
    #[test]
    fn every_other_error_is_unchanged() {
        for code in [None, Some("42601"), Some("23505"), Some("25P02")] {
            assert_eq!(
                tagged_db_message(code, "syntax error at or near \"slect\" at character 1"),
                "syntax error at or near \"slect\" at character 1",
                "code {code:?} must not be tagged"
            );
        }
    }
}
