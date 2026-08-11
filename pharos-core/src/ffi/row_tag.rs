use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Tag labels
// ---------------------------------------------------------------------------

/// Load every tag label. Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_tag_labels() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_tag_labels(state)) {
            Ok(labels) => to_json_c_string(&labels),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Create a tag label. `json` is JSON-encoded CreateTagLabel. Returns JSON TagLabel.
#[no_mangle]
pub extern "C" fn pharos_create_tag_label(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let label: crate::models::CreateTagLabel = match serde_json::from_str(&json_str) {
            Ok(l) => l,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::create_tag_label(state, label)) {
            Ok(created) => to_json_c_string(&created),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Update a tag label. `json` is JSON-encoded UpdateTagLabel. Returns JSON TagLabel or null.
#[no_mangle]
pub extern "C" fn pharos_update_tag_label(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let update: crate::models::UpdateTagLabel = match serde_json::from_str(&json_str) {
            Ok(u) => u,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::update_tag_label(state, update)) {
            Ok(updated) => to_json_c_string(&updated),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Count the tags that use a label. Returns the count as a decimal string.
/// An unknown label id gives "0", not an error.
#[no_mangle]
pub extern "C" fn pharos_count_tags_for_label(label_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(label_id) };
        match rt.block_on(crate::commands::count_tags_for_label(state, id)) {
            Ok(count) => to_c_string(&count.to_string()),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete a tag label. Returns "true" or "false".
#[no_mangle]
pub extern "C" fn pharos_delete_tag_label(label_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(label_id) };
        match rt.block_on(crate::commands::delete_tag_label(state, id)) {
            Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

// ---------------------------------------------------------------------------
// Row tags
// ---------------------------------------------------------------------------

/// Load every row tag of one connection. Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_row_tags(connection_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(connection_id) };
        match rt.block_on(crate::commands::load_row_tags(state, id)) {
            Ok(tags) => to_json_c_string(&tags),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Write a row tag. `json` is JSON-encoded UpsertRowTag. Returns JSON RowTag.
#[no_mangle]
pub extern "C" fn pharos_upsert_row_tag(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let upsert: crate::models::UpsertRowTag = match serde_json::from_str(&json_str) {
            Ok(u) => u,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::upsert_row_tag(state, upsert)) {
            Ok(tag) => to_json_c_string(&tag),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete one row tag. Returns "true" or "false".
#[no_mangle]
pub extern "C" fn pharos_delete_row_tag(tag_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(tag_id) };
        match rt.block_on(crate::commands::delete_row_tag(state, id)) {
            Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete many row tags. `json` is a JSON array of ids. Returns the number of
/// rows actually removed as a decimal string, which can be fewer than the
/// number of ids sent.
#[no_mangle]
pub extern "C" fn pharos_delete_row_tags(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let ids: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(ids) => ids,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::delete_row_tags(state, ids)) {
            Ok(count) => to_c_string(&count.to_string()),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}
