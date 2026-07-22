use std::os::raw::c_char;
use super::*;

// ---------------------------------------------------------------------------
// Workspaces
// ---------------------------------------------------------------------------

/// Upsert a workspace. `json` = WorkspaceUpsert. Returns "true" or error JSON.
#[no_mangle]
pub extern "C" fn pharos_upsert_workspace(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        let w: crate::models::WorkspaceUpsert = match serde_json::from_str(&s) {
            Ok(w) => w,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::upsert_workspace(w, state)) {
            Ok(()) => to_c_string("true"),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Associate a result. `json` = {historyId, workspaceId, resultOrder, colorIndex}.
#[no_mangle]
pub extern "C" fn pharos_associate_result(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Assoc { history_id: String, workspace_id: String, result_order: i64, color_index: i64 }
        let a: Assoc = match serde_json::from_str(&s) {
            Ok(a) => a,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::associate_result(a.history_id, a.workspace_id, a.result_order, a.color_index, None, state)) {
            Ok(()) => to_c_string("true"),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Load workspace summaries. `json` = {search?, limit?, offset?}. Returns JSON array.
#[no_mangle]
pub extern "C" fn pharos_load_workspaces(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize, Default)]
        #[serde(rename_all = "camelCase")]
        struct F { search: Option<String>, limit: Option<i64>, offset: Option<i64> }
        let f: F = serde_json::from_str(&s).unwrap_or_default();
        match rt.block_on(crate::commands::load_workspaces(f.search, f.limit, f.offset, state)) {
            Ok(v) => to_json_c_string(&v),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Load a full workspace by id. Returns JSON object, or NULL if not found.
#[no_mangle]
pub extern "C" fn pharos_load_workspace(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::load_workspace(id, state)) {
            Ok(Some(d)) => to_json_c_string(&d),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Rename a workspace. `json` = {id, name}. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_rename_workspace(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)] struct R { id: String, name: String }
        let r: R = match serde_json::from_str(&s) { Ok(r) => r, Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()) };
        match rt.block_on(crate::commands::rename_workspace(r.id, r.name, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Duplicate a workspace. Arg = id string. Returns the new id string, or NULL if not found.
#[no_mangle]
pub extern "C" fn pharos_duplicate_workspace(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::duplicate_workspace(id, state)) {
            Ok(Some(new_id)) => to_c_string(&new_id),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Delete a workspace (cascades). Arg = id string. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_workspace(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::delete_workspace(id, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Delete one child result. Arg = result id string. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_workspace_result(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::delete_workspace_result(id, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Update a result's display metadata. `json` = {resultId, customLabel?, colorIndex?}.
#[no_mangle]
pub extern "C" fn pharos_update_result_meta(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct U { result_id: String, custom_label: Option<String>, color_index: Option<i64> }
        let u: U = match serde_json::from_str(&s) { Ok(u) => u, Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()) };
        match rt.block_on(crate::commands::update_result_meta(u.result_id, u.custom_label, u.color_index, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Update a result's persisted chart view state. `json` = {resultId, json}.
#[no_mangle]
pub extern "C" fn pharos_update_result_chart_state(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct U { result_id: String, json: String }
        let u: U = match serde_json::from_str(&s) { Ok(u) => u, Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()) };
        match rt.block_on(crate::commands::update_result_chart_state(u.result_id, u.json, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}
