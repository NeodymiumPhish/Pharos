use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// App data export and import (File ▸ Export App Data…, File ▸ Import App
// Data…; `commands::app_backup`)
//
// All three are async: the key derivation alone takes a noticeable fraction
// of a second, and a file with Sessions' results in it can be large.
// ---------------------------------------------------------------------------

/// Run `work` on `json` decoded as `T`, and answer with its result as JSON.
fn spawn_backup_call<T, R, F, Fut>(json: *const c_char, callback: AsyncCallback, context: *mut std::ffi::c_void, work: F)
where
    T: serde::de::DeserializeOwned + Send + 'static,
    R: serde::Serialize,
    F: FnOnce(T, &'static crate::state::AppState) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Result<R, String>> + Send + 'static,
{
    let state = app_state();
    let json_str = unsafe { c_str_to_string(json) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        let options: T = match serde_json::from_str(&json_str) {
            Ok(o) => o,
            Err(e) => {
                callback_err(callback, ctx, &e.to_string());
                return;
            }
        };
        match work(options, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Write the chosen categories to a file. `json` is ExportAppDataOptions;
/// the answer is ExportAppDataResult.
#[no_mangle]
pub extern "C" fn pharos_export_app_data(
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    spawn_backup_call(json, callback, context, |options, state| {
        crate::commands::export_app_data(options, state)
    });
}

/// What a file holds. `json` is `{"path": ..., "passphrase": ...}` (the
/// passphrase may be absent); the answer is BackupSummary, `locked` for an
/// encrypted file read without its password.
#[no_mangle]
pub extern "C" fn pharos_inspect_app_data(
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    #[derive(serde::Deserialize)]
    struct Inspect {
        path: String,
        #[serde(default)]
        passphrase: Option<String>,
    }
    spawn_backup_call(json, callback, context, |options: Inspect, _state| async move {
        crate::commands::inspect_app_data(&options.path, options.passphrase.as_deref())
    });
}

/// Read the chosen categories from a file into the store. `json` is
/// ImportAppDataOptions; the answer is ImportAppDataResult.
#[no_mangle]
pub extern "C" fn pharos_import_app_data(
    json: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    spawn_backup_call(json, callback, context, |options, state| {
        crate::commands::import_app_data(options, state)
    });
}
