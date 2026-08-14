use std::os::raw::c_char;

use super::*;

/// Load every tag with its tuples. Returns a JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_tags() -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        match rt.block_on(crate::commands::load_tags(state)) {
            Ok(tags) => to_json_c_string(&tags),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Create a tag. `json` is a JSON-encoded CreateTag. Returns the stored Tag.
#[no_mangle]
pub extern "C" fn pharos_create_tag(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let create: crate::models::CreateTag = match serde_json::from_str(&json_str) {
            Ok(c) => c,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::create_tag(state, create)) {
            Ok(tag) => to_json_c_string(&tag),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Append tuples to a tag. `json` is a JSON-encoded AddTagTuples. Returns the
/// number inserted as a decimal string, which can be fewer than sent.
#[no_mangle]
pub extern "C" fn pharos_add_tag_tuples(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let payload: crate::models::AddTagTuples = match serde_json::from_str(&json_str) {
            Ok(p) => p,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::add_tag_tuples(state, payload)) {
            Ok(count) => to_c_string(&count.to_string()),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Update a tag. `json` is a JSON-encoded UpdateTag. Returns the Tag or null.
#[no_mangle]
pub extern "C" fn pharos_update_tag(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let update: crate::models::UpdateTag = match serde_json::from_str(&json_str) {
            Ok(u) => u,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::update_tag(state, update)) {
            Ok(tag) => to_json_c_string(&tag),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete a tag and, by cascade, its tuples. Returns "true" or "false".
#[no_mangle]
pub extern "C" fn pharos_delete_tag(tag_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(tag_id) };
        match rt.block_on(crate::commands::delete_tag(state, id)) {
            Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Delete individual tuples. `json` is a JSON array of ids. Returns the number
/// removed as a decimal string.
#[no_mangle]
pub extern "C" fn pharos_delete_tag_tuples(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let ids: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(ids) => ids,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::delete_tag_tuples(state, ids)) {
            Ok(count) => to_c_string(&count.to_string()),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}
