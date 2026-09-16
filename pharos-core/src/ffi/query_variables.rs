use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Query variables (the app-wide `{{name}}` list, shown in the sidebar)
// ---------------------------------------------------------------------------

/// Load every stored variable, in the user's order. Returns a JSON array.
/// Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_query_variables() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_query_variables(state)) {
            Ok(variables) => to_json_c_string(&variables),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Replace the stored list. `json` is a JSON array of QueryVariable; the array
/// order becomes the stored order. Returns NULL on success, an error C-string
/// otherwise.
#[no_mangle]
pub extern "C" fn pharos_save_query_variables(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let variables: Vec<crate::models::QueryVariable> = match serde_json::from_str(&json_str) {
            Ok(v) => v,
            Err(e) => return to_c_string(&e.to_string()),
        };
        match rt.block_on(crate::commands::save_query_variables(state, variables)) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => to_c_string(&e),
        }
    })
}
