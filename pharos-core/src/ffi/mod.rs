use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;

use tokio::runtime::Runtime;

use crate::state::AppState;

mod connection;
mod lifecycle;
mod query;
mod query_history;
mod saved_queries;
mod schema;
mod settings;
mod table_metadata;
mod table_ops;

// ---------------------------------------------------------------------------
// Global singletons
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static APP_STATE: OnceLock<AppState> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get().expect("pharos_init() not called")
}

fn app_state() -> &'static AppState {
    APP_STATE.get().expect("pharos_init() not called")
}

// ---------------------------------------------------------------------------
// Callback type for async results
// ---------------------------------------------------------------------------

/// Callback invoked when an async operation completes.
/// - `context`: opaque pointer passed through from the caller (e.g. Swift continuation)
/// - `result_json`: JSON-encoded result on success, NULL on error
/// - `error_msg`: error message on failure, NULL on success
///
/// Exactly one of `result_json` / `error_msg` will be non-NULL.
/// The caller must NOT free the strings --- they are freed by Rust after the callback returns.
pub type AsyncCallback = extern "C" fn(
    context: *mut std::ffi::c_void,
    result_json: *const c_char,
    error_msg: *const c_char,
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Convert a C string to a Rust String. Returns empty string for NULL.
unsafe fn c_str_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// Convert a C string to an Option<String>. Returns None for NULL.
unsafe fn c_str_to_option(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

/// Allocate a C string from a Rust &str. Caller must free with `pharos_free_string`.
fn to_c_string(s: &str) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Helper: serialize a value to a JSON C-string.
fn to_json_c_string<T: serde::Serialize>(value: &T) -> *mut c_char {
    let json = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    to_c_string(&json)
}

/// Invoke a callback with a JSON result. Takes `usize` context to stay Send-safe across awaits.
fn callback_ok(cb: AsyncCallback, ctx: usize, json: &str) {
    let c = CString::new(json).unwrap_or_default();
    cb(ctx as *mut std::ffi::c_void, c.as_ptr(), std::ptr::null());
}

/// Invoke a callback with an error. Takes `usize` context to stay Send-safe across awaits.
fn callback_err(cb: AsyncCallback, ctx: usize, error: &str) {
    let c = CString::new(error).unwrap_or_default();
    cb(ctx as *mut std::ffi::c_void, std::ptr::null(), c.as_ptr());
}
