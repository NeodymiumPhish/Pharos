use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Table operations
// ---------------------------------------------------------------------------

/// Clone a table. `json` is JSON-encoded CloneTableOptions.
#[no_mangle]
pub extern "C" fn pharos_clone_table(
    connection_id: *const c_char,
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let json_str = unsafe { c_str_to_string(json) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let options: crate::commands::table::CloneTableOptions = match serde_json::from_str(&json_str) {
            Ok(o) => o,
            Err(e) => {
                callback_err(callback, ctx, &e.to_string());
                return;
            }
        };
        match crate::commands::clone_table(conn_id, options, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Export table data. `json` is JSON-encoded ExportTableOptions.
#[no_mangle]
pub extern "C" fn pharos_export_table(
    connection_id: *const c_char,
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let json_str = unsafe { c_str_to_string(json) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let options: crate::commands::table::ExportTableOptions = match serde_json::from_str(&json_str) {
            Ok(o) => o,
            Err(e) => {
                callback_err(callback, ctx, &e.to_string());
                return;
            }
        };
        match crate::commands::export_table(conn_id, options, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get the live row count for an in-progress import.
/// `key` is `"{connection_id}|{schema}|{table}"`.
/// Returns the current row count, or `-1` if no import is active for that key.
#[no_mangle]
pub extern "C" fn pharos_get_import_progress(key: *const c_char) -> i64 {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let state = app_state();
        let key_str = unsafe { c_str_to_string(key) };
        match state.get_import_progress(&key_str) {
            Some(count) => count as i64,
            None => -1,
        }
    }));
    result.unwrap_or(-1)
}

/// Import CSV. `json` is JSON-encoded ImportCsvOptions.
#[no_mangle]
pub extern "C" fn pharos_import_csv(
    connection_id: *const c_char,
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let json_str = unsafe { c_str_to_string(json) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let options: crate::commands::table::ImportCsvOptions = match serde_json::from_str(&json_str) {
            Ok(o) => o,
            Err(e) => {
                callback_err(callback, ctx, &e.to_string());
                return;
            }
        };
        match crate::commands::import_csv(conn_id, options, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
