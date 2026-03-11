use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Saved queries
// ---------------------------------------------------------------------------

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

/// Batch delete saved queries. `json` is JSON array of IDs. Returns deleted count as string.
#[no_mangle]
pub extern "C" fn pharos_batch_delete_saved_queries(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };
    let ids: Vec<String> = match serde_json::from_str(&json_str) {
        Ok(ids) => ids,
        Err(e) => return to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    };
    match rt.block_on(crate::commands::batch_delete_saved_queries(state, ids)) {
        Ok(count) => to_c_string(&count.to_string()),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}

/// Extract table names from SQL for display. Returns comma-separated names or NULL.
#[no_mangle]
pub extern "C" fn pharos_extract_table_names(sql: *const c_char) -> *mut c_char {
    let sql_str = unsafe { c_str_to_string(sql) };
    match crate::commands::query::extract_table_names_for_history(&sql_str) {
        Some(names) => to_c_string(&names),
        None => std::ptr::null_mut(),
    }
}
