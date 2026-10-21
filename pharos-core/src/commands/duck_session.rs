//! One DuckDB connection per editor tab: the DuckDB side of `tab_session`.
//!
//! The same contract as the PostgreSQL tab session, as far as DuckDB allows:
//! every card of a tab runs on its tab's connection, one at a time, in the
//! order the cards were run, so a `SET`, a temp table or a `BEGIN … COMMIT`
//! carries from card to card. The reports and results have the same JSON
//! shape, so Swift's `TabSessionMonitor` and the cards need no second path.
//!
//! What differs, because DuckDB has no such thing:
//! - no savepoints: a card that fails or is cancelled inside an open
//!   transaction leaves it failed (DuckDB aborts it), and the banner's Roll
//!   Back ends it;
//! - no server-side idle-in-transaction limit: the report's limit is 0;
//! - no backend PID: cancel is `duckdb_interrupt` on the tab's connection.
//!
//! A parser or binder error does NOT abort DuckDB's transaction; an error
//! while a statement runs does. The state after every operation is read
//! from DuckDB itself (`exec::probe_transaction`), never guessed.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Instant;

use duckdb::{Connection, InterruptHandle, ProgressHandle};

use super::query::{history_entry, query_timeout_seconds, record_history, result_cache, ExecuteResult, QueryResult, QUERY_CANCELLED};
use super::tab_session::{
    CloseOutcome, SessionEndTransactionResult, SessionExecuteResult, SessionExplainResult, SessionQueryResult,
    SessionReport, SessionReset, SessionRunRequest, SessionTarget, TxnState, SESSION_LIMIT_MARKER,
};
use crate::db::duckdb::exec::{self, probe_transaction, run_cancellable, RunStop, TxnProbe};
use crate::state::{AppState, QueryCancel};

/// One editor tab's DuckDB connection, and the queue in front of it.
pub struct DuckSession {
    pub id: String,
    pub connection_id: String,
    /// Fair (FIFO): operations run in the order they were asked for.
    live: tokio::sync::Mutex<Option<Live>>,
    report: StdMutex<SessionReport>,
    waiting: AtomicUsize,
    closing: AtomicBool,
}

struct Live {
    conn: Arc<StdMutex<Connection>>,
    interrupt: Arc<InterruptHandle>,
    /// Taken at open, beside the interrupt: `run_on` holds `conn` for the
    /// whole query, so nothing could reach the connection to ask later.
    progress: Arc<ProgressHandle>,
    /// The schema the toolbar last set; None until it sets one.
    schema: Option<String>,
    txn: TxnState,
    txn_since: Option<Instant>,
}

