//! One PostgreSQL connection per editor tab: the "tab session".
//!
//! Every query card of a tab runs on its tab's connection, one at a time and
//! in the order the cards were run, so session state carries from card to
//! card the way it does in psql: a `SET`, a temp table, a `BEGIN` … `COMMIT`
//! spread over several cards.
//!
//! The connection is opened at the tab's first run, outside the shared pool
//! (it never takes a pool connection and never waits for one), with the
//! pool's own connect options plus a longer `idle_in_transaction_session_
//! timeout` (Settings ▸ Connections ▸ query cards). It is closed when the tab
//! closes, when the connection is disconnected or deleted, when its SSH tunnel
//! stops, and at shutdown — always with a rollback, never a commit.
//!
//! What Pharos does NOT do on a tab session, unlike the pool:
//! - no rollback of a transaction a card leaves open (`finish_user_sql`);
//! - no `SET statement_timeout` / `RESET` around each run: the query timeout
//!   is kept by the client, so a user's own `SET statement_timeout` card
//!   stays in force;
//! - `search_path` is sent only when the toolbar's schema changes, so a
//!   user's own `SET search_path` card stays in force until then;
//! - a result cut at the row limit, or a cancel, never closes the connection:
//!   rows are read through a cursor (`FETCH limit + 1`), and a cancel waits for
//!   the statement to end and keeps the session.
//!
//! Inside an open transaction each card runs inside `SAVEPOINT _pharos_card`:
//! a cancel or a timeout undoes only that card and the transaction stays
//! open. An SQL error leaves the transaction failed, as psql does. Pharos's
//! own work for a card (Load More, Load All, Explain, a cell edit, a
//! column describe) runs inside `SAVEPOINT _pharos_aux` in a transaction, so
//! it never ends or breaks the user's transaction, and is refused while the
//! transaction is failed.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

use futures::StreamExt;
use serde::{Deserialize, Serialize};
use sqlx::postgres::PgRow;
use sqlx::{Connection, Executor, PgConnection, Row};

use super::query::{
    build_row_identity, cancel_backend, cancel_until_ended, explain_statement, format_db_error, history_entry,
    pg_columns_to_defs, query_timeout_seconds, record_history, result_cache, rows_to_json, search_path_suffix,
    set_search_path, ExecuteResult, QueryResult, CANCEL_CONFIRM_WAIT, QUERY_CANCELLED,
};
use super::row_edit::{build_update_statement, history_sql, validate_request, RowUpdateRequest, RowUpdateResult};
use super::sql_lexer::{is_blank_or_comment, split_chunks, ChunkKind};
use crate::db::sqlite;
use crate::models::QueryHistoryEntry;
use crate::state::{AppState, QueryCancel};

// MARK: - Reports

/// Whether the tab's connection is in a transaction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TxnState {
    Idle,
    InTransaction,
    /// An error aborted the open transaction: only ROLLBACK works now.
    Failed,
    /// The connection is gone or did not answer.
    Unknown,
}

/// Why the tab's connection was replaced. Settings, temp tables and any open
/// transaction of the old connection are gone; Swift says so.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionReset {
    pub reason: String,
    pub at: String,
}

/// The tab session as Swift shows it: the transaction banner, the reset
/// notice, the waiting cards.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionReport {
    pub session_id: String,
    pub connection_id: String,
    pub open: bool,
    /// +1 each time the connection is (re)opened.
    pub generation: u64,
    pub backend_pid: i32,
    pub txn: TxnState,
    /// Seconds the open transaction has been open, when there is one.
    pub txn_elapsed_seconds: Option<f64>,
    /// The server's idle-in-transaction limit on this connection; 0 = none.
    pub idle_in_transaction_timeout_seconds: u32,
    pub read_only: bool,
    /// Operations queued behind the one running.
    pub waiting: usize,
    /// Set when this operation found the connection replaced.
    pub reset: Option<SessionReset>,
}

// MARK: - The session

/// One editor tab's connection, and the queue in front of it.
pub struct TabSession {
    pub id: String,
    pub connection_id: String,
    /// Fair (FIFO): operations run in the order they were asked for.
    conn: tokio::sync::Mutex<Option<LiveSession>>,
    report: StdMutex<SessionReport>,
    waiting: AtomicUsize,
    closing: AtomicBool,
}

struct LiveSession {
    conn: PgConnection,
    backend_pid: i32,
    /// The schema the toolbar last set; None until it sets one.
    pulldown_schema: Option<String>,
    txn: TxnState,
    last_used: Instant,
    /// Card savepoints made in the open transaction. Past
    /// `MAX_CARD_SAVEPOINTS` cards run without one: more than 64
    /// subtransactions that write overflow PostgreSQL's per-backend cache and
    /// slow snapshots for every session on the server.
    card_savepoints: u32,
}

const MAX_CARD_SAVEPOINTS: u32 = 48;

impl TabSession {
    fn new(id: &str, connection_id: &str, idle_seconds: u32) -> TabSession {
        TabSession {
            id: id.to_string(),
            connection_id: connection_id.to_string(),
            conn: tokio::sync::Mutex::new(None),
            report: StdMutex::new(SessionReport {
                session_id: id.to_string(),
                connection_id: connection_id.to_string(),
                open: false,
                generation: 0,
                backend_pid: 0,
                txn: TxnState::Idle,
                txn_elapsed_seconds: None,
                idle_in_transaction_timeout_seconds: idle_seconds,
                read_only: false,
                waiting: 0,
                reset: None,
            }),
            waiting: AtomicUsize::new(0),
            closing: AtomicBool::new(false),
        }
    }

    /// The last report, with the live queue length.
    pub fn report(&self) -> SessionReport {
        let mut r = self.report.lock().unwrap_or_else(|e| e.into_inner()).clone();
        r.waiting = self.waiting.load(Ordering::Relaxed);
        r
    }
}

// MARK: - Requests

/// Which tab session an operation runs on.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTarget {
    pub session_id: String,
    pub connection_id: String,
    #[serde(default)]
    pub schema: Option<String>,
    #[serde(default)]
    pub query_id: Option<String>,
}

/// A card's run (`session_execute_query` / `session_execute_statement`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRunRequest {
    #[serde(flatten)]
    pub target: SessionTarget,
    pub sql: String,
    #[serde(default)]
    pub limit: Option<u32>,
    #[serde(default)]
    pub source: Option<String>,
    /// Pharos's own work for a card (a chart aggregation, the re-read after a
    /// cell edit): runs in `_pharos_aux`, never as the user's statement.
    #[serde(default)]
    pub aux: bool,
}

/// A query result from a tab session: the result, and the session after it.
#[derive(Debug, Clone, Serialize)]
pub struct SessionQueryResult {
    #[serde(flatten)]
    pub result: QueryResult,
    pub session: SessionReport,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionExecuteResult {
    #[serde(flatten)]
    pub result: ExecuteResult,
    pub session: SessionReport,
}

// MARK: - Registry and lifecycle

/// The session for an editor tab, made when it has none. A tab that moved to
/// another connection gets its old session closed and a new one.
async fn session_for(state: &AppState, session_id: &str, connection_id: &str) -> Result<Arc<TabSession>, String> {
    let existing = state.tab_session(session_id);
    if let Some(s) = existing {
        if s.connection_id == connection_id {
            return Ok(s);
        }
        close_tab_session(state, session_id).await;
    }
    // Opening does not wait on the pool, but it does need one: the pool's
    // options are this connection's options.
    state.require_pool(connection_id)?;
    let settings = state.settings();
    let cap = settings.connections.max_tab_sessions_per_connection as usize;
    if cap > 0 && state.tab_session_count(connection_id) >= cap {
        return Err(format!(
            "{} This server already has {} editor-tab connections open (Settings ▸ Connections). \
             Close a tab, or raise the limit.",
            SESSION_LIMIT_MARKER, cap
        ));
    }
    let session = Arc::new(TabSession::new(session_id, connection_id, settings.connections.tab_idle_in_transaction_seconds));
    state.insert_tab_session(session.clone());
    Ok(session)
}

/// The marker on the refusal when a server has its share of tab connections.
pub const SESSION_LIMIT_MARKER: &str = "[PHAROS_SESSION_LIMIT]";
/// The marker on the refusal when the server cannot hold a tab session (a
/// PostgreSQL-compatible server without the functions it needs). Swift runs
/// the tab's cards on the pool then.
pub const SESSION_UNAVAILABLE_MARKER: &str = "[PHAROS_SESSION_UNAVAILABLE]";

/// Open the tab's own connection with the pool's options.
async fn connect(state: &AppState, connection_id: &str) -> Result<(PgConnection, i32), String> {
    let pool = state.require_pool(connection_id)?;
    let settings = state.settings();
    let idle_ms = settings.connections.tab_idle_in_transaction_seconds.saturating_mul(1000);
    // The pool's own options: host or tunnel port, the SSL mode that actually
    // connected, the startup GUCs. The tab's idle-in-transaction limit is
    // appended after the pool's; PostgreSQL applies `-c` options in order.
    let options = pool
        .connect_options()
        .as_ref()
        .clone()
        .options([("idle_in_transaction_session_timeout", idle_ms.to_string())]);
    let budget = Duration::from_secs(settings.connections.connect_timeout_seconds.max(1) as u64);
    let mut conn = tokio::time::timeout(budget, PgConnection::connect_with(&options))
        .await
        .map_err(|_| "Timed out opening the tab's connection".to_string())?
        .map_err(|e| connect_failure(&e))?;
    // TimeZone and DateStyle: the pool sets them on each of ITS connections
    // after connecting (sqlx claims both in the startup packet).
    for sql in crate::db::postgres::session_setup_sql(&state.session_options(connection_id)) {
        if let Err(e) = (&mut conn).execute(sqlx::raw_sql(&sql)).await {
            let _ = conn.close().await;
            return Err(format_db_error(&e));
        }
    }
    let probe = (&mut conn)
        .fetch_one(sqlx::raw_sql("SELECT pg_backend_pid(), statement_timestamp() = transaction_timestamp()"))
        .await;
    match probe {
        Ok(row) => {
            let pid: i32 = row.try_get(0).unwrap_or(0);
            Ok((conn, pid))
        }
        Err(e) => {
            let _ = conn.close().await;
            Err(format!("{} {}", SESSION_UNAVAILABLE_MARKER, format_db_error(&e)))
        }
    }
}

fn connect_failure(e: &sqlx::Error) -> String {
    if let Some(db) = e.as_database_error() {
        if db.code().as_deref() == Some("53300") {
            return "The server has no free connections for this tab.".to_string();
        }
    }
    format_db_error(e)
}

/// Close a tab's session: queued operations are dropped, a running one is
/// cancelled, an open transaction is rolled back (never committed).
pub async fn close_tab_session(state: &AppState, session_id: &str) -> Option<CloseOutcome> {
    let session = state.remove_tab_session(session_id)?;
    session.closing.store(true, Ordering::Relaxed);
    let guard = tokio::time::timeout(Duration::from_secs(2), session.conn.lock()).await;
    let Ok(mut guard) = guard else {
        // The running operation closes the connection when it sees `closing`.
        return Some(CloseOutcome { closed: false, had_open_transaction: false, rolled_back: false });
    };
    let Some(mut live) = guard.take() else {
        return Some(CloseOutcome { closed: true, had_open_transaction: false, rolled_back: false });
    };
    let had = live.txn == TxnState::InTransaction || live.txn == TxnState::Failed;
    let mut rolled_back = false;
    if had {
        rolled_back = (&mut live.conn).execute(sqlx::raw_sql("ROLLBACK")).await.is_ok();
    }
    let _ = live.conn.close().await;
    Some(CloseOutcome { closed: true, had_open_transaction: had, rolled_back })
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CloseOutcome {
    pub closed: bool,
    pub had_open_transaction: bool,
    pub rolled_back: bool,
}

/// Close every session of a connection: before its pool and its tunnel go.
pub async fn close_sessions_for_connection(state: &AppState, connection_id: &str) {
    for id in state.tab_session_ids(connection_id) {
        close_tab_session(state, &id).await;
    }
}

// MARK: - The operation frame

/// Wait for the session (FIFO behind the running operation), or for the
/// cancel, whichever comes first.
async fn lock_or_cancel<'a>(
    session: &'a TabSession,
    cancel: &QueryCancel,
) -> Result<tokio::sync::MutexGuard<'a, Option<LiveSession>>, String> {
    session.waiting.fetch_add(1, Ordering::Relaxed);
    let result = tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(QUERY_CANCELLED.to_string()),
        guard = session.conn.lock() => Ok(guard),
    };
    session.waiting.fetch_sub(1, Ordering::Relaxed);
    result
}

