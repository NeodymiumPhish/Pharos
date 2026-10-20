//! DuckDB, the in-process engine.
//!
//! A DuckDB connection record names a file (or `:memory:`). Connect opens ONE
//! database instance for it and keeps it in `AppState::duck_dbs`, the way a
//! PostgreSQL record keeps a pool. Everything else hangs off that instance:
//!
//! - each editor tab gets its own `duckdb::Connection` (`try_clone`), so a
//!   tab's `SET`, `search_path`, temp tables and `BEGIN … COMMIT` carry from
//!   card to card (`commands::duck_session`);
//! - a pool-style command (the navigator's catalog reads, an export, a call
//!   with no tab) runs on a fresh connection of its own, as a pool command
//!   takes a pool connection;
//! - every call blocks, so it runs under `spawn_blocking`.
//!
//! DuckDB allows one read-write PROCESS per file, and two instances of the
//! same file inside one process would both believe they own it. So an
//! instance is shared by every record that names the same file
//! (`AppState::duck_instance_for_path`).

pub mod catalog;
pub mod exec;
pub mod text;

use std::path::Path;
use std::sync::{Arc, Mutex};

use duckdb::{AccessMode, Config, Connection};

/// The path a record uses for an in-memory database.
pub const IN_MEMORY: &str = ":memory:";

/// The marker on a connect failure caused by another process's write lock.
/// Swift reads it to offer "Open Read-Only".
pub const LOCKED_MARKER: &str = "[PHAROS_DUCKDB_LOCKED]";

/// The marker on a connect failure caused by a file written by a newer
/// DuckDB than this one.
pub const TOO_NEW_MARKER: &str = "[PHAROS_DUCKDB_TOO_NEW]";

/// What the user can tune for every DuckDB database (Settings ▸ Connections ▸
/// DuckDB). Blank means DuckDB's own default.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct OpenOptions {
    pub threads: Option<u32>,
    pub memory_limit: Option<String>,
    pub extension_directory: Option<String>,
    pub autoinstall_extensions: bool,
    pub allow_community_extensions: bool,
}

impl OpenOptions {
    pub fn from_settings(s: &crate::models::ConnectionSettings) -> OpenOptions {
        let blank_to_none = |v: &str| {
            let t = v.trim();
            if t.is_empty() { None } else { Some(t.to_string()) }
        };
        OpenOptions {
            threads: if s.duckdb_threads == 0 { None } else { Some(s.duckdb_threads) },
            memory_limit: blank_to_none(&s.duckdb_memory_limit),
            extension_directory: blank_to_none(&s.duckdb_extension_directory),
            autoinstall_extensions: s.duckdb_autoinstall_extensions,
            allow_community_extensions: s.duckdb_allow_community_extensions,
        }
    }
}

/// One open DuckDB database.
pub struct DuckDbInstance {
    /// The path as opened: absolute, or `:memory:`.
    pub path: String,
    pub read_only: bool,
    /// The connection the instance was opened with. It keeps the database
    /// alive and is the source of every other connection; nothing runs on it.
    root: Mutex<Connection>,
}

impl std::fmt::Debug for DuckDbInstance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DuckDbInstance").field("path", &self.path).field("read_only", &self.read_only).finish()
    }
}

impl DuckDbInstance {
    /// Open (or create) the database at `path`. A missing file is created
    /// unless `read_only`, which DuckDB refuses for a missing file.
    pub fn open(path: &str, read_only: bool, options: &OpenOptions) -> Result<DuckDbInstance, String> {
        let path = normalized_path(path);
        let mut config = Config::default()
            .access_mode(if read_only { AccessMode::ReadOnly } else { AccessMode::ReadWrite })
            .map_err(|e| e.to_string())?;
        if let Some(threads) = options.threads {
            config = config.threads(threads as i64).map_err(|e| e.to_string())?;
        }
        if let Some(limit) = &options.memory_limit {
            config = config.max_memory(limit).map_err(|e| format!("Memory limit \"{}\": {}", limit, e))?;
        }
        if let Some(dir) = &options.extension_directory {
            config = config.with("extension_directory", dir).map_err(|e| e.to_string())?;
        }
        config = config
            .with("autoinstall_known_extensions", if options.autoinstall_extensions { "true" } else { "false" })
            .map_err(|e| e.to_string())?
            .with("allow_community_extensions", if options.allow_community_extensions { "true" } else { "false" })
            .map_err(|e| e.to_string())?;

        let conn = if path == IN_MEMORY {
            Connection::open_in_memory_with_flags(config)
        } else {
            if read_only && !Path::new(&path).exists() {
                return Err(format!("The file does not exist: {}", path));
            }
            if let Some(parent) = Path::new(&path).parent() {
                if !parent.as_os_str().is_empty() && !parent.exists() {
                    return Err(format!("The folder does not exist: {}", parent.display()));
                }
            }
            Connection::open_with_flags(&path, config)
        }
        .map_err(|e| open_failure_message(&e.to_string()))?;

        Ok(DuckDbInstance { path, read_only, root: Mutex::new(conn) })
    }

