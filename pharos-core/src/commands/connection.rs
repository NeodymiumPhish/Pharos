
use crate::db::ssh_tunnel::{self, SshTunnel};
use crate::db::{credentials, postgres, sqlite};
use crate::models::{ConnectionConfig, ConnectionInfo, ConnectionStatus, TestConnectionResult};
use crate::state::AppState;

/// Sanitize error messages to remove sensitive data like passwords
fn sanitize_error(error: &str) -> String {
    // Remove anything that looks like a postgres connection URL
    let mut sanitized = error.to_string();

    // Replace postgres:// URLs with credentials hidden
    if sanitized.contains("postgres://") {
        // Pattern: postgres://user:pass@host:port/db
        if let Some(start) = sanitized.find("postgres://") {
            if let Some(at_pos) = sanitized[start..].find('@') {
                let end = start + at_pos + 1;
                sanitized = format!(
                    "{}postgres://[credentials]@{}",
                    &sanitized[..start],
                    &sanitized[end..]
                );
            }
        }
    }

    // Also remove any password= parameters
    while let Some(start) = sanitized.find("password=") {
        let after = &sanitized[start + 9..];
        let end_offset = after
            .find(|c: char| c.is_whitespace() || c == '&' || c == '"' || c == '\'' || c == ';')
            .unwrap_or(after.len());
        sanitized = format!(
            "{}password=[hidden]{}",
            &sanitized[..start],
            &after[end_offset..]
        );
    }

    sanitized
}

/// Save a new connection configuration
pub async fn save_connection(
    config: ConnectionConfig,
    state: &AppState,
) -> Result<(), String> {
    // Store the secrets in the OS keychain and update the cache. An EMPTY
    // secret means "the caller did not send one", never "clear it": the form
    // sends the password masked unless the user revealed it, so an empty
    // string must leave the stored value alone.
    {
        let mut cache = state.password_cache.lock().map_err(|e| e.to_string())?;
        if !config.password.is_empty() {
            credentials::store_password_with_cache(&config.id, &config.password, &mut cache)?;
        }
        let ssh_key = credentials::ssh_secret_key(&config.id);
        match config.ssh_tunnel.as_ref() {
            Some(tunnel) if !tunnel.secret.is_empty() => {
                credentials::store_password_with_cache(&ssh_key, &tunnel.secret, &mut cache)?;
            }
            // The tunnel is gone, so its secret must go too. Without this the
            // Keychain keeps a secret no connection can ever use or delete.
            None if cache.contains_key(&ssh_key) => {
                credentials::delete_password_with_cache(&ssh_key, &mut cache)?;
            }
            _ => {}
        }
    }

    // Save metadata to SQLite (without password)
    {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::save_connection(&db, &config).map_err(|e| e.to_string())?;
    }

    // Update in-memory cache (with password for active use)
    state.set_config(config);

    Ok(())
}

/// Delete a connection configuration
pub async fn delete_connection(
    connection_id: String,
    state: &AppState,
) -> Result<(), String> {
    // Disconnect if connected
    if let Some(pool) = state.remove_pool(&connection_id) {
        pool.close().await;
    }
    close_tunnel(&connection_id, state).await;

    // Delete every secret this connection owns, in one keychain write
    {
        let mut cache = state.password_cache.lock().map_err(|e| e.to_string())?;
        credentials::delete_connection_secrets_with_cache(&connection_id, &mut cache)?;
    }

    // Delete from SQLite
    {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::delete_connection(&db, &connection_id).map_err(|e| e.to_string())?;
    }

    // Remove from in-memory cache
    state.remove_config(&connection_id);

    Ok(())
}

/// Persist the user's connection ordering. `ids` is the full ordered list
/// (top-to-bottom) of connection IDs. Each row's sort_order is rewritten.
pub async fn reorder_connections(
    ids: Vec<String>,
    state: &AppState,
) -> Result<(), String> {
    let mut db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::reorder_connections(&mut db, &ids).map_err(|e| e.to_string())
}

/// Load all saved connection configurations
pub async fn load_connections(state: &AppState) -> Result<Vec<ConnectionConfig>, String> {
    let mut configs = {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::load_connections(&db).map_err(|e| e.to_string())?
    };

    // Load the secrets from the in-memory cache (populated at startup). The
    // SQLite column holds the tunnel with an empty secret, so the tunnel is
    // only usable once this fills it back in.
    for config in &mut configs {
        if let Some(password) = state.get_cached_password(&config.id) {
            config.password = password;
        }
        if let Some(tunnel) = config.ssh_tunnel.as_mut() {
            if let Some(secret) =
                state.get_cached_password(&credentials::ssh_secret_key(&config.id))
            {
                tunnel.secret = secret;
            }
        }
    }

    // Update in-memory cache
    for config in &configs {
        state.set_config(config.clone());
    }

    Ok(configs)
}

