//! Attach other databases to an open DuckDB database (Query ▸ Attach
//! Database…): a saved PostgreSQL connection (DuckDB's `postgres_scanner`,
//! linked into Pharos) or a DuckDB or SQLite database file.
//!
//! The password never appears in SQL that a user sees or that history
//! stores: Pharos makes a TEMPORARY DuckDB secret from the connection's
//! password (Keychain or this session's) and attaches with
//! `ATTACH '' AS alias (TYPE postgres, SECRET name)`. Both statements run
//! here, outside every history path. DuckDB lists such a secret with the
//! password redacted and never writes it to disk (`allow_persistent_secrets`
//! is off, `db::duckdb`).
//!
//! A PostgreSQL attach lives while its PostgreSQL connection is connected: it
//! reuses that connection's SSH tunnel (127.0.0.1:<local port>), and
//! `connection::disconnect_postgres` detaches it before the tunnel closes.
//! Attached databases and secrets belong to the DuckDB instance, so every tab
//! on that file sees them.
//!
//! DuckDB keeps no attach between sessions, so Pharos remembers each attach
//! made here (`duck_attachments`) and makes it again: a file when the DuckDB
//! record connects (`restore`), a PostgreSQL connection when both are
//! connected (`restore`, `restore_for_pg`). A restore never starts a
//! PostgreSQL connect, so it never asks for a password. Detach forgets.
//!
//! One writer per file (rule G1): DuckDB's file lock does not stop a second
//! instance in the SAME process, so a file may be held by more than one
//! Pharos instance — opened as a record, or attached — only when every
//! holder is read-only (`check_file_holders`).

use std::sync::{Arc, Weak};

use serde::Serialize;

use crate::db::duckdb::{normalized_path, DuckDbInstance, IN_MEMORY};
use crate::db::sqlite::{self, DuckAttachmentRow};
use crate::models::{ConnectionConfig, Engine, SslMode};
use crate::state::AppState;

/// One live PostgreSQL attach: its secret goes when it detaches.
pub struct PgAttachment {
    pub pg_id: String,
    pub alias: String,
    pub secret: String,
    pub read_only: bool,
    pub instance: Weak<DuckDbInstance>,
}

/// What to attach.
#[derive(Debug, Clone, PartialEq)]
pub enum AttachSource {
    /// A saved PostgreSQL connection, by id. It must be connected.
    Postgres(String),
    /// A DuckDB or SQLite database file.
    File(String),
}

impl AttachSource {
    /// The FFI form: kind `"postgres"` with a connection id, or `"file"`
    /// with a path.
    pub fn parse(kind: &str, value: String) -> Result<AttachSource, String> {
        match kind {
            "postgres" => Ok(AttachSource::Postgres(value)),
            "file" => Ok(AttachSource::File(value)),
            other => Err(format!("Unknown attach source \"{}\".", other)),
        }
    }
}

/// One database attached to (or remembered by) a DuckDB database, as the
/// front end lists it.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentInfo {
    pub alias: String,
    /// DuckDB's database type: "postgres", "duckdb", "sqlite"…
    pub kind: String,
    /// The file (or URL) of a file database.
    pub path: Option<String>,
    pub pg_id: Option<String>,
    pub pg_name: Option<String>,
    pub read_only: bool,
    /// Attached now. False for a remembered attach that waits for its
    /// PostgreSQL connection, or that could not be restored.
    pub attached: bool,
    /// Pharos attaches it again each time this DuckDB record opens.
    pub remembered: bool,
}

/// What `restore_for_pg` did on one DuckDB database.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RestoreOutcome {
    pub duck_connection_id: String,
    pub alias: String,
    pub error: Option<String>,
}

/// The CA bundle macOS ships. libpq (with Pharos's OpenSSL) has no system
/// trust store of its own, so `verify-ca` / `verify-full` without a root
/// certificate on the record use this file — the same Apple roots sqlx
/// trusts on the PostgreSQL path, without certificates a user added to the
/// Keychain.
const MACOS_CA_BUNDLE: &str = "/etc/ssl/cert.pem";

/// Names an alias may not take: DuckDB's own databases.
const RESERVED_ALIASES: [&str; 4] = ["memory", "system", "temp", "main"];

