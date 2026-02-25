use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

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
