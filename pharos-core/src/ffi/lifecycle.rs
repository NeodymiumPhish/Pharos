use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use std::time::Duration;

use sqlx::PgPool;
use tokio::runtime::Runtime;

use super::*;

const SHUTDOWN_PER_POOL_BUDGET: Duration = Duration::from_secs(2);
const SHUTDOWN_TOTAL_BUDGET: Duration = Duration::from_secs(4);

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Initialize the Rust runtime, SQLite database, and credential cache.
/// `app_data_dir` must be a valid UTF-8 path to the application support directory.
/// Returns true on success.
#[no_mangle]
pub extern "C" fn pharos_init(app_data_dir: *const c_char) -> bool {
    // Initialize logger. The default filter is `error`, which hid every
    // `log::warn!` in the crate — including the one that reports a connection
    // falling back to plaintext. `RUST_LOG` still overrides it.
    let _ = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("warn"),
    )
    .try_init();

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
        let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
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
///
/// Bounded so the caller never blocks indefinitely: each pool gets
/// `SHUTDOWN_PER_POOL_BUDGET` to close gracefully, and the whole call is
/// capped at `SHUTDOWN_TOTAL_BUDGET`. A pool that exceeds its budget is
/// dropped — `PgPool::drop` is non-blocking and the OS reaps sockets on
/// process exit.
#[no_mangle]
pub extern "C" fn pharos_shutdown() {
    let Some(state) = APP_STATE.get() else { return };
    let Some(runtime) = RUNTIME.get() else { return };

    // Signal any in-flight queries to bail. The query execution loop
    // observes this flag and returns early.
    {
        let queries = state.running_queries.lock().unwrap_or_else(|e| e.into_inner());
        for q in queries.values() {
            q.cancelled.store(true, Ordering::SeqCst);
        }
    }

    // Drain the pool map so dropped pools are released even on timeout.
    let pools: Vec<PgPool> = {
        let mut conns = state.connections.lock().unwrap_or_else(|e| e.into_inner());
        conns.drain().map(|(_, p)| p).collect()
    };

    // Drain the tunnels too. Draining is what makes the timeout safe: a tunnel
    // that is not closed in time is DROPPED inside the runtime, and
    // `kill_on_drop` stops its `ssh` anyway, so no child can outlive the app.
    let tunnels = state.take_all_tunnels();

    let _ = runtime.block_on(async {
        tokio::time::timeout(SHUTDOWN_TOTAL_BUDGET, async {
            let closes = pools.into_iter().map(|pool| async move {
                let _ = tokio::time::timeout(SHUTDOWN_PER_POOL_BUDGET, pool.close()).await;
                // On timeout `pool` drops here — non-blocking.
            });
            futures::future::join_all(closes).await;

            // The tunnels last: a pool still closing needs its road open.
            // `close` caps its own wait at 2 s, and they all run together.
            futures::future::join_all(tunnels.into_iter().map(|t| t.close())).await;
        })
        .await
    });
}

/// Free a string allocated by Rust. Must be called for every non-NULL string returned by pharos_* functions.
#[no_mangle]
pub extern "C" fn pharos_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}