impl DuckSession {
    fn new(id: &str, connection_id: &str) -> DuckSession {
        DuckSession {
            id: id.to_string(),
            connection_id: connection_id.to_string(),
            live: tokio::sync::Mutex::new(None),
            report: StdMutex::new(SessionReport {
                session_id: id.to_string(),
                connection_id: connection_id.to_string(),
                open: false,
                generation: 0,
                backend_pid: 0,
                txn: TxnState::Idle,
                txn_elapsed_seconds: None,
                idle_in_transaction_timeout_seconds: 0,
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

// MARK: - Registry

impl AppState {
    pub fn duck_session(&self, id: &str) -> Option<Arc<DuckSession>> {
        self.duck_sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    fn insert_duck_session(&self, session: Arc<DuckSession>) {
        self.duck_sessions.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone(), session);
    }

    fn remove_duck_session(&self, id: &str) -> Option<Arc<DuckSession>> {
        self.duck_sessions.lock().unwrap_or_else(|e| e.into_inner()).remove(id)
    }

    fn duck_session_ids(&self, connection_id: &str) -> Vec<String> {
        self.duck_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .filter(|s| s.connection_id == connection_id)
            .map(|s| s.id.clone())
            .collect()
    }

    fn duck_session_count(&self, connection_id: &str) -> usize {
        self.duck_session_ids(connection_id).len()
    }
}

/// The session for an editor tab, made when it has none. A tab that moved to
/// another connection gets its old session (of either engine) closed.
async fn session_for(state: &AppState, session_id: &str, connection_id: &str) -> Result<Arc<DuckSession>, String> {
    if let Some(s) = state.duck_session(session_id) {
        if s.connection_id == connection_id {
            return Ok(s);
        }
    }
    super::tab_session::close_tab_session(state, session_id).await;
    state.require_duck(connection_id)?;
    let cap = state.settings().connections.max_tab_sessions_per_connection as usize;
    if cap > 0 && state.duck_session_count(connection_id) >= cap {
        return Err(format!(
            "{} This database already has {} editor-tab connections open (Settings ▸ Connections). \
             Close a tab, or raise the limit.",
            SESSION_LIMIT_MARKER, cap
        ));
    }
    let session = Arc::new(DuckSession::new(session_id, connection_id));
    state.insert_duck_session(session.clone());
    Ok(session)
}

/// Close a tab's DuckDB connection, rolling back an open transaction.
pub async fn close_duck_session(state: &AppState, session_id: &str) -> Option<CloseOutcome> {
    let session = state.remove_duck_session(session_id)?;
    session.closing.store(true, Ordering::Relaxed);
    let guard = tokio::time::timeout(std::time::Duration::from_secs(2), session.live.lock()).await;
    let Ok(mut guard) = guard else {
        return Some(CloseOutcome { closed: false, had_open_transaction: false, rolled_back: false });
    };
    let Some(live) = guard.take() else {
        return Some(CloseOutcome { closed: true, had_open_transaction: false, rolled_back: false });
    };
    let had = matches!(live.txn, TxnState::InTransaction | TxnState::Failed);
    let conn = live.conn.clone();
    let rolled_back = tokio::task::spawn_blocking(move || {
        let c = conn.lock().unwrap_or_else(|e| e.into_inner());
        had && c.execute_batch("ROLLBACK").is_ok()
    })
    .await
    .unwrap_or(false);
    Some(CloseOutcome { closed: true, had_open_transaction: had, rolled_back })
}

/// Close every DuckDB tab session of a connection.
pub async fn close_duck_sessions_for_connection(state: &AppState, connection_id: &str) {
    for id in state.duck_session_ids(connection_id) {
        close_duck_session(state, &id).await;
    }
}

/// Every DuckDB tab session, for shutdown: dropping a connection rolls back
/// its open transaction, so no commit can happen on the way out.
pub fn drop_all_duck_sessions(state: &AppState) {
    let sessions: Vec<_> = state.duck_sessions.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, s)| s).collect();
    for s in sessions {
        s.closing.store(true, Ordering::Relaxed);
    }
}

// MARK: - The operation frame

async fn lock_or_cancel<'a>(
    session: &'a DuckSession,
    cancel: &QueryCancel,
) -> Result<tokio::sync::MutexGuard<'a, Option<Live>>, String> {
    session.waiting.fetch_add(1, Ordering::Relaxed);
    let result = tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(QUERY_CANCELLED.to_string()),
        guard = session.live.lock() => Ok(guard),
    };
    session.waiting.fetch_sub(1, Ordering::Relaxed);
    result
}

/// Open the tab's connection at its first operation. A DuckDB connection
/// cannot go half-open like a socket, so there is no ping.
fn ensure_live(guard: &mut Option<Live>, session: &DuckSession, state: &AppState) -> Result<Option<SessionReset>, String> {
    if guard.is_some() {
        return Ok(None);
    }
    let instance = state.require_duck(&session.connection_id)?;
    let conn = instance.connect()?;
    let interrupt = conn.interrupt_handle();
    let progress = conn.progress_handle();
    *guard = Some(Live { conn: Arc::new(StdMutex::new(conn)), interrupt, progress, schema: None, txn: TxnState::Idle, txn_since: None });
    let mut r = session.report.lock().unwrap_or_else(|e| e.into_inner());
    r.generation += 1;
    // A first open is not a reset; a reopen after the connection was lost
    // would be, but a DuckDB connection is only replaced when its database
    // was reconnected, and the tab then gets a new session.
    Ok(None)
}

