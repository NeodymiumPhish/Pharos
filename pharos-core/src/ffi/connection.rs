use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Connection management
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