/// The config the POOL uses.
///
/// With a tunnel the pool talks to the local end, so the host and port are
/// replaced and the tunnel is removed — nothing downstream of here should be
/// able to open a second one. Without a tunnel it is the config unchanged.
///
/// `ConnectionInfo` keeps the DATABASE host and port throughout, because that
/// is what the user typed and what the UI must show.
fn pool_config(config: &ConnectionConfig, tunnel: Option<&SshTunnel>) -> ConnectionConfig {
    let mut effective = config.clone();
    if let Some(tunnel) = tunnel {
        effective.host = "127.0.0.1".to_string();
        effective.port = tunnel.local_port;
        effective.ssh_tunnel = None;
    }
    effective
}

fn info_with(config: &ConnectionConfig, status: ConnectionStatus, error: Option<String>, latency_ms: Option<u64>) -> ConnectionInfo {
    ConnectionInfo {
        id: config.id.clone(),
        name: config.name.clone(),
        host: config.host.clone(),
        port: config.port,
        database: config.database.clone(),
        status,
        error,
        latency_ms,
    }
}

/// Connect to a PostgreSQL database
pub async fn connect_postgres(
    connection_id: String,
    state: &AppState,
) -> Result<ConnectionInfo, String> {
    // Get the connection config
    let config = state
        .get_config(&connection_id)
        .ok_or_else(|| format!("Connection not found: {}", connection_id))?;

    // A tunnel that stopped since the last call leaves a pool that cannot
    // carry anything. Drop it BEFORE the has_pool question, or Connect would
    // answer "already connected" with a dead socket.
    state.reap_dead_tunnel(&connection_id);

    // Check if already connected
    if state.has_pool(&connection_id) {
        return Ok(info_with(&config, ConnectionStatus::Connected, None, None));
    }

    // This attempt owns the outcome; a reason from an earlier one must not
    // survive it.
    state.clear_tunnel_failure(&connection_id);

    let start = std::time::Instant::now();

    // The tunnel opens BEFORE the pool, because the pool's address depends on
    // it. A tunnel that will not open is the whole failure — there is nothing
    // to try the pool against.
    let tunnel = match config.ssh_tunnel.as_ref() {
        None => None,
        Some(tunnel_config) => {
            match ssh_tunnel::open(tunnel_config, &config.host, config.port).await {
                Ok(tunnel) => Some(tunnel),
                Err(e) => {
                    return Ok(info_with(
                        &config,
                        ConnectionStatus::Error,
                        Some(sanitize_error(&e.user_message())),
                        None,
                    ))
                }
            }
        }
    };

    // The session and the pool tuning, from the settings CACHE — one `Arc`
    // clone, never a read of SQLite per connect (plan §5.2 K).
    let settings = state.settings();
    let session = postgres::SessionOptions::from_settings(&settings.connections, &config);
    let tuning = postgres::PoolTuning::from(&settings.connections);

    match postgres::create_pool_with(&pool_config(&config, tunnel.as_ref()), &session, &tuning).await {
        Ok(pool) => {
            let latency = start.elapsed().as_millis() as u64;
            state.add_pool(connection_id.clone(), pool);
            if let Some(tunnel) = tunnel {
                state.add_tunnel(connection_id.clone(), tunnel);
            }
            Ok(info_with(&config, ConnectionStatus::Connected, None, Some(latency)))
        }
        Err(e) => {
            let message = pool_failure_message(&config, tunnel, &e).await;
            Ok(info_with(&config, ConnectionStatus::Error, Some(message), None))
        }
    }
}

/// Why the pool failed, and close the tunnel it was going to use.
///
/// A live tunnel over a database the SSH server cannot reach gives the pool an
/// ordinary socket error, so the reason is only in the tunnel's stderr. Read
/// it before the tunnel is closed.
async fn pool_failure_message(
    config: &ConnectionConfig,
    tunnel: Option<SshTunnel>,
    error: &sqlx::Error,
) -> String {
    let Some(tunnel) = tunnel else {
        return sanitize_error(&error.to_string());
    };
    let forward = ssh_tunnel::forward_failure(&tunnel.stderr_tail(), &config.host, config.port);
    // A failed connect must leave nothing running, exactly as a failed connect
    // without a tunnel leaves no pool.
    tunnel.close().await;
    sanitize_error(&forward.unwrap_or_else(|| error.to_string()))
}

