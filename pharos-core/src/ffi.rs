use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;

use tokio::runtime::Runtime;

use crate::state::AppState;

// ---------------------------------------------------------------------------
// Global singletons
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static APP_STATE: OnceLock<AppState> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get().expect("pharos_init() not called")
}

fn app_state() -> &'static AppState {
    APP_STATE.get().expect("pharos_init() not called")
}

// ---------------------------------------------------------------------------
// Callback type for async results
// ---------------------------------------------------------------------------

/// Callback invoked when an async operation completes.
/// - `context`: opaque pointer passed through from the caller (e.g. Swift continuation)
/// - `result_json`: JSON-encoded result on success, NULL on error
/// - `error_msg`: error message on failure, NULL on success
///
/// Exactly one of `result_json` / `error_msg` will be non-NULL.
/// The caller must NOT free the strings — they are freed by Rust after the callback returns.
pub type AsyncCallback = extern "C" fn(
    context: *mut std::ffi::c_void,
    result_json: *const c_char,
    error_msg: *const c_char,
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convert a C string to a Rust String. Returns empty string for NULL.
unsafe fn c_str_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// Convert a C string to an Option<String>. Returns None for NULL.
unsafe fn c_str_to_option(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

/// Allocate a C string from a Rust &str. Caller must free with `pharos_free_string`.
fn to_c_string(s: &str) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Helper: serialize a value to a JSON C-string.
fn to_json_c_string<T: serde::Serialize>(value: &T) -> *mut c_char {
    let json = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    to_c_string(&json)
}

/// Invoke a callback with a JSON result. Takes `usize` context to stay Send-safe across awaits.
fn callback_ok(cb: AsyncCallback, ctx: usize, json: &str) {
    let c = CString::new(json).unwrap_or_default();
    cb(ctx as *mut std::ffi::c_void, c.as_ptr(), std::ptr::null());
}

/// Invoke a callback with an error. Takes `usize` context to stay Send-safe across awaits.
fn callback_err(cb: AsyncCallback, ctx: usize, error: &str) {
    let c = CString::new(error).unwrap_or_default();
    cb(ctx as *mut std::ffi::c_void, std::ptr::null(), c.as_ptr());
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Initialize the Rust runtime, SQLite database, and credential cache.
/// `app_data_dir` must be a valid UTF-8 path to the application support directory.
/// Returns true on success.
#[no_mangle]
pub extern "C" fn pharos_init(app_data_dir: *const c_char) -> bool {
    // Initialize logger
    let _ = env_logger::try_init();

    let dir = unsafe { c_str_to_string(app_data_dir) };
    let path = std::path::PathBuf::from(&dir);

    // Create tokio runtime
    let rt = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            log::error!("Failed to create tokio runtime: {}", e);
            return false;
        }
    };
    let _ = RUNTIME.set(rt);

    // Initialize SQLite
    let metadata_db = match crate::db::sqlite::init_database(&path) {
        Ok(db) => db,
        Err(e) => {
            log::error!("Failed to initialize SQLite: {}", e);
            return false;
        }
    };

    let state = AppState::new(metadata_db);

    // Load connections and initialize password cache
    {
        let db = state.metadata_db.lock().unwrap();
        if let Ok(configs) = crate::db::sqlite::load_connections(&db) {
            let connection_ids: Vec<String> = configs.iter().map(|c| c.id.clone()).collect();
            match crate::db::credentials::migrate_legacy_passwords(&connection_ids) {
                Ok(passwords) => {
                    state.init_password_cache(passwords);
                }
                Err(e) => {
                    log::warn!("Failed to load passwords from keychain: {}", e);
                }
            }
            for config in configs {
                state.set_config(config);
            }
        }
    }

    let _ = APP_STATE.set(state);
    true
}

/// Shut down the Rust runtime. Call on app termination.
#[no_mangle]
pub extern "C" fn pharos_shutdown() {
    // OnceLock values are never dropped, but we can close open pools
    if let Some(state) = APP_STATE.get() {
        let pools: Vec<_> = {
            let conns = state.connections.lock().unwrap();
            conns.values().cloned().collect()
        };
        if let Some(rt) = RUNTIME.get() {
            for pool in pools {
                rt.block_on(pool.close());
            }
        }
    }
}

/// Free a string allocated by Rust. Must be called for every non-NULL string returned by pharos_* functions.
#[no_mangle]
pub extern "C" fn pharos_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}

// ---------------------------------------------------------------------------
// SQL Formatting (pure computation, no I/O)
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

// ---------------------------------------------------------------------------
// Synchronous operations (fast, no network I/O)
// ---------------------------------------------------------------------------

/// Load all connection configs. Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_connections() -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    match rt.block_on(crate::commands::load_connections(state)) {
        Ok(configs) => to_json_c_string(&configs),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Save a connection config. `json` is a JSON-encoded ConnectionConfig.
/// Returns NULL on success, or an error message string (caller must free).
#[no_mangle]
pub extern "C" fn pharos_save_connection(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };
    let config: crate::models::ConnectionConfig = match serde_json::from_str(&json_str) {
        Ok(c) => c,
        Err(e) => return to_c_string(&e.to_string()),
    };
    match rt.block_on(crate::commands::save_connection(config, state)) {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => to_c_string(&e),
    }
}

