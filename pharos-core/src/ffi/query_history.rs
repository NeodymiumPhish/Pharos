use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Query history
// ---------------------------------------------------------------------------

/// Load query history. `json` is JSON with optional filters: {connectionId?, search?, limit?, offset?}.
/// Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_query_history(json: *const c_char) -> *mut c_char {
    ffi_sync!({
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
            only_legacy: Option<bool>,
        }

        let filter: HistoryFilter = serde_json::from_str(&json_str).unwrap_or(HistoryFilter {
            connection_id: None,
            search: None,
            limit: Some(100),
            offset: Some(0),
            only_legacy: None,
        });

        match rt.block_on(crate::commands::load_query_history(
            filter.connection_id,
            filter.search,
            filter.limit,
            filter.offset,
            filter.only_legacy.unwrap_or(false),
            state,
        )) {
            Ok(entries) => to_json_c_string(&entries),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete a query history entry. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_query_history_entry(entry_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(entry_id) };
        match rt.block_on(crate::commands::delete_query_history_entry(id, state)) {
            Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Get cached result data for a history entry. Returns JSON or NULL.
#[no_mangle]
pub extern "C" fn pharos_get_query_history_result(entry_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(entry_id) };
        match rt.block_on(crate::commands::get_query_history_result(id, state)) {
            Ok(Some(data)) => to_json_c_string(&data),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Batch delete query history entries. `json` is a JSON array of ID strings.
/// Returns the count of deleted entries as a string, or error JSON.
#[no_mangle]
pub extern "C" fn pharos_batch_delete_query_history(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let ids: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(ids) => ids,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::batch_delete_query_history_entries(ids, state)) {
            Ok(count) => to_c_string(&format!("{}", count)),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Clear Query History. `json` is `{"olderThanDays": n, "preview": bool}`;
/// `olderThanDays` of 0 (or absent) means everything, and `preview` counts
/// without deleting. Returns `{"deleted": n}` or `{"error": "..."}`.
/// Caller must free.
#[no_mangle]
pub extern "C" fn pharos_clear_query_history(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ClearRequest {
            #[serde(default)]
            older_than_days: u32,
            #[serde(default)]
            preview: bool,
        }

        let request: ClearRequest = serde_json::from_str(&json_str)
            .unwrap_or(ClearRequest { older_than_days: 0, preview: false });

        match rt.block_on(crate::commands::clear_query_history(
            state,
            request.older_than_days,
            request.preview,
        )) {
            Ok(deleted) => to_json_c_string(&serde_json::json!({ "deleted": deleted })),
            Err(e) => to_c_string(&serde_json::json!({ "error": e }).to_string()),
        }
    })
}
