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

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use duckdb::{AccessMode, Config, Connection};

/// What every Pharos connection sets so `ProgressHandle` has numbers to read.
const PROGRESS_SETTINGS: &str =
    "SET enable_progress_bar = true; SET enable_progress_bar_print = false; SET progress_bar_time = 300";

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
///
/// Extensions are not a setting: Pharos links its extensions in
/// (`duckdb/extension_config.cmake`), and the hardened app could not load a
/// downloaded one, so every database opens with downloads and community
/// extensions off.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct OpenOptions {
    pub threads: Option<u32>,
    pub memory_limit: Option<String>,
}

static APP_DATA_DIRECTORY: OnceLock<PathBuf> = OnceLock::new();

/// Give DuckDB Pharos-owned folders (`pharos_init`) in place of the ones in
/// `~/.duckdb`, which it shares with the DuckDB CLI and the Python package:
///
/// - `duckdb_extensions`: an extension downloaded to `~/.duckdb` would load
///   in a Debug build and fail in the hardened Release build, and
///   `duckdb_extensions()` would show the download in place of the built-in
///   copy. Pharos's folder stays empty, so every build behaves the same.
/// - `duckdb_secrets` (mode 0700): DuckDB loads every persistent secret in
///   its secret folder at startup, so another tool's S3 keys would be live in
///   Pharos. Pharos also refuses `CREATE PERSISTENT SECRET` and `… IN
///   <storage>` before they run (`exec::refuse_stored_secrets`), because
///   DuckDB writes those secrets to disk in plain text. Persistent storage
///   itself stays ON: with it off, DuckDB's postgres extension fails every
///   `ATTACH '…' (TYPE postgres)` that names no secret ("Unknown secret
///   storage found: 'local_file'", measured 2026-10-21).
pub fn set_app_data_directory(app_data_dir: &Path) {
    let _ = std::fs::create_dir_all(app_data_dir.join("duckdb_extensions"));
    let secrets = app_data_dir.join("duckdb_secrets");
    let _ = std::fs::create_dir_all(&secrets);
    let _ = std::fs::set_permissions(&secrets, std::os::unix::fs::PermissionsExt::from_mode(0o700));
    let _ = APP_DATA_DIRECTORY.set(app_data_dir.to_path_buf());
}

/// `<app data>/<name>`, or (before `set_app_data_directory`, and in tests) a
/// folder in the temporary directory.
fn app_folder(name: &str) -> PathBuf {
    match APP_DATA_DIRECTORY.get() {
        Some(dir) => dir.join(name),
        None => std::env::temp_dir().join(format!("pharos_{}", name)),
    }
}

fn extension_directory() -> PathBuf {
    app_folder("duckdb_extensions")
}

