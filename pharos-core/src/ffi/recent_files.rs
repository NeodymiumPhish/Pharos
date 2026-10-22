use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Recent files (the sidebar's Files navigator)
// ---------------------------------------------------------------------------

/// Every recent file, newest first. Returns a JSON array of RecentFile.
/// Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_recent_files() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_recent_files(state)) {
            Ok(files) => to_json_c_string(&files),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Note files as opened. `json` is a JSON array of RecentFile. Returns NULL on
/// success, an error C-string otherwise.
#[no_mangle]
pub extern "C" fn pharos_touch_recent_files(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let files: Vec<crate::models::RecentFile> = match serde_json::from_str(&json_str) {
            Ok(v) => v,
            Err(e) => return to_c_string(&e.to_string()),
        };
        match rt.block_on(crate::commands::touch_recent_files(state, files)) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => to_c_string(&e),
        }
    })
}

/// Remove paths from the list. `json` is a JSON array of path strings.
/// Returns NULL on success, an error C-string otherwise.
#[no_mangle]
pub extern "C" fn pharos_remove_recent_files(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let paths: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(v) => v,
            Err(e) => return to_c_string(&e.to_string()),
        };
        match rt.block_on(crate::commands::remove_recent_files(state, paths)) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => to_c_string(&e),
        }
    })
}
