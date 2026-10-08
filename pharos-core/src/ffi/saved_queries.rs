use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Saved queries
// ---------------------------------------------------------------------------

/// Load saved queries. Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_saved_queries() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_saved_queries(state)) {
            Ok(queries) => to_json_c_string(&queries),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Create a saved query. `json` is JSON-encoded CreateSavedQuery. Returns JSON SavedQuery.
#[no_mangle]
pub extern "C" fn pharos_create_saved_query(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let query: crate::models::CreateSavedQuery = match serde_json::from_str(&json_str) {
            Ok(q) => q,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::create_saved_query(state, query)) {
            Ok(saved) => to_json_c_string(&saved),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Update a saved query. `json` is JSON-encoded UpdateSavedQuery. Returns JSON SavedQuery or null.
#[no_mangle]
pub extern "C" fn pharos_update_saved_query(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let update: crate::models::UpdateSavedQuery = match serde_json::from_str(&json_str) {
            Ok(u) => u,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::update_saved_query(state, update)) {
            Ok(saved) => to_json_c_string(&saved),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete a saved query. Returns "true" or "false".
#[no_mangle]
pub extern "C" fn pharos_delete_saved_query(query_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(query_id) };
        match rt.block_on(crate::commands::delete_saved_query(state, id)) {
            Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Batch delete saved queries. `json` is JSON array of IDs. Returns deleted count as string.
#[no_mangle]
pub extern "C" fn pharos_batch_delete_saved_queries(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let ids: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(ids) => ids,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::batch_delete_saved_queries(state, ids)) {
            Ok(count) => to_c_string(&count.to_string()),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Extract table names from SQL for display. Returns comma-separated names or NULL.
#[no_mangle]
pub extern "C" fn pharos_extract_table_names(sql: *const c_char) -> *mut c_char {
    ffi_sync!({
        let sql_str = unsafe { c_str_to_string(sql) };
        match crate::commands::query::extract_table_names_for_history(&sql_str) {
            Some(names) => to_c_string(&names),
            None => std::ptr::null_mut(),
        }
    })
}

// ---------------------------------------------------------------------------
// Session results (a saved query's stored results)
// ---------------------------------------------------------------------------

/// Stage one result of a Session save. `json` is JSON-encoded
/// StageSavedQueryResult. Returns JSON StagedSavedQueryResult.
#[no_mangle]
pub extern "C" fn pharos_stage_saved_query_result(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let row: crate::models::StageSavedQueryResult = match serde_json::from_str(&json_str) {
            Ok(r) => r,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::stage_saved_query_result(state, row)) {
            Ok(staged) => to_json_c_string(&staged),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Make a staged snapshot the Session's own. `json` is JSON-encoded
/// CommitSavedQuerySnapshot. Returns JSON CommittedSavedQuerySnapshot.
#[no_mangle]
pub extern "C" fn pharos_commit_saved_query_snapshot(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let commit: crate::models::CommitSavedQuerySnapshot = match serde_json::from_str(&json_str) {
            Ok(c) => c,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::commit_saved_query_snapshot(state, commit)) {
            Ok(done) => to_json_c_string(&done),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Discard the rows a failed Session save staged. Returns the count removed.
#[no_mangle]
pub extern "C" fn pharos_abort_saved_query_snapshot(
    saved_query_id: *const c_char,
    snapshot_id: *const c_char,
) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(saved_query_id) };
        let snapshot = unsafe { c_str_to_string(snapshot_id) };
        match rt.block_on(crate::commands::abort_saved_query_snapshot(state, id, snapshot)) {
            Ok(count) => to_c_string(&count.to_string()),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// A Session's stored results, without rows. Returns a JSON array of
/// SavedQueryResultMeta.
#[no_mangle]
pub extern "C" fn pharos_load_saved_query_results(saved_query_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(saved_query_id) };
        match rt.block_on(crate::commands::load_saved_query_results(state, id)) {
            Ok(metas) => to_json_c_string(&metas),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// One stored Session result, in the shape of a history result. Returns JSON
/// or NULL when its rows are not stored.
#[no_mangle]
pub extern "C" fn pharos_get_saved_query_result(result_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(result_id) };
        match rt.block_on(crate::commands::get_saved_query_result(state, id)) {
            Ok(Some(data)) => to_json_c_string(&data),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}