fn secret_directory() -> PathBuf {
    app_folder("duckdb_secrets")
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
        config = config
            .with("extension_directory", &extension_directory().to_string_lossy())
            .map_err(|e| e.to_string())?
            .with("autoinstall_known_extensions", "false")
            .map_err(|e| e.to_string())?
            .with("allow_community_extensions", "false")
            .map_err(|e| e.to_string())?
            .with("secret_directory", &secret_directory().to_string_lossy())
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
    /// `search_path` and session settings. Progress tracking is on for every
    /// connection (`enable_progress_bar` is per connection), never printed,
    /// and starts estimating after 300 ms, so a short query costs nothing.
    pub fn connect(&self) -> Result<Connection, String> {
        let root = self.root.lock().unwrap_or_else(|e| e.into_inner());
        let conn = root.try_clone().map_err(|e| e.to_string())?;
        conn.execute_batch(PROGRESS_SETTINGS).map_err(|e| e.to_string())?;
        Ok(conn)
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

    /// Progress is readable from another thread while a query runs, and is
    /// gone once the connection closes.
    #[test]
    fn progress_is_readable_while_a_query_runs() {
        let db = DuckDbInstance::open(IN_MEMORY, false, &OpenOptions::default()).unwrap();
        let setup = db.connect().unwrap();
        setup.execute_batch("CREATE TABLE t AS SELECT range AS x FROM range(60000000)").unwrap();
        let conn = db.connect().unwrap();
        let progress = conn.progress_handle();
        let interrupt = conn.interrupt_handle();
        let worker = std::thread::spawn(move || {
            conn.query_row("SELECT count(DISTINCT hash(x) % 100000007) FROM t", [], |r| r.get::<_, i64>(0)).ok();
            conn
        });
        let mut seen = None;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        while std::time::Instant::now() < deadline && !worker.is_finished() {
            // A reading above 0: a table scan reports real progress (a
            // `range()` source would stay at 0 for the whole run).
            if let Some(p) = progress.query_progress().and_then(|p| p.percentage).filter(|p| *p > 0.0) {
                seen = Some(p);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        interrupt.interrupt();
        let conn = worker.join().unwrap();
        let p = seen.expect("a percentage above 0 while the query ran");
        assert!(p > 0.0 && p <= 100.0, "{p}");
        drop(conn);
        assert_eq!(progress.query_progress(), None, "no reading after the connection closed");
    }

    /// The extensions `duckdb/extension_config.cmake` links in. Each must
    /// report `(BUILT-IN)` and work with no download (autoinstall is off).
    const BUILT_IN: [&str; 11] = [
        "core_functions", "parquet", "json", "icu", "autocomplete", "inet", "fts", "excel", "sqlite_scanner",
        "httpfs", "postgres_scanner",
    ];

    fn memory_conn() -> Connection {
        DuckDbInstance::open(IN_MEMORY, false, &OpenOptions::default()).unwrap().connect().unwrap()
    }

    #[test]
    fn every_extension_is_built_in() {
        let c = memory_conn();
        for name in BUILT_IN {
            let path: String = c
                .query_row(
                    "SELECT install_path FROM duckdb_extensions() WHERE extension_name = ?",
                    [name],
                    |r| r.get(0),
                )
                .unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(path, "(BUILT-IN)", "{name}");
        }
    }

    #[test]
    fn built_in_extensions_work() {
        let c = memory_conn();
        // inet
        let host: String = c.query_row("SELECT host('192.168.1.5/24'::INET)", [], |r| r.get(0)).unwrap();
        assert_eq!(host, "192.168.1.5");
        let inside: bool =
            c.query_row("SELECT '10.1.2.3'::INET <<= '10.0.0.0/8'::INET", [], |r| r.get(0)).unwrap();
        assert!(inside);
        // icu
        c.execute_batch("SET TimeZone = 'Asia/Tokyo'").unwrap();
        let tokyo: String = c
            .query_row("SELECT (TIMESTAMPTZ '2026-01-01 00:00:00+00')::VARCHAR", [], |r| r.get(0))
            .unwrap();
        assert_eq!(tokyo, "2026-01-01 09:00:00+09");
        // fts
        c.execute_batch(
            "CREATE TABLE docs(id INT, body VARCHAR);
             INSERT INTO docs VALUES (1, 'the quick brown fox'), (2, 'lazy dogs sleep');",
        )
        .unwrap();
        // Its own batch: DuckDB expands the PRAGMA while it binds the batch,
        // before `docs` exists.
        c.execute_batch("PRAGMA create_fts_index('docs', 'id', 'body')").unwrap();
        let hit: i32 = c
            .query_row(
                "SELECT id FROM (SELECT id, fts_main_docs.match_bm25(id, 'fox') AS s FROM docs) WHERE s IS NOT NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(hit, 1);
        // autocomplete
        let n: i64 = c
            .query_row("SELECT count(*) FROM sql_auto_complete('SEL')", [], |r| r.get(0))
            .unwrap();
        assert!(n > 0);
        // json, parquet, excel and sqlite: write a file, read it back.
        let dir = std::env::temp_dir().join(format!("pharos_duck_ext_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        for (ext, write, read) in [
            ("parquet", "(FORMAT parquet)", "read_parquet"),
            ("json", "(FORMAT json)", "read_json"),
            ("xlsx", "(FORMAT xlsx, HEADER true)", "read_xlsx"),
        ] {
            let f = dir.join(format!("t.{ext}")).to_string_lossy().to_string();
            c.execute_batch(&format!("COPY (SELECT 1 AS a, 'x' AS b) TO '{f}' {write}")).unwrap_or_else(|e| panic!("{ext}: {e}"));
            let b: String = c
                .query_row(&format!("SELECT b FROM {read}('{f}')"), [], |r| r.get(0))
                .unwrap_or_else(|e| panic!("{ext}: {e}"));
            assert_eq!(b, "x", "{ext}");
        }
        let lite = dir.join("t.sqlite").to_string_lossy().to_string();
        {
            let r = rusqlite::Connection::open(&lite).unwrap();
            r.execute_batch("CREATE TABLE t(a INTEGER, b TEXT); INSERT INTO t VALUES (7, 'lite');").unwrap();
        }
        c.execute_batch(&format!("ATTACH '{lite}' AS lite (TYPE sqlite)")).unwrap();
        let b: String = c.query_row("SELECT b FROM lite.t WHERE a = 7", [], |r| r.get(0)).unwrap();
        assert_eq!(b, "lite");
        // rusqlite's SQLite and the extension's renamed copy live side by side.
        let v: String = rusqlite::Connection::open_in_memory()
            .unwrap()
            .query_row("SELECT sqlite_version()", [], |r| r.get(0))
            .unwrap();
        assert!(!v.starts_with("3.38."), "rusqlite must keep its own SQLite, got {v}");
        drop(c);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A one-file HTTP server on 127.0.0.1 for httpfs: HEAD, GET and byte
    /// ranges, one request per connection. Returns the base URL.
    fn serve_once_per_connection(body: &'static [u8]) -> String {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request = String::new();
                if reader.read_line(&mut request).is_err() {
                    continue;
                }
                let mut range = None;
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                    let lower = line.to_ascii_lowercase();
                    if let Some(r) = lower.strip_prefix("range: bytes=") {
                        let (a, b) = r.trim().split_once('-').unwrap_or(("0", ""));
                        let a: usize = a.parse().unwrap_or(0);
                        let b: usize = b.parse().unwrap_or(body.len() - 1).min(body.len() - 1);
                        range = Some((a, b));
                    }
                }
                let head = request.starts_with("HEAD");
                let mut out = stream;
                let (status, part, extra) = match range {
                    Some((a, b)) => ("206 Partial Content", &body[a..=b], format!("Content-Range: bytes {a}-{b}/{}\r\n", body.len())),
                    None => ("200 OK", body, String::new()),
                };
                let _ = write!(
                    out,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\n{extra}Connection: close\r\n\r\n",
                    part.len()
                );
                if !head {
                    let _ = out.write_all(part);
                }
            }
        });
        url
    }

    #[test]
    fn httpfs_reads_a_csv_over_http() {
        let url = serve_once_per_connection(b"id,name\n1,ada\n2,grace\n3,linus\n");
        let c = memory_conn();
        let (n, last): (i64, String) = c
            .query_row(
                &format!("SELECT count(*), max(name) FROM read_csv('{url}/people.csv')"),
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((n, last.as_str()), (3, "linus"));
    }

    /// HTTPS needs OpenSSL to find CA certificates on macOS. Reads a 60-row
    /// file from DuckDB's own repository at the pinned tag.
    #[test]
    #[ignore = "needs the internet (raw.githubusercontent.com)"]
    fn live_httpfs_reads_https() {
        let c = memory_conn();
        let n: i64 = c
            .query_row(
                "SELECT count(*) FROM read_csv('https://raw.githubusercontent.com/duckdb/duckdb/v1.5.6/data/csv/real/web_page.csv')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 60);
    }

    fn live_pg_dsn() -> String {
        let v = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
        format!(
            "host={} port={} dbname={} user={}",
            v("PHAROS_TEST_PG_HOST", "127.0.0.1"),
            v("PHAROS_TEST_PG_PORT", "5432"),
            v("PHAROS_TEST_PG_DB", "nfinn"),
            v("PHAROS_TEST_PG_USER", "nfinn")
        )
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_postgres_attach_reads_and_joins() {
        let c = memory_conn();
        c.execute_batch(&format!("ATTACH '{}' AS pg (TYPE postgres, READ_ONLY)", live_pg_dsn())).unwrap();
        let v: String = c.query_row("SELECT * FROM postgres_query('pg', 'SELECT version()')", [], |r| r.get(0)).unwrap();
        assert!(v.starts_with("PostgreSQL"), "{v}");
        // A PostgreSQL catalog table joined with a DuckDB table.
        c.execute_batch("CREATE TABLE wanted AS SELECT 'pg_class' AS relname").unwrap();
        let n: i64 = c
            .query_row(
                "SELECT count(*) FROM pg.pg_catalog.pg_tables t JOIN wanted w ON t.tablename = w.relname",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 1);
    }

    /// The form Pharos would use: the password goes into an in-memory secret
    /// (made by Pharos from the Keychain), never into SQL the user sees or
    /// history stores; ATTACH names only the secret.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_postgres_attach_through_a_secret() {
        let c = memory_conn();
        c.execute_batch(
            "CREATE SECRET pharos_pg (TYPE postgres, HOST '127.0.0.1', PORT 5432, DATABASE 'nfinn', USER 'nfinn', PASSWORD 'not-used-by-trust-auth')",
        )
        .unwrap();
        let shown: String = c
            .query_row("SELECT secret_string FROM duckdb_secrets() WHERE name = 'pharos_pg'", [], |r| r.get(0))
            .unwrap();
        assert!(!shown.contains("not-used-by-trust-auth"), "duckdb_secrets() must redact: {shown}");
        let persistent: bool = c
            .query_row("SELECT persistent FROM duckdb_secrets() WHERE name = 'pharos_pg'", [], |r| r.get(0))
            .unwrap();
        assert!(!persistent, "CREATE SECRET without PERSISTENT stays in memory");
        c.execute_batch("ATTACH '' AS pg (TYPE postgres, SECRET pharos_pg, READ_ONLY)").unwrap();
        let one: i32 = c.query_row("SELECT * FROM postgres_query('pg', 'SELECT 1')", [], |r| r.get(0)).unwrap();
        assert_eq!(one, 1);
    }

    /// Secrets live in memory only: a persistent one is refused with a plain
    /// sentence, a temporary one works, and DuckDB's secret folder is
    /// Pharos's own, not `~/.duckdb/stored_secrets`.
    #[test]
    fn secrets_are_never_written_to_disk() {
        let c = memory_conn();
        for sql in [
            "CREATE PERSISTENT SECRET s1 (TYPE s3, KEY_ID 'k', SECRET 'never-on-disk')",
            "SELECT 1; CREATE SECRET s1 IN local_file (TYPE s3, SECRET 'never-on-disk')",
        ] {
            assert_eq!(exec::execute_text(&c, sql).unwrap_err(), exec::PERSISTENT_SECRET_SENTENCE, "{sql}");
            assert_eq!(exec::query_text(&c, sql, None, 0).err().as_deref(), Some(exec::PERSISTENT_SECRET_SENTENCE));
        }
        exec::execute_text(&c, "CREATE SECRET s2 (TYPE s3, KEY_ID 'k', SECRET 'in-memory')").unwrap();
        let (persistent, n): (bool, i64) = c
            .query_row("SELECT bool_or(persistent), count(*) FROM duckdb_secrets()", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        assert!(!persistent);
        assert_eq!(n, 1, "only the temporary secret, no other tool's");
        let dir: String = c.query_row("SELECT current_setting('secret_directory')", [], |r| r.get(0)).unwrap();
        assert_eq!(PathBuf::from(dir), secret_directory());
        assert!(!secret_directory().join("s1.duckdb_secret").exists());
    }

    #[test]
    fn extensions_are_never_downloaded() {
        let c = memory_conn();
        for setting in ["autoinstall_known_extensions", "allow_community_extensions"] {
            let on: bool = c
                .query_row(&format!("SELECT current_setting('{setting}')"), [], |r| r.get(0))
                .unwrap();
            assert!(!on, "{setting}");
        }
    }

    #[test]
    fn the_linked_version_is_1_5() {
        assert!(duckdb_version().starts_with("v1.5"), "{}", duckdb_version());
    }
}
