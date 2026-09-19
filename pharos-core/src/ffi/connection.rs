use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

/// Load all connection configs. Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_connections() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_connections(state)) {
            Ok(configs) => to_json_c_string(&configs),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Save a connection config. `json` is a JSON-encoded ConnectionConfig.
/// Returns NULL on success, or an error message string (caller must free).
#[no_mangle]
pub extern "C" fn pharos_save_connection(json: *const c_char) -> *mut c_char {
    ffi_sync!({
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
    })
}

/// Reorder connections. `json` is a JSON-encoded array of connection IDs in
/// the desired top-to-bottom order. Returns NULL on success or error string.
#[no_mangle]
pub extern "C" fn pharos_reorder_connections(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let ids: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(v) => v,
            Err(e) => return to_c_string(&e.to_string()),
        };
        match rt.block_on(crate::commands::reorder_connections(ids, state)) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => to_c_string(&e),
        }
    })
}

/// Delete a connection. Returns NULL on success or error string.
#[no_mangle]
pub extern "C" fn pharos_delete_connection(connection_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(connection_id) };
        match rt.block_on(crate::commands::delete_connection(id, state)) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => to_c_string(&e),
        }
    })
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
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::connect_postgres(id, state).await {
            Ok(info) => {
                let json = serde_json::to_string(&info).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Connect to PostgreSQL with a password the user has just typed, rather than
/// one the Keychain holds. Calls `callback` when done.
///
/// The password is held for this process only — it is never written to the
/// Keychain by this call, and never logged. The same shape as `pharos_connect`
/// otherwise: the strings are copied out of the caller's memory before the
/// task is spawned, and Rust frees what it hands back to the callback.
#[no_mangle]
pub extern "C" fn pharos_connect_with_password(
    connection_id: *const c_char,
    password: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let password = unsafe { c_str_to_string(password) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::connect_postgres_with_password(id, password, state).await {
            Ok(info) => {
                let json = serde_json::to_string(&info).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Connect with an SSH tunnel secret the user has just typed, rather than one
/// the Keychain holds. Calls `callback` when done.
///
/// The sibling of `pharos_connect_with_password`, for the other secret, and
/// the same contract: held for this process only, never written to the
/// Keychain by this call, never logged. It retries the whole connect, tunnel
/// included.
#[no_mangle]
pub extern "C" fn pharos_connect_with_ssh_secret(
    connection_id: *const c_char,
    secret: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let id = unsafe { c_str_to_string(connection_id) };
    let secret = unsafe { c_str_to_string(secret) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::connect_postgres_with_ssh_secret(id, secret, state).await {
            Ok(info) => {
                let json = serde_json::to_string(&info).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Forget every password typed this run — database passwords and SSH tunnel
/// secrets alike, because both live in the one process-only map, under keys
/// that cannot collide. The Keychain is untouched. Returns how many were
/// dropped, so the caller can log a count and never a name.
#[no_mangle]
pub extern "C" fn pharos_clear_session_passwords() -> u32 {
    match std::panic::catch_unwind(AssertUnwindSafe(|| {
        crate::commands::clear_session_passwords(app_state()) as u32
    })) {
        Ok(dropped) => dropped,
        Err(_) => 0,
    }
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

    ffi_spawn!(callback, context, async move {
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

    ffi_spawn!(callback, context, async move {
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
