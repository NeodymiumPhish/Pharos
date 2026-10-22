//! Attach a saved PostgreSQL connection to an open DuckDB database
//! (DuckDB's `postgres_scanner`, linked into Pharos).
//!
//! The password never appears in SQL that a user sees or that history
//! stores: Pharos makes a TEMPORARY DuckDB secret from the connection's
//! password (Keychain or this session's) and attaches with
//! `ATTACH '' AS alias (TYPE postgres, SECRET name)`. Both statements run
//! here, outside every history path. DuckDB lists such a secret with the
//! password redacted and never writes it to disk (`allow_persistent_secrets`
//! is off, `db::duckdb`).
//!
//! An attach lives while its PostgreSQL connection is connected: it reuses
//! that connection's SSH tunnel (127.0.0.1:<local port>), and
//! `connection::disconnect_postgres` detaches it before the tunnel closes.
//! Attached databases and secrets belong to the DuckDB instance, so every tab
//! on that file sees them.

use std::sync::{Arc, Weak};

use serde::Serialize;

use crate::db::duckdb::DuckDbInstance;
use crate::models::{ConnectionConfig, Engine, SslMode};
use crate::state::AppState;

/// One live attach.
pub struct PgAttachment {
    pub pg_id: String,
    pub alias: String,
    pub secret: String,
    pub read_only: bool,
    pub instance: Weak<DuckDbInstance>,
}

/// What the front end lists for a DuckDB database.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AttachmentInfo {
    pub alias: String,
    pub pg_id: String,
    pub pg_name: String,
    pub read_only: bool,
}

/// The CA bundle macOS ships. libpq (with Pharos's OpenSSL) has no system
/// trust store of its own, so `verify-ca` / `verify-full` without a root
/// certificate on the record use this file — the same Apple roots sqlx
/// trusts on the PostgreSQL path, without certificates a user added to the
/// Keychain.
const MACOS_CA_BUNDLE: &str = "/etc/ssl/cert.pem";

/// Names an alias may not take: DuckDB's own databases.
const RESERVED_ALIASES: [&str; 4] = ["memory", "system", "temp", "main"];

/// A default alias from a connection name: lower case, `[a-z0-9_]`, starting
/// with a letter or `_` ("Live Analysis" → `live_analysis`, "2024 db" →
/// `pg_2024_db`).
pub fn default_alias(name: &str) -> String {
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
        out = format!("pg_{}", out).trim_end_matches('_').to_string();
    }
    if RESERVED_ALIASES.contains(&out.as_str()) {
        out = format!("pg_{}", out);
    }
    out.truncate(63);
    out
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

fn secret_name(alias: &str) -> String {
    format!("pharos_pg_{}", alias)
}

/// Drop entries whose DuckDB instance has closed.
fn prune(list: &mut Vec<PgAttachment>) {
    list.retain(|a| a.instance.strong_count() > 0);
}