    /// A new connection on this database: its own transaction, its own
    /// `search_path` and session settings.
    pub fn connect(&self) -> Result<Connection, String> {
        let root = self.root.lock().unwrap_or_else(|e| e.into_inner());
        root.try_clone().map_err(|e| e.to_string())
    }

    /// Run `work` on a fresh connection off the async runtime.
    pub async fn with_connection<T, F>(self: &Arc<Self>, work: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(&Connection) -> Result<T, String> + Send + 'static,
    {
        let instance = self.clone();
        tokio::task::spawn_blocking(move || {
            let conn = instance.connect()?;
            work(&conn)
        })
        .await
        .map_err(|e| format!("DuckDB task failed: {}", e))?
    }
}

/// `~` expanded and the path made absolute, so two records that spell the
/// same file differently share one instance.
pub fn normalized_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() || trimmed == IN_MEMORY {
        return IN_MEMORY.to_string();
    }
    let expanded = match trimmed.strip_prefix("~/") {
        Some(rest) => match std::env::var("HOME") {
            Ok(home) => format!("{}/{}", home.trim_end_matches('/'), rest),
            Err(_) => trimmed.to_string(),
        },
        None => trimmed.to_string(),
    };
    let p = Path::new(&expanded);
    match p.canonicalize() {
        Ok(c) => c.to_string_lossy().to_string(),
        // A file that does not exist yet: canonicalise its folder.
        Err(_) => match (p.parent().and_then(|d| d.canonicalize().ok()), p.file_name()) {
            (Some(dir), Some(name)) => dir.join(name).to_string_lossy().to_string(),
            _ => expanded,
        },
    }
}

/// DuckDB's open error, tagged when Swift can act on it.
fn open_failure_message(raw: &str) -> String {
    if raw.contains("Could not set lock on file") {
        format!("{} {}", LOCKED_MARKER, raw)
    } else if raw.contains("Serialization Error") || raw.contains("newer version of DuckDB") || raw.contains("storage version") {
        format!(
            "{} {} The file was written by a newer DuckDB than the one in Pharos (DuckDB {}).",
            TOO_NEW_MARKER,
            raw,
            duckdb_version()
        )
    } else {
        raw.to_string()
    }
}

/// The DuckDB library version Pharos links, e.g. `v1.5.6`.
pub fn duckdb_version() -> String {
    Connection::open_in_memory()
        .and_then(|c| c.query_row("SELECT library_version FROM pragma_version()", [], |r| r.get::<_, String>(0)))
        .unwrap_or_else(|_| "unknown".to_string())
}

/// True for the error an `interrupt()` produces.
pub fn is_interrupt(message: &str) -> bool {
    message.contains("INTERRUPT Error") || message.contains("Interrupted!")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(tag: &str) -> String {
        std::env::temp_dir()
            .join(format!("pharos_duck_{}_{}.duckdb", tag, uuid::Uuid::new_v4()))
            .to_string_lossy()
            .to_string()
    }

    #[test]
    fn opening_a_missing_file_creates_it_and_connections_share_it() {
        let path = temp_path("create");
        let db = DuckDbInstance::open(&path, false, &OpenOptions::default()).unwrap();
        assert!(Path::new(&path).exists());
        let a = db.connect().unwrap();
        a.execute_batch("CREATE TABLE t AS SELECT 1 AS x").unwrap();
        let b = db.connect().unwrap();
        let x: i32 = b.query_row("SELECT x FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(x, 1);
        drop((a, b, db));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn read_only_refuses_a_missing_file_and_writes() {
        let path = temp_path("ro");
        assert!(DuckDbInstance::open(&path, true, &OpenOptions::default()).is_err());
        {
            let db = DuckDbInstance::open(&path, false, &OpenOptions::default()).unwrap();
            db.connect().unwrap().execute_batch("CREATE TABLE t(x INT)").unwrap();
        }
        let db = DuckDbInstance::open(&path, true, &OpenOptions::default()).unwrap();
        let err = db.connect().unwrap().execute_batch("INSERT INTO t VALUES (1)").unwrap_err();
        assert!(err.to_string().to_lowercase().contains("read-only") || err.to_string().contains("read only"), "{err}");
        drop(db);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_missing_folder_is_reported_before_duckdb_runs() {
        let err = DuckDbInstance::open("/nonexistent-pharos-dir/x.duckdb", false, &OpenOptions::default()).unwrap_err();
        assert!(err.contains("folder does not exist"), "{err}");
    }

    #[test]
    fn a_bad_memory_limit_is_a_clear_error() {
        let options = OpenOptions { memory_limit: Some("lots".into()), ..Default::default() };
        let err = DuckDbInstance::open(IN_MEMORY, false, &options).unwrap_err();
        assert!(err.contains("Memory limit"), "{err}");
    }

    #[test]
    fn normalized_path_keeps_memory_and_expands_home() {
        assert_eq!(normalized_path(""), IN_MEMORY);
        assert_eq!(normalized_path(" :memory: "), IN_MEMORY);
        let home = std::env::var("HOME").unwrap();
        assert!(normalized_path("~/x-pharos-missing.duckdb").starts_with(&home));
    }

    #[test]
    fn the_linked_version_is_1_5() {
        assert!(duckdb_version().starts_with("v1.5"), "{}", duckdb_version());
    }
}
