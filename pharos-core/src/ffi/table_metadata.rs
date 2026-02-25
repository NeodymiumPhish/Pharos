use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Table metadata
// ---------------------------------------------------------------------------

/// Get table indexes. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_table_indexes(
    connection_id: *const c_char,
    schema_name: *const c_char,
    table_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let table = unsafe { c_str_to_string(table_name) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::get_table_indexes(conn_id, schema, table, state).await {
            Ok(indexes) => {
                let json = serde_json::to_string(&indexes).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get table constraints. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_table_constraints(
    connection_id: *const c_char,
    schema_name: *const c_char,
    table_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let table = unsafe { c_str_to_string(table_name) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::get_table_constraints(conn_id, schema, table, state).await {
            Ok(constraints) => {
                let json = serde_json::to_string(&constraints).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