/// Disconnect from a PostgreSQL database
pub async fn disconnect_postgres(
    connection_id: String,
    state: &AppState,
) -> Result<(), String> {
    if let Some(pool) = state.remove_pool(&connection_id) {
        pool.close().await;
    }
    // The pool goes first: the tunnel is the road the pool's sockets run on.
    close_tunnel(&connection_id, state).await;
    state.clear_analyze_denied(&connection_id);
    state.clear_key_cache(&connection_id);
    Ok(())
}

/// Stop this connection's tunnel, if it has one, and forget any recorded
/// failure. Safe to call when there is neither.
async fn close_tunnel(connection_id: &str, state: &AppState) {
    if let Some(tunnel) = state.take_tunnel(connection_id) {
        tunnel.close().await;
    }
    state.clear_tunnel_failure(connection_id);
}

/// Test a connection configuration without saving it.
///
/// It takes the same path as Connect, tunnel and all, so the Test button can
/// never pass a configuration that Connect would refuse.
pub async fn test_connection(config: ConnectionConfig) -> Result<TestConnectionResult, String> {
    let tunnel = match config.ssh_tunnel.as_ref() {
        None => None,
        Some(tunnel_config) => {
            match ssh_tunnel::open(tunnel_config, &config.host, config.port).await {
                Ok(tunnel) => Some(tunnel),
                Err(e) => {
                    return Ok(TestConnectionResult {
                        success: false,
                        latency_ms: None,
                        error: Some(sanitize_error(&e.user_message())),
                    })
                }
            }
        }
    };

    let result = postgres::test_connection(&pool_config(&config, tunnel.as_ref())).await;
    match result {
        Ok(latency) => {
            if let Some(tunnel) = tunnel {
                tunnel.close().await;
            }
            Ok(TestConnectionResult {
                success: true,
                latency_ms: Some(latency),
                error: None,
            })
        }
        Err(e) => Ok(TestConnectionResult {
            success: false,
            latency_ms: None,
            error: Some(pool_failure_message(&config, tunnel, &e).await),
        }),
    }
}


/// A failed connect must leave the state exactly as it was, so the NEXT
/// Connect runs the whole path again instead of finding a half-created pool.
///
/// Slow by nature — the pool retries a refused port until its acquire deadline
/// — so it is opt-in. It needs no server; run it with
///
///   cargo test --release failed_connect -- --ignored --nocapture
#[cfg(test)]
mod failed_connect_state_tests {
    use super::{connect_postgres, disconnect_postgres};
    use crate::models::{ConnectionConfig, ConnectionStatus, SslMode};
    use crate::state::AppState;
    use rusqlite::Connection as SqliteConnection;

    /// A port nothing listens on, so every attempt fails the same way.
    const CLOSED_PORT: u16 = 5499;

    fn state_with_a_dead_connection() -> (AppState, String) {
        let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
        let config = ConnectionConfig {
            id: "dead".to_string(),
            name: "dead".to_string(),
            host: "127.0.0.1".to_string(),
            port: CLOSED_PORT,
            database: "nowhere".to_string(),
            username: "nobody".to_string(),
            password: String::new(),
            ssl_mode: SslMode::Disable,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        };
        let id = config.id.clone();
        state.set_config(config);
        (state, id)
    }

    #[test]
    #[ignore = "waits out two connect timeouts (~20 s); needs no server"]
    fn a_failed_connect_leaves_no_pool_and_the_next_one_still_runs() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let (state, id) = state_with_a_dead_connection();

            let first = connect_postgres(id.clone(), &state)
                .await
                .expect("connect reports failure as a value, not an Err");
            assert_eq!(first.status, ConnectionStatus::Error);
            assert!(first.error.is_some(), "the failure must carry a reason");
            assert!(
                !state.has_pool(&id),
                "a failed connect registered a pool; the next Connect would \
                 short-circuit and report Connected"
            );

            // The tell that distinguishes a real second attempt from the
            // has_pool short-circuit: it must come back Error again, never
            // Connected, and still leave the registry empty.
            let second = connect_postgres(id.clone(), &state)
                .await
                .expect("the second connect must run");
            assert_eq!(
                second.status,
                ConnectionStatus::Error,
                "the second Connect returned a cached success"
            );
            assert!(!state.has_pool(&id));

