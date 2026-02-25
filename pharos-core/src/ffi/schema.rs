use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Schema introspection
// ---------------------------------------------------------------------------

/// Get schemas. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_schemas(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::get_schemas(conn_id, state).await {
            Ok(schemas) => {
                let json = serde_json::to_string(&schemas).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get tables for a schema. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_tables(
    connection_id: *const c_char,
    schema_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::get_tables(conn_id, schema, state).await {
            Ok(tables) => {
                let json = serde_json::to_string(&tables).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get columns for a table. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_columns(
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

        match crate::commands::get_columns(conn_id, schema, table, state).await {
            Ok(columns) => {
                let json = serde_json::to_string(&columns).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get all columns for all tables in a schema (batch). Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_schema_columns(
    connection_id: *const c_char,
    schema_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let ctx = context as usize;

    runtime().spawn(async move {
        match crate::commands::get_schema_columns(conn_id, schema, state).await {
            Ok(columns) => {
                let json = serde_json::to_string(&columns).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Analyze a schema. Returns JSON AnalyzeResult via callback.
#[no_mangle]
pub extern "C" fn pharos_analyze_schema(
    connection_id: *const c_char,
    schema_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::analyze_schema(conn_id, schema, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get schema functions. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_schema_functions(
    connection_id: *const c_char,
    schema_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::get_schema_functions(conn_id, schema, state).await {
            Ok(functions) => {
                let json = serde_json::to_string(&functions).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