/// Make sure the session has a live connection: open it at the first
/// operation, and replace a dead one — after 2 s idle a quick ping finds a
/// half-open socket (sleep, a NAT, a tunnel restart) before any SQL is sent.
/// Returns the reset to report when the connection was replaced.
async fn ensure_live(
    guard: &mut Option<LiveSession>,
    session: &TabSession,
    state: &AppState,
) -> Result<Option<SessionReset>, String> {
    let mut reason: Option<String> = None;
    if let Some(live) = guard.as_mut() {
        if live.last_used.elapsed() >= Duration::from_secs(2) {
            match tokio::time::timeout(Duration::from_secs(5), live.conn.ping()).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => reason = Some(lost_reason(&e)),
                Err(_) => reason = Some("The connection did not answer".to_string()),
            }
        }
        if reason.is_some() {
            *guard = None;
        }
    }
    if guard.is_none() {
        let had_one = session.report.lock().unwrap_or_else(|e| e.into_inner()).generation > 0;
        let (conn, pid) = connect(state, &session.connection_id).await?;
        let read_only = state.get_config(&session.connection_id).map(|c| c.read_only).unwrap_or(false);
        *guard = Some(LiveSession {
            conn,
            backend_pid: pid,
            pulldown_schema: None,
            txn: TxnState::Idle,
            last_used: Instant::now(),
            card_savepoints: 0,
        });
        let mut r = session.report.lock().unwrap_or_else(|e| e.into_inner());
        r.generation += 1;
        r.open = true;
        r.backend_pid = pid;
        r.txn = TxnState::Idle;
        r.txn_elapsed_seconds = None;
        r.read_only = read_only;
        if had_one {
            return Ok(Some(SessionReset {
                reason: reason.unwrap_or_else(|| "The connection was lost".to_string()),
                at: chrono::Utc::now().to_rfc3339(),
            }));
        }
    }
    Ok(None)
}

/// Why a connection is gone, in the user's words.
fn lost_reason(e: &sqlx::Error) -> String {
    if let Some(db) = e.as_database_error() {
        match db.code().as_deref() {
            Some("25P03") => return "The server ended the session: a transaction was idle too long".to_string(),
            Some("57P05") => return "The server ended the idle session".to_string(),
            Some("57P01") | Some("57P02") | Some("57P03") => return format!("The server ended the session: {}", db.message()),
            _ => {}
        }
    }
    format!("The connection was lost: {}", e)
}

/// True when an error means the connection itself is gone.
pub(crate) fn is_fatal(e: &sqlx::Error) -> bool {
    match e {
        sqlx::Error::Io(_) | sqlx::Error::Tls(_) | sqlx::Error::Protocol(_) | sqlx::Error::WorkerCrashed
        | sqlx::Error::PoolClosed => true,
        sqlx::Error::Database(db) => matches!(
            db.code().as_deref(),
            Some(c) if c.starts_with("08") || ["57P01", "57P02", "57P03", "57P05", "25P03"].contains(&c)
        ),
        _ => false,
    }
}

/// Send the toolbar's schema when it is not what this connection last got.
async fn apply_schema(live: &mut LiveSession, schema: Option<&str>, state: &AppState) {
    let Some(schema) = schema else { return };
    if live.pulldown_schema.as_deref() == Some(schema) || live.txn == TxnState::Failed {
        return;
    }
    if set_search_path(&mut live.conn, schema, &search_path_suffix(state)).await.is_ok() {
        live.pulldown_schema = Some(schema.to_string());
    }
}

/// Read the transaction state after an operation and put it in the report.
/// On a read-only connection, turn read-only back on if a card turned it off,
/// and roll back a read-write transaction (returns why, to fail the card).
async fn finish(guard: &mut Option<LiveSession>, session: &TabSession, state: &AppState, reset: Option<SessionReset>) -> (SessionReport, Option<String>) {
    let mut refusal = None;
    if let Some(live) = guard.as_mut() {
        live.last_used = Instant::now();
        let probe = (&mut live.conn)
            .fetch_one(sqlx::raw_sql(
                "SELECT statement_timestamp() = transaction_timestamp(), \
                 EXTRACT(EPOCH FROM clock_timestamp() - transaction_timestamp())::float8, \
                 current_setting('default_transaction_read_only'), current_setting('transaction_read_only')",
            ))
            .await;
        let read_only = state.get_config(&session.connection_id).map(|c| c.read_only).unwrap_or(false);
        let mut elapsed = None;
        live.txn = match probe {
            Ok(row) => {
                let idle: bool = row.try_get(0).unwrap_or(true);
                if !idle {
                    elapsed = row.try_get::<f64, _>(1).ok();
                }
                if read_only {
                    let default_ro: String = row.try_get(2).unwrap_or_default();
                    let txn_ro: String = row.try_get(3).unwrap_or_default();
                    if !idle && txn_ro == "off" {
                        let _ = (&mut live.conn).execute(sqlx::raw_sql("ROLLBACK")).await;
                        refusal = Some(format!("{} This connection is read-only. Pharos rolled back the read-write transaction.",
                                               super::query::READ_ONLY_MARKER));
                    }
                    if default_ro == "off" {
                        let _ = (&mut live.conn).execute(sqlx::raw_sql("SET default_transaction_read_only = on")).await;
                        refusal.get_or_insert(format!("{} This connection is read-only. Pharos turned read-only back on.",
                                                      super::query::READ_ONLY_MARKER));
                    }
                }
                if refusal.is_some() || idle { TxnState::Idle } else { TxnState::InTransaction }
            }
            Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("25P02") => TxnState::Failed,
            Err(e) if is_fatal(&e) => TxnState::Unknown,
            Err(_) => TxnState::Unknown,
        };
        if live.txn == TxnState::Idle {
            live.card_savepoints = 0;
        }
        let mut r = session.report.lock().unwrap_or_else(|e| e.into_inner());
        r.txn = live.txn;
        r.txn_elapsed_seconds = elapsed;
        r.backend_pid = live.backend_pid;
        r.open = true;
        r.read_only = read_only;
        r.reset = reset.clone();
    }
    if guard.as_ref().map(|l| l.txn == TxnState::Unknown).unwrap_or(false) {
        // The connection did not answer the probe: the next operation opens
        // a new one and reports the reset.
        *guard = None;
    }
    if guard.is_none() {
        let mut r = session.report.lock().unwrap_or_else(|e| e.into_inner());
        r.open = false;
        r.txn = TxnState::Unknown;
        r.txn_elapsed_seconds = None;
        r.reset = reset.clone();
    }
    if session.closing.load(Ordering::Relaxed) {
        if let Some(mut live) = guard.take() {
            let _ = (&mut live.conn).execute(sqlx::raw_sql("ROLLBACK")).await;
            let _ = live.conn.close().await;
        }
    }
    (session.report(), refusal)
}

// MARK: - Statement shape

/// What kind of statement a card holds, for how it is run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Shape {
    /// One statement that can be a cursor: SELECT, WITH, VALUES, TABLE.
    cursorable: bool,
    /// BEGIN, COMMIT, ROLLBACK, SAVEPOINT …: never wrapped in a savepoint.
    transaction_control: bool,
    /// More than one statement.
    multiple: bool,
}

fn shape(sql: &str) -> Shape {
    let chunks: Vec<_> = split_chunks(sql).into_iter().filter(|c| !c.body.is_empty()).collect();
    let first = chunks.first().map(|c| c.body(sql)).unwrap_or("");
    let word = first_word(first);
    Shape {
        cursorable: matches!(word.as_str(), "select" | "with" | "values" | "table") || first.starts_with('('),
        transaction_control: matches!(
            word.as_str(),
            "begin" | "start" | "commit" | "end" | "rollback" | "abort" | "savepoint" | "release" | "prepare"
        ),
        multiple: chunks.len() > 1,
    }
}

fn first_word(sql: &str) -> String {
    sql.trim_start().chars().take_while(|c| c.is_ascii_alphabetic()).collect::<String>().to_ascii_lowercase()
}

/// Statements that would break or desynchronise the connection, refused
/// before they are sent: psql meta-commands, COPY to or from the client.
fn refusal_before_send(sql: &str) -> Option<String> {
    if sql.trim().is_empty() || is_blank_or_comment(sql) {
        return Some("The card holds no statement.".to_string());
    }
    for chunk in split_chunks(sql) {
        match chunk.kind {
            ChunkKind::PsqlMeta => return Some("psql meta-commands (\\…) only run in psql.".to_string()),
            ChunkKind::CopyData => return Some("COPY … FROM STDIN needs psql; Pharos cannot send its data.".to_string()),
            ChunkKind::Statement => {
                let words: Vec<String> = chunk.body(sql).split_whitespace().map(|w| w.to_ascii_lowercase()).collect();
                if words.first().map(String::as_str) == Some("copy") && words.iter().any(|w| w.starts_with("stdout")) {
                    return Some("COPY … TO STDOUT needs psql. Use Export instead.".to_string());
                }
            }
        }
    }
    None
}