/// The toolbar's schema for this tab, sent only when it changes, so a
/// user's own `SET search_path` card stays in force until then.
fn schema_sql(schema: &str) -> String {
    let escaped = schema.replace('\'', "''");
    if schema == "main" {
        "SET search_path = 'main'".to_string()
    } else {
        format!("SET search_path = '{},main'", escaped)
    }
}

/// Run `work` on the tab's connection, stoppable by cancel and the query
/// timeout. The toolbar schema is applied first when it changed.
async fn run_on<T, F>(live: &mut Live, schema: Option<&str>, cancel: &QueryCancel, state: &AppState, work: F) -> Result<T, RunStop>
where
    T: Send + 'static,
    F: FnOnce(&Connection) -> Result<T, String> + Send + 'static,
{
    let set_schema = match schema {
        Some(s) if !s.is_empty() && live.schema.as_deref() != Some(s) => Some(s.to_string()),
        _ => None,
    };
    let conn = live.conn.clone();
    let applied = set_schema.clone();
    let result = run_cancellable(live.interrupt.clone(), cancel, query_timeout_seconds(state), move || {
        let c = conn.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(s) = &applied {
            // A schema that no longer exists must not block the card.
            if let Err(e) = c.execute_batch(&schema_sql(s)) {
                log::warn!("DuckDB: could not set search_path to {}: {}", s, e);
            }
        }
        work(&c)
    })
    .await;
    if let Some(s) = set_schema {
        live.schema = Some(s);
    }
    result
}

/// Read the transaction state from DuckDB and publish the report.
async fn finish(guard: &mut Option<Live>, session: &DuckSession, state: &AppState) -> SessionReport {
    let read_only = state.get_config(&session.connection_id).map(|c| c.read_only).unwrap_or(false)
        || state.get_duck(&session.connection_id).map(|d| d.read_only).unwrap_or(false);
    if let Some(live) = guard.as_mut() {
        let conn = live.conn.clone();
        let probe = tokio::task::spawn_blocking(move || {
            let c = conn.lock().unwrap_or_else(|e| e.into_inner());
            probe_transaction(&c)
        })
        .await
        .unwrap_or(TxnProbe::Unknown);
        let txn = match probe {
            TxnProbe::Idle => TxnState::Idle,
            TxnProbe::Open => TxnState::InTransaction,
            TxnProbe::Failed => TxnState::Failed,
            TxnProbe::Unknown => TxnState::Unknown,
        };
        if txn == TxnState::Idle {
            live.txn_since = None;
        } else if live.txn_since.is_none() {
            live.txn_since = Some(Instant::now());
        }
        live.txn = txn;
        let mut r = session.report.lock().unwrap_or_else(|e| e.into_inner());
        r.open = true;
        r.txn = txn;
        r.txn_elapsed_seconds = live.txn_since.map(|t| t.elapsed().as_secs_f64());
        r.read_only = read_only;
        r.reset = None;
    }
    if session.closing.load(Ordering::Relaxed) {
        // Dropping the connection rolls back whatever it held.
        *guard = None;
    }
    session.report()
}

const FAILED_TRANSACTION: &str = "The transaction failed. Roll it back first.";

/// psql-only input and an empty card, refused before anything runs.
fn refusal_before_send(sql: &str) -> Option<String> {
    use super::sql_lexer::{is_blank_or_comment, split_chunks, ChunkKind};
    if sql.trim().is_empty() || is_blank_or_comment(sql) {
        return Some("The card holds no statement.".to_string());
    }
    for chunk in split_chunks(sql) {
        match chunk.kind {
            ChunkKind::PsqlMeta => return Some("psql meta-commands (\\…) do not run on DuckDB.".to_string()),
            ChunkKind::CopyData => return Some("COPY … FROM STDIN is not supported by DuckDB. Use Import instead.".to_string()),
            ChunkKind::Statement => {}
        }
    }
    None
}

