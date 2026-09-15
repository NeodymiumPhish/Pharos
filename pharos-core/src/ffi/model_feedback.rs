use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Model feedback
//
// Both functions are synchronous: the table is local SQLite and a press must
// not leave the button waiting. They follow the single-channel convention of
// the saved-query functions — one C-string carries either the answer or
// `{"error": "..."}`.
// ---------------------------------------------------------------------------

/// Record one rating of model output. `rating` is `1` (helpful) or `-1` (not
/// helpful). Returns `{"ok":true}` on success. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_record_model_feedback(
    feature: *const c_char,
    prompt_hash: *const c_char,
    rating: i32,
) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let feature = unsafe { c_str_to_string(feature) };
        let prompt_hash = unsafe { c_str_to_string(prompt_hash) };
        match rt.block_on(crate::commands::record_model_feedback(
            state,
            feature,
            prompt_hash,
            rating,
        )) {
            Ok(()) => to_c_string("{\"ok\":true}"),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Load the most recent ratings, newest first. Returns a JSON array. Caller
/// must free.
#[no_mangle]
pub extern "C" fn pharos_load_model_feedback(limit: i32) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_model_feedback(state, limit)) {
            Ok(entries) => to_json_c_string(&entries),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}
