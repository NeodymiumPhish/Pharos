use std::ffi::CString;
use std::os::raw::c_char;

use tokio::runtime::Runtime;

use super::*;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Initialize the Rust runtime, SQLite database, and credential cache.
/// `app_data_dir` must be a valid UTF-8 path to the application support directory.
/// Returns true on success.
#[no_mangle]
pub extern "C" fn pharos_init(app_data_dir: *const c_char) -> bool {
    // Initialize logger
    let _ = env_logger::try_init();

    let dir = unsafe { c_str_to_string(app_data_dir) };
    let path = std::path::PathBuf::from(&dir);

    // Create tokio runtime
    let rt = match Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            log::error!("Failed to create tokio runtime: {}", e);
            return false;
        }
    };
    let _ = RUNTIME.set(rt);

    // Initialize SQLite
    let metadata_db = match crate::db::sqlite::init_database(&path) {
        Ok(db) => db,
        Err(e) => {
            log::error!("Failed to initialize SQLite: {}", e);
            return false;
        }
    };

    let state = AppState::new(metadata_db);

    // Load connections and initialize password cache
    {
        let db = state.metadata_db.lock().unwrap();
        if let Ok(configs) = crate::db::sqlite::load_connections(&db) {
            let connection_ids: Vec<String> = configs.iter().map(|c| c.id.clone()).collect();
            match crate::db::credentials::migrate_legacy_passwords(&connection_ids) {
                Ok(passwords) => {
                    state.init_password_cache(passwords);
                }
                Err(e) => {
                    log::warn!("Failed to load passwords from keychain: {}", e);
                }
            }
            for config in configs {
                state.set_config(config);
            }
        }
    }

    let _ = APP_STATE.set(state);
    true
}

/// Shut down the Rust runtime. Call on app termination.
#[no_mangle]
pub extern "C" fn pharos_shutdown() {
    // OnceLock values are never dropped, but we can close open pools
    if let Some(state) = APP_STATE.get() {
        let pools: Vec<_> = {
            let conns = state.connections.lock().unwrap();
            conns.values().cloned().collect()
        };
        if let Some(rt) = RUNTIME.get() {
            for pool in pools {
                rt.block_on(pool.close());
            }
        }
    }
}

/// Free a string allocated by Rust. Must be called for every non-NULL string returned by pharos_* functions.
#[no_mangle]
pub extern "C" fn pharos_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}