/// A default alias from a name: lower case, `[a-z0-9_]`, starting with a
/// letter or `_`. `prefix` starts a name that would otherwise start with a
/// digit or be empty or reserved ("Live Analysis" → `live_analysis`,
/// "2024 db" with `pg` → `pg_2024_db`).
pub fn default_alias(name: &str, prefix: &str) -> String {
    let mut out = String::new();
    for ch in name.trim().chars() {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let mut out = out.trim_matches('_').to_string();
    if out.is_empty() || out.starts_with(|c: char| c.is_ascii_digit()) {
        out = format!("{}_{}", prefix, out).trim_end_matches('_').to_string();
    }
    if RESERVED_ALIASES.contains(&out.as_str()) {
        out = format!("{}_{}", prefix, out);
    }
    out.truncate(63);
    out
}

/// The default alias of a source: the connection's name, or the file's name
/// without its extension.
fn source_default_alias(source: &AttachSource, state: &AppState) -> String {
    match source {
        AttachSource::Postgres(pg_id) => {
            default_alias(&state.get_config(pg_id).map(|c| c.name).unwrap_or_default(), "pg")
        }
        AttachSource::File(path) => default_alias(
            &std::path::Path::new(path).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            "db",
        ),
    }
}

/// `base`, or `base_2`, `base_3`… — the first name not in `taken`.
fn first_free_alias(base: &str, taken: &[String]) -> String {
    if !taken.iter().any(|t| t == base) {
        return base.to_string();
    }
    (2..)
        .map(|n| {
            let suffix = format!("_{}", n);
            format!("{}{}", &base[..base.len().min(63 - suffix.len())], suffix)
        })
        .find(|a| !taken.contains(a))
        .unwrap_or_default()
}

/// An alias the user typed: the same rules `default_alias` produces.
pub fn validate_alias(alias: &str) -> Result<(), String> {
    let ok = !alias.is_empty()
        && alias.len() <= 63
        && alias.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && alias.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !ok {
        return Err(format!(
            "\"{}\" cannot name an attached database: use lower-case letters, digits and _, starting with a letter.",
            alias
        ));
    }
    if RESERVED_ALIASES.contains(&alias) {
        return Err(format!("\"{}\" is one of DuckDB's own database names.", alias));
    }
    Ok(())
}

/// A SQL string literal.
fn literal(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// The file's name, for messages.
fn file_name(path: &str) -> String {
    std::path::Path::new(path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| path.to_string())
}

/// Where libpq connects: the connection's SSH tunnel when it has one.
pub fn endpoint(config: &ConnectionConfig, tunnel_port: Option<u16>) -> (String, u16) {
    match tunnel_port {
        Some(port) => ("127.0.0.1".to_string(), port),
        None => (config.host.clone(), config.port),
    }
}

/// The libpq `sslrootcert` for a record, or None.
fn root_cert(config: &ConnectionConfig) -> Result<Option<String>, String> {
    if let Some(path) = config.ssl_root_cert_path.as_deref().filter(|p| !p.trim().is_empty()) {
        return Ok(Some(path.to_string()));
    }
    match config.ssl_mode {
        SslMode::VerifyCa | SslMode::VerifyFull => {
            if std::path::Path::new(MACOS_CA_BUNDLE).exists() {
                Ok(Some(MACOS_CA_BUNDLE.to_string()))
            } else {
                Err(format!(
                    "SSL mode {} needs a root certificate: give the connection one (Connections ▸ SSL Root Certificate).",
                    config.ssl_mode
                ))
            }
        }
        _ => Ok(None),
    }
}

/// `CREATE OR REPLACE SECRET` for one attach. Temporary: never PERSISTENT.
pub fn secret_sql(
    secret: &str,
    config: &ConnectionConfig,
    host: &str,
    port: u16,
    password: &str,
) -> Result<String, String> {
    let mut opts = vec![
        "TYPE postgres".to_string(),
        format!("HOST {}", literal(host)),
        format!("PORT {}", literal(&port.to_string())),
        format!("DATABASE {}", literal(&config.database)),
        format!("USER {}", literal(&config.username)),
        format!("SSLMODE {}", literal(&config.ssl_mode.to_string())),
        format!("APPLICATION_NAME {}", literal("Pharos (DuckDB attach)")),
    ];
    if !password.is_empty() {
        opts.push(format!("PASSWORD {}", literal(password)));
    }
    if let Some(cert) = root_cert(config)? {
        opts.push(format!("SSLROOTCERT {}", literal(&cert)));
    }
    Ok(format!("CREATE OR REPLACE TEMPORARY SECRET {} ({})", secret, opts.join(", ")))
}

pub fn attach_sql(alias: &str, secret: &str, read_only: bool) -> String {
    format!(
        "ATTACH '' AS {} (TYPE postgres, SECRET {}{})",
        alias,
        secret,
        if read_only { ", READ_ONLY" } else { "" }
    )
}

/// The type of a database file from its first 16 bytes: "duckdb" or
/// "sqlite". Checked before DuckDB sees the file, because a read-write
/// ATTACH of a missing file CREATES it (measured 2026-10-31) and an
/// attach of some other file gives a confusing error.
pub fn database_kind(path: &str) -> Result<&'static str, String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|_| format!("The file is not there: {}", path))?;
    let mut header = [0u8; 16];
    let mut read = 0;
    while read < header.len() {
        match file.read(&mut header[read..]) {
            Ok(0) => break,
            Ok(n) => read += n,
            Err(e) => return Err(format!("Pharos cannot read {}: {}", file_name(path), e)),
        }
    }
    if read == 16 && &header == b"SQLite format 3\0" {
        Ok("sqlite")
    } else if read >= 12 && &header[8..12] == b"DUCK" {
        Ok("duckdb")
    } else {
        Err(format!("\"{}\" is not a DuckDB or SQLite database.", file_name(path)))
    }
}

/// `ATTACH '<path>' AS "<alias>"` for a database file of type `kind`.
pub fn file_attach_sql(path: &str, alias: &str, kind: &str, read_only: bool) -> String {
    let mut opts = Vec::new();
    if kind == "sqlite" {
        opts.push("TYPE sqlite");
    }
    if read_only {
        opts.push("READ_ONLY");
    }
    let opts = if opts.is_empty() { String::new() } else { format!(" ({})", opts.join(", ")) };
    format!("ATTACH {} AS \"{}\"{}", literal(path), alias, opts)
}

fn secret_name(alias: &str) -> String {
    format!("pharos_pg_{}", alias)
}

/// Drop entries whose DuckDB instance has closed.
fn prune(list: &mut Vec<PgAttachment>) {
    list.retain(|a| a.instance.strong_count() > 0);
}

/// The live PostgreSQL attach of `pg_id` on `instance`, as (alias, read_only).
fn pg_attachment_on(state: &AppState, instance: &Arc<DuckDbInstance>, pg_id: &str) -> Option<(String, bool)> {
    let mut list = state.pg_attachments.lock().unwrap_or_else(|e| e.into_inner());
    prune(&mut list);
    list.iter()
        .find(|a| a.pg_id == pg_id && a.instance.upgrade().is_some_and(|i| Arc::ptr_eq(&i, instance)))
        .map(|a| (a.alias.clone(), a.read_only))
}

// MARK: - One writer per file (G1)

/// One place in this process that holds a database file.
#[derive(Debug, Clone, PartialEq)]
struct FileHolder {
    /// The DuckDB record that has the file open, or that it is attached to.
    record: String,
    /// The alias, when the file is attached (not opened as the record).
    alias: Option<String>,
    read_only: bool,
}

/// The message for a request that `holder` blocks, or None when both can
/// share the file (both read-only).
fn holder_conflict(path: &str, holder: &FileHolder, want_read_only: bool) -> Option<String> {
    if holder.read_only && want_read_only {
        return None;
    }
    let file = file_name(path);
    let record = &holder.record;
    Some(match (&holder.alias, holder.read_only) {
        (None, false) => format!("\"{}\" is open in Pharos (\"{}\") with write access. Close its tabs first.", file, record),
        (None, true) => format!("\"{}\" is open in Pharos (\"{}\"). Use Read-only, or close its tabs first.", file, record),
        (Some(alias), false) => {
            format!("\"{}\" is attached to \"{}\" as {} with write access. Detach it there first.", file, record, alias)
        }
        (Some(alias), true) => {
            format!("\"{}\" is attached to \"{}\" as {}. Use Read-only, or detach it there first.", file, record, alias)
        }
    })
}

/// Every open record and every attach that holds `path` (normalized),
/// except the attach `skip` (an instance and an alias).
async fn file_holders(
    state: &AppState,
    path: &str,
    skip: Option<(&Arc<DuckDbInstance>, &str)>,
) -> Result<Vec<FileHolder>, String> {
    let mut seen: Vec<(Arc<DuckDbInstance>, String)> = Vec::new();
    for (id, instance) in state.duck_entries() {
        if !seen.iter().any(|(i, _)| Arc::ptr_eq(i, &instance)) {
            let name = state.get_config(&id).map(|c| c.name).unwrap_or(id);
            seen.push((instance, name));
        }
    }
    if let Some(closing) = state.duck_still_closing(path) {
        if !seen.iter().any(|(i, _)| Arc::ptr_eq(i, &closing)) {
            seen.push((closing, file_name(path)));
        }
    }
    let mut holders = Vec::new();
    for (instance, record) in seen {
        if instance.path == path {
            holders.push(FileHolder { record: record.clone(), alias: None, read_only: instance.read_only });
        }
        let p = path.to_string();
        let attached: Vec<(String, bool)> = instance
            .with_connection(move |c| {
                let mut stmt = c
                    .prepare("SELECT database_name, readonly FROM duckdb_databases() WHERE path = ?")
                    .map_err(|e| e.to_string())?;
                let rows = stmt
                    .query_map([&p], |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)))
                    .map_err(|e| e.to_string())?;
                rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
            })
            .await?;
        for (alias, read_only) in attached {
            if skip.is_some_and(|(i, a)| Arc::ptr_eq(i, &instance) && a == alias) {
                continue;
            }
            holders.push(FileHolder { record: record.clone(), alias: Some(alias), read_only });
        }
    }
    Ok(holders)
}

/// G1 for a new attach or open of `path` (normalized): refused when another
/// holder could write, or when this one would write beside any holder.
pub async fn check_file_holders(state: &AppState, path: &str, read_only: bool) -> Result<(), String> {
    check_file_holders_except(state, path, read_only, None).await
}