// MARK: - Operations

pub async fn execute_query(request: SessionRunRequest, state: &AppState) -> Result<SessionQueryResult, String> {
    let t = &request.target;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let limit = request.limit.unwrap_or(1000) as usize;
    let start = Instant::now();
    if let Some(refusal) = refusal_before_send(&request.sql) {
        return Err(refusal);
    }

    let mut guard = lock_or_cancel(&session, &cancel).await?;
    ensure_live(&mut guard, &session, state)?;
    if let Some(live) = guard.as_ref() {
        registered.attach_progress(live.progress.clone());
    }
    let outcome = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        if request.aux && live.txn == TxnState::Failed {
            Err(RunStop::Failed(FAILED_TRANSACTION.to_string()))
        } else {
            let sql = request.sql.clone();
            run_on(live, t.schema.as_deref(), &cancel, state, move |c| exec::query_text(c, &sql, Some(limit), 0)).await
        }
    };
    drop(registered);
    let report = finish(&mut guard, &session, state).await;
    drop(guard);
    let rows = outcome.map_err(RunStop::message)?;
    let execution_time_ms = start.elapsed().as_millis() as u64;
    let row_count = rows.rows.len();
    let history_entry_id = if request.aux {
        None
    } else {
        let entry = history_entry(state, &t.connection_id, &request.sql, &t.schema, request.source.clone(),
                                  row_count as i64, execution_time_ms, Some(rows.columns.len() as i64));
        record_history(state, &entry, result_cache(&rows.columns, &rows.rows, None));
        Some(entry.id)
    };
    Ok(SessionQueryResult {
        result: QueryResult {
            columns: rows.columns,
            rows: rows.rows,
            row_count,
            execution_time_ms,
            has_more: rows.has_more,
            history_entry_id,
            row_identity: None,
        },
        session: report,
    })
}

pub async fn execute_statement(request: SessionRunRequest, state: &AppState) -> Result<SessionExecuteResult, String> {
    let t = &request.target;
    let session = session_for(state, &t.session_id, &t.connection_id).await?;
    let query_id = t.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let start = Instant::now();
    if let Some(refusal) = refusal_before_send(&request.sql) {
        return Err(refusal);
    }

    let mut guard = lock_or_cancel(&session, &cancel).await?;
    ensure_live(&mut guard, &session, state)?;
    if let Some(live) = guard.as_ref() {
        registered.attach_progress(live.progress.clone());
    }
    let outcome = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        let sql = request.sql.clone();
        run_on(live, t.schema.as_deref(), &cancel, state, move |c| exec::execute_text(c, &sql)).await
    };
    drop(registered);
    let report = finish(&mut guard, &session, state).await;
    drop(guard);
    let rows_affected = outcome.map_err(RunStop::message)?;
    let execution_time_ms = start.elapsed().as_millis() as u64;
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

/// Load More: the next page of the card's LAST statement, re-run with an
/// OFFSET on the tab's connection (it sees the tab's temp tables).
pub async fn fetch_more_rows(target: SessionTarget, sql: String, limit: i64, offset: i64, state: &AppState)
                             -> Result<SessionQueryResult, String> {
    paged(target, sql, Some(limit.max(1) as usize), offset.max(0) as usize, state, |_| {}).await
}

/// Load All: every row of the card's last statement, up to `max_rows`.
pub async fn fetch_all_rows(target: SessionTarget, sql: String, max_rows: i64, state: &AppState,
                            on_progress: impl Fn(u64) + Send) -> Result<SessionQueryResult, String> {
    paged(target, sql, Some(max_rows.max(1) as usize), 0, state, on_progress).await
}

