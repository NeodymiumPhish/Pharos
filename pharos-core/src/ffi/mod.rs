use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::AssertUnwindSafe;
use std::sync::OnceLock;

use futures::FutureExt;
use tokio::runtime::Runtime;

use crate::state::AppState;

// ---------------------------------------------------------------------------
// Panic-safety macros for FFI boundary (must be defined before submodules)
// ---------------------------------------------------------------------------

/// Wrap a synchronous FFI function body in catch_unwind.
/// Returns a JSON error C-string if the body panics.
macro_rules! ffi_sync {
    ($body:expr) => {
        match std::panic::catch_unwind(AssertUnwindSafe(|| $body)) {
            Ok(result) => result,
            Err(_) => to_c_string("{\"error\":\"internal panic\"}")
        }
    };
}

/// Spawn an async FFI task with panic safety.
/// If the future panics, the callback is invoked with an error instead of being silently dropped.
/// The body should use its own `callback`/`ctx` variables as normal.
/// AsyncCallback (fn ptr) and usize are Copy, so the monitor task gets its own copies.
macro_rules! ffi_spawn {
    ($cb:expr, $ctx:expr, $future:expr) => {{
        let __ffi_cb: AsyncCallback = $cb;
        let __ffi_ctx: usize = $ctx as usize;
        let __handle = runtime().spawn(AssertUnwindSafe($future).catch_unwind());
        runtime().spawn(async move {
            match __handle.await {
                Ok(Ok(())) => {}
                Ok(Err(_)) => callback_err(__ffi_cb, __ffi_ctx, "internal panic"),
                Err(_) => callback_err(__ffi_cb, __ffi_ctx, "task cancelled"),
            }
        });
    }};
}

mod app_backup;
mod cards;
mod connection;
mod duckdb;
mod lifecycle;
mod model_feedback;
mod query;
mod query_history;
mod query_variables;
mod recent_files;
mod row_edit;
mod saved_queries;
mod schema;
mod session;
mod settings;
mod table_metadata;
mod tab_session;
mod table_ops;
mod tag;
mod workspace;

// ---------------------------------------------------------------------------
// Global singletons
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
pub(crate) static APP_STATE: OnceLock<AppState> = OnceLock::new();

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
/// **Note:** The callback may be invoked on any thread. The caller (Swift) must ensure
/// the context pointer remains valid until the callback fires.
pub type AsyncCallback = extern "C" fn(
    context: *mut std::ffi::c_void,
    result_json: *const c_char,
    error_msg: *const c_char,
);

/// Callback invoked while a long operation is still running.
/// - `context`: the SAME opaque pointer the operation's `AsyncCallback` is given,
///   so one box on the caller's side carries both closures.
/// - `rows_loaded`: rows held so far — a running total, never a per-chunk delta.
///
/// It is called zero or more times, always BEFORE the completion callback and
/// never after it, and always from the operation's own task. The caller's box
/// must therefore stay alive until completion (it already must), and the
/// progress side must not consume the retain the completion side ends with.
///
/// `Option<fn>` rather than a bare `fn`: a nullable C function pointer. It has
/// to be the alias that carries the `Option`, not the parameter that wraps the
/// alias — cbindgen cannot see through `Option<Alias>` and emits an opaque
/// `struct Option_ProgressCallback` for it, which no caller can pass NULL to.
pub type ProgressCallback =
    Option<extern "C" fn(context: *mut std::ffi::c_void, rows_loaded: u64)>;

/// Callback that hands a result's rows over as one PRB1 block
/// (`commands::result_block`), called once, right BEFORE the completion
/// callback, from the same task, with the SAME context.
/// - `block` / `block_len`: the block. OWNERSHIP PASSES to the caller, who
///   frees it with `pharos_free_block(block, block_len)` — Swift wraps it in a
///   `Data` with that deallocator, so the rows are never copied.
///
/// The completion callback then carries the result's other fields as JSON
/// with `"rows":[]`. NULL keeps the old contract: the rows travel inside the
/// JSON. Nullable alias, as for `ProgressCallback`.
pub type BlockCallback =
    Option<extern "C" fn(context: *mut std::ffi::c_void, block: *mut u8, block_len: usize)>;