/// On a read-only connection: the obvious ways a card would turn writes on.
fn read_only_bypass(sql: &str) -> bool {
    let flat = sql.split_whitespace().collect::<Vec<_>>().join(" ").to_ascii_lowercase();
    let starts = |w: &str| flat.starts_with(w);
    // SET / RESET / set_config() / ALTER … SET of either read-only setting.
    let writes_setting = flat.contains("transaction_read_only")
        && (starts("set ") || starts("reset ") || flat.contains("set_config") || starts("alter "));
    // BEGIN READ WRITE, START TRANSACTION READ WRITE, SET [SESSION
    // CHARACTERISTICS AS] TRANSACTION READ WRITE.
    let read_write = flat.contains("read write") && (starts("begin") || starts("start ") || starts("set "));
    writes_setting || read_write
}

// MARK: - Reading rows

/// How reading stopped early.
enum Stop {
    Cancelled,
    TimedOut,
}

/// What a read produced.
enum ReadError {
    Stopped(Stop),
    Sql(String),
    Lost(String),
}

fn deadline(state: &AppState) -> Option<tokio::time::Instant> {
    let seconds = query_timeout_seconds(state);
    (seconds > 0).then(|| tokio::time::Instant::now() + Duration::from_secs(seconds as u64))
}

async fn stop_signal(cancel: &QueryCancel, until: Option<tokio::time::Instant>) -> Stop {
    match until {
        Some(at) => tokio::select! {
            _ = cancel.cancelled() => Stop::Cancelled,
            _ = tokio::time::sleep_until(at) => Stop::TimedOut,
        },
        None => {
            cancel.cancelled().await;
            Stop::Cancelled
        }
    }
}

/// Run `sql` raw and read every row, keeping the first `keep`. Reading to the
/// end keeps the connection usable without a cancel.
async fn read_all(conn: &mut PgConnection, sql: &str, keep: usize, cancel: &QueryCancel,
                  until: Option<tokio::time::Instant>, shift: usize) -> Result<(Vec<PgRow>, usize), ReadError> {
    let mut stream = sqlx::raw_sql(sql).fetch(&mut *conn);
    let mut rows = Vec::new();
    let mut total = 0usize;
    let stop = stop_signal(cancel, until);
    tokio::pin!(stop);
    loop {
        let next = tokio::select! {
            biased;
            why = &mut stop => return Err(ReadError::Stopped(why)),
            next = stream.next() => next,
        };
        match next {
            None => break,
            Some(Ok(row)) => {
                total += 1;
                if rows.len() < keep {
                    rows.push(row);
                }
            }
            Some(Err(e)) if is_fatal(&e) => return Err(ReadError::Lost(lost_reason(&e))),
            Some(Err(e)) => return Err(ReadError::Sql(shifted_error(&e, shift))),
        }
    }
    Ok((rows, total))
}

/// Execute a statement Pharos wrote (no rows wanted).
async fn exec(conn: &mut PgConnection, sql: &str) -> Result<(), String> {
    conn.execute(sqlx::raw_sql(sql)).await.map(|_| ()).map_err(|e| format_db_error(&e))
}

/// `format_db_error`, with an "at character N" moved back by the length of
/// a prefix Pharos put in front of the user's SQL (a `DECLARE … FOR`).
fn shifted_error(e: &sqlx::Error, shift: usize) -> String {
    let message = format_db_error(e);
    if shift == 0 {
        return message;
    }
    let marker = " at character ";
    match message.rfind(marker) {
        Some(i) => {
            let (head, tail) = message.split_at(i + marker.len());
            match tail.trim().parse::<usize>() {
                Ok(n) if n > shift => format!("{}{}", head, n - shift),
                _ => message,
            }
        }
        None => message,
    }
}

/// Stop the statement on the server and wait until it has ended, keeping the
/// connection. False when it would not stop: the caller drops the connection.
async fn stop_statement(conn: &mut PgConnection, state: &AppState, connection_id: &str, backend_pid: i32) -> bool {
    let Ok(pool) = state.require_pool(connection_id) else { return false };
    let send_cancel = || {
        let pool = pool.clone();
        async move {
            if let Err(e) = cancel_backend(&pool, backend_pid).await {
                log::warn!("Could not cancel a statement on tab backend {}: {}", backend_pid, e);
            }
        }
    };
    cancel_until_ended(conn, CANCEL_CONFIRM_WAIT, send_cancel).await
}

const CURSOR_PREFIX: &str = "DECLARE _pharos_c NO SCROLL CURSOR FOR ";

/// Read a card's SELECT through a cursor: the first `limit + 1` rows, without
/// running the rest of the result and without closing the connection.
/// `in_transaction`: the user's transaction is open (the caller holds the
/// card savepoint); otherwise Pharos's own BEGIN … COMMIT holds the cursor.
///
/// A cancel or a timeout is handled here: the statement is stopped on the
/// server FIRST, then Pharos's own transaction is rolled back. A ROLLBACK sent
/// first would wait behind the running FETCH.
#[allow(clippy::too_many_arguments)]
async fn read_through_cursor(live: &mut LiveSession, sql: &str, limit: u32, in_transaction: bool,
                             cancel: &QueryCancel, until: Option<tokio::time::Instant>,
                             state: &AppState, connection_id: &str)
                             -> Result<Option<(Vec<PgRow>, usize)>, ReadError> {
    if !in_transaction {
        exec(&mut live.conn, "BEGIN").await.map_err(ReadError::Sql)?;
    }
    let declare = format!("{}{}", CURSOR_PREFIX, sql.trim().trim_end_matches(';'));
    if let Err(e) = (&mut live.conn).execute(sqlx::raw_sql(&declare)).await {
        if is_fatal(&e) {
            return Err(ReadError::Lost(lost_reason(&e)));
        }
        let unsupported = e.as_database_error().and_then(|d| d.code()).map(|c| c == "0A000").unwrap_or(false);
        if !in_transaction {
            let _ = exec(&mut live.conn, "ROLLBACK").await;
        }
        // A data-modifying WITH cannot be a cursor: the caller runs it raw.
        if unsupported {
            return Ok(None);
        }
        return Err(ReadError::Sql(shifted_error(&e, CURSOR_PREFIX.chars().count())));
    }
    let fetch = format!("FETCH FORWARD {} FROM _pharos_c", limit as u64 + 1);
    let read = read_all(&mut live.conn, &fetch, limit as usize + 1, cancel, until, 0).await;
    match read {
        Ok((rows, total)) => {
            let _ = exec(&mut live.conn, "CLOSE _pharos_c").await;
            if !in_transaction {
                exec(&mut live.conn, "COMMIT").await.map_err(ReadError::Sql)?;
            }
            Ok(Some((rows, total)))
        }
        Err(ReadError::Stopped(why)) => {
            if !stop_statement(&mut live.conn, state, connection_id, live.backend_pid).await {
                return Err(ReadError::Lost("The statement would not stop; the connection was closed".to_string()));
            }
            if !in_transaction {
                let _ = exec(&mut live.conn, "ROLLBACK").await;
            }
            Err(ReadError::Stopped(why))
        }
        Err(err) => {
            if !in_transaction && !matches!(err, ReadError::Lost(_)) {
                let _ = exec(&mut live.conn, "ROLLBACK").await;
            }
            Err(err)
        }
    }
}

// MARK: - Card runs

/// Run a card's SELECT-like statement on its tab's connection.
pub async fn session_execute_query(request: SessionRunRequest, state: &AppState) -> Result<SessionQueryResult, String> {
    let t = &request.target;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id.clone());
    let cancel = registered.cancel.clone();
    let limit = request.limit.unwrap_or(1000);
    let start = Instant::now();

    if let Some(refusal) = refusal_before_send(&request.sql) {
        return Err(refusal);
    }
    let read_only = state.get_config(&t.connection_id).map(|c| c.read_only).unwrap_or(false);
    if read_only && read_only_bypass(&request.sql) {
        return Err(format!("{} This connection is read-only.", super::query::READ_ONLY_MARKER));
    }

    let mut guard = lock_or_cancel(&session, &cancel).await?;
    let reset = ensure_live(&mut guard, &session, state).await?;
    let until = deadline(state);
    let outcome = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        apply_schema(live, t.schema.as_deref(), state).await;
        run_rows(live, &request, limit, &cancel, until, state, &t.connection_id).await
    };
    drop(registered);
    let (rows, total) = match outcome {
        Ok(v) => v,
        Err(e) => {
            let message = read_error_message(e, &mut guard, state);
            let (report, _) = finish(&mut guard, &session, state, reset).await;
            log::debug!("Tab session {} after a failed run: {:?}", session.id, report.txn);
            return Err(message);
        }
    };
    let in_transaction = guard.as_ref().map(|l| l.txn == TxnState::InTransaction).unwrap_or(false);

    // Columns: from the first row, or a describe for an empty result (inside
    // the aux savepoint in a transaction, where a failed describe would
    // otherwise abort the user's transaction).
    let columns = if let Some(first) = rows.first() {
        pg_columns_to_defs(first.columns())
    } else if let Some(live) = guard.as_mut() {
        describe_columns(live, &request.sql).await
    } else {
        Vec::new()
    };
    let has_more = total > limit as usize;
    let row_count = rows.len().min(limit as usize);
    let json_rows = rows_to_json(rows, &columns, row_count);
    let execution_time_ms = start.elapsed().as_millis() as u64;

    let (report, refusal) = finish(&mut guard, &session, state, reset).await;
    drop(guard);
    if let Some(refusal) = refusal {
        return Err(refusal);
    }

    // The row identity reads the catalogue through the pool. Inside an open
    // transaction a table it created is not visible there yet: no identity
    // then, rather than a wrong one.
    let row_identity = if in_transaction || request.aux || json_rows.is_empty() {
        None
    } else {
        match state.require_pool(&t.connection_id) {
            Ok(pool) => build_row_identity(&pool, &t.connection_id, &columns, &json_rows, state).await,
            Err(_) => None,
        }
    };

    let history_entry_id = if request.aux {
        None
    } else {
        let entry = history_entry(state, &t.connection_id, &request.sql, &t.schema, request.source.clone(),
                                  row_count as i64, execution_time_ms, Some(columns.len() as i64));
        record_history(state, &entry, result_cache(&columns, &json_rows, row_identity.as_ref()));
        Some(entry.id)
    };

    Ok(SessionQueryResult {
        result: QueryResult {
            columns,
            rows: json_rows,
            row_count,
            execution_time_ms,
            has_more,
            history_entry_id,
            row_identity,
        },
        session: report,
    })
}

