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
    // Initialize logger. The BUILT filter is `trace` so that every record in
    // the crate can reach the logger, and the effective level is then capped
    // to `warn` — which is what the engine has always written — through
    // `log::set_max_level`. Building at `warn` instead would make the cap
    // permanent: `pharos_set_log_level` could never raise it, because
    // env_logger's own filter would still throw the record away.
    //
    // `RUST_LOG` overrides all of it: a developer who names a level in the
    // environment keeps it, and `pharos_set_log_level` refuses to interfere.
    let _ = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("trace"),
    )
    .try_init();
    if !rust_log_is_set() {
        log::set_max_level(log::LevelFilter::Warn);
    }

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

    // The SSH askpass helper (D3). A failure here is not fatal: every tunnel
    // that uses the agent or a key with no passphrase works without it, and
    // the ones that need it report a clear reason when they are tried.
    if let Err(e) = crate::db::ssh_tunnel::install_askpass_helper(&path) {
        log::warn!("Could not write the SSH password helper: {}", e);
    }

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

    // Load the settings blob once. Every engine-side reader takes a snapshot
    // from `state.settings()`; `save_settings` refreshes it.
    {
        let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
        match crate::db::sqlite::load_settings(&db) {
            Ok(settings) => state.replace_settings(settings),
            Err(e) => log::error!("Failed to load settings: {}", e),
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

// ---------------------------------------------------------------------------
// Log level
// ---------------------------------------------------------------------------

/// Whether the developer named a level in the environment.
///
/// Their choice wins: `pharos_init` leaves env_logger's own filter alone and
/// `pharos_set_log_level` is a no-op, so a `RUST_LOG=debug` run is not
/// silenced by whatever the user last picked in Settings.
fn rust_log_is_set() -> bool {
    std::env::var_os("RUST_LOG").is_some_and(|v| !v.is_empty())
}

/// The level a name asks for, or `None` when it is not one Pharos accepts.
///
/// Case-insensitive, and `warn` and `warning` are the same level: the Swift
/// enum spells it `warning`, `log` spells it `warn`.
pub(crate) fn parse_log_level(name: &str) -> Option<log::LevelFilter> {
    match name.trim().to_ascii_lowercase().as_str() {
        "error" => Some(log::LevelFilter::Error),
        "warn" | "warning" => Some(log::LevelFilter::Warn),
        "info" => Some(log::LevelFilter::Info),
        "debug" => Some(log::LevelFilter::Debug),
        _ => None,
    }
}

/// Set how much the engine writes to the log. Accepts `error`, `warn`
/// (or `warning`), `info` and `debug`, in any case.
///
/// Returns false, changing nothing, when the name is not one of those or when
/// `RUST_LOG` is set in the environment.
#[no_mangle]
pub extern "C" fn pharos_set_log_level(level: *const c_char) -> bool {
    // No `ffi_sync!` here: that wrapper returns a C string, and nothing in
    // this body can panic — the pointer read is already fallible.
    if rust_log_is_set() {
        return false;
    }
    let Some(name) = (unsafe { c_str_to_option(level) }) else {
        return false;
    };
    let Some(filter) = parse_log_level(&name) else {
        log::warn!("Ignoring unknown log level {:?}", name);
        return false;
    };
    log::set_max_level(filter);
    true
}

/// Free a string allocated by Rust. Must be called for every non-NULL string returned by pharos_* functions.
#[no_mangle]
pub extern "C" fn pharos_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}

#[cfg(test)]
mod log_level_tests {
    use super::parse_log_level;
    use log::LevelFilter;

    #[test]
    fn every_accepted_name_maps_to_its_level() {
        assert_eq!(parse_log_level("error"), Some(LevelFilter::Error));
        assert_eq!(parse_log_level("warn"), Some(LevelFilter::Warn));
        assert_eq!(parse_log_level("info"), Some(LevelFilter::Info));
        assert_eq!(parse_log_level("debug"), Some(LevelFilter::Debug));
    }

    /// The Swift enum spells the second level `warning`; `log` spells it
    /// `warn`. Both must be read, or the default setting would be rejected.
    #[test]
    fn warning_and_warn_are_the_same_level() {
        assert_eq!(parse_log_level("warning"), Some(LevelFilter::Warn));
        assert_eq!(parse_log_level("warning"), parse_log_level("warn"));
    }

    #[test]
    fn the_name_is_read_whatever_case_it_arrives_in() {
        for name in ["DEBUG", "Debug", "dEbUg"] {
            assert_eq!(parse_log_level(name), Some(LevelFilter::Debug), "{name}");
        }
        assert_eq!(parse_log_level("  Info  "), Some(LevelFilter::Info));
    }

    #[test]
    fn an_unknown_name_is_rejected() {
        for name in ["", "trace", "off", "verbose", "warning!", "3"] {
            assert_eq!(parse_log_level(name), None, "{name} must not be accepted");
        }
    }

    /// `trace` and `off` are deliberately absent: `trace` on a database
    /// client writes credentials-adjacent chatter, and `off` would hide the
    /// plaintext-fallback warning the user needs to see.
    #[test]
    fn trace_and_off_are_not_offered() {
        assert_eq!(parse_log_level("trace"), None);
        assert_eq!(parse_log_level("off"), None);
    }
}
