use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Inline cell editing
// ---------------------------------------------------------------------------

/// Apply pending grid cell edits in ONE transaction.
/// `json` is a JSON-encoded `RowUpdateRequest` (camelCase).
/// On success the callback receives a JSON `RowUpdateResult`.
#[no_mangle]
pub extern "C" fn pharos_apply_row_updates(
    connection_id: *const c_char,
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let json_str = unsafe { c_str_to_string(json) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let request: crate::commands::row_edit::RowUpdateRequest =
            match serde_json::from_str(&json_str) {
                Ok(r) => r,
                Err(e) => {
                    callback_err(callback, ctx, &e.to_string());
                    return;
                }
            };
        match crate::commands::row_edit::apply_row_updates(conn_id, request, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