/// The rows of a run: through a cursor when the statement can be one, raw
/// otherwise; inside the card (or aux) savepoint in a transaction.
async fn run_rows(live: &mut LiveSession, request: &SessionRunRequest, limit: u32, cancel: &QueryCancel,
                  until: Option<tokio::time::Instant>, state: &AppState, connection_id: &str)
                  -> Result<(Vec<PgRow>, usize), ReadError> {
    let sql = request.sql.as_str();
    let s = shape(sql);
    let in_transaction = live.txn == TxnState::InTransaction;
    if request.aux && live.txn == TxnState::Failed {
        return Err(ReadError::Sql(FAILED_TRANSACTION.to_string()));
    }
    let savepoint = if in_transaction && !s.transaction_control && !s.multiple {
        if request.aux {
            Some("_pharos_aux")
        } else if live.card_savepoints < MAX_CARD_SAVEPOINTS {
            live.card_savepoints += 1;
            Some("_pharos_card")
        } else {
            None
        }
    } else {
        None
    };
    if let Some(name) = savepoint {
        exec(&mut live.conn, &format!("SAVEPOINT {}", name)).await.map_err(ReadError::Sql)?;
    }

    let mut stopped_in_cursor = false;
    let mut result = if s.cursorable && !s.multiple && live.txn != TxnState::Failed {
        match read_through_cursor(live, sql, limit, in_transaction, cancel, until, state, connection_id).await {
            Ok(Some(v)) => Ok(v),
            Ok(None) => read_all(&mut live.conn, sql, limit as usize + 1, cancel, until, 0).await,
            Err(e) => {
                stopped_in_cursor = matches!(e, ReadError::Stopped(_));
                Err(e)
            }
        }
    } else {
        read_all(&mut live.conn, sql, limit as usize + 1, cancel, until, 0).await
    };

    if let (Err(ReadError::Stopped(_)), false) = (&result, stopped_in_cursor) {
        if !stop_statement(&mut live.conn, state, connection_id, live.backend_pid).await {
            result = Err(ReadError::Lost("The statement would not stop; the connection was closed".to_string()));
        }
    }
    if let Some(name) = savepoint {
        match &result {
            Ok(_) => {
                let _ = exec(&mut live.conn, &format!("RELEASE SAVEPOINT {}", name)).await;
            }
            // A cancel or a timeout undoes this card only; the transaction
            // goes on. Pharos's own work never leaves it failed either.
            Err(ReadError::Stopped(_)) | Err(ReadError::Sql(_)) if request.aux || matches!(result, Err(ReadError::Stopped(_))) => {
                let _ = exec(&mut live.conn, &format!("ROLLBACK TO SAVEPOINT {name}; RELEASE SAVEPOINT {name}")).await;
            }
            // A user's SQL error leaves the transaction failed, as psql does.
            _ => {}
        }
    }
    result
}

/// The message for a read that did not finish, and the connection dropped
/// when it is gone.
fn read_error_message(e: ReadError, guard: &mut Option<LiveSession>, state: &AppState) -> String {
    match e {
        ReadError::Stopped(Stop::Cancelled) => QUERY_CANCELLED.to_string(),
        ReadError::Stopped(Stop::TimedOut) => {
            format!("Query timed out after {} s (Settings ▸ Query)", query_timeout_seconds(state))
        }
        ReadError::Sql(m) => m,
        ReadError::Lost(m) => {
            *guard = None;
            format!("{}. The tab's connection was reset; the statement may or may not have run.", m)
        }
    }
}

const FAILED_TRANSACTION: &str = "The transaction failed. Roll it back first.";

async fn describe_columns(live: &mut LiveSession, sql: &str) -> Vec<super::row_identity::ColumnDef> {
    match live.txn {
        TxnState::Failed | TxnState::Unknown => Vec::new(),
        TxnState::InTransaction => {
            if exec(&mut live.conn, "SAVEPOINT _pharos_aux").await.is_err() {
                return Vec::new();
            }
            let columns = match (&mut live.conn).describe(sql).await {
                Ok(desc) => pg_columns_to_defs(desc.columns()),
                Err(_) => Vec::new(),
            };
            let _ = exec(&mut live.conn, "ROLLBACK TO SAVEPOINT _pharos_aux; RELEASE SAVEPOINT _pharos_aux").await;
            columns
        }
        TxnState::Idle => match (&mut live.conn).describe(sql).await {
            Ok(desc) => pg_columns_to_defs(desc.columns()),
            Err(_) => Vec::new(),
        },
    }
}

/// Run a card's other statement (INSERT, UPDATE, DDL, SET, BEGIN …) on its
/// tab's connection.
pub async fn session_execute_statement(request: SessionRunRequest, state: &AppState) -> Result<SessionExecuteResult, String> {
    let t = &request.target;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id.clone());
    let cancel = registered.cancel.clone();
    let start = Instant::now();

    if let Some(refusal) = refusal_before_send(&request.sql) {
        return Err(refusal);
    }
    let read_only = state.get_config(&t.connection_id).map(|c| c.read_only).unwrap_or(false);
    if read_only && read_only_bypass(&request.sql) {
        return Err(format!("{} This connection is read-only.", super::query::READ_ONLY_MARKER));
    }

    let mut guard = lock_or_cancel(&session, &cancel).await?;
    let reset = ensure_live(&mut guard, &session, state).await?;
    let until = deadline(state);
    let outcome: Result<u64, ReadError> = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        apply_schema(live, t.schema.as_deref(), state).await;
        let s = shape(&request.sql);
        let savepoint = live.txn == TxnState::InTransaction && !s.transaction_control && !s.multiple
            && live.card_savepoints < MAX_CARD_SAVEPOINTS;
        if savepoint {
            live.card_savepoints += 1;
        }
        let mut result = Ok(0);
        if savepoint {
            if let Err(e) = exec(&mut live.conn, "SAVEPOINT _pharos_card").await {
                result = Err(ReadError::Sql(e));
            }
        }
        if result.is_ok() {
            let run = (&mut live.conn).execute(sqlx::raw_sql(&request.sql));
            let stop = stop_signal(&cancel, until);
            result = tokio::select! {
                biased;
                why = stop => Err(ReadError::Stopped(why)),
                done = run => match done {
                    Ok(r) => Ok(r.rows_affected()),
                    Err(e) if is_fatal(&e) => Err(ReadError::Lost(lost_reason(&e))),
                    Err(e) => Err(ReadError::Sql(format_db_error(&e))),
                },
            };
        }
        if let Err(ReadError::Stopped(_)) = &result {
            if !stop_statement(&mut live.conn, state, &t.connection_id, live.backend_pid).await {
                result = Err(ReadError::Lost("The statement would not stop; the connection was closed".to_string()));
            } else if savepoint {
                let _ = exec(&mut live.conn, "ROLLBACK TO SAVEPOINT _pharos_card; RELEASE SAVEPOINT _pharos_card").await;
            }
        } else if savepoint && result.is_ok() {
            let _ = exec(&mut live.conn, "RELEASE SAVEPOINT _pharos_card").await;
        }
        result
    };
    drop(registered);
    let rows_affected = match outcome {
        Ok(n) => n,
        Err(e) => {
            let message = read_error_message(e, &mut guard, state);
            finish(&mut guard, &session, state, reset).await;
            return Err(message);
        }
    };
    let execution_time_ms = start.elapsed().as_millis() as u64;
    let (report, refusal) = finish(&mut guard, &session, state, reset).await;
    drop(guard);
    if let Some(refusal) = refusal {
        return Err(refusal);
    }

    let history_entry_id = if request.aux {
        None
    } else {
        let entry = history_entry(state, &t.connection_id, &request.sql, &t.schema, request.source.clone(),
                                  rows_affected as i64, execution_time_ms, None);
        record_history(state, &entry, None);
        Some(entry.id)
    };
    Ok(SessionExecuteResult {
        result: ExecuteResult { rows_affected, execution_time_ms, history_entry_id },
        session: report,
    })
}

// MARK: - Pharos's own work

/// Load More on a tab session: the next page of a card's statement, read on
/// its own connection, so it sees the tab's temp tables, settings and
/// uncommitted rows.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionFetchMoreRequest {
    #[serde(flatten)]
    pub target: SessionTarget,
    pub sql: String,
    pub limit: i64,
    pub offset: i64,
}

pub async fn session_fetch_more_rows(request: SessionFetchMoreRequest, state: &AppState) -> Result<SessionQueryResult, String> {
    // One row past the page, as the pool's Load More does: that row is how
    // `has_more` knows more remain (it is read, then dropped).
    let sql = format!(
        "SELECT * FROM ({}) AS _pharos_paginated LIMIT {} OFFSET {}",
        request.sql.trim().trim_end_matches(';'),
        request.limit + 1,
        request.offset
    );
    let mut run = SessionRunRequest {
        target: request.target.clone(),
        sql,
        limit: Some(request.limit.max(1) as u32),
        source: None,
        aux: true,
    };
    run.target.query_id = request.target.query_id.clone();
    session_execute_query(run, state).await
}

/// Load All on a tab session: one consistent snapshot through a server
/// cursor, inside Pharos's own transaction when the session is idle, inside
/// the aux savepoint when the user's transaction is open.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionFetchAllRequest {
    #[serde(flatten)]
    pub target: SessionTarget,
    pub sql: String,
    pub max_rows: i64,
}