async fn check_file_holders_except(
    state: &AppState,
    path: &str,
    read_only: bool,
    skip: Option<(&Arc<DuckDbInstance>, &str)>,
) -> Result<(), String> {
    if path == IN_MEMORY {
        return Ok(());
    }
    for holder in file_holders(state, path, skip).await? {
        if let Some(message) = holder_conflict(path, &holder, read_only) {
            return Err(message);
        }
    }
    Ok(())
}

// MARK: - Attach

/// Attach `source` to the DuckDB database of `duck_id` and remember it, so
/// the record attaches it again each time it opens. `alias` None = a default
/// from the source's name (made unique). A source already attached to this
/// database returns that attach.
pub async fn attach(
    duck_id: String,
    source: AttachSource,
    alias: Option<String>,
    read_only: bool,
    state: &AppState,
) -> Result<AttachmentInfo, String> {
    let info = attach_now(&duck_id, &source, alias, read_only, state).await?;
    remember(state, &duck_id, &source, &info);
    Ok(info)
}

fn remember(state: &AppState, duck_id: &str, source: &AttachSource, info: &AttachmentInfo) {
    let row = DuckAttachmentRow {
        duck_connection_id: duck_id.to_string(),
        alias: info.alias.clone(),
        kind: info.kind.clone(),
        pg_connection_id: match source {
            AttachSource::Postgres(id) => Some(id.clone()),
            AttachSource::File(_) => None,
        },
        file_path: info.path.clone(),
        read_only: info.read_only,
    };
    let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
    if let Err(e) = sqlite::save_duck_attachment(&db, &row) {
        log::warn!("Could not remember the attach {}: {}", info.alias, e);
    }
}

/// Attach without remembering (a restore, or `attach`).
async fn attach_now(
    duck_id: &str,
    source: &AttachSource,
    alias: Option<String>,
    read_only: bool,
    state: &AppState,
) -> Result<AttachmentInfo, String> {
    let instance = state.require_duck(duck_id)?;
    let typed = alias.map(|a| a.trim().to_string()).filter(|a| !a.is_empty());
    if let Some(a) = &typed {
        validate_alias(a)?;
    }
    let base = source_default_alias(source, state);
    match source {
        AttachSource::Postgres(pg_id) => attach_postgres(&instance, pg_id, typed, base, read_only, state).await,
        AttachSource::File(path) => attach_file(&instance, path, typed, base, read_only, state).await,
    }
}

/// The names in use on an instance.
async fn taken_aliases(instance: &Arc<DuckDbInstance>) -> Result<Vec<String>, String> {
    instance
        .with_connection(|c| {
            let mut stmt = c.prepare("SELECT database_name FROM duckdb_databases()").map_err(|e| e.to_string())?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0)).map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await
}

/// The alias to use: the typed one when free, else the first free default.
fn choose_alias(typed: Option<String>, base: &str, taken: &[String]) -> Result<String, String> {
    match typed {
        Some(a) if taken.contains(&a) => {
            Err(format!("A database named \"{}\" is already attached. Choose another name.", a))
        }
        Some(a) => Ok(a),
        None => Ok(first_free_alias(base, taken)),
    }
}

async fn attach_postgres(
    instance: &Arc<DuckDbInstance>,
    pg_id: &str,
    typed: Option<String>,
    base: String,
    read_only: bool,
    state: &AppState,
) -> Result<AttachmentInfo, String> {
    let config = state.get_config(pg_id).ok_or_else(|| format!("No connection {}", pg_id))?;
    if config.engine != Engine::Postgres {
        return Err(format!("\"{}\" is not a PostgreSQL connection.", config.name));
    }
    let info = |alias: String, read_only: bool| AttachmentInfo {
        alias,
        kind: "postgres".to_string(),
        path: None,
        pg_id: Some(pg_id.to_string()),
        pg_name: Some(config.name.clone()),
        read_only,
        attached: true,
        remembered: false,
    };
    if let Some((alias, ro)) = pg_attachment_on(state, instance, pg_id) {
        return Ok(info(alias, ro));
    }
    // Connected, and its tunnel (if any) alive: the pool check reaps a dead one.
    state
        .require_pool(pg_id)
        .map_err(|_| format!("Connect \"{}\" first.", config.name))?;
    let tunnel_port = state.tunnel_local_port(pg_id);
    if config.ssh_tunnel.is_some() && tunnel_port.is_none() {
        return Err(format!("The SSH tunnel of \"{}\" is not open. Connect it again.", config.name));
    }
    let (host, port) = endpoint(&config, tunnel_port);
    let stored = state.get_cached_password(pg_id).unwrap_or_else(|| config.password.clone());
    let password = state.effective_password(pg_id, &stored);

    let alias = choose_alias(typed, &base, &taken_aliases(instance).await?)?;
    let read_only = read_only || config.read_only;
    let secret = secret_name(&alias);
    let create = secret_sql(&secret, &config, &host, port, &password)?;
    let attach = attach_sql(&alias, &secret, read_only);

    let secret_c = secret.clone();
    instance
        .with_connection(move |c| {
            c.execute_batch(&create).map_err(|e| crate::commands::connection::sanitize_error(&e.to_string()))?;
            if let Err(e) = c.execute_batch(&attach) {
                let _ = c.execute_batch(&format!("DROP TEMPORARY SECRET IF EXISTS {}", secret_c));
                return Err(crate::commands::connection::sanitize_error(&e.to_string()));
            }
            Ok(())
        })
        .await?;

    let mut list = state.pg_attachments.lock().unwrap_or_else(|e| e.into_inner());
    prune(&mut list);
    list.push(PgAttachment {
        pg_id: pg_id.to_string(),
        alias: alias.clone(),
        secret,
        read_only,
        instance: Arc::downgrade(instance),
    });
    Ok(info(alias, read_only))
}

async fn attach_file(
    instance: &Arc<DuckDbInstance>,
    path: &str,
    typed: Option<String>,
    base: String,
    read_only: bool,
    state: &AppState,
) -> Result<AttachmentInfo, String> {
    let path = normalized_path(path);
    if path == IN_MEMORY {
        return Err("Choose a database file to attach.".to_string());
    }
    if path == instance.path {
        return Err("A database cannot attach its own file.".to_string());
    }
    let info = |alias: String, kind: &str, read_only: bool| AttachmentInfo {
        alias,
        kind: kind.to_string(),
        path: Some(path.clone()),
        pg_id: None,
        pg_name: None,
        read_only,
        attached: true,
        remembered: false,
    };
    // Already attached here: that attach.
    let p = path.clone();
    let existing: Option<(String, String, bool)> = instance
        .with_connection(move |c| {
            match c.query_row(
                "SELECT database_name, type, readonly FROM duckdb_databases() WHERE path = ?",
                [&p],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            ) {
                Ok(row) => Ok(Some(row)),
                Err(duckdb::Error::QueryReturnedNoRows) => Ok(None),
                Err(e) => Err(e.to_string()),
            }
        })
        .await?;
    if let Some((alias, kind, ro)) = existing {
        return Ok(info(alias, &kind, ro));
    }
    let kind = database_kind(&path)?;
    check_file_holders(state, &path, read_only).await?;
    let alias = choose_alias(typed, &base, &taken_aliases(instance).await?)?;
    let sql = file_attach_sql(&path, &alias, kind, read_only);
    instance.with_connection(move |c| c.execute_batch(&sql).map_err(|e| e.to_string())).await?;
    Ok(info(alias, kind, read_only))
}