/// Attach `pg_id` (connected) to the DuckDB database of `duck_id`.
pub async fn attach_postgres(
    duck_id: String,
    pg_id: String,
    alias: Option<String>,
    read_only: bool,
    state: &AppState,
) -> Result<AttachmentInfo, String> {
    let instance = state.require_duck(&duck_id)?;
    let config = state.get_config(&pg_id).ok_or_else(|| format!("No connection {}", pg_id))?;
    if config.engine != Engine::Postgres {
        return Err(format!("\"{}\" is not a PostgreSQL connection.", config.name));
    }
    // Connected, and its tunnel (if any) alive: the pool check reaps a dead one.
    state
        .require_pool(&pg_id)
        .map_err(|_| format!("Connect \"{}\" first.", config.name))?;
    let tunnel_port = state.tunnel_local_port(&pg_id);
    if config.ssh_tunnel.is_some() && tunnel_port.is_none() {
        return Err(format!("The SSH tunnel of \"{}\" is not open. Connect it again.", config.name));
    }
    let (host, port) = endpoint(&config, tunnel_port);
    let stored = state.get_cached_password(&pg_id).unwrap_or_else(|| config.password.clone());
    let password = state.effective_password(&pg_id, &stored);

    let alias = alias.map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).unwrap_or_else(|| default_alias(&config.name));
    validate_alias(&alias)?;
    let read_only = read_only || config.read_only;
    let secret = secret_name(&alias);
    let create = secret_sql(&secret, &config, &host, port, &password)?;
    let attach = attach_sql(&alias, &secret, read_only);

    let (alias_c, secret_c) = (alias.clone(), secret.clone());
    instance
        .with_connection(move |c| {
            let taken: bool = c
                .query_row("SELECT count(*) > 0 FROM duckdb_databases() WHERE database_name = ?", [&alias_c], |r| r.get(0))
                .map_err(|e| e.to_string())?;
            if taken {
                return Err(format!("A database named \"{}\" is already attached. Choose another name.", alias_c));
            }
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
    list.push(PgAttachment { pg_id: pg_id.clone(), alias: alias.clone(), secret, read_only, instance: Arc::downgrade(&instance) });
    Ok(AttachmentInfo { alias, pg_id, pg_name: config.name, read_only })
}

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

/// Detach database `alias` from the DuckDB database of `duck_id`: one Pharos
/// attached (its secret goes too), or one the user attached with SQL.
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
        Some(e) => detach_on(instance, e.alias, e.secret).await,
        None => {
            let quoted = format!("\"{}\"", alias.replace('"', "\"\""));
            instance
                .with_connection(move |c| c.execute_batch(&format!("DETACH DATABASE {}", quoted)).map_err(|e| e.to_string()))
                .await
        }
    }
}

/// Detach every attach of `pg_id` (its connection is closing). Errors are
/// logged: the PostgreSQL side closes either way.
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

/// The attaches on the DuckDB database of `duck_id`.
pub fn list(duck_id: &str, state: &AppState) -> Result<Vec<AttachmentInfo>, String> {
    let instance = state.require_duck(duck_id)?;
    let mut list = state.pg_attachments.lock().unwrap_or_else(|e| e.into_inner());
    prune(&mut list);
    Ok(list
        .iter()
        .filter(|a| a.instance.upgrade().is_some_and(|i| Arc::ptr_eq(&i, &instance)))
        .map(|a| {
            let config = state.get_config(&a.pg_id);
            AttachmentInfo {
                alias: a.alias.clone(),
                pg_id: a.pg_id.clone(),
                pg_name: config.as_ref().map(|c| c.name.clone()).unwrap_or_default(),
                read_only: a.read_only,
            }
        })
        .collect())
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
            let got = default_alias(name);
            assert_eq!(got, want, "{name}");
            validate_alias(&got).unwrap();
        }
        assert!(validate_alias("Bad Name").is_err());
        assert!(validate_alias("x;drop").is_err());
        assert!(validate_alias("memory").is_err());
        assert!(validate_alias("1abc").is_err());
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

        let a = rt.block_on(attach_postgres("duck-live".into(), "pg-live".into(), None, true, &state)).unwrap();
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
        assert_eq!(list("duck-live", &state).unwrap().len(), 1);
        let again = rt.block_on(attach_postgres("duck-live".into(), "pg-live".into(), None, true, &state));
        assert!(again.unwrap_err().contains("already attached"));

        rt.block_on(crate::commands::connection::disconnect_postgres("pg-live".into(), &state)).unwrap();
        let gone = rt.block_on(instance.with_connection(|c| {
            c.query_row("SELECT count(*) FROM local_pg.pg_catalog.pg_tables", [], |r| r.get::<_, i64>(0)).map_err(|e| e.to_string())
        }));
        assert!(gone.is_err(), "detached with its PostgreSQL connection");
        assert!(list("duck-live", &state).unwrap().is_empty());
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
        let err = rt.block_on(attach_postgres("duck-x".into(), "pg-off".into(), None, true, &state)).unwrap_err();
        assert!(err.contains("Connect \"Local PG\" first"), "{err}");
    }
}