pub async fn session_fetch_all_rows(request: SessionFetchAllRequest, state: &AppState,
                                    on_progress: impl Fn(u64) + Send) -> Result<SessionQueryResult, String> {
    let t = &request.target;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let start = Instant::now();
    let mut guard = lock_or_cancel(&session, &cancel).await?;
    let reset = ensure_live(&mut guard, &session, state).await?;
    let cap = request.max_rows.max(1) as usize;
    let outcome: Result<(Vec<PgRow>, bool), ReadError> = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        apply_schema(live, t.schema.as_deref(), state).await;
        let in_transaction = live.txn == TxnState::InTransaction;
        if live.txn == TxnState::Failed {
            Err(ReadError::Sql(FAILED_TRANSACTION.to_string()))
        } else {
            let open = if in_transaction { "SAVEPOINT _pharos_aux" } else { "BEGIN" };
            let close_ok = if in_transaction { "CLOSE _pharos_all; RELEASE SAVEPOINT _pharos_aux" } else { "CLOSE _pharos_all; COMMIT" };
            let close_err = if in_transaction { "ROLLBACK TO SAVEPOINT _pharos_aux; RELEASE SAVEPOINT _pharos_aux" } else { "ROLLBACK" };
            let mut result = exec(&mut live.conn, open).await.map_err(ReadError::Sql);
            if result.is_ok() {
                result = exec(&mut live.conn, &format!("DECLARE _pharos_all NO SCROLL CURSOR FOR {}",
                                                      request.sql.trim().trim_end_matches(';')))
                    .await
                    .map_err(ReadError::Sql);
            }
            let mut rows: Vec<PgRow> = Vec::new();
            let mut more = false;
            while result.is_ok() {
                let want = (cap + 1 - rows.len()).min(5000);
                let fetched = read_all(&mut live.conn, &format!("FETCH FORWARD {} FROM _pharos_all", want),
                                       want, &cancel, None, 0).await;
                match fetched {
                    Ok((chunk, n)) => {
                        let done = n < want;
                        rows.extend(chunk);
                        if rows.len() > cap {
                            rows.truncate(cap);
                            more = true;
                            break;
                        }
                        on_progress(rows.len() as u64);
                        if done { break; }
                    }
                    Err(e) => result = Err(e),
                }
            }
            if let Err(ReadError::Stopped(_)) = &result {
                if !stop_statement(&mut live.conn, state, &t.connection_id, live.backend_pid).await {
                    result = Err(ReadError::Lost("The load would not stop; the connection was closed".to_string()));
                }
            }
            match result {
                Ok(()) => exec(&mut live.conn, close_ok).await.map(|_| (rows, more)).map_err(ReadError::Sql),
                Err(e) => {
                    let _ = exec(&mut live.conn, close_err).await;
                    Err(e)
                }
            }
        }
    };
    drop(registered);
    let (rows, has_more) = match outcome {
        Ok(v) => v,
        Err(e) => {
            let message = read_error_message(e, &mut guard, state);
            finish(&mut guard, &session, state, reset).await;
            return Err(message);
        }
    };
    let (report, _) = finish(&mut guard, &session, state, reset).await;
    drop(guard);
    let columns = rows.first().map(|r| pg_columns_to_defs(r.columns())).unwrap_or_default();
    let row_count = rows.len();
    let json_rows = rows_to_json(rows, &columns, usize::MAX);
    Ok(SessionQueryResult {
        result: QueryResult {
            columns,
            rows: json_rows,
            row_count,
            execution_time_ms: start.elapsed().as_millis() as u64,
            has_more,
            history_entry_id: None,
            row_identity: None,
        },
        session: report,
    })
}

/// Explain a card on its tab's connection. ANALYZE runs the statement and
/// undoes it: in Pharos's own transaction when idle, to the aux savepoint in
/// the user's transaction, which stays open.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionExplainRequest {
    #[serde(flatten)]
    pub target: SessionTarget,
    pub sql: String,
    #[serde(default)]
    pub analyze: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionExplainResult {
    pub plan: String,
    pub session: SessionReport,
}

pub async fn session_explain(request: SessionExplainRequest, state: &AppState) -> Result<SessionExplainResult, String> {
    let statement = explain_statement(&request.sql, request.analyze)?;
    let t = &request.target;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let mut guard = lock_or_cancel(&session, &cancel).await?;
    let reset = ensure_live(&mut guard, &session, state).await?;
    let outcome: Result<String, String> = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        apply_schema(live, t.schema.as_deref(), state).await;
        match live.txn {
            TxnState::Failed => Err(FAILED_TRANSACTION.to_string()),
            txn => {
                let in_transaction = txn == TxnState::InTransaction;
                let (open, undo) = match (request.analyze, in_transaction) {
                    (true, false) => (Some("BEGIN"), Some("ROLLBACK")),
                    (_, true) => (Some("SAVEPOINT _pharos_aux"), Some("ROLLBACK TO SAVEPOINT _pharos_aux; RELEASE SAVEPOINT _pharos_aux")),
                    (false, false) => (None, None),
                };
                let mut result = Ok(String::new());
                if let Some(open) = open {
                    if let Err(e) = exec(&mut live.conn, open).await { result = Err(e); }
                }
                if result.is_ok() {
                    result = match (&mut live.conn).fetch_optional(sqlx::raw_sql(&statement)).await {
                        Ok(Some(row)) => row
                            .try_get_raw(0)
                            .ok()
                            .and_then(|raw| if sqlx::ValueRef::is_null(&raw) { None } else { raw.as_str().ok().map(str::to_string) })
                            .ok_or_else(|| "EXPLAIN returned no plan".to_string()),
                        Ok(None) => Err("EXPLAIN returned no plan".to_string()),
                        Err(e) => Err(format_db_error(&e)),
                    };
                }
                if let Some(undo) = undo {
                    let _ = exec(&mut live.conn, undo).await;
                }
                result
            }
        }
    };
    drop(registered);
    let (report, _) = finish(&mut guard, &session, state, reset).await;
    outcome.map(|plan| SessionExplainResult { plan, session: report })
}

/// Cell edits on a tab session. Idle: one transaction of their own. In the
/// user's open transaction: a savepoint, so the edits are part of that
/// transaction ("saved when you commit") — and an edit can never wait on a
/// row lock the tab's own transaction holds.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRowUpdateRequest {
    #[serde(flatten)]
    pub target: SessionTarget,
    pub request: RowUpdateRequest,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRowUpdateResult {
    #[serde(flatten)]
    pub result: RowUpdateResult,
    /// The edits are in the user's open transaction, not yet committed.
    pub in_transaction: bool,
    pub session: SessionReport,
}

pub async fn session_apply_row_updates(request: SessionRowUpdateRequest, state: &AppState) -> Result<SessionRowUpdateResult, String> {
    validate_request(&request.request)?;
    let t = &request.target;
    state.require_writable(&t.connection_id)?;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let start = Instant::now();
    let mut guard = lock_or_cancel(&session, &cancel).await?;
    let reset = ensure_live(&mut guard, &session, state).await?;
    let mut in_transaction = false;
    let outcome: Result<i64, String> = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        match live.txn {
            TxnState::Failed => Err(FAILED_TRANSACTION.to_string()),
            txn => {
                in_transaction = txn == TxnState::InTransaction;
                let (open, done, undo) = if in_transaction {
                    ("SAVEPOINT _pharos_edit", "RELEASE SAVEPOINT _pharos_edit",
                     "ROLLBACK TO SAVEPOINT _pharos_edit; RELEASE SAVEPOINT _pharos_edit")
                } else {
                    ("BEGIN", "COMMIT", "ROLLBACK")
                };
                let mut result = exec(&mut live.conn, open).await.map(|_| 0i64);
                for row_index in 0..request.request.rows.len() {
                    if result.is_err() { break; }
                    let (sql, params) = match build_update_statement(&request.request, row_index) {
                        Ok(pair) => pair,
                        Err(e) => { result = Err(e); break; }
                    };
                    // Not persistent: a user's DEALLOCATE ALL card must not
                    // leave a cached statement name behind on this connection.
                    let mut query = sqlx::query(&sql).persistent(false);
                    for value in &params {
                        query = query.bind(value.clone());
                    }
                    result = match query.fetch_all(&mut live.conn).await {
                        Ok(rows) if rows.len() == 1 => result.map(|n| n + 1),
                        Ok(rows) if rows.is_empty() => Err(format!(
                            "Row {} was not updated: the row is gone, its key changed, or another session changed \
                             a value since it was loaded. Nothing was changed.", row_index + 1)),
                        Ok(rows) => Err(format!("Row {}: the key matched more than one row ({}); nothing was changed.",
                                                row_index + 1, rows.len())),
                        Err(e) => Err(format!("Row {} could not be updated: {}. Nothing was changed.",
                                              row_index + 1, format_db_error(&e))),
                    };
                }
                match result {
                    Ok(n) => exec(&mut live.conn, done).await.map(|_| n),
                    Err(e) => {
                        let _ = exec(&mut live.conn, undo).await;
                        Err(e)
                    }
                }
            }
        }
    };
    drop(registered);
    let (report, _) = finish(&mut guard, &session, state, reset).await;
    drop(guard);
    let rows_updated = outcome?;
    let execution_time_ms = start.elapsed().as_millis() as u64;
    let history_entry_id = uuid::Uuid::new_v4().to_string();
    {
        let connection_name = state.get_config(&t.connection_id).map(|c| c.name).unwrap_or_else(|| t.connection_id.clone());
        let entry = QueryHistoryEntry {
            id: history_entry_id.clone(),
            connection_id: t.connection_id.clone(),
            connection_name,
            sql: history_sql(&request.request, rows_updated),
            row_count: Some(rows_updated),
            execution_time_ms: execution_time_ms as i64,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false,
            schema: Some(request.request.schema.clone()),
            column_count: None,
            table_names: Some(format!("{}.{}", request.request.schema, request.request.table)),
            source: None,
            status: crate::models::HISTORY_STATUS_OK.to_string(),
            error_message: None,
        };
        if let Ok(db) = state.metadata_db.lock() {
            if let Err(e) = sqlite::save_query_history(&db, &entry, None, None, None) {
                log::warn!("Failed to save query history for cell edits: {}", e);
            }
        }
    }
    Ok(SessionRowUpdateResult {
        result: RowUpdateResult { rows_updated, execution_time_ms, history_entry_id: Some(history_entry_id) },
        in_transaction,
        session: report,
    })
}

