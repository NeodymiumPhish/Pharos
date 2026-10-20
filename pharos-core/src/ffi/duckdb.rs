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
/// `options_json`: `{"sql": "...", "schema": "main" | null, "filePath": "/abs/x.parquet"}`.
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
    }

    ffi_spawn!(callback, context, async move {
        let options: Options = match serde_json::from_str(&json) {
            Ok(o) => o,
            Err(e) => return callback_err(callback, ctx, &format!("Invalid options: {}", e)),
        };
        match crate::commands::duck::export_parquet(id, options.sql, options.schema, options.file_path, state).await {
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