/// `ATTACH '<url>' AS "<alias>" (READ_ONLY)` for a DuckDB database file a web
/// page serves over HTTP (`pharos://duckdb/attach`). httpfs reads it in place
/// with Range requests; DuckDB attaches such a file read-only only. The URL
/// must be `http(s)://`, with no user, password or control characters.
pub fn remote_attach_sql(url: &str, alias: &str) -> Result<String, String> {
    let lower = url.to_ascii_lowercase();
    let rest = lower
        .strip_prefix("https://")
        .or_else(|| lower.strip_prefix("http://"))
        .ok_or_else(|| "Only an http:// or https:// database can be attached from a link.".to_string())?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() || authority.contains('@') {
        return Err("The link's database address needs a host and no user name or password.".to_string());
    }
    if url.chars().any(char::is_control) {
        return Err("The link's database address has a control character.".to_string());
    }
    validate_alias(alias)?;
    Ok(format!("ATTACH {} AS \"{}\" (READ_ONLY)", literal(url), alias))
}

/// Attach the DuckDB database at `url` to the DuckDB database of `duck_id`,
/// read-only, as `alias`. It runs here, so no card and no history entry shows
/// it; the front end reloads the navigator after. Returns the alias. A link
/// attach is not remembered: its in-memory database is new each time.
pub async fn attach_remote(duck_id: String, url: String, alias: String, state: &AppState) -> Result<String, String> {
    let instance = state.require_duck(&duck_id)?;
    let attach = remote_attach_sql(&url, &alias)?;
    let alias_c = alias.clone();
    instance
        .with_connection(move |c| {
            let taken: bool = c
                .query_row("SELECT count(*) > 0 FROM duckdb_databases() WHERE database_name = ?", [&alias_c], |r| r.get(0))
                .map_err(|e| e.to_string())?;
            if taken {
                return Err(format!("A database named \"{}\" is already attached.", alias_c));
            }
            c.execute_batch(&attach).map_err(|e| e.to_string())
        })
        .await?;
    Ok(alias)
}

// MARK: - Restore

/// Make the remembered attaches of `duck_id` again (its record has just
/// connected): every file, and every PostgreSQL connection that is connected
/// now. The others wait for `restore_for_pg`. A failure does not stop the
/// connect: it is kept for the front end (`take_restore_failures`).
pub async fn restore(duck_id: &str, state: &AppState) {
    let rows = {
        let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
        sqlite::load_duck_attachments(&db, duck_id).unwrap_or_else(|e| {
            log::warn!("Could not read the attaches of {}: {}", duck_id, e);
            Vec::new()
        })
    };
    let mut failures = Vec::new();
    for row in rows {
        let source = match (&row.pg_connection_id, &row.file_path) {
            (Some(pg), _) if state.require_pool(pg).is_ok() => AttachSource::Postgres(pg.clone()),
            (Some(_), _) => continue,
            (None, Some(path)) => AttachSource::File(path.clone()),
            (None, None) => continue,
        };
        if let Err(e) = attach_now(duck_id, &source, Some(row.alias.clone()), row.read_only, state).await {
            failures.push(format!("{}: {}", row.alias, e));
        }
    }
    if !failures.is_empty() {
        let mut map = state.attach_restore_failures.lock().unwrap_or_else(|e| e.into_inner());
        map.insert(duck_id.to_string(), failures);
    }
}

/// The restore failures of `duck_id` since the last call, then none.
pub fn take_restore_failures(duck_id: &str, state: &AppState) -> Vec<String> {
    let mut map = state.attach_restore_failures.lock().unwrap_or_else(|e| e.into_inner());
    map.remove(duck_id).unwrap_or_default()
}

/// `pg_id` has just connected: attach it to each connected DuckDB record
/// that remembers it. Returns what happened on each, so the front end can
/// reload those navigators and show a failure.
pub async fn restore_for_pg(pg_id: &str, state: &AppState) -> Vec<RestoreOutcome> {
    if state.require_pool(pg_id).is_err() {
        return Vec::new();
    }
    let rows = {
        let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
        sqlite::load_duck_attachments_for_pg(&db, pg_id).unwrap_or_default()
    };
    let mut out = Vec::new();
    for row in rows {
        let Some(instance) = state.get_duck(&row.duck_connection_id) else { continue };
        if pg_attachment_on(state, &instance, pg_id).is_some() {
            continue;
        }
        let result = attach_now(
            &row.duck_connection_id,
            &AttachSource::Postgres(pg_id.to_string()),
            Some(row.alias.clone()),
            row.read_only,
            state,
        )
        .await;
        out.push(RestoreOutcome { duck_connection_id: row.duck_connection_id, alias: row.alias, error: result.err() });
    }
    out
}

// MARK: - Detach

/// DETACH and drop the secret on one instance.
async fn detach_on(instance: Arc<DuckDbInstance>, alias: String, secret: String) -> Result<(), String> {
    instance
        .with_connection(move |c| {
            let detached = c.execute_batch(&format!("DETACH DATABASE IF EXISTS {}", alias)).map_err(|e| e.to_string());
            let _ = c.execute_batch(&format!("DROP TEMPORARY SECRET IF EXISTS {}", secret));
            detached
        })
        .await
}

/// Detach database `alias` from the DuckDB database of `duck_id` — one
/// Pharos attached (a PostgreSQL attach's secret goes too), or one the user
/// attached with SQL — and forget it, so the record does not attach it again.
pub async fn detach(duck_id: String, alias: String, state: &AppState) -> Result<(), String> {
    let instance = state.require_duck(&duck_id)?;
    let entry = {
        let mut list = state.pg_attachments.lock().unwrap_or_else(|e| e.into_inner());
        prune(&mut list);
        list.iter()
            .position(|a| a.alias == alias && a.instance.upgrade().is_some_and(|i| Arc::ptr_eq(&i, &instance)))
            .map(|at| list.remove(at))
    };
    match entry {
        Some(e) => detach_on(instance, e.alias, e.secret).await?,
        None => {
            let quoted = format!("\"{}\"", alias.replace('"', "\"\""));
            instance
                .with_connection(move |c| c.execute_batch(&format!("DETACH DATABASE IF EXISTS {}", quoted)).map_err(|e| e.to_string()))
                .await?
        }
    }
    let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
    if let Err(e) = sqlite::delete_duck_attachment(&db, &duck_id, &alias) {
        log::warn!("Could not forget the attach {}: {}", alias, e);
    }
    Ok(())
}

/// Detach every attach of `pg_id` (its connection is closing). Errors are
/// logged: the PostgreSQL side closes either way. The attaches stay
/// remembered, for the next connect.
pub async fn detach_all_for(pg_id: &str, state: &AppState) {
    let entries: Vec<PgAttachment> = {
        let mut list = state.pg_attachments.lock().unwrap_or_else(|e| e.into_inner());
        prune(&mut list);
        let (mine, rest): (Vec<_>, Vec<_>) = list.drain(..).partition(|a| a.pg_id == pg_id);
        *list = rest;
        mine
    };
    for a in entries {
        if let Some(instance) = a.instance.upgrade() {
            if let Err(e) = detach_on(instance, a.alias.clone(), a.secret).await {
                log::warn!("Could not detach {} from DuckDB: {}", a.alias, e);
            }
        }
    }
}

