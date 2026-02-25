use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Query execution
// ---------------------------------------------------------------------------

/// Format SQL with PostgreSQL conventions. Returns formatted SQL. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_format_sql(sql: *const c_char) -> *mut c_char {
    let sql_str = match unsafe { c_str_to_option(sql) } {
        Some(s) => s,
        None => return to_c_string(""),
    };
    let options = sqlformat::FormatOptions {
        indent: sqlformat::Indent::Spaces(2),
        uppercase: Some(true),
        lines_between_queries: 2,
        ..Default::default()
    };
    let formatted = sqlformat::format(&sql_str, &sqlformat::QueryParams::None, &options);
    to_c_string(&formatted)
}

/// Execute a SQL query. Returns JSON QueryResult via callback.
#[no_mangle]
pub extern "C" fn pharos_execute_query(
    connection_id: *const c_char,
    sql: *const c_char,
    query_id: *const c_char,
    limit: i32,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let qid = unsafe { c_str_to_option(query_id) };
    let schema_str = unsafe { c_str_to_option(schema) };
    let lim = if limit > 0 { Some(limit as u32) } else { None };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::execute_query(conn_id, sql_str, qid, lim, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Execute a statement (INSERT/UPDATE/DELETE). Returns JSON ExecuteResult via callback.
#[no_mangle]
pub extern "C" fn pharos_execute_statement(
    connection_id: *const c_char,
    sql: *const c_char,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let schema_str = unsafe { c_str_to_option(schema) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::execute_statement(conn_id, sql_str, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Fetch more rows. Returns JSON QueryResult via callback.
#[no_mangle]
pub extern "C" fn pharos_fetch_more_rows(
    connection_id: *const c_char,
    sql: *const c_char,
    limit: i64,
    offset: i64,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let schema_str = unsafe { c_str_to_option(schema) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::fetch_more_rows(conn_id, sql_str, limit, offset, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Cancel a running query. Returns immediately (synchronous).
#[no_mangle]
pub extern "C" fn pharos_cancel_query(
    connection_id: *const c_char,
    query_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let qid = unsafe { c_str_to_string(query_id) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::cancel_query(conn_id, qid, state).await {
            Ok(cancelled) => callback_ok(callback, ctx, if cancelled { "true" } else { "false" }),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Validate SQL syntax. Returns JSON ValidationResult via callback.
#[no_mangle]
pub extern "C" fn pharos_validate_sql(
    connection_id: *const c_char,
    sql: *const c_char,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let schema_str = unsafe { c_str_to_option(schema) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::validate_sql(conn_id, sql_str, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
