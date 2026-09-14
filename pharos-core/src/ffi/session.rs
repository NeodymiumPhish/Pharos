use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Session (the set of editor tabs open at the end of the last run)
// ---------------------------------------------------------------------------

/// Load the stored session. Returns JSON. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_session() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_session(state)) {
            Ok(session) => to_json_c_string(&session),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Save the session. `json` is a JSON-encoded Session. Returns NULL on success,
/// an error C-string otherwise.
#[no_mangle]
pub extern "C" fn pharos_save_session(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let session: crate::models::Session = match serde_json::from_str(&json_str) {
            Ok(s) => s,
            Err(e) => return to_c_string(&e.to_string()),
        };
        match rt.block_on(crate::commands::save_session(state, session)) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => to_c_string(&e),
        }
    })
}
