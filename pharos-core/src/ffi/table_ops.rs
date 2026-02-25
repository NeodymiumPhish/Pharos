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

    runtime().spawn(async move {

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

    runtime().spawn(async move {

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

    runtime().spawn(async move {

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
