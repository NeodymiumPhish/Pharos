use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Query history
// ---------------------------------------------------------------------------

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

/// Batch delete query history entries. `json` is a JSON array of ID strings.
/// Returns the count of deleted entries as a string, or error JSON.
#[no_mangle]
pub extern "C" fn pharos_batch_delete_query_history(json: *const c_char) -> *mut c_char {
    let state = app_state();
    let rt = runtime();
    let json_str = unsafe { c_str_to_string(json) };
    let ids: Vec<String> = match serde_json::from_str(&json_str) {
        Ok(ids) => ids,
        Err(e) => return to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    };
    match rt.block_on(crate::commands::batch_delete_query_history_entries(ids, state)) {
        Ok(count) => to_c_string(&format!("{}", count)),
        Err(e) => to_c_string(&format!("{{\"error\":\"{}\"}}", e)),
    }
}