/// Free a block a `BlockCallback` or an out-parameter handed over.
///
/// # Safety
/// `block` must be a pointer pharos-core handed over with exactly this
/// `block_len`, and must not be used after this call.
#[no_mangle]
pub unsafe extern "C" fn pharos_free_block(block: *mut u8, block_len: usize) {
    if !block.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(block, block_len)) });
    }
}

/// Hand a boxed block's ownership to the caller as (pointer, length).
fn block_into_raw(block: Vec<u8>) -> (*mut u8, usize) {
    let boxed = block.into_boxed_slice();
    let len = boxed.len();
    (Box::into_raw(boxed) as *mut u8, len)
}

/// A value whose rows can be moved out for a `BlockCallback`.
trait TakeRows {
    fn take_rows(&mut self) -> crate::commands::result_block::Rows;
}

impl TakeRows for crate::commands::query::QueryResult {
    fn take_rows(&mut self) -> crate::commands::result_block::Rows {
        std::mem::replace(&mut self.rows, crate::commands::result_block::Rows::empty())
    }
}

impl TakeRows for crate::commands::tab_session::SessionQueryResult {
    fn take_rows(&mut self) -> crate::commands::result_block::Rows {
        self.result.take_rows()
    }
}

/// A stored result (history or Session) as JSON, with its rows moved into a
/// block written to `out_block` / `out_len` when both are non-NULL (the JSON
/// then carries `"rows":[]`). NULL out-parameters keep the rows in the JSON.
fn stored_result_c_string(
    mut data: crate::commands::QueryHistoryResultData,
    out_block: *mut *mut u8,
    out_len: *mut usize,
) -> *mut c_char {
    if !out_block.is_null() && !out_len.is_null() {
        match crate::commands::result_block::from_json_rows(data.rows.get()) {
            Ok(block) => {
                let (ptr, len) = block_into_raw(block);
                unsafe {
                    *out_block = ptr;
                    *out_len = len;
                }
                data.rows = serde_json::value::RawValue::from_string("[]".to_string())
                    .expect("[] is JSON");
            }
            Err(e) => {
                return to_c_string(&serde_json::json!({ "error": format!("Stored rows: {}", e) }).to_string());
            }
        }
    }
    to_json_c_string_owned(data)
}

/// Complete a result-returning call: the rows as a block through
/// `block_callback` (when the caller gave one), then the rest as JSON
/// through `callback_json`.
fn callback_result<T: serde::Serialize + TakeRows>(
    cb: AsyncCallback,
    block_callback: BlockCallback,
    ctx: usize,
    mut value: T,
) {
    if let Some(deliver) = block_callback {
        let (ptr, len) = block_into_raw(value.take_rows().into_block());
        deliver(ctx as *mut std::ffi::c_void, ptr, len);
    }
    callback_json(cb, ctx, value);
}

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

/// Serialize `value` into ONE owned buffer that `pharos_free_string` frees,
/// dropping `value` first. For a large result (`to_json_c_string` kept the
/// value, a `String` and a `CString` copy alive at once) this holds one.
/// Exact size, as `CString::into_raw` gives: `pharos_free_string` frees with
/// `CString::from_raw`.
fn to_json_c_string_owned<T: serde::Serialize>(value: T) -> *mut c_char {
    let buf = serde_json::to_vec(&value).unwrap_or_else(|_| b"null".to_vec());
    drop(value);
    // serde_json escapes every byte below 0x20, so `buf` has no interior NUL
    // and `CString::new` only appends one; the default is never taken.
    CString::new(buf).unwrap_or_default().into_raw()
}