            // Disconnecting after a failure is a no-op, not an error.
            disconnect_postgres(id.clone(), &state)
                .await
                .expect("disconnect after a failed connect must succeed");
            assert!(!state.has_pool(&id));
        });
    }
}

/// The connect flow with a tunnel: the address the pool is given, the failure
/// paths, and what is left behind afterwards.
///
/// Every test here uses a REFUSED loopback port for the SSH server, so `ssh`
/// stops at once and the whole module runs offline in well under a second.
#[cfg(test)]
mod tunnel_connect_tests {
    use super::*;
    use crate::db::ssh_tunnel::{self, pick_local_port, SshTunnel};
    use crate::models::{SshAuth, SshTunnelConfig, SslMode};
    use rusqlite::Connection as SqliteConnection;
    use tokio::process::Command;

    fn config(tunnel: Option<SshTunnelConfig>) -> ConnectionConfig {
        ConnectionConfig {
            id: "c1".to_string(),
            name: "c1".to_string(),
            host: "db.internal".to_string(),
            port: 5432,
            database: "nbt".to_string(),
            username: "app".to_string(),
            password: String::new(),
            ssl_mode: SslMode::Disable,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: tunnel,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    /// An SSH server on a loopback port nothing listens on, so every attempt
    /// is refused at once.
    fn tunnel_to_nowhere() -> SshTunnelConfig {
        SshTunnelConfig {
            host: "127.0.0.1".to_string(),
            port: pick_local_port().expect("a closed port"),
            user: Some("nobody".to_string()),
            auth: SshAuth::Agent,
            key_path: None,
            secret: String::new(),
            accept_new_host_keys: false,
        }
    }

    /// The pool must be pointed at the LOCAL end, and must not be able to open
    /// a second tunnel of its own.
    #[test]
    fn the_pool_config_points_at_the_local_end_of_the_tunnel() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let _guard = rt.enter();
        let child = Command::new("/bin/sleep")
            .arg("30")
            .kill_on_drop(true)
            .spawn()
            .expect("spawn");
        let tunnel = SshTunnel::for_test(child, 61234, "");
        let original = config(Some(tunnel_to_nowhere()));

        let effective = pool_config(&original, Some(&tunnel));
        assert_eq!(effective.host, "127.0.0.1");
        assert_eq!(effective.port, 61234);
        assert!(
            effective.ssh_tunnel.is_none(),
            "the pool must not be able to open a tunnel of its own"
        );
        // Everything the tunnel does not touch comes through unchanged.
        assert_eq!(effective.database, "nbt");
        assert_eq!(effective.username, "app");
        assert_eq!(effective.ssl_mode, SslMode::Disable);

        // And the ORIGINAL is untouched, so the UI still shows the database
        // the user typed.
        assert_eq!(original.host, "db.internal");
        assert_eq!(original.port, 5432);
    }

    #[test]
    fn the_pool_config_of_a_connection_without_a_tunnel_is_unchanged() {
        let original = config(None);
        let effective = pool_config(&original, None);
        assert_eq!(effective.host, "db.internal");
        assert_eq!(effective.port, 5432);
        assert!(effective.ssh_tunnel.is_none());
    }

    /// A tunnel that will not open is the whole failure. Nothing may be left
    /// registered, and the NEXT Connect must run the path again instead of
    /// finding a half-made connection.
    #[test]
    fn a_tunnel_that_will_not_open_leaves_no_pool_and_no_tunnel() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let state = AppState::new(SqliteConnection::open_in_memory().unwrap());
            let cfg = config(Some(tunnel_to_nowhere()));
            let id = cfg.id.clone();
            state.set_config(cfg);

            let first = connect_postgres(id.clone(), &state)
                .await
                .expect("a failure is a value, not an Err");
            assert_eq!(first.status, ConnectionStatus::Error);
            let message = first.error.clone().expect("a failure must carry a reason");
            assert!(
                message.contains("did not answer"),
                "the SSH failure must be the reported reason, got {message:?}"
            );
            assert!(!state.has_pool(&id), "no pool may be registered");
            assert!(!state.has_tunnel(&id), "no tunnel may be registered");

            // The UI shows the DATABASE, never the loopback address.
            assert_eq!(first.host, "db.internal");
            assert_eq!(first.port, 5432);

            // Disconnecting after a tunnel failure is a no-op, not an error.
            disconnect_postgres(id.clone(), &state)
                .await
                .expect("disconnect after a failed tunnel must succeed");

            // A second Connect must really run: the tell is that it comes back
            // Error again rather than short-circuiting to Connected.
            let second = connect_postgres(id.clone(), &state)
                .await
                .expect("the second connect must run");
            assert_eq!(second.status, ConnectionStatus::Error);
            assert!(!state.has_pool(&id));
        });
    }

    /// Connect must reap BEFORE it asks whether a pool already exists.
    /// Without that order it finds the stale pool of a dead tunnel and answers
    /// "Connected" over a socket that goes nowhere — and the user has no way
    /// left to reconnect.
    #[test]
    fn connect_does_not_report_a_stale_pool_as_connected() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let _guard = rt.enter();
        rt.block_on(async {
            let state = AppState::new(SqliteConnection::open_in_memory().unwrap());
            let cfg = config(Some(tunnel_to_nowhere()));
            let id = cfg.id.clone();
            state.set_config(cfg);

            // The state a killed tunnel leaves behind before anything notices.
            state.add_pool(
                id.clone(),
                sqlx::postgres::PgPoolOptions::new()
                    .connect_lazy("postgres://nobody@127.0.0.1:1/nowhere")
                    .expect("a lazy pool"),
            );
            let mut child = Command::new("/bin/sleep")
                .arg("30")
                .kill_on_drop(true)
                .spawn()
                .expect("spawn");
            let _ = child.start_kill();
            let _ = child.wait().await;
            state.add_tunnel(id.clone(), SshTunnel::for_test(child, 61003, "ssh: gone\n"));

            let info = connect_postgres(id.clone(), &state).await.expect("connect");
            assert_eq!(
                info.status,
                ConnectionStatus::Error,
                "Connect answered from the stale pool instead of reconnecting"
            );
            assert!(!state.has_pool(&id), "the stale pool must be dropped");
        });
    }

    /// Test Connection takes the same path, so the button cannot pass a
    /// configuration that Connect would refuse.
    #[test]
    fn test_connection_reports_the_tunnel_failure_too() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let result = test_connection(config(Some(tunnel_to_nowhere())))
                .await
                .expect("test reports a failure as a value");
            assert!(!result.success);
            let message = result.error.expect("a reason");
            assert!(
                message.contains("did not answer"),
                "got {message:?}"
            );
        });
    }

    /// A forward the SSH server cannot make gives the pool a plain socket
    /// error, so the reason has to come from the tunnel's stderr.
    #[test]
    fn a_forward_failure_is_named_for_the_database_not_the_socket() {
        let tail = "channel 1: open failed: connect failed: Connection refused\n";
        assert_eq!(
            ssh_tunnel::forward_failure(tail, "ubuntu-wsl.finn.ts.net", 5433),
            Some("The SSH server could not reach ubuntu-wsl.finn.ts.net:5433.".to_string())
        );
        // A tail that says nothing about a forward must NOT be claimed: the
        // pool's own message is better than a guess.
        assert_eq!(
            ssh_tunnel::forward_failure("debug1: nothing to see\n", "db", 5432),
            None
        );
    }
}