/// Delete a connection. Returns NULL on success or error string.
#[no_mangle]
pub extern "C" fn pharos_delete_connection(connection_id: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let id = unsafe { c_str_to_string(connection_id) };
    match rt.block_on(crate::commands::delete_connection(id, state)) {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => to_c_string(&e),
    }
}

/// Load settings. Returns JSON. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_settings() -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    match rt.block_on(crate::commands::load_settings(state)) {
        Ok(settings) => to_json_c_string(&settings),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Save settings. `json` is a JSON-encoded AppSettings.
#[no_mangle]
pub extern "C" fn pharos_save_settings(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };
    let settings: crate::models::AppSettings = match serde_json::from_str(&json_str) {
        Ok(s) => s,
        Err(e) => return to_c_string(&e.to_string()),
    };
    match rt.block_on(crate::commands::save_settings(state, settings)) {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => to_c_string(&e),
    }
}

/// Load saved queries. Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_saved_queries() -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    match rt.block_on(crate::commands::load_saved_queries(state)) {
        Ok(queries) => to_json_c_string(&queries),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Create a saved query. `json` is JSON-encoded CreateSavedQuery. Returns JSON SavedQuery.
#[no_mangle]
pub extern "C" fn pharos_create_saved_query(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };
    let query: crate::models::CreateSavedQuery = match serde_json::from_str(&json_str) {
        Ok(q) => q,
        Err(e) => return to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    };
    match rt.block_on(crate::commands::create_saved_query(state, query)) {
        Ok(saved) => to_json_c_string(&saved),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Update a saved query. `json` is JSON-encoded UpdateSavedQuery. Returns JSON SavedQuery or null.
#[no_mangle]
pub extern "C" fn pharos_update_saved_query(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };
    let update: crate::models::UpdateSavedQuery = match serde_json::from_str(&json_str) {
        Ok(u) => u,
        Err(e) => return to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    };
    match rt.block_on(crate::commands::update_saved_query(state, update)) {
        Ok(saved) => to_json_c_string(&saved),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Delete a saved query. Returns "true" or "false".
#[no_mangle]
pub extern "C" fn pharos_delete_saved_query(query_id: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let id = unsafe { c_str_to_string(query_id) };
    match rt.block_on(crate::commands::delete_saved_query(state, id)) {
        Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Load query history. `json` is JSON with optional filters: {connectionId?, search?, limit?, offset?}.
/// Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_query_history(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };

    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct HistoryFilter {
        connection_id: Option<String>,
        search: Option<String>,
        limit: Option<i64>,
        offset: Option<i64>,
    }

    let filter: HistoryFilter = serde_json::from_str(&json_str).unwrap_or(HistoryFilter {
        connection_id: None,
        search: None,
        limit: Some(100),
        offset: Some(0),
    });

    match rt.block_on(crate::commands::load_query_history(
        filter.connection_id,
        filter.search,
        filter.limit,
        filter.offset,
        state,
    )) {
        Ok(entries) => to_json_c_string(&entries),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Delete a query history entry. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_query_history_entry(entry_id: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let id = unsafe { c_str_to_string(entry_id) };
    match rt.block_on(crate::commands::delete_query_history_entry(id, state)) {
        Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Get cached result data for a history entry. Returns JSON or NULL.
#[no_mangle]
pub extern "C" fn pharos_get_query_history_result(entry_id: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let id = unsafe { c_str_to_string(entry_id) };
    match rt.block_on(crate::commands::get_query_history_result(id, state)) {
        Ok(Some(data)) => to_json_c_string(&data),
        Ok(None) => std::ptr::null_mut(),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

// ---------------------------------------------------------------------------
// Async operations (network/database I/O)
// ---------------------------------------------------------------------------

/// Connect to PostgreSQL. Calls `callback` when done.
#[no_mangle]
pub extern "C" fn pharos_connect(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize; // Make Send-safe

    runtime().spawn(async move {

        match crate::commands::connect_postgres(id, state).await {
            Ok(info) => {
                let json = serde_json::to_string(&info).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Disconnect from PostgreSQL. Calls `callback` when done.
#[no_mangle]
pub extern "C" fn pharos_disconnect(
    connection_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let ctx = context as usize;

    runtime().spawn(async move {

        match crate::commands::disconnect_postgres(id, state).await {
            Ok(()) => callback_ok(callback, ctx, "null"),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Test a connection config. `json` is JSON-encoded ConnectionConfig.
#[no_mangle]
pub extern "C" fn pharos_test_connection(
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let json_str = unsafe { c_str_to_string(json) };
    let ctx = context as usize;

    runtime().spawn(async move {

        let config: crate::models::ConnectionConfig = match serde_json::from_str(&json_str) {
            Ok(c) => c,
            Err(e) => {
                callback_err(callback, ctx, &e.to_string());
                return;
            }
        };
        match crate::commands::test_connection(config).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
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