/// Invoke a callback with `value` as JSON, serialized straight into the
/// buffer the callback reads and with `value` dropped BEFORE the callback.
///
/// Swift decodes inside the callback, so whatever Rust holds then stays
/// alive for the whole decode. For a large result that is the biggest thing
/// in the process: `callback_ok` held the value (a `serde_json::Value` per
/// cell), the JSON `String` and a `CString` copy of it. This holds one
/// buffer. A value that fails to serialize goes to the error callback, not
/// as an empty string Swift then fails to decode.
fn callback_json<T: serde::Serialize>(cb: AsyncCallback, ctx: usize, value: T) {
    match serde_json::to_vec(&value) {
        Ok(mut buf) => {
            drop(value);
            // No interior NUL (serde_json escapes control bytes), so this
            // one terminates the string `strlen` reads.
            buf.push(0);
            cb(ctx as *mut std::ffi::c_void, buf.as_ptr() as *const c_char, std::ptr::null());
        }
        Err(e) => {
            drop(value);
            callback_err(cb, ctx, &format!("Failed to encode the result: {}", e));
        }
    }
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

#[cfg(test)]
mod json_buffer_tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    /// What each callback received, by context. Tests run on parallel
    /// threads, so each one reads back only its own context.
    static RECEIVED: Mutex<Vec<(usize, Option<String>, Option<String>)>> = Mutex::new(Vec::new());

    extern "C" fn record(ctx: *mut std::ffi::c_void, ok: *const c_char, err: *const c_char) {
        let read = |p: *const c_char| {
            (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned())
        };
        RECEIVED.lock().unwrap().push((ctx as usize, read(ok), read(err)));
    }

    fn received(ctx: usize) -> (Option<String>, Option<String>) {
        let all = RECEIVED.lock().unwrap();
        let mine: Vec<_> = all.iter().filter(|r| r.0 == ctx).collect();
        assert_eq!(mine.len(), 1, "exactly one callback for context {}", ctx);
        (mine[0].1.clone(), mine[0].2.clone())
    }

    /// A result whose cells hold every kind of control byte, NUL included:
    /// the bytes Rust hands over must still be the whole JSON text.
    fn awkward_result() -> serde_json::Value {
        serde_json::json!({
            "columns": [{"name": "c", "data_type": "text"}],
            "rows": [["a\u{0}b", "\t\n\r", "\u{1}\u{1f}\u{7f}", "ünïcødé ✓"]],
            "row_count": 1,
        })
    }

    #[test]
    fn callback_json_hands_over_the_whole_json_text() {
        let value = awkward_result();
        let expected = serde_json::to_string(&value).unwrap();
        callback_json(record, 101, value);
        let (ok, err) = received(101);
        assert_eq!(err, None);
        assert_eq!(ok.as_deref(), Some(expected.as_str()),
                   "an interior NUL would cut the text short at strlen");
    }

    #[test]
    fn a_value_that_cannot_serialize_reaches_the_error_callback() {
        // serde_json refuses a map whose keys are not strings.
        let mut bad = BTreeMap::new();
        bad.insert((1, 2), 3);
        callback_json(record, 102, bad);
        let (ok, err) = received(102);
        assert_eq!(ok, None, "no empty success payload");
        assert!(err.unwrap().contains("Failed to encode the result"));
    }

    #[test]
    fn the_owned_c_string_is_the_json_text_and_frees_cleanly() {
        let value = awkward_result();
        let expected = serde_json::to_string(&value).unwrap();
        let ptr = to_json_c_string_owned(value);
        assert!(!ptr.is_null());
        assert_eq!(unsafe { CStr::from_ptr(ptr) }.to_str().unwrap(), expected);
        // The same free the Swift side calls; a wrong-size allocation would
        // fault here under the system allocator's checks.
        lifecycle::pharos_free_string(ptr);
    }

    #[test]
    fn the_owned_c_string_keeps_the_null_fallback() {
        let mut bad = BTreeMap::new();
        bad.insert((1, 2), 3);
        let ptr = to_json_c_string_owned(bad);
        assert_eq!(unsafe { CStr::from_ptr(ptr) }.to_str().unwrap(), "null");
        lifecycle::pharos_free_string(ptr);
    }
}
