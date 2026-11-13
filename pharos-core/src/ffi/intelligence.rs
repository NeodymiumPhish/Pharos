use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// The custom AI endpoint's API key (Settings ▸ Intelligence)
//
// Synchronous: the Keychain blob is already cached in memory, and a store is
// one Keychain write made while the user waits on the Save button.
// ---------------------------------------------------------------------------

/// Keep the custom AI endpoint's API key in the Keychain. An empty key
/// removes it. Returns false when the Keychain refused.
#[no_mangle]
pub extern "C" fn pharos_intelligence_endpoint_key_store(key: *const c_char) -> bool {
    std::panic::catch_unwind(AssertUnwindSafe(|| {
        let key = unsafe { c_str_to_string(key) };
        match crate::commands::intelligence::store_endpoint_key(app_state(), &key) {
            Ok(()) => true,
            Err(e) => {
                log::error!("AI endpoint key not stored: {}", e);
                false
            }
        }
    }))
    .unwrap_or(false)
}

/// Remove the custom AI endpoint's API key. Returns false when the Keychain
/// refused; removing a key that is not there succeeds.
#[no_mangle]
pub extern "C" fn pharos_intelligence_endpoint_key_delete() -> bool {
    std::panic::catch_unwind(AssertUnwindSafe(|| {
        crate::commands::intelligence::delete_endpoint_key(app_state()).is_ok()
    }))
    .unwrap_or(false)
}

/// The custom AI endpoint's API key as a JSON string, or JSON `null` when
/// none is stored. Free with `pharos_free_string`.
#[no_mangle]
pub extern "C" fn pharos_intelligence_endpoint_key() -> *mut c_char {
    ffi_sync!(to_json_c_string(&crate::commands::intelligence::endpoint_key(app_state())))
}