async fn paged(target: SessionTarget, sql: String, limit: Option<usize>, offset: usize, state: &AppState,
               on_progress: impl Fn(u64) + Send) -> Result<SessionQueryResult, String> {
    let session = session_for(state, &target.session_id, &target.connection_id).await?;
    let query_id = target.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let start = Instant::now();
    let statement = exec::statements(&sql).pop().ok_or_else(|| "The card holds no statement.".to_string())?;

    let mut guard = lock_or_cancel(&session, &cancel).await?;
    ensure_live(&mut guard, &session, state)?;
    if let Some(live) = guard.as_ref() {
        registered.attach_progress(live.progress.clone());
    }
    let outcome = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        if live.txn == TxnState::Failed {
            Err(RunStop::Failed(FAILED_TRANSACTION.to_string()))
        } else {
            run_on(live, target.schema.as_deref(), &cancel, state, move |c| exec::rows_of(c, &statement, limit, offset)).await
        }
    };
    drop(registered);
    let report = finish(&mut guard, &session, state).await;
    drop(guard);
    let rows = outcome.map_err(RunStop::message)?;
    on_progress(rows.rows.len() as u64);
    let row_count = rows.rows.len();
    Ok(SessionQueryResult {
        result: QueryResult {
            columns: rows.columns,
            rows: rows.rows,
            row_count,
            execution_time_ms: start.elapsed().as_millis() as u64,
            has_more: rows.has_more,
            history_entry_id: None,
            row_identity: None,
        },
        session: report,
    })
}

/// EXPLAIN as a plan for the plan view (`exec::explain_plan_json`). EXPLAIN
/// ANALYZE runs the statement: when
/// the tab is idle it runs inside Pharos's own transaction, rolled back.
pub async fn explain(target: SessionTarget, sql: String, analyze: bool, state: &AppState) -> Result<SessionExplainResult, String> {
    let statement = super::query::single_statement(&sql)?;
    let session = session_for(state, &target.session_id, &target.connection_id).await?;
    let query_id = target.query_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let registered = state.register_query(query_id);
    let cancel = registered.cancel.clone();
    let mut guard = lock_or_cancel(&session, &cancel).await?;
    ensure_live(&mut guard, &session, state)?;
    if let Some(live) = guard.as_ref() {
        registered.attach_progress(live.progress.clone());
    }
    let outcome = {
        let live = guard.as_mut().expect("ensure_live leaves a connection");
        match live.txn {
            TxnState::Failed => Err(RunStop::Failed(FAILED_TRANSACTION.to_string())),
            txn => {
                let wrap = analyze && txn == TxnState::Idle;
                run_on(live, target.schema.as_deref(), &cancel, state, move |c| {
                    if wrap {
                        c.execute_batch("BEGIN").map_err(|e| e.to_string())?;
                    }
                    let plan = exec::explain_plan_json(c, &statement, analyze);
                    if wrap {
                        let _ = c.execute_batch("ROLLBACK");
                    }
                    plan
                })
                .await
            }
        }
    };
    drop(registered);
    let report = finish(&mut guard, &session, state).await;
    outcome.map(|plan| SessionExplainResult { plan, session: report }).map_err(RunStop::message)
}

