use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// DuckDB
// ---------------------------------------------------------------------------

/// Connect a DuckDB record READ-ONLY, for this connect only: the "Open
/// Read-Only" answer to a lock held by another process. Returns
/// `ConnectionInfo` JSON via callback, as `pharos_connect` does.
#[no_mangle]
pub extern "C" fn pharos_connect_read_only(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        state.request_duck_read_only_once(&id);
        match crate::commands::connect_postgres(id, state).await {
            Ok(info) => callback_ok(callback, ctx, &serde_json::to_string(&info).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Connect a DuckDB record and, for this connect only, create its file when
/// it is missing: File ▸ New DuckDB Database…, Save of a new record in the
/// Connections Manager, and the missing-file alert's Create Empty Database.
/// Every other connect refuses a missing file (`MISSING_MARKER`). Returns
/// `ConnectionInfo` JSON via callback, as `pharos_connect` does.
#[no_mangle]
pub extern "C" fn pharos_connect_create(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        state.request_duck_create_once(&id);
        match crate::commands::connect_postgres(id, state).await {
            Ok(info) => callback_ok(callback, ctx, &serde_json::to_string(&info).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// The editor's DuckDB vocabulary for a connected record:
/// `{"keywords": [...], "functions": [...]}` via callback.
#[no_mangle]
pub extern "C" fn pharos_duckdb_vocabulary(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::duck::vocabulary(id, state).await {
            Ok((keywords, functions)) => {
                let json = serde_json::json!({ "keywords": keywords, "functions": functions });
                callback_ok(callback, ctx, &json.to_string());
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Export a query to Parquet with DuckDB's own writer.
/// `options_json`: `{"sql": "...", "schema": "main" | null, "filePath": "/abs/x.parquet", "queryId": "…" | null}`.
/// Returns `ExportTableResult` JSON via callback.
#[no_mangle]
pub extern "C" fn pharos_export_parquet(
    connection_id: *const c_char,
    options_json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let json = unsafe { c_str_to_string(options_json) };
    let ctx = context as usize;

    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Options {
        sql: String,
        #[serde(default)]
        schema: Option<String>,
        file_path: String,
        /// Makes the export cancellable through `pharos_cancel_query`.
        #[serde(default)]
        query_id: Option<String>,
    }

    ffi_spawn!(callback, context, async move {
        let options: Options = match serde_json::from_str(&json) {
            Ok(o) => o,
            Err(e) => return callback_err(callback, ctx, &format!("Invalid options: {}", e)),
        };
        match crate::commands::duck::export_parquet(id, options.sql, options.schema, options.file_path, options.query_id, state).await {
            Ok(result) => callback_ok(callback, ctx, &serde_json::to_string(&result).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// The DuckDB library version Pharos links, e.g. `"v1.5.6"`, as a JSON
/// string. Free with `pharos_free_string`.
#[no_mangle]
pub extern "C" fn pharos_duckdb_version() -> *mut c_char {
    ffi_sync!(to_json_c_string(&crate::db::duckdb::duckdb_version()))
}

/// The progress of a running query, read without waiting:
/// `{"percentage": 42.0 | null, "rowsProcessed": n, "totalRows": n}`, or `null`
/// when the query is not running, its engine reports no progress (PostgreSQL),
/// or the engine has no estimate yet. Poll it while a card runs. Free the
/// result with `pharos_free_string`.
#[no_mangle]
pub extern "C" fn pharos_query_progress(query_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let id = unsafe { c_str_to_string(query_id) };
        let progress = APP_STATE.get().and_then(|state| state.query_progress(&id));
        let json = match progress {
            Some(p) => serde_json::json!({
                "percentage": p.percentage,
                "rowsProcessed": p.rows_processed,
                "totalRows": p.total_rows_to_process,
            }),
            None => serde_json::Value::Null,
        };
        to_c_string(&json.to_string())
    })
}

/// Attach a connected PostgreSQL connection to an open DuckDB database
/// (`commands::duck_attach`). `alias` empty = a default from the connection's
/// name. The password goes into a temporary DuckDB secret, never into SQL a
/// user sees or history keeps. Returns `AttachmentInfo` JSON via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_attach_postgres(
    duck_connection_id: *const c_char,
    pg_connection_id: *const c_char,
    alias: *const c_char,
    read_only: bool,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let duck_id = unsafe { c_str_to_string(duck_connection_id) };
    let pg_id = unsafe { c_str_to_string(pg_connection_id) };
    let alias = unsafe { c_str_to_string(alias) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let alias = if alias.trim().is_empty() { None } else { Some(alias) };
        match crate::commands::duck_attach::attach_postgres(duck_id, pg_id, alias, read_only, state).await {
            Ok(info) => callback_ok(callback, ctx, &serde_json::to_string(&info).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Detach a PostgreSQL connection Pharos attached to a DuckDB database.
/// Returns `null` via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_detach(
    duck_connection_id: *const c_char,
    alias: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let duck_id = unsafe { c_str_to_string(duck_connection_id) };
    let alias = unsafe { c_str_to_string(alias) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::duck_attach::detach(duck_id, alias, state).await {
            Ok(()) => callback_ok(callback, ctx, "null"),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// The PostgreSQL connections attached to a DuckDB database:
/// `[AttachmentInfo]` JSON via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_attachments(
    duck_connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let duck_id = unsafe { c_str_to_string(duck_connection_id) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::duck_attach::list(&duck_id, state) {
            Ok(list) => callback_ok(callback, ctx, &serde_json::to_string(&list).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