/// Validate a card on its tab's connection, so a temp table or a
/// `search_path` set by an earlier card is known. Validation never waits:
/// when the session is busy, or its transaction failed, the card is reported
/// valid and is checked again at the next edit. A tab whose connection is not
/// open yet is validated on the pool, which sees the same objects.
///
/// `PREPARE` takes ACCESS SHARE locks, so it runs under a short `SET LOCAL
/// lock_timeout`, in Pharos's own transaction (idle) or a savepoint (in the
/// user's transaction); the rollback releases the locks. A prepared
/// statement is not transactional, so it is deallocated before the rollback.
pub async fn session_validate_sql(target: SessionTarget, sql: String, state: &AppState)
                                  -> Result<super::query::ValidationResult, String> {
    let valid = || super::query::ValidationResult { valid: true, error: None };
    let sql_trimmed = sql.trim();
    if sql_trimmed.is_empty() {
        return Ok(valid());
    }
    let session = match state.tab_session(&target.session_id) {
        Some(s) if s.connection_id == target.connection_id => s,
        _ => return super::query::validate_sql(target.connection_id, sql, target.schema, state).await,
    };
    let Ok(mut guard) = session.conn.try_lock() else { return Ok(valid()) };
    let Some(live) = guard.as_mut() else {
        drop(guard);
        return super::query::validate_sql(target.connection_id, sql, target.schema, state).await;
    };
    if live.txn != TxnState::Idle && live.txn != TxnState::InTransaction {
        return Ok(valid());
    }
    apply_schema(live, target.schema.as_deref(), state).await;
    let in_transaction = live.txn == TxnState::InTransaction;
    let (open, undo) = if in_transaction {
        ("SAVEPOINT _pharos_aux", "ROLLBACK TO SAVEPOINT _pharos_aux; RELEASE SAVEPOINT _pharos_aux")
    } else {
        ("BEGIN", "ROLLBACK")
    };
    if exec(&mut live.conn, open).await.is_err() {
        return Ok(valid());
    }
    let _ = exec(&mut live.conn, "SET LOCAL lock_timeout = '500ms'").await;
    let prefix = "PREPARE _pharos_validate AS ";
    let leading = sql.len() - sql.trim_start().len();
    let outcome = (&mut live.conn).execute(sqlx::raw_sql(&format!("{}{}", prefix, sql_trimmed))).await;
    let result = match outcome {
        Ok(_) => {
            let _ = exec(&mut live.conn, "DEALLOCATE _pharos_validate").await;
            valid()
        }
        // A lock wait says nothing about the SQL.
        Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("55P03") => valid(),
        Err(e) => super::query::validation_failure(&e, &sql, prefix.len(), leading),
    };
    let _ = exec(&mut live.conn, undo).await;
    live.last_used = Instant::now();
    Ok(result)
}

/// The banner's Commit and Roll Back.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEndTransactionRequest {
    pub session_id: String,
    pub commit: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEndTransactionResult {
    pub committed: bool,
    pub rolled_back: bool,
    pub session: SessionReport,
}

pub async fn session_end_transaction(request: SessionEndTransactionRequest, state: &AppState) -> Result<SessionEndTransactionResult, String> {
    let session = state.tab_session(&request.session_id).ok_or_else(|| "The tab has no connection of its own.".to_string())?;
    let mut guard = session.conn.lock().await;
    let outcome = match guard.as_mut() {
        None => Err("The tab's connection is gone; there is no transaction to end.".to_string()),
        Some(live) => {
            let was_failed = live.txn == TxnState::Failed;
            let sql = if request.commit { "COMMIT" } else { "ROLLBACK" };
            match exec(&mut live.conn, sql).await {
                // COMMIT of a failed transaction is answered with ROLLBACK.
                Ok(()) => Ok((request.commit && !was_failed, !request.commit || was_failed)),
                Err(e) => Err(e),
            }
        }
    };
    let (report, _) = finish(&mut guard, &session, state, None).await;
    let (committed, rolled_back) = outcome?;
    Ok(SessionEndTransactionResult { committed, rolled_back, session: report })
}

// MARK: - State registry helpers on AppState

impl AppState {
    pub fn tab_session(&self, id: &str) -> Option<Arc<TabSession>> {
        self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    fn insert_tab_session(&self, session: Arc<TabSession>) {
        self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), session);
    }

    fn remove_tab_session(&self, id: &str) -> Option<Arc<TabSession>> {
        self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner()).remove(id)
    }

    pub fn tab_session_count(&self, connection_id: &str) -> usize {
        self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner()).values().filter(|s| s.connection_id == connection_id).count()
    }

    pub fn tab_session_ids(&self, connection_id: &str) -> Vec<String> {
        self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner())
            .values().filter(|s| s.connection_id == connection_id).map(|s| s.id.clone()).collect()
    }

    /// Drop a connection's sessions without closing them: their sockets are
    /// already gone with a dead tunnel. Dropping a connection does not block.
    pub fn drop_tab_sessions(&self, connection_id: &str) {
        let mut map = self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner());
        let ids: Vec<String> = map.values().filter(|s| s.connection_id == connection_id).map(|s| s.id.clone()).collect();
        for id in ids {
            if let Some(s) = map.remove(&id) {
                s.closing.store(true, Ordering::Relaxed);
                let mut r = s.report.lock().unwrap_or_else(|e| e.into_inner());
                r.open = false;
                r.txn = TxnState::Unknown;
            }
        }
    }

    /// Every session, for shutdown.
    pub fn take_all_tab_sessions(&self) -> Vec<Arc<TabSession>> {
        self.tab_sessions.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, s)| s).collect()
    }

    /// The session options a connection's pool was made with.
    pub fn session_options(&self, connection_id: &str) -> crate::db::postgres::SessionOptions {
        self.session_options.lock().unwrap_or_else(|e| e.into_inner()).get(connection_id).cloned().unwrap_or_default()
    }

    pub fn set_session_options(&self, connection_id: &str, options: crate::db::postgres::SessionOptions) {
        self.session_options.lock().unwrap_or_else(|e| e.into_inner()).insert(connection_id.to_string(), options);
    }

    pub fn forget_session_options(&self, connection_id: &str) {
        self.session_options.lock().unwrap_or_else(|e| e.into_inner()).remove(connection_id);
    }
}

/// Close every session at shutdown, rolling back, within a time budget.
pub async fn close_all_tab_sessions(state: &AppState, budget: Duration) {
    let sessions = state.take_all_tab_sessions();
    let closes = sessions.into_iter().map(|s| async move {
        s.closing.store(true, Ordering::Relaxed);
        if let Ok(mut guard) = tokio::time::timeout(budget, s.conn.lock()).await {
            if let Some(mut live) = guard.take() {
                if live.txn != TxnState::Idle {
                    let _ = (&mut live.conn).execute(sqlx::raw_sql("ROLLBACK")).await;
                }
                let _ = tokio::time::timeout(budget, live.conn.close()).await;
            }
        }
    });
    futures::future::join_all(closes).await;
}

/// For `HashMap` users outside this module (the type is private otherwise).
pub type TabSessionMap = HashMap<String, Arc<TabSession>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes() {
        assert!(shape("select 1").cursorable);
        assert!(shape("  WITH x AS (SELECT 1) SELECT * FROM x").cursorable);
        assert!(shape("(SELECT 1) UNION (SELECT 2)").cursorable);
        assert!(!shape("UPDATE t SET x = 1").cursorable);
        assert!(shape("BEGIN").transaction_control);
        assert!(shape("rollback to savepoint a").transaction_control);
        assert!(!shape("SELECT 1").transaction_control);
        assert!(shape("SELECT 1; SELECT 2").multiple);
        assert!(!shape("SELECT ';'").multiple);
    }

    #[test]
    fn refusals_before_send() {
        assert!(refusal_before_send("  -- nothing\n").is_some());
        assert!(refusal_before_send("\\set x 1").is_some());
        assert!(refusal_before_send("COPY t FROM STDIN;\n1\n\\.").is_some());
        assert!(refusal_before_send("copy t to stdout").is_some());
        assert!(refusal_before_send("COPY t TO '/tmp/x'").is_none());
        assert!(refusal_before_send("SELECT 1").is_none());
    }

    #[test]
    fn read_only_bypasses() {
        assert!(read_only_bypass("SET default_transaction_read_only = off"));
        assert!(read_only_bypass("BEGIN READ  WRITE"));
        assert!(read_only_bypass("set session characteristics as transaction read write"));
        assert!(read_only_bypass("SELECT set_config('default_transaction_read_only', 'off', false)"));
        assert!(!read_only_bypass("SELECT 1"));
        assert!(!read_only_bypass("SHOW default_transaction_read_only"));
        assert!(!read_only_bypass("SELECT 'read write'"));
    }

    #[test]
    fn error_positions_shift_back_over_the_prefix() {
        let e = "syntax error at or near \"FORM\" at character 52".to_string();
        // `shifted_error` works on a formatted message; check its arithmetic
        // through the same split it uses.
        let marker = " at character ";
        let i = e.rfind(marker).unwrap();
        let n: usize = e[i + marker.len()..].parse().unwrap();
        assert_eq!(n - CURSOR_PREFIX.chars().count(), 52 - 39);
        assert_eq!(CURSOR_PREFIX.chars().count(), 39);
    }

    #[test]
    fn fatal_errors() {
        assert!(is_fatal(&sqlx::Error::PoolClosed));
        assert!(!is_fatal(&sqlx::Error::RowNotFound));
    }

    #[test]
    fn ffi_shapes() {
        let request: SessionRunRequest = serde_json::from_str(
            r#"{"sessionId":"t","connectionId":"c","schema":"public","queryId":"q","sql":"SELECT 1","limit":5}"#,
        ).unwrap();
        assert_eq!(request.target.session_id, "t");
        assert_eq!(request.target.schema.as_deref(), Some("public"));
        assert_eq!(request.limit, Some(5));
        assert!(!request.aux);
        let result = SessionQueryResult {
            result: QueryResult { columns: vec![], rows: vec![], row_count: 0, execution_time_ms: 1, has_more: false,
                                  history_entry_id: None, row_identity: None },
            session: TabSession::new("t", "c", 600).report(),
        };
        let json = serde_json::to_value(&result).unwrap();
        assert_eq!(json["row_count"], 0, "the pool's snake_case fields stay as they are");
        assert_eq!(json["session"]["sessionId"], "t");
        let edit: SessionEndTransactionRequest = serde_json::from_str(r#"{"sessionId":"t","commit":true}"#).unwrap();
        assert!(edit.commit);
    }

    #[test]
    fn reports_serialize_camel_case() {
        let s = TabSession::new("tab-1", "c1", 600);
        let json = serde_json::to_value(s.report()).unwrap();
        assert_eq!(json["sessionId"], "tab-1");
        assert_eq!(json["txn"], "idle");
        assert_eq!(json["idleInTransactionTimeoutSeconds"], 600);
        assert!(json["reset"].is_null());
    }
}

/// Live tests against a real server: `cargo test --lib live_tab_session -- --ignored --test-threads=1`.
#[cfg(test)]
mod live_tab_session_tests {
    use super::*;
    use crate::commands::row_edit::{RowUpdateColumn, RowUpdateRow};
    use crate::db::postgres::{create_pool_with, PoolTuning, SessionOptions};
    use crate::models::{ConnectionConfig, SslMode};
    use rusqlite::Connection as SqliteConnection;

    const CONN: &str = "live-tab-session-test";
    const TAB: &str = "tab-1";