/// Validate a card without running it: `prepare` binds the statement and
/// executes nothing. Only the FIRST statement is checked, because a later
/// one may name a table an earlier one creates. Skipped (valid) while the
/// tab's connection is busy, as on PostgreSQL.
pub async fn validate_sql(target: SessionTarget, sql: String, state: &AppState) -> Result<super::query::ValidationResult, String> {
    let valid = super::query::ValidationResult { valid: true, error: None };
    let Some(first) = exec::statements(&sql).into_iter().next() else { return Ok(valid) };
    let session = state.duck_session(&target.session_id).filter(|s| s.connection_id == target.connection_id);
    let conn: Arc<StdMutex<Connection>> = match &session {
        Some(s) => {
            let Ok(guard) = s.live.try_lock() else { return Ok(valid) };
            match guard.as_ref() {
                Some(live) if live.txn != TxnState::Failed => live.conn.clone(),
                Some(_) => return Ok(valid),
                None => Arc::new(StdMutex::new(state.require_duck(&target.connection_id)?.connect()?)),
            }
        }
        None => Arc::new(StdMutex::new(state.require_duck(&target.connection_id)?.connect()?)),
    };
    let schema = target.schema.clone();
    let fresh = session.is_none();
    let outcome = tokio::task::spawn_blocking(move || {
        let c = conn.lock().unwrap_or_else(|e| e.into_inner());
        if fresh {
            if let Some(s) = schema.filter(|s| !s.is_empty()) {
                let _ = c.execute_batch(&schema_sql(&s));
            }
        }
        c.prepare(&first).map(|_| ()).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?;
    Ok(match outcome {
        Ok(()) => valid,
        Err(message) => validation_failure(&sql, &message),
    })
}

/// A DuckDB error as a validation result. DuckDB puts the position in the
/// message (`LINE 2: …` and a caret line under the quoted text).
pub fn validation_failure(sql: &str, message: &str) -> super::query::ValidationResult {
    let (line, column) = match error_line_column(message) {
        Some((l, c)) => (Some(l), Some(c)),
        None => (None, None),
    };
    let position = match (line, column) {
        (Some(l), Some(c)) => {
            let leading = sql.len() - sql.trim_start().len();
            let line_start: usize = sql.trim_start().split('\n').take(l - 1).map(|s| s.chars().count() + 1).sum();
            Some(leading + line_start + c)
        }
        _ => None,
    };
    super::query::ValidationResult {
        valid: false,
        error: Some(super::query::ValidationError {
            message: message.lines().next().unwrap_or(message).trim().to_string(),
            position,
            line,
            column,
        }),
    }
}

/// `(line, column)`, both 1-based, from DuckDB's `LINE n: <text>` and caret
/// lines. None when the quoted text was cut (it starts with `...`).
pub fn error_line_column(message: &str) -> Option<(usize, usize)> {
    let lines: Vec<&str> = message.lines().collect();
    let at = lines.iter().position(|l| l.starts_with("LINE "))?;
    let label_end = lines[at].find(": ")? + 2;
    let line: usize = lines[at][5..label_end - 2].trim().parse().ok()?;
    if lines[at][label_end..].starts_with("...") {
        return Some((line, 1));
    }
    let caret = lines.get(at + 1)?.find('^')?;
    Some((line, caret.saturating_sub(label_end) + 1))
}

/// The banner's Commit and Roll Back.
pub async fn end_transaction(session_id: &str, commit: bool, state: &AppState) -> Result<SessionEndTransactionResult, String> {
    let session = state.duck_session(session_id).ok_or_else(|| "The tab has no connection of its own.".to_string())?;
    let mut guard = session.live.lock().await;
    let outcome = match guard.as_mut() {
        None => Err("The tab's connection is gone; there is no transaction to end.".to_string()),
        Some(live) => {
            let was_failed = live.txn == TxnState::Failed;
            // DuckDB refuses COMMIT of an aborted transaction; it rolls back.
            let sql = if commit && !was_failed { "COMMIT" } else { "ROLLBACK" };
            let conn = live.conn.clone();
            tokio::task::spawn_blocking(move || {
                let c = conn.lock().unwrap_or_else(|e| e.into_inner());
                c.execute_batch(sql).map_err(|e| e.to_string())
            })
            .await
            .map_err(|e| e.to_string())?
            .map(|_| (commit && !was_failed, !commit || was_failed))
        }
    };
    let report = finish(&mut guard, &session, state).await;
    let (committed, rolled_back) = outcome?;
    Ok(SessionEndTransactionResult { committed, rolled_back, session: report })
}

/// For `HashMap` users outside this module.
pub type DuckSessionMap = HashMap<String, Arc<DuckSession>>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::duckdb::{DuckDbInstance, OpenOptions, IN_MEMORY};
    use crate::models::{ConnectionConfig, Engine};

    fn state_with_duck(id: &str) -> AppState {
        let sqlite = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::sqlite::create_schema(&sqlite).unwrap();
        let state = AppState::new(sqlite);
        let mut config: ConnectionConfig = serde_json::from_value(serde_json::json!({
            "id": id, "name": "duck", "host": "", "port": 0, "database": IN_MEMORY, "username": "", "engine": "duckdb"
        }))
        .unwrap();
        config.engine = Engine::Duckdb;
        state.set_config(config);
        let instance = DuckDbInstance::open(IN_MEMORY, false, &OpenOptions::default()).unwrap();
        state.add_duck(id.to_string(), Arc::new(instance));
        state
    }

    fn run(session: &str, sql: &str) -> SessionRunRequest {
        serde_json::from_value(serde_json::json!({
            "sessionId": session, "connectionId": "d1", "sql": sql, "limit": 2
        }))
        .unwrap()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_tab_keeps_its_session_state_across_cards() {
        let state = state_with_duck("d1");
        execute_statement(run("tab", "CREATE TEMP TABLE t AS SELECT range AS x FROM range(5)"), &state).await.unwrap();
        let r = execute_query(run("tab", "SELECT x FROM t ORDER BY x"), &state).await.unwrap();
        assert_eq!(r.result.row_count, 2);
        assert!(r.result.has_more);
        assert_eq!(r.result.columns[0].data_type, "BIGINT");
        assert!(r.result.history_entry_id.is_some());
        // Another tab has its own connection: the temp table is not there.
        assert!(execute_query(run("other", "SELECT * FROM t"), &state).await.is_err());
        let target: SessionTarget = serde_json::from_value(serde_json::json!({"sessionId": "tab", "connectionId": "d1"})).unwrap();
        let more = fetch_more_rows(target.clone(), "SELECT x FROM t ORDER BY x".into(), 2, 2, &state).await.unwrap();
        assert_eq!(more.result.rows, vec![serde_json::json!(["2"]), serde_json::json!(["3"])]);
        let all = fetch_all_rows(target, "SELECT x FROM t ORDER BY x".into(), 100, &state, |_| {}).await.unwrap();
        assert_eq!(all.result.row_count, 5);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_report_follows_the_transaction() {
        let state = state_with_duck("d1");
        execute_statement(run("tab", "CREATE TABLE t(a INT PRIMARY KEY)"), &state).await.unwrap();
        let r = execute_statement(run("tab", "BEGIN"), &state).await.unwrap();
        assert_eq!(r.session.txn, TxnState::InTransaction);
        assert_eq!(r.session.idle_in_transaction_timeout_seconds, 0);
        execute_statement(run("tab", "INSERT INTO t VALUES (1)"), &state).await.unwrap();
        assert!(execute_statement(run("tab", "INSERT INTO t VALUES (1)"), &state).await.is_err());
        assert_eq!(state.duck_session("tab").unwrap().report().txn, TxnState::Failed);
        let end = end_transaction("tab", true, &state).await.unwrap();
        assert!(end.rolled_back && !end.committed);
        assert_eq!(end.session.txn, TxnState::Idle);
        execute_statement(run("tab", "BEGIN"), &state).await.unwrap();
        execute_statement(run("tab", "INSERT INTO t VALUES (2)"), &state).await.unwrap();
        let end = end_transaction("tab", true, &state).await.unwrap();
        assert!(end.committed);
        let r = execute_query(run("tab", "SELECT count(*) FROM t"), &state).await.unwrap();
        assert_eq!(r.result.rows, vec![serde_json::json!(["1"])]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn closing_a_tab_rolls_back() {
        let state = state_with_duck("d1");
        execute_statement(run("tab", "CREATE TABLE t(a INT)"), &state).await.unwrap();
        execute_statement(run("tab", "BEGIN; INSERT INTO t VALUES (1)"), &state).await.unwrap();
        let out = close_duck_session(&state, "tab").await.unwrap();
        assert!(out.had_open_transaction && out.rolled_back);
        let r = execute_query(run("tab2", "SELECT count(*) FROM t"), &state).await.unwrap();
        assert_eq!(r.result.rows, vec![serde_json::json!(["0"])]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_toolbar_schema_is_the_search_path() {
        let state = state_with_duck("d1");
        execute_statement(run("tab", "CREATE SCHEMA s; CREATE TABLE s.only_here(v INT); INSERT INTO s.only_here VALUES (7)"), &state)
            .await
            .unwrap();
        let mut req = run("tab", "SELECT v FROM only_here");
        req.target.schema = Some("s".into());
        let r = execute_query(req, &state).await.unwrap();
        assert_eq!(r.result.rows, vec![serde_json::json!(["7"])]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn psql_input_is_refused_and_explain_is_text() {
        let state = state_with_duck("d1");
        assert!(execute_query(run("tab", "\\dt"), &state).await.unwrap_err().contains("psql"));
        let target: SessionTarget = serde_json::from_value(serde_json::json!({"sessionId": "tab", "connectionId": "d1"})).unwrap();
        let plan = explain(target, "SELECT 1".into(), false, &state).await.unwrap();
        assert!(plan.plan.starts_with("[{\"Plan\""), "{}", plan.plan);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn validation_reports_duckdbs_position() {
        let state = state_with_duck("d1");
        let target: SessionTarget = serde_json::from_value(serde_json::json!({"sessionId": "tab", "connectionId": "d1"})).unwrap();
        let ok = validate_sql(target.clone(), "SELECT 1; SELECT * FROM made_by_the_first".into(), &state).await.unwrap();
        assert!(ok.valid);
        let bad = validate_sql(target, "SELECT 1,\n  nope FROM range(1)".into(), &state).await.unwrap();
        let e = bad.error.expect("an error");
        assert!(e.message.contains("Binder Error"), "{}", e.message);
        assert_eq!(e.line, Some(2), "{:?}", e);
        assert_eq!(e.column, Some(3), "{:?}", e);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_write_on_a_read_only_database_fails_and_returns() {
        let path = std::env::temp_dir().join(format!("pharos_ro_{}.duckdb", uuid::Uuid::new_v4()));
        let path = path.to_string_lossy().to_string();
        {
            let rw = DuckDbInstance::open(&path, false, &OpenOptions::default()).unwrap();
            rw.connect().unwrap().execute_batch("CREATE TABLE t(a INT)").unwrap();
        }
        let state = state_with_duck("d1");
        state.add_duck("d1".into(), Arc::new(DuckDbInstance::open(&path, true, &OpenOptions::default()).unwrap()));
        let done = tokio::time::timeout(std::time::Duration::from_secs(10),
                                        execute_statement(run("tab", "INSERT INTO t VALUES (1)"), &state)).await;
        let result = done.expect("the call must return, not hang");
        let err = result.unwrap_err();
        assert!(err.to_lowercase().contains("read-only") || err.to_lowercase().contains("read only"), "{err}");
        assert!(err.starts_with(crate::commands::query::READ_ONLY_MARKER), "tagged like PostgreSQL's 25006: {err}");
        let again = tokio::time::timeout(std::time::Duration::from_secs(10),
                                         execute_query(run("tab", "SELECT count(*) FROM t"), &state)).await;
        assert!(again.expect("a second call must not hang").is_ok());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn line_and_column_come_from_the_caret() {
        let msg = "Parser Error: syntax error at or near \"FORM\"\n\nLINE 1: SELECT 1 FORM t\n                 ^";
        assert_eq!(error_line_column(msg), Some((1, 10)));
        assert_eq!(error_line_column("Catalog Error: Table with name x does not exist!"), None);
    }
}
