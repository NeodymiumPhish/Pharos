//! FFI for the editor tabs' own connections (`commands::tab_session`).
//!
//! Every request is one camelCase JSON object, so a new field never changes
//! a C signature. Results are the pool's result types (snake_case fields, as
//! Swift already decodes them) plus a camelCase `session` report.

use std::os::raw::c_char;

use serde::Deserialize;

use super::*;
use crate::commands::tab_session::{
    self, SessionEndTransactionRequest, SessionExplainRequest, SessionFetchAllRequest, SessionFetchMoreRequest,
    SessionRowUpdateRequest, SessionRunRequest, SessionTarget,
};

/// Parse a request, or answer the callback with why it does not parse.
fn parse<T: for<'de> Deserialize<'de>>(json: *const c_char, callback: AsyncCallback, ctx: usize) -> Option<T> {
    let text = unsafe { c_str_to_string(json) };
    match serde_json::from_str::<T>(&text) {
        Ok(v) => Some(v),
        Err(e) => {
            callback_err(callback, ctx, &format!("Invalid session request: {}", e));
            None
        }
    }
}

fn answer<T: serde::Serialize>(callback: AsyncCallback, ctx: usize, result: Result<T, String>) {
    match result {
        Ok(value) => callback_ok(callback, ctx, &serde_json::to_string(&value).unwrap_or_default()),
        Err(e) => callback_err(callback, ctx, &e),
    }
}

/// Run a card's row-returning statement on its tab's connection.
/// Request: `{sessionId, connectionId, schema?, queryId?, sql, limit?, source?, aux?}`.
/// Result: QueryResult JSON plus `session`.
#[no_mangle]
pub extern "C" fn pharos_session_execute_query(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionRunRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_execute_query(request, state).await);
    });
}

/// Run a card's other statement on its tab's connection. Same request as
/// `pharos_session_execute_query`; result: ExecuteResult JSON plus `session`.
#[no_mangle]
pub extern "C" fn pharos_session_execute_statement(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionRunRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_execute_statement(request, state).await);
    });
}

/// Load More on the tab's connection.
/// Request: `{sessionId, connectionId, schema?, queryId?, sql, limit, offset}`.
#[no_mangle]
pub extern "C" fn pharos_session_fetch_more_rows(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionFetchMoreRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_fetch_more_rows(request, state).await);
    });
}

/// Load All on the tab's connection.
/// Request: `{sessionId, connectionId, schema?, queryId?, sql, maxRows}`.
#[no_mangle]
pub extern "C" fn pharos_session_fetch_all_rows(
    request_json: *const c_char,
    progress: ProgressCallback,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionFetchAllRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    let on_progress = move |rows_loaded: u64| {
        if let Some(cb) = progress {
            cb(ctx as *mut std::ffi::c_void, rows_loaded);
        }
    };
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_fetch_all_rows(request, state, on_progress).await);
    });
}

/// Explain a card on the tab's connection.
/// Request: `{sessionId, connectionId, schema?, queryId?, sql, analyze}`.
/// Result: `{plan, session}`, the plan being PostgreSQL's FORMAT JSON text.
#[no_mangle]
pub extern "C" fn pharos_session_explain(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionExplainRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_explain(request, state).await);
    });
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValidateRequest {
    #[serde(flatten)]
    target: SessionTarget,
    sql: String,
}

/// Validate a card on the tab's connection; never waits behind a run.
/// Request: `{sessionId, connectionId, schema?, sql}`. Result: ValidationResult.
#[no_mangle]
pub extern "C" fn pharos_session_validate_sql(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<ValidateRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_validate_sql(request.target, request.sql, state).await);
    });
}

/// Cell edits on the tab's connection.
/// Request: `{sessionId, connectionId, schema?, queryId?, request: RowUpdateRequest}`.
/// Result: RowUpdateResult plus `inTransaction` and `session`.
#[no_mangle]
pub extern "C" fn pharos_session_apply_row_updates(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionRowUpdateRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_apply_row_updates(request, state).await);
    });
}

/// The banner's Commit / Roll Back. Request: `{sessionId, commit}`.
/// Result: `{committed, rolledBack, session}`.
#[no_mangle]
pub extern "C" fn pharos_session_end_transaction(request_json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let Some(request) = parse::<SessionEndTransactionRequest>(request_json, callback, ctx) else { return };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        answer(callback, ctx, tab_session::session_end_transaction(request, state).await);
    });
}

/// Close a tab's connection: an open transaction is rolled back, never
/// committed. Result: `{closed, hadOpenTransaction, rolledBack}`, or `null`
/// when the tab had no connection.
#[no_mangle]
pub extern "C" fn pharos_tab_session_close(session_id: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void) {
    let ctx = context as usize;
    let id = unsafe { c_str_to_string(session_id) };
    let state = app_state();
    ffi_spawn!(callback, context, async move {
        let outcome = tab_session::close_tab_session(state, &id).await;
        callback_ok(callback, ctx, &serde_json::to_string(&outcome).unwrap_or_else(|_| "null".into()));
    });
}

/// A tab connection's last report (synchronous). Returns the report JSON, or
/// `null` when the tab has no connection. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_tab_session_state(session_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let id = unsafe { c_str_to_string(session_id) };
        let report = APP_STATE.get().and_then(|state| state.tab_session(&id)).map(|s| s.report());
        to_json_c_string(&report)
    })
}