// MARK: - List

/// The databases attached to the DuckDB database of `duck_id` — by Pharos or
/// with SQL — then its remembered attaches that are not attached now.
pub async fn list(duck_id: &str, state: &AppState) -> Result<Vec<AttachmentInfo>, String> {
    let instance = state.require_duck(duck_id)?;
    let attached: Vec<(String, String, Option<String>, bool)> = instance
        .with_connection(|c| {
            let mut stmt = c
                .prepare(
                    "SELECT database_name, type, path, readonly FROM duckdb_databases() \
                     WHERE NOT internal AND database_name <> current_database() \
                       AND database_name NOT IN ('system', 'temp') ORDER BY database_oid",
                )
                .map_err(|e| e.to_string())?;
            let rows = stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .map_err(|e| e.to_string())?;
            rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
        })
        .await?;
    let remembered = {
        let db = state.metadata_db.lock().unwrap_or_else(|e| e.into_inner());
        sqlite::load_duck_attachments(&db, duck_id).unwrap_or_default()
    };
    let pg_ids: Vec<(String, String)> = {
        let mut list = state.pg_attachments.lock().unwrap_or_else(|e| e.into_inner());
        prune(&mut list);
        list.iter()
            .filter(|a| a.instance.upgrade().is_some_and(|i| Arc::ptr_eq(&i, &instance)))
            .map(|a| (a.alias.clone(), a.pg_id.clone()))
            .collect()
    };
    let pg_name = |id: &str| state.get_config(id).map(|c| c.name);
    let mut out: Vec<AttachmentInfo> = attached
        .into_iter()
        .map(|(alias, kind, path, read_only)| {
            let pg_id = pg_ids.iter().find(|(a, _)| *a == alias).map(|(_, id)| id.clone());
            AttachmentInfo {
                remembered: remembered.iter().any(|r| r.alias == alias),
                pg_name: pg_id.as_deref().and_then(pg_name),
                pg_id,
                path: path.filter(|p| !p.is_empty()),
                alias,
                kind,
                read_only,
                attached: true,
            }
        })
        .collect();
    for row in remembered {
        if out.iter().any(|a| a.alias == row.alias) {
            continue;
        }
        out.push(AttachmentInfo {
            pg_name: row.pg_connection_id.as_deref().and_then(pg_name),
            alias: row.alias,
            kind: row.kind,
            path: row.file_path,
            pg_id: row.pg_connection_id,
            read_only: row.read_only,
            attached: false,
            remembered: true,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pg(name: &str) -> ConnectionConfig {
        ConnectionConfig {
            id: "pg1".into(),
            name: name.into(),
            host: "db.example.com".into(),
            port: 6543,
            database: "sales".into(),
            username: "ana".into(),
            password: String::new(),
            ssl_mode: SslMode::Require,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            saved: true,
            session_time_zone: None,
            ssl_root_cert_path: None,
            engine: Engine::Postgres,
        }
    }

    #[test]
    fn default_aliases_are_valid_identifiers() {
        for (name, want) in [
            ("Live Analysis", "live_analysis"),
            ("Ghostnet/ZISK", "ghostnet_zisk"),
            ("2024 db", "pg_2024_db"),
            ("  ", "pg"),
            ("main", "pg_main"),
            ("WHOIS - CH", "whois_ch"),
        ] {
            let got = default_alias(name, "pg");
            assert_eq!(got, want, "{name}");
            validate_alias(&got).unwrap();
        }
        assert!(validate_alias("Bad Name").is_err());
        assert!(validate_alias("x;drop").is_err());
        assert!(validate_alias("memory").is_err());
        assert!(validate_alias("1abc").is_err());
    }

    #[test]
    fn file_aliases_and_free_names() {
        assert_eq!(default_alias("sales-2024", "db"), "sales_2024");
        assert_eq!(default_alias("2024", "db"), "db_2024");
        assert_eq!(default_alias("main", "db"), "db_main");
        let taken = vec!["sales".to_string(), "sales_2".to_string()];
        assert_eq!(first_free_alias("sales", &taken), "sales_3");
        assert_eq!(first_free_alias("other", &taken), "other");
        let long = "a".repeat(63);
        let free = first_free_alias(&long, &[long.clone()]);
        assert_eq!(free.len(), 63, "{free}");
        assert!(free.ends_with("_2"));
    }

    #[test]
    fn file_attach_sql_quotes_and_types() {
        assert_eq!(file_attach_sql("/a/it's.duckdb", "its", "duckdb", false), "ATTACH '/a/it''s.duckdb' AS \"its\"");
        assert_eq!(file_attach_sql("/a/s.db", "s", "sqlite", true), "ATTACH '/a/s.db' AS \"s\" (TYPE sqlite, READ_ONLY)");
        assert_eq!(file_attach_sql("/a/d.ddb", "d", "duckdb", true), "ATTACH '/a/d.ddb' AS \"d\" (READ_ONLY)");
    }

    #[test]
    fn g1_only_read_only_holders_share_a_file() {
        let opened = |ro| FileHolder { record: "Sales".into(), alias: None, read_only: ro };
        let attached = |ro| FileHolder { record: "Scratch".into(), alias: Some("sales".into()), read_only: ro };
        assert_eq!(holder_conflict("/a/sales.duckdb", &opened(true), true), None);
        assert_eq!(holder_conflict("/a/sales.duckdb", &attached(true), true), None);
        let m = holder_conflict("/a/sales.duckdb", &opened(false), true).unwrap();
        assert!(m.contains("open in Pharos (\"Sales\") with write access"), "{m}");
        let m = holder_conflict("/a/sales.duckdb", &opened(true), false).unwrap();
        assert!(m.contains("Use Read-only"), "{m}");
        let m = holder_conflict("/a/sales.duckdb", &attached(false), true).unwrap();
        assert!(m.contains("attached to \"Scratch\" as sales with write access"), "{m}");
        assert!(holder_conflict("/a/sales.duckdb", &attached(true), false).unwrap().contains("detach it there"));
    }

    // MARK: file attaches, G1, remember and restore (no network)

    /// A state whose metadata database has Pharos's tables, so attaches are
    /// remembered.
    fn file_state() -> AppState {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::sqlite::create_schema(&conn).unwrap();
        AppState::new(conn)
    }

    fn duck_record(state: &AppState, id: &str, database: &str, read_only: bool) -> ConnectionConfig {
        let c = ConnectionConfig {
            id: id.into(),
            name: id.into(),
            engine: Engine::Duckdb,
            database: database.into(),
            read_only,
            ..pg(id)
        };
        state.set_config(c.clone());
        crate::db::sqlite::save_connection(&state.metadata_db.lock().unwrap(), &c).unwrap();
        c
    }

    fn connect(rt: &tokio::runtime::Runtime, state: &AppState, c: &ConnectionConfig) -> crate::models::ConnectionInfo {
        rt.block_on(crate::commands::duck::connect(c.clone(), state)).unwrap()
    }

    fn make_db(dir: &std::path::Path, name: &str, rows: i64) -> String {
        let path = dir.join(name);
        let c = duckdb::Connection::open(&path).unwrap();
        c.execute_batch(&format!("CREATE TABLE t AS SELECT range AS id FROM range({}); CHECKPOINT;", rows)).unwrap();
        path.to_string_lossy().to_string()
    }

    fn count(rt: &tokio::runtime::Runtime, state: &AppState, duck: &str, sql: &'static str) -> Result<i64, String> {
        let instance = state.require_duck(duck).unwrap();
        rt.block_on(instance.with_connection(move |c| c.query_row(sql, [], |r| r.get(0)).map_err(|e| e.to_string())))
    }

    fn temp_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("pharos-attach-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn a_file_attaches_queries_and_is_listed() {
        let dir = temp_dir();
        let sales = make_db(&dir, "sales.duckdb", 5);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = file_state();
        let home = duck_record(&state, "home", ":memory:", false);
        connect(&rt, &state, &home);

        let a = rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), None, true, &state)).unwrap();
        assert_eq!((a.alias.as_str(), a.kind.as_str(), a.read_only), ("sales", "duckdb", true));
        assert_eq!(count(&rt, &state, "home", "SELECT count(*) FROM sales.main.t"), Ok(5));
        let again = rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), Some("other".into()), true, &state)).unwrap();
        assert_eq!(again.alias, "sales", "the same file again is the same attach");

        // Another file with the same name gets the next free default.
        std::fs::create_dir_all(dir.join("b")).unwrap();
        let sales_b = make_db(&dir.join("b"), "sales.duckdb", 2);
        let b = rt.block_on(attach("home".into(), AttachSource::File(sales_b), None, true, &state)).unwrap();
        assert_eq!(b.alias, "sales_2");

        let listed = rt.block_on(list("home", &state)).unwrap();
        assert_eq!(listed.iter().map(|a| a.alias.as_str()).collect::<Vec<_>>(), ["sales", "sales_2"]);
        assert!(listed.iter().all(|a| a.attached && a.remembered && a.pg_id.is_none()));
        assert_eq!(listed[0].path.as_deref(), Some(sales.as_str()));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_sqlite_file_attaches_and_other_files_are_refused() {
        let dir = temp_dir();
        let sq = dir.join("legacy.sqlite");
        {
            let c = rusqlite::Connection::open(&sq).unwrap();
            c.execute_batch("CREATE TABLE s(a INTEGER); INSERT INTO s VALUES (7), (8);").unwrap();
        }
        std::fs::write(dir.join("notes.db"), "hello, this is text").unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = file_state();
        let home = duck_record(&state, "home", ":memory:", false);
        connect(&rt, &state, &home);

        let a = rt.block_on(attach("home".into(), AttachSource::File(sq.to_string_lossy().into()), None, true, &state)).unwrap();
        assert_eq!((a.alias.as_str(), a.kind.as_str()), ("legacy", "sqlite"));
        assert_eq!(count(&rt, &state, "home", "SELECT count(*) FROM legacy.s"), Ok(2));

        let text = dir.join("notes.db").to_string_lossy().to_string();
        let e = rt.block_on(attach("home".into(), AttachSource::File(text), None, true, &state)).unwrap_err();
        assert!(e.contains("is not a DuckDB or SQLite database"), "{e}");
        let missing = dir.join("gone.duckdb");
        let e = rt
            .block_on(attach("home".into(), AttachSource::File(missing.to_string_lossy().into()), None, false, &state))
            .unwrap_err();
        assert!(e.contains("not there"), "{e}");
        assert!(!missing.exists(), "a read-write attach must not create the file");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn g1_one_writer_per_file_in_the_process() {
        let dir = temp_dir();
        let sales = make_db(&dir, "sales.duckdb", 3);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = file_state();
        let home = duck_record(&state, "home", ":memory:", false);
        connect(&rt, &state, &home);

        // Opened read-write as a record: no attach at all.
        let writer = duck_record(&state, "Sales", &sales, false);
        connect(&rt, &state, &writer);
        let e = rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), None, true, &state)).unwrap_err();
        assert!(e.contains("open in Pharos (\"Sales\") with write access"), "{e}");
        rt.block_on(crate::commands::duck::disconnect("Sales", &state));

        // Opened read-only: a read-only attach shares it, a writable one does not.
        let reader = duck_record(&state, "Sales RO", &sales, true);
        connect(&rt, &state, &reader);
        let e = rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), None, false, &state)).unwrap_err();
        assert!(e.contains("Use Read-only"), "{e}");
        rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), None, true, &state)).unwrap();
        rt.block_on(crate::commands::duck::disconnect("Sales RO", &state));
        rt.block_on(detach("home".into(), "sales".into(), &state)).unwrap();

        // Attached read-write: the record cannot open it.
        rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), None, false, &state)).unwrap();
        let info = connect(&rt, &state, &writer);
        assert_eq!(info.status, crate::models::ConnectionStatus::Error);
        let e = info.error.unwrap();
        assert!(e.contains("attached to \"home\" as sales with write access"), "{e}");
        // Nor can a second database attach it.
        let other = duck_record(&state, "other", ":memory:", false);
        connect(&rt, &state, &other);
        let e = rt.block_on(attach("other".into(), AttachSource::File(sales.clone()), None, true, &state)).unwrap_err();
        assert!(e.contains("with write access"), "{e}");
        // And a database cannot attach its own file.
        rt.block_on(detach("home".into(), "sales".into(), &state)).unwrap();
        connect(&rt, &state, &writer);
        let e = rt.block_on(attach("Sales".into(), AttachSource::File(sales.clone()), None, true, &state)).unwrap_err();
        assert!(e.contains("its own file"), "{e}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn attaches_are_remembered_restored_and_forgotten() {
        let dir = temp_dir();
        let sales = make_db(&dir, "sales.duckdb", 4);
        let gone = make_db(&dir, "gone.duckdb", 1);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = file_state();
        let home = duck_record(&state, "home", ":memory:", false);
        connect(&rt, &state, &home);
        rt.block_on(attach("home".into(), AttachSource::File(sales.clone()), None, true, &state)).unwrap();
        rt.block_on(attach("home".into(), AttachSource::File(gone.clone()), None, true, &state)).unwrap();
        // A PostgreSQL attach remembered from an earlier run, not connected now.
        let pg_rec = ConnectionConfig { id: "pg-off".into(), ..pg("Warehouse") };
        state.set_config(pg_rec.clone());
        crate::db::sqlite::save_duck_attachment(
            &state.metadata_db.lock().unwrap(),
            &crate::db::sqlite::DuckAttachmentRow {
                duck_connection_id: "home".into(),
                alias: "warehouse".into(),
                kind: "postgres".into(),
                pg_connection_id: Some("pg-off".into()),
                file_path: None,
                read_only: true,
            },
        )
        .unwrap();

        rt.block_on(crate::commands::duck::disconnect("home", &state));
        std::fs::remove_file(&gone).unwrap();
        let info = connect(&rt, &state, &home);
        assert_eq!(info.status, crate::models::ConnectionStatus::Connected, "a failed restore does not stop the connect");
        assert_eq!(count(&rt, &state, "home", "SELECT count(*) FROM sales.main.t"), Ok(4), "restored");
        let failures = take_restore_failures("home", &state);
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(failures[0].starts_with("gone: The file is not there"), "{failures:?}");
        assert!(take_restore_failures("home", &state).is_empty(), "taken once");

        let listed = rt.block_on(list("home", &state)).unwrap();
        let by = |a: &str| listed.iter().find(|x| x.alias == a).cloned().unwrap();
        assert!(by("sales").attached);
        assert!(!by("gone").attached && by("gone").remembered, "kept for when the file is back");
        let w = by("warehouse");
        assert!(!w.attached && w.remembered, "waits for its connection; no failure");
        assert_eq!(w.pg_name.as_deref(), Some("Warehouse"));
        // Not connected: restore_for_pg does nothing.
        assert!(rt.block_on(restore_for_pg("pg-off", &state)).is_empty());

        // Detach forgets.
        rt.block_on(detach("home".into(), "sales".into(), &state)).unwrap();
        rt.block_on(crate::commands::duck::disconnect("home", &state));
        connect(&rt, &state, &home);
        assert!(count(&rt, &state, "home", "SELECT count(*) FROM sales.main.t").is_err(), "not attached again");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_tunnel_port_wins() {
        let c = pg("p");
        assert_eq!(endpoint(&c, Some(50123)), ("127.0.0.1".to_string(), 50123));
        assert_eq!(endpoint(&c, None), ("db.example.com".to_string(), 6543));
    }

    #[test]
    fn the_secret_carries_the_password_and_quotes_it() {
        let sql = secret_sql("pharos_pg_x", &pg("p"), "h", 5432, "it's").unwrap();
        assert!(sql.starts_with("CREATE OR REPLACE TEMPORARY SECRET pharos_pg_x (TYPE postgres"), "{sql}");
        assert!(sql.contains("PASSWORD 'it''s'"), "{sql}");
        assert!(sql.contains("SSLMODE 'require'"), "{sql}");
        assert!(!sql.contains("PERSISTENT"));
        assert!(!secret_sql("s", &pg("p"), "h", 1, "").unwrap().contains("PASSWORD"), "trust auth: no password option");
        let mut v = pg("p");
        v.ssl_mode = SslMode::VerifyFull;
        let sql = secret_sql("s", &v, "h", 1, "").unwrap();
        assert!(sql.contains(&format!("SSLROOTCERT '{}'", MACOS_CA_BUNDLE)), "{sql}");
        v.ssl_root_cert_path = Some("/x/root.crt".into());
        assert!(secret_sql("s", &v, "h", 1, "").unwrap().contains("SSLROOTCERT '/x/root.crt'"));
        assert_eq!(attach_sql("a", "s", true), "ATTACH '' AS a (TYPE postgres, SECRET s, READ_ONLY)");
    }

    fn live_pg_config(id: &str) -> ConnectionConfig {
        let v = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
        ConnectionConfig {
            id: id.into(),
            name: "Local PG".into(),
            host: v("PHAROS_TEST_PG_HOST", "127.0.0.1"),
            port: v("PHAROS_TEST_PG_PORT", "5432").parse().unwrap_or(5432),
            database: v("PHAROS_TEST_PG_DB", "nfinn"),
            username: v("PHAROS_TEST_PG_USER", "nfinn"),
            ssl_mode: SslMode::Disable,
            ..pg("Local PG")
        }
    }

    /// The whole command against a live PostgreSQL: attach, query, join,
    /// nothing secret in DuckDB's listings, and a PostgreSQL disconnect
    /// detaches.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_attach_query_and_detach_on_disconnect() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = AppState::new(rusqlite::Connection::open_in_memory().unwrap());
        let mut cfg = live_pg_config("pg-live");
        // The env file's password for a server that asks for one; trust auth
        // (local Postgres.app) ignores the stand-in.
        let password = std::env::var("PHAROS_TEST_PG_PASSWORD")
            .ok()
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| "sekrit-never-shown".to_string());
        cfg.password = password.clone();
        state.set_config(cfg.clone());
        rt.block_on(crate::commands::connection::connect_postgres(cfg.id.clone(), &state)).unwrap();
        let duck = crate::models::ConnectionConfig { id: "duck-live".into(), engine: Engine::Duckdb, database: ":memory:".into(), ..pg("duck") };
        state.set_config(duck.clone());
        let info = rt.block_on(crate::commands::duck::connect(duck.clone(), &state)).unwrap();
        assert_eq!(info.status, crate::models::ConnectionStatus::Connected, "{:?}", info.error);

        let a = rt.block_on(attach("duck-live".into(), AttachSource::Postgres("pg-live".into()), None, true, &state)).unwrap();
        assert_eq!(a.alias, "local_pg");
        let instance = state.require_duck("duck-live").unwrap();
        let (n, secrets): (i64, String) = rt
            .block_on(instance.with_connection(|c| {
                c.execute_batch("CREATE TABLE wanted AS SELECT 'pg_class' AS relname").map_err(|e| e.to_string())?;
                let n: i64 = c
                    .query_row("SELECT count(*) FROM local_pg.pg_catalog.pg_tables t JOIN wanted w ON t.tablename = w.relname", [], |r| r.get(0))
                    .map_err(|e| e.to_string())?;
                let s: String = c
                    .query_row("SELECT string_agg(secret_string, ' ') || ' persistent=' || bool_or(persistent)::VARCHAR FROM duckdb_secrets()", [], |r| r.get(0))
                    .map_err(|e| e.to_string())?;
                Ok((n, s))
            }))
            .unwrap();
        assert_eq!(n, 1);
        assert!(!secrets.contains(&password), "the password is in DuckDB's secret listing");
        assert!(secrets.contains("password=redacted"), "{secrets}");
        assert!(secrets.ends_with(" persistent=false"), "never persistent: {secrets}");
        assert_eq!(rt.block_on(list("duck-live", &state)).unwrap().len(), 1);
        let again = rt.block_on(attach("duck-live".into(), AttachSource::Postgres("pg-live".into()), None, true, &state));
        assert_eq!(again.unwrap().alias, "local_pg", "the same connection again is the same attach");

        rt.block_on(crate::commands::connection::disconnect_postgres("pg-live".into(), &state)).unwrap();
        let gone = rt.block_on(instance.with_connection(|c| {
            c.query_row("SELECT count(*) FROM local_pg.pg_catalog.pg_tables", [], |r| r.get::<_, i64>(0)).map_err(|e| e.to_string())
        }));
        assert!(gone.is_err(), "detached with its PostgreSQL connection");
        assert!(rt.block_on(list("duck-live", &state)).unwrap().iter().all(|a| !a.attached));
        // A database the user attached with SQL detaches too.
        rt.block_on(instance.with_connection(|c| c.execute_batch("ATTACH ':memory:' AS scratch").map_err(|e| e.to_string()))).unwrap();
        rt.block_on(detach("duck-live".into(), "scratch".into(), &state)).unwrap();
        let n: i64 = rt
            .block_on(instance.with_connection(|c| c.query_row("SELECT count(*) FROM duckdb_secrets()", [], |r| r.get(0)).map_err(|e| e.to_string())))
            .unwrap();
        assert_eq!(n, 0, "its secret is dropped");
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_attach_needs_a_connected_postgres() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = AppState::new(rusqlite::Connection::open_in_memory().unwrap());
        state.set_config(live_pg_config("pg-off"));
        let duck = crate::models::ConnectionConfig { id: "duck-x".into(), engine: Engine::Duckdb, database: ":memory:".into(), ..pg("duck") };
        state.set_config(duck.clone());
        rt.block_on(crate::commands::duck::connect(duck, &state)).unwrap();
        let err = rt.block_on(attach("duck-x".into(), AttachSource::Postgres("pg-off".into()), None, true, &state)).unwrap_err();
        assert!(err.contains("Connect \"Local PG\" first"), "{err}");
    }

    /// A PostgreSQL disconnect detaches but remembers; the next connect of
    /// that connection attaches it again (`restore_for_pg`), and so does the
    /// next connect of the DuckDB record while it is connected (`restore`).
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_postgres_attach_is_restored_on_connect() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = file_state();
        let mut cfg = live_pg_config("pg-r");
        cfg.password = std::env::var("PHAROS_TEST_PG_PASSWORD").unwrap_or_default();
        state.set_config(cfg.clone());
        rt.block_on(crate::commands::connection::connect_postgres(cfg.id.clone(), &state)).unwrap();
        let home = duck_record(&state, "home-r", ":memory:", false);
        connect(&rt, &state, &home);
        rt.block_on(attach("home-r".into(), AttachSource::Postgres("pg-r".into()), Some("wh".into()), true, &state)).unwrap();

        rt.block_on(crate::commands::connection::disconnect_postgres("pg-r".into(), &state)).unwrap();
        let listed = rt.block_on(list("home-r", &state)).unwrap();
        assert!(listed.iter().any(|a| a.alias == "wh" && !a.attached && a.remembered), "{listed:?}");

        rt.block_on(crate::commands::connection::connect_postgres(cfg.id.clone(), &state)).unwrap();
        let outcomes = rt.block_on(restore_for_pg("pg-r", &state));
        assert_eq!(outcomes.len(), 1);
        assert_eq!(outcomes[0].error, None);
        assert_eq!(count(&rt, &state, "home-r", "SELECT (count(*) > 0)::INT FROM wh.pg_catalog.pg_tables"), Ok(1));

        rt.block_on(crate::commands::duck::disconnect("home-r", &state));
        connect(&rt, &state, &home);
        assert_eq!(count(&rt, &state, "home-r", "SELECT (count(*) > 0)::INT FROM wh.pg_catalog.pg_tables"), Ok(1));
        assert!(take_restore_failures("home-r", &state).is_empty());
    }

    #[test]
    fn remote_attach_sql_is_read_only_and_quoted() {
        assert_eq!(
            remote_attach_sql("http://127.0.0.1:8765/db/0a1b/t7091.duckdb", "t7091").unwrap(),
            "ATTACH 'http://127.0.0.1:8765/db/0a1b/t7091.duckdb' AS \"t7091\" (READ_ONLY)"
        );
        assert_eq!(
            remote_attach_sql("https://h.example/a'b.duckdb", "a_b").unwrap(),
            "ATTACH 'https://h.example/a''b.duckdb' AS \"a_b\" (READ_ONLY)"
        );
    }

    #[test]
    fn remote_attach_sql_refuses_other_addresses() {
        for url in [
            "file:///etc/passwd",
            "/tmp/x.duckdb",
            "s3://bucket/x.duckdb",
            "http:///x.duckdb",
            "http://u:p@h/x.duckdb",
            "http://h/x\n.duckdb",
        ] {
            assert!(remote_attach_sql(url, "x").is_err(), "{url}");
        }
        assert!(remote_attach_sql("http://h/x.duckdb", "main").is_err(), "reserved alias");
        assert!(remote_attach_sql("http://h/x.duckdb", "X\"; DROP").is_err(), "alias not an identifier");
    }

    /// Serve one file over HTTP/1.1 with HEAD and Range, as the Recon to
    /// DuckDB app does: just enough for httpfs. Returns the port.
    fn serve_file(path: std::path::PathBuf) -> u16 {
        use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let path = path.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request = String::new();
                    if reader.read_line(&mut request).is_err() {
                        return;
                    }
                    let mut range = None;
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                        if let Some(v) = line.to_ascii_lowercase().strip_prefix("range: bytes=") {
                            let (a, b) = v.trim().split_once('-').unwrap();
                            range = Some((a.parse::<u64>().unwrap(), b.parse::<u64>().ok()));
                        }
                    }
                    let mut file = std::fs::File::open(&path).unwrap();
                    let size = file.metadata().unwrap().len();
                    let (start, end) = match range {
                        Some((a, b)) => (a, b.unwrap_or(size - 1).min(size - 1)),
                        None => (0, size - 1),
                    };
                    let status = if range.is_some() { "206 Partial Content" } else { "200 OK" };
                    let mut head = format!(
                        "HTTP/1.1 {status}\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n",
                        end - start + 1
                    );
                    if range.is_some() {
                        head += &format!("Content-Range: bytes {start}-{end}/{size}\r\n");
                    }
                    head += "\r\n";
                    let _ = stream.write_all(head.as_bytes());
                    if request.starts_with("GET") {
                        let mut body = vec![0; (end - start + 1) as usize];
                        file.seek(SeekFrom::Start(start)).unwrap();
                        file.read_exact(&mut body).unwrap();
                        let _ = stream.write_all(&body);
                    }
                });
            }
        });
        port
    }

    #[test]
    fn attach_remote_reads_a_database_over_http() {
        let path = std::env::temp_dir().join(format!("pharos-remote-{}.duckdb", uuid::Uuid::new_v4()));
        {
            let c = duckdb::Connection::open(&path).unwrap();
            c.execute_batch("CREATE TABLE pdns AS SELECT range AS id FROM range(1000); CHECKPOINT;").unwrap();
        }
        let url = format!("http://127.0.0.1:{}/db/x/remote.duckdb", serve_file(path.clone()));

        let rt = tokio::runtime::Runtime::new().unwrap();
        let state = AppState::new(rusqlite::Connection::open_in_memory().unwrap());
        let duck = ConnectionConfig { id: "duck-r".into(), engine: Engine::Duckdb, database: ":memory:".into(), ..pg("duck") };
        state.set_config(duck.clone());
        rt.block_on(crate::commands::duck::connect(duck, &state)).unwrap();

        let alias = rt.block_on(attach_remote("duck-r".into(), url.clone(), "remote".into(), &state)).unwrap();
        assert_eq!(alias, "remote");
        let instance = state.require_duck("duck-r").unwrap();
        let (n, read_only): (i64, bool) = rt
            .block_on(instance.with_connection(|c| {
                let n = c.query_row("SELECT count(*) FROM remote.main.pdns", [], |r| r.get(0)).map_err(|e| e.to_string())?;
                let ro = c
                    .query_row("SELECT readonly FROM duckdb_databases() WHERE database_name = 'remote'", [], |r| r.get(0))
                    .map_err(|e| e.to_string())?;
                Ok((n, ro))
            }))
            .unwrap();
        assert_eq!(n, 1000);
        assert!(read_only, "attached read-only");
        // The tab's schema `remote.main` (duck_session::schema_sql) finds its
        // tables with no prefix.
        let unqualified: i64 = rt
            .block_on(instance.with_connection(|c| {
                c.execute_batch("SET search_path = 'remote.main,main'").map_err(|e| e.to_string())?;
                c.query_row("SELECT count(*) FROM pdns", [], |r| r.get(0)).map_err(|e| e.to_string())
            }))
            .unwrap();
        assert_eq!(unqualified, 1000);
        let again = rt.block_on(attach_remote("duck-r".into(), url, "remote".into(), &state)).unwrap_err();
        assert!(again.contains("already attached"), "{again}");
        let _ = std::fs::remove_file(path);
    }
}