    fn env_or(key: &str, fallback: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| fallback.to_string())
    }

    fn live_config(read_only: bool) -> ConnectionConfig {
        ConnectionConfig {
            id: CONN.to_string(),
            name: CONN.to_string(),
            host: env_or("PHAROS_TEST_PG_HOST", "localhost"),
            port: env_or("PHAROS_TEST_PG_PORT", "5432").parse().unwrap_or(5432),
            database: env_or("PHAROS_TEST_PG_DB", "nfinn"),
            username: env_or("PHAROS_TEST_PG_USER", "nfinn"),
            password: std::env::var("PHAROS_TEST_PG_PASSWORD").unwrap_or_default(),
            ssl_mode: SslMode::Prefer,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    /// A state with a pool for CONN, made the way `connect_postgres` makes it.
    async fn live_state(read_only: bool) -> AppState {
        let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
        let config = live_config(read_only);
        let session = SessionOptions::from_settings(&state.settings().connections, &config);
        let tuning = PoolTuning { max_connections: 2, ..PoolTuning::default() };
        let pool = create_pool_with(&config, &session, &tuning).await.expect("connect to the live server");
        state.add_pool(CONN.to_string(), pool);
        state.set_session_options(CONN, session);
        state.set_config(config);
        state
    }

    async fn other_user() -> PgConnection {
        let c = live_config(false);
        let opts = sqlx::postgres::PgConnectOptions::new()
            .host(&c.host).port(c.port).database(&c.database).username(&c.username).password(&c.password);
        PgConnection::connect_with(&opts).await.expect("second connection")
    }

    fn target(tab: &str) -> SessionTarget {
        SessionTarget { session_id: tab.to_string(), connection_id: CONN.to_string(), schema: None, query_id: None }
    }

    fn card(tab: &str, sql: &str) -> SessionRunRequest {
        SessionRunRequest { target: target(tab), sql: sql.to_string(), limit: Some(1000), source: None, aux: false }
    }

    async fn query(state: &AppState, sql: &str) -> Result<SessionQueryResult, String> {
        session_execute_query(card(TAB, sql), state).await
    }

    async fn statement(state: &AppState, sql: &str) -> Result<SessionExecuteResult, String> {
        session_execute_statement(card(TAB, sql), state).await
    }

    async fn scalar(state: &AppState, sql: &str) -> String {
        let r = query(state, sql).await.unwrap_or_else(|e| panic!("{sql}: {e}"));
        r.result.rows[0][0].as_str().expect("text").to_string()
    }

    fn table_name(tag: &str) -> String {
        format!("pharos_ts_{}_{}", tag, std::process::id())
    }

    fn block_on<F: std::future::Future<Output = ()>>(f: F) {
        tokio::runtime::Runtime::new().expect("tokio runtime").block_on(f);
    }

    const LIVE: &str = "needs a live PostgreSQL (Postgres.app) on localhost:5432";

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_set_carries_to_the_next_card() {
        let _ = LIVE;
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "SET work_mem = '77MB'").await.expect("SET");
            assert_eq!(scalar(&state, "SHOW work_mem").await, "77MB");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_temp_table_carries_to_the_next_card() {
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "CREATE TEMP TABLE carried AS SELECT 41 + 1 AS n").await.expect("create");
            assert_eq!(scalar(&state, "SELECT n FROM carried").await, "42");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_transaction_spans_cards_and_others_wait_for_the_commit() {
        block_on(async {
            let state = live_state(false).await;
            let t = table_name("txn");
            let mut other = other_user().await;
            other.execute(sqlx::raw_sql(&format!("CREATE TABLE {t} (id int primary key, v int); INSERT INTO {t} VALUES (1, 0)"))).await.unwrap();

            let begun = statement(&state, "BEGIN").await.expect("BEGIN");
            assert_eq!(begun.session.txn, TxnState::InTransaction);
            let updated = statement(&state, &format!("UPDATE {t} SET v = 5 WHERE id = 1")).await.expect("UPDATE");
            assert_eq!(updated.result.rows_affected, 1);
            assert_eq!(updated.session.txn, TxnState::InTransaction);

            // Another user: does not see it, and waits for the row lock.
            let seen: i32 = sqlx::query_scalar(&format!("SELECT v FROM {t} WHERE id = 1")).fetch_one(&mut other).await.unwrap();
            assert_eq!(seen, 0, "uncommitted value visible to another user");
            other.execute(sqlx::raw_sql("SET lock_timeout = '300ms'")).await.unwrap();
            let blocked = other.execute(sqlx::raw_sql(&format!("UPDATE {t} SET v = 9 WHERE id = 1"))).await;
            assert!(blocked.is_err(), "the other user's UPDATE did not wait for the tab's lock");

            let committed = statement(&state, "COMMIT").await.expect("COMMIT");
            assert_eq!(committed.session.txn, TxnState::Idle);
            let seen: i32 = sqlx::query_scalar(&format!("SELECT v FROM {t} WHERE id = 1")).fetch_one(&mut other).await.unwrap();
            assert_eq!(seen, 5);
            other.execute(sqlx::raw_sql(&format!("DROP TABLE {t}"))).await.unwrap();
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_users_statement_timeout_is_kept() {
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "SET statement_timeout = '123s'").await.expect("SET");
            query(&state, "SELECT 1").await.expect("run");
            assert_eq!(scalar(&state, "SHOW statement_timeout").await, "123s");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_the_schema_pulldown_does_not_undo_a_users_search_path() {
        block_on(async {
            let state = live_state(false).await;
            let mut req = card(TAB, "SELECT 1");
            req.target.schema = Some("public".to_string());
            session_execute_query(req.clone(), &state).await.expect("first run sets public");
            let mut set = card(TAB, "SET search_path = pg_catalog");
            set.target.schema = Some("public".to_string());
            session_execute_statement(set, &state).await.expect("SET");
            let mut show = card(TAB, "SHOW search_path");
            show.target.schema = Some("public".to_string());
            let r = session_execute_query(show, &state).await.expect("SHOW");
            assert_eq!(r.result.rows[0][0].as_str(), Some("pg_catalog"));
            // A CHANGED pull-down is sent.
            let mut moved = card(TAB, "SHOW search_path");
            moved.target.schema = Some("information_schema".to_string());
            let r = session_execute_query(moved, &state).await.expect("SHOW");
            assert!(r.result.rows[0][0].as_str().unwrap().starts_with("information_schema"), "{:?}", r.result.rows);
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_transaction_states() {
        block_on(async {
            let state = live_state(false).await;
            assert_eq!(statement(&state, "BEGIN").await.unwrap().session.txn, TxnState::InTransaction);
            let failed = query(&state, "SELECT 1/0").await;
            assert!(failed.is_err());
            assert_eq!(state.tab_session(TAB).unwrap().report().txn, TxnState::Failed);
            let refused = query(&state, "SELECT 1").await;
            assert!(refused.unwrap_err().contains("aborted"), "a failed transaction runs nothing");
            assert_eq!(statement(&state, "ROLLBACK").await.unwrap().session.txn, TxnState::Idle);
            assert_eq!(scalar(&state, "SELECT 2").await, "2");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_cut_at_the_row_limit_keeps_the_connection() {
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "SET work_mem = '66MB'").await.unwrap();
            let pid = scalar(&state, "SELECT pg_backend_pid()::text").await;
            let mut req = card(TAB, "SELECT g FROM generate_series(1, 100000) g");
            req.limit = Some(10);
            let r = session_execute_query(req, &state).await.expect("limited run");
            assert_eq!(r.result.row_count, 10);
            assert!(r.result.has_more);
            assert_eq!(r.session.txn, TxnState::Idle);
            assert_eq!(scalar(&state, "SELECT pg_backend_pid()::text").await, pid, "the connection was replaced");
            assert_eq!(scalar(&state, "SHOW work_mem").await, "66MB");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_cancel_inside_a_transaction_keeps_the_transaction() {
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "BEGIN").await.unwrap();
            statement(&state, "CREATE TEMP TABLE kept (n int)").await.unwrap();
            statement(&state, "INSERT INTO kept VALUES (1)").await.unwrap();
            let mut slow = card(TAB, "SELECT pg_sleep(20)");
            slow.target.query_id = Some("slow".to_string());
            let started = Instant::now();
            let cancel = async {
                tokio::time::sleep(Duration::from_millis(400)).await;
                assert!(state.mark_query_cancelled("slow"), "the query was not registered");
            };
            let (r, _) = tokio::join!(session_execute_query(slow, &state), cancel);
            assert_eq!(r.unwrap_err(), QUERY_CANCELLED);
            assert!(started.elapsed() < Duration::from_secs(8), "the cancel did not stop the statement");
            let report = state.tab_session(TAB).unwrap().report();
            assert_eq!(report.txn, TxnState::InTransaction, "the cancel ended the transaction");
            assert_eq!(scalar(&state, "SELECT count(*)::text FROM kept").await, "1");
            statement(&state, "ROLLBACK").await.unwrap();
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_cancel_while_idle_keeps_the_connection() {
        block_on(async {
            let state = live_state(false).await;
            let pid = scalar(&state, "SELECT pg_backend_pid()::text").await;
            let mut slow = card(TAB, "SELECT pg_sleep(20)");
            slow.target.query_id = Some("slow".to_string());
            let cancel = async {
                tokio::time::sleep(Duration::from_millis(400)).await;
                state.mark_query_cancelled("slow");
            };
            let (r, _) = tokio::join!(session_execute_query(slow, &state), cancel);
            assert_eq!(r.unwrap_err(), QUERY_CANCELLED);
            let after = query(&state, "SELECT pg_backend_pid()::text").await.unwrap();
            assert_eq!(after.result.rows[0][0].as_str().unwrap(), pid);
            assert!(after.session.reset.is_none());
            assert_eq!(after.session.txn, TxnState::Idle);
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_writable_cte_over_the_limit_is_committed_in_full() {
        block_on(async {
            let state = live_state(false).await;
            let t = table_name("cte");
            let mut other = other_user().await;
            other.execute(sqlx::raw_sql(&format!("CREATE TABLE {t} (n int)"))).await.unwrap();
            let mut req = card(TAB, &format!("WITH x AS (INSERT INTO {t} SELECT generate_series(1, 20) RETURNING n) SELECT n FROM x"));
            req.limit = Some(5);
            let r = session_execute_query(req, &state).await.expect("writable CTE");
            assert_eq!(r.result.row_count, 5);
            assert!(r.result.has_more);
            let n: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {t}")).fetch_one(&mut other).await.unwrap();
            assert_eq!(n, 20);
            other.execute(sqlx::raw_sql(&format!("DROP TABLE {t}"))).await.unwrap();
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_error_positions_match_the_pool() {
        block_on(async {
            let state = live_state(false).await;
            let sql = "SELECT 1\nFROM nowhere_at_all_xyz";
            let session_error = query(&state, sql).await.unwrap_err();
            let pool_error = crate::commands::execute_query(CONN.to_string(), sql.to_string(), None, None, None, None, &state)
                .await
                .unwrap_err();
            assert_eq!(session_error, pool_error);
            assert!(session_error.contains("at character 15"), "{session_error}");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_pharos_work_inside_a_transaction_leaves_it_healthy() {
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "BEGIN").await.unwrap();
            statement(&state, "CREATE TEMP TABLE aux_t AS SELECT generate_series(1, 30) AS n").await.unwrap();
            // A Load More of a bad statement fails, and the transaction stays good.
            let bad = SessionFetchMoreRequest { target: target(TAB), sql: "SELECT nope FROM aux_t".into(), limit: 10, offset: 10 };
            assert!(session_fetch_more_rows(bad, &state).await.is_err());
            assert_eq!(state.tab_session(TAB).unwrap().report().txn, TxnState::InTransaction);
            let good = SessionFetchMoreRequest { target: target(TAB), sql: "SELECT n FROM aux_t ORDER BY n".into(), limit: 10, offset: 10 };
            let page = session_fetch_more_rows(good, &state).await.expect("load more sees the temp table");
            assert_eq!(page.result.rows[0][0].as_str(), Some("11"));
            assert!(page.result.history_entry_id.is_none(), "Pharos's own work is not history");
            // Explain ANALYZE of a write is undone; the transaction stays open.
            let plan = session_explain(SessionExplainRequest { target: target(TAB), sql: "DELETE FROM aux_t".into(), analyze: true }, &state)
                .await.expect("explain");
            assert!(plan.plan.contains("Delete"), "{}", plan.plan);
            assert_eq!(plan.session.txn, TxnState::InTransaction);
            assert_eq!(scalar(&state, "SELECT count(*)::text FROM aux_t").await, "30");
            // Load All.
            let all = session_fetch_all_rows(SessionFetchAllRequest { target: target(TAB), sql: "SELECT n FROM aux_t".into(), max_rows: 1000 }, &state, |_| {})
                .await.expect("load all");
            assert_eq!(all.result.row_count, 30);
            assert_eq!(all.session.txn, TxnState::InTransaction);
            // Validation sees the temp table and leaves the transaction alone.
            let v = session_validate_sql(target(TAB), "SELECT n FROM aux_t".into(), &state).await.unwrap();
            assert!(v.valid, "{:?}", v.error.map(|e| e.message));
            let v = session_validate_sql(target(TAB), "SELECT m FROM aux_t".into(), &state).await.unwrap();
            assert!(!v.valid);
            assert_eq!(state.tab_session(TAB).unwrap().report().txn, TxnState::InTransaction);
            statement(&state, "ROLLBACK").await.unwrap();
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_load_more_says_when_more_rows_remain() {
        block_on(async {
            let state = live_state(false).await;
            let sql = "SELECT g FROM generate_series(1, 3000) g ORDER BY g";
            let page = |offset| SessionFetchMoreRequest { target: target(TAB), sql: sql.into(), limit: 1000, offset };
            let second = session_fetch_more_rows(page(1000), &state).await.expect("page 2");
            assert_eq!(second.result.row_count, 1000);
            assert!(second.result.has_more, "rows 2001-3000 remain after page 2");
            let third = session_fetch_more_rows(page(2000), &state).await.expect("page 3");
            assert_eq!(third.result.row_count, 1000);
            assert!(!third.result.has_more, "nothing remains after page 3");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_cell_edit_inside_the_tabs_transaction_does_not_deadlock() {
        block_on(async {
            let state = live_state(false).await;
            let t = table_name("edit");
            let mut other = other_user().await;
            other.execute(sqlx::raw_sql(&format!("CREATE TABLE {t} (id int primary key, v text); INSERT INTO {t} VALUES (1, 'a')"))).await.unwrap();
            statement(&state, "BEGIN").await.unwrap();
            statement(&state, &format!("UPDATE {t} SET v = 'b' WHERE id = 1")).await.unwrap();
            let request = RowUpdateRequest {
                schema: "public".into(),
                table: t.clone(),
                key_columns: vec![RowUpdateColumn { name: "id".into(), data_type: "INT4".into() }],
                key_description: "primary key".into(),
                columns: vec![RowUpdateColumn { name: "v".into(), data_type: "TEXT".into() }],
                rows: vec![RowUpdateRow { key: vec!["1".into()], old_values: vec![Some("b".into())], new_values: vec![Some("c".into())] }],
            };
            let edit = tokio::time::timeout(Duration::from_secs(5),
                session_apply_row_updates(SessionRowUpdateRequest { target: target(TAB), request }, &state))
                .await
                .expect("the edit waited on the tab's own lock")
                .expect("edit");
            assert_eq!(edit.result.rows_updated, 1);
            assert!(edit.in_transaction);
            assert_eq!(edit.session.txn, TxnState::InTransaction);
            let seen: String = sqlx::query_scalar(&format!("SELECT v FROM {t}")).fetch_one(&mut other).await.unwrap();
            assert_eq!(seen, "a", "the edit is visible before the commit");
            session_end_transaction(SessionEndTransactionRequest { session_id: TAB.into(), commit: true }, &state).await.unwrap();
            let seen: String = sqlx::query_scalar(&format!("SELECT v FROM {t}")).fetch_one(&mut other).await.unwrap();
            assert_eq!(seen, "c");
            other.execute(sqlx::raw_sql(&format!("DROP TABLE {t}"))).await.unwrap();
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_a_terminated_backend_is_reported_as_a_reset() {
        block_on(async {
            let state = live_state(false).await;
            statement(&state, "SET work_mem = '55MB'").await.unwrap();
            let pid: i32 = scalar(&state, "SELECT pg_backend_pid()::text").await.parse().unwrap();
            let mut other = other_user().await;
            other.execute(sqlx::raw_sql(&format!("SELECT pg_terminate_backend({pid})"))).await.unwrap();
            tokio::time::sleep(Duration::from_millis(2100)).await;
            let r = query(&state, "SHOW work_mem").await.expect("runs on a new connection");
            assert!(r.session.reset.is_some(), "the reset was not reported");
            assert_ne!(r.session.backend_pid, pid);
            assert_ne!(r.result.rows[0][0].as_str(), Some("55MB"), "settings of the old connection survived?");
            let again = query(&state, "SELECT 1").await.unwrap();
            assert!(again.session.reset.is_none(), "a reset is reported once");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_uses_the_tab_idle_in_transaction_limit() {
        block_on(async {
            let state = live_state(false).await;
            let mut settings = (*state.settings()).clone();
            settings.connections.tab_idle_in_transaction_seconds = 7;
            state.replace_settings(settings);
            assert_eq!(scalar(&state, "SHOW idle_in_transaction_session_timeout").await, "7s");
            assert_eq!(state.tab_session(TAB).unwrap().report().idle_in_transaction_timeout_seconds, 7);
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_the_per_server_limit_refuses_one_more_tab() {
        block_on(async {
            let state = live_state(false).await;
            let mut settings = (*state.settings()).clone();
            settings.connections.max_tab_sessions_per_connection = 2;
            state.replace_settings(settings);
            session_execute_query(card("a", "SELECT 1"), &state).await.unwrap();
            session_execute_query(card("b", "SELECT 1"), &state).await.unwrap();
            let refused = session_execute_query(card("c", "SELECT 1"), &state).await.unwrap_err();
            assert!(refused.starts_with(SESSION_LIMIT_MARKER), "{refused}");
            close_tab_session(&state, "a").await;
            session_execute_query(card("c", "SELECT 1"), &state).await.expect("room after a close");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_close_rolls_back() {
        block_on(async {
            let state = live_state(false).await;
            let t = table_name("close");
            let mut other = other_user().await;
            other.execute(sqlx::raw_sql(&format!("CREATE TABLE {t} (n int)"))).await.unwrap();
            statement(&state, "BEGIN").await.unwrap();
            statement(&state, &format!("INSERT INTO {t} VALUES (1)")).await.unwrap();
            let outcome = close_tab_session(&state, TAB).await.expect("closed");
            assert!(outcome.closed && outcome.had_open_transaction && outcome.rolled_back);
            let n: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {t}")).fetch_one(&mut other).await.unwrap();
            assert_eq!(n, 0);
            assert!(state.tab_session(TAB).is_none());
            other.execute(sqlx::raw_sql(&format!("DROP TABLE {t}"))).await.unwrap();
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_disconnect_closes_the_tabs_connections() {
        block_on(async {
            let state = live_state(false).await;
            query(&state, "SELECT 1").await.unwrap();
            crate::commands::disconnect_postgres(CONN.to_string(), &state).await.unwrap();
            assert!(state.tab_session(TAB).is_none());
            assert_eq!(state.tab_session_count(CONN), 0);
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_read_only_refuses_the_bypass() {
        block_on(async {
            let state = live_state(true).await;
            let refused = statement(&state, "SET default_transaction_read_only = off").await.unwrap_err();
            assert!(refused.starts_with(crate::commands::query::READ_ONLY_MARKER), "{refused}");
            assert_eq!(scalar(&state, "SHOW default_transaction_read_only").await, "on");
            // The server refuses the write itself (even a temp table's
            // catalogue write), with the marker Swift reads.
            let t = table_name("ro");
            let real = statement(&state, &format!("CREATE TABLE {t} (n int)")).await.unwrap_err();
            assert!(real.contains("25006"), "{real}");
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_runs_in_the_order_asked_and_a_waiting_card_can_be_cancelled() {
        block_on(async {
            let state = live_state(false).await;
            query(&state, "SELECT 1").await.unwrap();
            let mut slow = card(TAB, "SELECT pg_sleep(1)");
            slow.target.query_id = Some("first".into());
            let mut waiting = card(TAB, "SELECT 2");
            waiting.target.query_id = Some("second".into());
            let session = state.tab_session(TAB).unwrap();
            let watch = async {
                tokio::time::sleep(Duration::from_millis(300)).await;
                assert_eq!(session.report().waiting, 1, "the second card is not waiting");
                state.mark_query_cancelled("second");
            };
            let (a, b, _) = tokio::join!(session_execute_query(slow, &state), session_execute_query(waiting, &state), watch);
            assert!(a.is_ok());
            assert_eq!(b.unwrap_err(), QUERY_CANCELLED);
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_tab_session_refuses_copy_and_meta_commands_without_breaking() {
        block_on(async {
            let state = live_state(false).await;
            assert!(statement(&state, "COPY (SELECT 1) TO STDOUT").await.is_err());
            assert!(statement(&state, "\\dt").await.is_err());
            assert_eq!(scalar(&state, "SELECT 3").await, "3");
        });
    }
}
