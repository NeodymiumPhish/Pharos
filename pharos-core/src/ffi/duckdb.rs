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
            Ok(result) => callback_json(callback, ctx, result),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// How many tables and views of its own an in-memory DuckDB database holds
/// (F7): a JSON number via callback.
#[no_mangle]
pub extern "C" fn pharos_duckdb_user_table_count(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {
        match crate::commands::duck::user_table_count(id, state).await {
            Ok(n) => callback_ok(callback, ctx, &n.to_string()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Save an in-memory DuckDB database to a new file (F7). `true` via
/// callback, or the error.
#[no_mangle]
pub extern "C" fn pharos_duckdb_save_in_memory(
    connection_id: *const c_char,
    file_path: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let path = unsafe { c_str_to_string(file_path) };
    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {
        match crate::commands::duck::save_in_memory(id, path, state).await {
            Ok(()) => callback_ok(callback, ctx, "true"),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Store a DuckDB cloud credential's secret key in the Keychain (Settings ▸
/// Connections ▸ DuckDB), and apply the entries to the open databases.
/// Returns false when the Keychain refused it.
#[no_mangle]
pub extern "C" fn pharos_duckdb_cloud_secret_store(id: *const c_char, secret: *const c_char) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let id = unsafe { c_str_to_string(id) };
        let secret = unsafe { c_str_to_string(secret) };
        match crate::commands::duck_cloud::store_secret(app_state(), &id, &secret) {
            Ok(()) => true,
            Err(e) => {
                log::error!("DuckDB cloud secret not stored: {}", e);
                false
            }
        }
    }))
    .unwrap_or(false)
}

/// Remove a DuckDB cloud credential's secret key (its entry was deleted).
#[no_mangle]
pub extern "C" fn pharos_duckdb_cloud_secret_delete(id: *const c_char) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let id = unsafe { c_str_to_string(id) };
        crate::commands::duck_cloud::delete_secret(app_state(), &id).is_ok()
    }))
    .unwrap_or(false)
}

/// Whether a DuckDB cloud credential has a secret key stored.
#[no_mangle]
pub extern "C" fn pharos_duckdb_cloud_secret_exists(id: *const c_char) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let id = unsafe { c_str_to_string(id) };
        crate::commands::duck_cloud::has_secret(app_state(), &id)
    }))
    .unwrap_or(false)
}

/// Another process's lock on a DuckDB file, as the lock message (a JSON
/// string), or JSON null when the file is free. Free with
/// `pharos_free_string`.
#[no_mangle]
pub extern "C" fn pharos_duckdb_lock_holder(path: *const c_char) -> *mut c_char {
    let path = unsafe { c_str_to_string(path) };
    ffi_sync!(to_json_c_string(&crate::db::duckdb::lock_holder(&path)))
}

/// The DuckDB library version Pharos links, e.g. `"v2.0.0"`, as a JSON
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
                "percentage": p.percentage(),
                "rowsProcessed": p.rows_processed(),
                "totalRows": p.total_rows_to_process(),
            }),
            None => serde_json::Value::Null,
        };
        to_c_string(&json.to_string())
    })
}

/// Attach a database to an open DuckDB database and remember it
/// (`commands::duck_attach::attach`, Query ▸ Attach Database…). `kind` is
/// `"postgres"` (`source` = a CONNECTED PostgreSQL connection's id; the
/// password goes into a temporary DuckDB secret, never into SQL a user sees
/// or history keeps) or `"file"` (`source` = a DuckDB or SQLite file's path).
/// `alias` empty = a default from the source's name. Returns
/// `AttachmentInfo` JSON via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_attach(
    duck_connection_id: *const c_char,
    kind: *const c_char,
    source: *const c_char,
    alias: *const c_char,
    read_only: bool,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let duck_id = unsafe { c_str_to_string(duck_connection_id) };
    let kind = unsafe { c_str_to_string(kind) };
    let source = unsafe { c_str_to_string(source) };
    let alias = unsafe { c_str_to_string(alias) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let alias = if alias.trim().is_empty() { None } else { Some(alias) };
        let result = match crate::commands::duck_attach::AttachSource::parse(&kind, source) {
            Ok(source) => crate::commands::duck_attach::attach(duck_id, source, alias, read_only, state).await,
            Err(e) => Err(e),
        };
        match result {
            Ok(info) => callback_ok(callback, ctx, &serde_json::to_string(&info).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Attach the DuckDB database file at `url` (http/https) to an open DuckDB
/// database, read-only, as `alias` (`commands::duck_attach::attach_remote`):
/// the `pharos://duckdb/attach` link. No card or history entry shows it.
/// Returns the alias as a JSON string via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_attach_remote(
    duck_connection_id: *const c_char,
    url: *const c_char,
    alias: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let duck_id = unsafe { c_str_to_string(duck_connection_id) };
    let url = unsafe { c_str_to_string(url) };
    let alias = unsafe { c_str_to_string(alias) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::duck_attach::attach_remote(duck_id, url, alias, state).await {
            Ok(alias) => callback_ok(callback, ctx, &serde_json::to_string(&alias).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Detach a database from a DuckDB database and forget it (it is not
/// attached again on the next open). Returns `null` via callback.
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

/// The databases attached to a DuckDB database, then its remembered attaches
/// that are not attached now: `[AttachmentInfo]` JSON via callback.
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
        match crate::commands::duck_attach::list(&duck_id, state).await {
            Ok(list) => callback_ok(callback, ctx, &serde_json::to_string(&list).unwrap_or_default()),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// A PostgreSQL connection has just connected: attach it to each connected
/// DuckDB database that remembers it (`duck_attach::restore_for_pg`).
/// Returns `[RestoreOutcome]` JSON via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_restore_for_pg(
    pg_connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let pg_id = unsafe { c_str_to_string(pg_connection_id) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let outcomes = crate::commands::duck_attach::restore_for_pg(&pg_id, state).await;
        callback_ok(callback, ctx, &serde_json::to_string(&outcomes).unwrap_or_default());
    });
}

/// The remembered attaches a DuckDB connect could not restore, once:
/// `["alias: message"]` JSON via callback.
#[no_mangle]
pub extern "C" fn pharos_duck_take_restore_failures(
    duck_connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let duck_id = unsafe { c_str_to_string(duck_connection_id) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let failures = crate::commands::duck_attach::take_restore_failures(&duck_id, state);
        callback_ok(callback, ctx, &serde_json::to_string(&failures).unwrap_or_default());
    });
}