/// The connect flow against the user's bastion.
///
///   set -a; source tasks/live-test.env; set +a
///   cargo test --release live_connect -- --ignored --nocapture
#[cfg(test)]
mod live_connect_tests {
    use super::*;
    use crate::models::{SshAuth, SshTunnelConfig, SslMode};
    use rusqlite::Connection as SqliteConnection;

    fn env_or(key: &str, fallback: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| fallback.to_string())
    }

    fn live_config() -> ConnectionConfig {
        ConnectionConfig {
            id: "live".to_string(),
            name: "live".to_string(),
            host: env_or("PHAROS_TEST_PG_HOST", "localhost"),
            port: env_or("PHAROS_TEST_PG_PORT", "5432").parse().unwrap_or(5432),
            database: env_or("PHAROS_TEST_PG_DB", "postgres"),
            username: env_or("PHAROS_TEST_PG_USER", "postgres"),
            password: std::env::var("PHAROS_TEST_PG_PASSWORD").unwrap_or_default(),
            ssl_mode: SslMode::Prefer,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: Some(SshTunnelConfig {
                host: env_or("PHAROS_TEST_SSH_HOST", "localhost"),
                port: env_or("PHAROS_TEST_SSH_PORT", "22").parse().unwrap_or(22),
                user: std::env::var("PHAROS_TEST_SSH_USER")
                    .ok()
                    .filter(|u| !u.is_empty()),
                auth: SshAuth::Agent,
                key_path: None,
                secret: String::new(),
                accept_new_host_keys: false,
            }),
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    fn state_with_live_config() -> (AppState, String) {
        let state = AppState::new(SqliteConnection::open_in_memory().unwrap());
        let config = live_config();
        let id = config.id.clone();
        state.set_config(config);
        (state, id)
    }

    fn local_port_of(state: &AppState, id: &str) -> u16 {
        state
            .tunnels
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(id)
            .map(|t| t.local_port)
            .expect("the connection must hold a tunnel")
    }

    fn ssh_pids_on(local_port: u16) -> Vec<i32> {
        let output = std::process::Command::new("/usr/bin/pgrep")
            .args(["-f", &format!("ssh -N -L 127.0.0.1:{local_port}:")])
            .output()
            .expect("pgrep must run");
        String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .filter_map(|p| p.parse().ok())
            .collect()
    }

    /// Connect, query, disconnect. The connection reports the DATABASE host,
    /// never the loopback the pool actually uses.
    #[test]
    #[ignore = "needs the user's bastion; see tasks/live-test.env"]
    fn live_connect_runs_a_query_and_disconnect_stops_the_tunnel() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (state, id) = state_with_live_config();

            let info = connect_postgres(id.clone(), &state).await.expect("connect");
            assert_eq!(info.status, ConnectionStatus::Connected, "{:?}", info.error);
            println!("connected in {:?} ms", info.latency_ms);
            assert_eq!(
                info.host,
                env_or("PHAROS_TEST_PG_HOST", "localhost"),
                "the UI must show the database host, not 127.0.0.1"
            );
            assert!(state.has_tunnel(&id));

            let local_port = local_port_of(&state, &id);
            assert!(!ssh_pids_on(local_port).is_empty(), "the child must be visible");

            let pool = state.require_pool(&id).expect("the pool is handed out");
            let row: (i32,) = sqlx::query_as("SELECT 1")
                .fetch_one(&pool)
                .await
                .expect("SELECT 1 through the tunnel");
            assert_eq!(row.0, 1);

            // A metadata command takes the same path a user's click does.
            let schemas = crate::commands::metadata::get_schemas(id.clone(), &state)
                .await
                .expect("get_schemas through the tunnel");
            println!("{} schemas", schemas.len());

            disconnect_postgres(id.clone(), &state).await.expect("disconnect");
            assert!(!state.has_pool(&id));
            assert!(!state.has_tunnel(&id));
            assert!(
                ssh_pids_on(local_port).is_empty(),
                "disconnect left an ssh child behind"
            );
        });
    }

    /// D4 end to end: kill the `ssh` under a live connection, then make the
    /// call a user would make. The reason must reach the user, and Connect
    /// must be willing to run again.
    #[test]
    #[ignore = "needs the user's bastion; see tasks/live-test.env"]
    fn live_a_killed_tunnel_reports_itself_at_the_next_call() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (state, id) = state_with_live_config();
            let info = connect_postgres(id.clone(), &state).await.expect("connect");
            assert_eq!(info.status, ConnectionStatus::Connected, "{:?}", info.error);

            let local_port = local_port_of(&state, &id);
            let pids = ssh_pids_on(local_port);
            assert_eq!(pids.len(), 1, "expected one ssh child, found {pids:?}");

            // Kill by PID only — never by name.
            let killed = std::process::Command::new("/bin/kill")
                .arg(pids[0].to_string())
                .status()
                .expect("kill must run");
            assert!(killed.success());
            // The signal needs a moment to be delivered and the child reaped.
            for _ in 0..40 {
                if ssh_pids_on(local_port).is_empty() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }

            let error = crate::commands::metadata::get_schemas(id.clone(), &state)
                .await
                .expect_err("a dead tunnel must fail the call");
            println!("reported: {error}");
            assert!(
                error.starts_with("SSH tunnel closed:"),
                "the user must be told the tunnel closed, got {error:?}"
            );
            assert!(!state.has_pool(&id), "the dead pool must be dropped");
            assert!(!state.has_tunnel(&id));

            // And Connect must run the whole path again rather than answering
            // "already connected" from the stale pool.
            let again = connect_postgres(id.clone(), &state).await.expect("reconnect");
            assert_eq!(again.status, ConnectionStatus::Connected, "{:?}", again.error);
            assert_eq!(state.tunnel_failure(&id), None, "the old reason must be cleared");

            let port_now = local_port_of(&state, &id);
            disconnect_postgres(id.clone(), &state).await.expect("disconnect");
            assert!(ssh_pids_on(port_now).is_empty());
        });
    }
}
