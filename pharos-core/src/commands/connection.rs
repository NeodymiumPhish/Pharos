
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

/// What a save must do with one of this connection's secrets.
///
/// Pure, so the rule can be read and proved on its own, apart from the
/// Keychain write that carries it out. The DATABASE password and the SSH
/// tunnel secret take the SAME rule, under their own switches and their own
/// Keychain keys — see `password_action`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasswordAction {
    /// Write it to the Keychain, and to the cache that mirrors it.
    Store,
    /// Remove whatever the Keychain holds for this connection.
    Forget,
    /// Neither. Nothing was sent and nothing has to go.
    Leave,
}

/// The rule behind `save_connection`'s handling of a remember switch.
///
/// It serves BOTH switches. `ConnectionConfig::remember_password` governs the
/// database password under the bare connection id;
/// `SshTunnelConfig::remember_secret` governs the tunnel secret under
/// `credentials::ssh_secret_key`. The two are independent — one may be on
/// while the other is off — but the rule they follow is one rule, written
/// once.
///
/// The switch off means the secret is NOT written down. It also
/// means anything already written down has to go: a switch labelled "remember
/// the password" that leaves the old one in the Keychain says the opposite of
/// what it does, which is why the control was taken out of the form until this
/// rule existed.
///
/// `sent_is_empty` is "the caller sent no password", never "clear it": the
/// form sends the field masked unless the user revealed it, so an empty string
/// must leave a remembered password alone.
pub fn password_action(
    remember: bool,
    sent_is_empty: bool,
    keychain_has_one: bool,
) -> PasswordAction {
    if !remember {
        // A Keychain write is not free, so an already-absent secret is left
        // alone rather than deleted again.
        return if keychain_has_one { PasswordAction::Forget } else { PasswordAction::Leave };
    }
    if sent_is_empty { PasswordAction::Leave } else { PasswordAction::Store }
}

/// Save a new connection configuration
pub async fn save_connection(
    mut config: ConnectionConfig,
    state: &AppState,
) -> Result<(), String> {
    // Store the secrets in the OS keychain and update the cache. An EMPTY
    // secret means "the caller did not send one", never "clear it": the form
    // sends the password masked unless the user revealed it, so an empty
    // string must leave the stored value alone.
    {
        let mut cache = state.password_cache.lock().map_err(|e| e.to_string())?;
        let action = password_action(
            config.remember_password,
            config.password.is_empty(),
            cache.contains_key(&config.id),
        );
        // Read BEFORE the action: `Forget` takes the stored value out of the
        // cache, and this session should keep working with it.
        let carried = if config.password.is_empty() {
            cache.get(&config.id).cloned()
        } else {
            Some(config.password.clone())
        };
        match action {
            PasswordAction::Store => {
                credentials::store_password_with_cache(&config.id, &config.password, &mut cache)?;
            }
            PasswordAction::Forget => {
                credentials::delete_password_with_cache(&config.id, &mut cache)?;
            }
            PasswordAction::Leave => {}
        }
        if config.remember_password {
            // It is written down now, so the process-only copy has no job.
            state.forget_session_password(&config.id);
        } else {
            // Not written down, so what we have goes to the map that dies with
            // the process. Without this, turning the switch off would drop a
            // live connection's password mid-session.
            if let Some(password) = carried {
                state.set_session_password(&config.id, &password);
            }
            // The cached CONFIG must not become the password's second home
            // either: `load_connections` hands it back to the front end, and a
            // record that does not remember its password has none to hand.
            config.password.clear();
        }

        // The SSH secret has its OWN switch, `SshTunnelConfig::remember_secret`,
        // under its own Keychain key. It follows the same rule as the database
        // password — not written, and anything written already deleted — and
        // the prompt sheet asks for it when a tunnel fails to authenticate.
        // The two switches are independent: clearing one must not touch the
        // other's secret.
        let ssh_key = credentials::ssh_secret_key(&config.id);
        match config.ssh_tunnel.as_mut() {
            // The tunnel is gone, so its secret must go too — from the
            // Keychain AND from the process-only map. Without this the
            // Keychain keeps a secret no connection can ever use or delete.
            None => {
                if cache.contains_key(&ssh_key) {
                    credentials::delete_password_with_cache(&ssh_key, &mut cache)?;
                }
                state.forget_session_password(&ssh_key);
            }
            Some(tunnel) => {
                let action = password_action(
                    tunnel.remember_secret,
                    tunnel.secret.is_empty(),
                    cache.contains_key(&ssh_key),
                );
                // Read BEFORE the action, for the same reason the database
                // password is: `Forget` takes the stored value out of the
                // cache, and this session should keep its tunnel working.
                let carried = if tunnel.secret.is_empty() {
                    cache.get(&ssh_key).cloned()
                } else {
                    Some(tunnel.secret.clone())
                };
                match action {
                    PasswordAction::Store => {
                        credentials::store_password_with_cache(
                            &ssh_key,
                            &tunnel.secret,
                            &mut cache,
                        )?;
                    }
                    PasswordAction::Forget => {
                        credentials::delete_password_with_cache(&ssh_key, &mut cache)?;
                    }
                    PasswordAction::Leave => {}
                }
                if tunnel.remember_secret {
                    // It is written down now, so the process-only copy has no
                    // job.
                    state.forget_session_password(&ssh_key);
                } else {
                    if let Some(secret) = carried {
                        state.set_session_password(&ssh_key, &secret);
                    }
                    // And the cached CONFIG must not become its second home:
                    // `load_connections` hands the record to the front end,
                    // and a tunnel that remembers no secret has none to hand.
                    tunnel.secret.clear();
                }
            }
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
    // And the ones that were never written down — both of them.
    state.forget_session_password(&connection_id);
    state.forget_session_password(&credentials::ssh_secret_key(&connection_id));

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
    let mut config = state
        .get_config(&connection_id)
        .ok_or_else(|| format!("Connection not found: {}", connection_id))?;

    // Which password this attempt dials with: the one typed this run, else the
    // one the Keychain gave us at startup, else none. A record whose
    // `remember_password` is off has nothing in the Keychain, so the session
    // map is the only place it can come from.
    config.password = state.effective_password(&connection_id, &config.password);

    // And the same question for the TUNNEL's secret, under its own key. A
    // tunnel whose `remember_secret` is off has nothing in the Keychain, so
    // the session map is the only place its secret can come from.
    if let Some(tunnel) = config.ssh_tunnel.as_mut() {
        let ssh_key = credentials::ssh_secret_key(&connection_id);
        tunnel.secret = state.effective_password(&ssh_key, &tunnel.secret);
    }

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
                    // TAGGED, so the front end can tell "the bastion refused
                    // our identity" — the one failure it can answer, by
                    // asking for the tunnel secret — from every other reason
                    // a tunnel does not open.
                    return Ok(info_with(
                        &config,
                        ConnectionStatus::Error,
                        Some(sanitize_error(&ssh_tunnel::tagged_tunnel_message(&e))),
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

/// Connect with a password the user has just typed.
///
/// The password is put in the process-only session map FIRST, so this attempt
/// and every later one in this run find it — including the reconnect the front
/// end makes to refresh a connection's status. Nothing is written to the
/// Keychain here: storing it is a separate, explicit act (a save with
/// `remember_password` on), because this call is also what a connection that
/// deliberately remembers nothing uses.
pub async fn connect_postgres_with_password(
    connection_id: String,
    password: String,
    state: &AppState,
) -> Result<ConnectionInfo, String> {
    state.set_session_password(&connection_id, &password);
    connect_postgres(connection_id, state).await
}

/// Connect with an SSH tunnel secret the user has just typed.
///
/// The sibling of `connect_postgres_with_password`, for the other secret. It
/// goes into the same process-only map under `credentials::ssh_secret_key`, so
/// this attempt and every later one this run find it, and nothing is written
/// to the Keychain here — storing it is a separate, explicit act (a save with
/// `remember_secret` on).
///
/// It retries the WHOLE connect, tunnel and pool both: the tunnel opens before
/// the pool, so there is no shorter path back.
pub async fn connect_postgres_with_ssh_secret(
    connection_id: String,
    secret: String,
    state: &AppState,
) -> Result<ConnectionInfo, String> {
    state.set_session_password(&credentials::ssh_secret_key(&connection_id), &secret);
    connect_postgres(connection_id, state).await
}

/// Forget every password typed this run. The Keychain is not touched — there
/// is nothing of this map in it. Returns how many were dropped.
pub fn clear_session_passwords(state: &AppState) -> usize {
    state.clear_session_passwords()
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
            remember_secret: true,
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
                remember_secret: true,
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

/// `remember_password` off means the password is NOT written down, and that
/// anything already written down goes.
///
/// Two layers are proved here. The RULE (`password_action`) is pure and runs
/// everywhere. The SIDE EFFECT runs against the real macOS Keychain, under an
/// isolated service name from `PHAROS_KEYCHAIN_SERVICE`, so the user's own
/// passwords are never read or written by a test.
#[cfg(test)]
mod remember_password_tests {
    use super::{password_action, save_connection, PasswordAction};
    use crate::db::{credentials, sqlite};
    use crate::models::{ConnectionConfig, SslMode};
    use crate::state::AppState;
    use std::path::PathBuf;

    // ---- the rule, all eight inputs -------------------------------------

    #[test]
    fn remembering_stores_what_was_sent_and_leaves_what_was_not() {
        // Sent, so it is written — whether or not one is there already.
        assert_eq!(password_action(true, false, false), PasswordAction::Store);
        assert_eq!(password_action(true, false, true), PasswordAction::Store);
        // Not sent. The form masks the field unless the user reveals it, so an
        // empty string is "no password came with this save", never "clear it".
        assert_eq!(password_action(true, true, false), PasswordAction::Leave);
        assert_eq!(password_action(true, true, true), PasswordAction::Leave);
    }

    #[test]
    fn not_remembering_never_stores_and_removes_what_is_there() {
        // The case the checkbox was taken out of the form for: a password
        // arrives with the switch OFF and must not reach the Keychain.
        assert_eq!(password_action(false, false, false), PasswordAction::Leave);
        assert_eq!(password_action(false, false, true), PasswordAction::Forget);
        // And the switch going off on its own, with the field left masked.
        assert_eq!(password_action(false, true, true), PasswordAction::Forget);
        assert_eq!(password_action(false, true, false), PasswordAction::Leave);
    }

    // ---- the side effect, against the real Keychain ---------------------

    fn temp_db_dir(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("pharos_test_{}_{}", tag, uuid::Uuid::new_v4()))
    }

    fn config(id: &str, password: &str, remember: bool) -> ConnectionConfig {
        ConnectionConfig {
            id: id.to_string(),
            name: format!("conn-{}", id),
            host: "127.0.0.1".to_string(),
            port: 5432,
            database: "nfinn".to_string(),
            username: "nfinn".to_string(),
            password: password.to_string(),
            ssl_mode: SslMode::Disable,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only: false,
            remember_password: remember,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    /// A save with the switch ON writes the password; the same record saved
    /// again with the switch OFF takes it back out of the Keychain, and the
    /// session keeps it in the map that is never written anywhere.
    ///
    /// Against the real Keychain, under a service name of this test's own —
    /// `PHAROS_KEYCHAIN_SERVICE`, the same hook the re-identified test build
    /// of the app uses. Serial: the env var is process-wide, and the suite is
    /// run with `--test-threads=1`.
    #[test]
    fn clearing_the_switch_deletes_the_stored_password() {
        let service = format!("com.pharos.test.remember.{}", uuid::Uuid::new_v4());
        std::env::set_var("PHAROS_KEYCHAIN_SERVICE", &service);

        let dir = temp_db_dir("remember");
        let db = sqlite::init_database(&dir).expect("sqlite");
        let state = AppState::new(db);
        let rt = tokio::runtime::Runtime::new().expect("runtime");

        // 1. Remembered: the Keychain holds it.
        rt.block_on(save_connection(config("c1", "hunter2", true), &state))
            .expect("save with remember on");
        let stored = credentials::load_all_passwords().expect("read keychain");
        assert_eq!(stored.get("c1").map(String::as_str), Some("hunter2"),
                   "a remembered password is written");
        assert!(state.session_password("c1").is_none(),
                "a remembered password needs no process-only copy");

        // 2. The switch goes off, with the field masked (empty), which is what
        // the form sends when the user only clicked the checkbox.
        rt.block_on(save_connection(config("c1", "", false), &state))
            .expect("save with remember off");

        let after = credentials::load_all_passwords().expect("read keychain");
        assert!(!after.contains_key("c1"),
                "clearing the switch DELETES the stored password");
        assert!(!state
                    .password_cache
                    .lock()
                    .unwrap()
                    .contains_key("c1"),
                "and the cache that mirrors the Keychain agrees");
        assert_eq!(state.session_password("c1").as_deref(), Some("hunter2"),
                   "this session keeps working, from the map that is never written down");

        // 3. A save that ARRIVES with a password and the switch off must not
        // write it either.
        rt.block_on(save_connection(config("c2", "s3cret", false), &state))
            .expect("save a new record with remember off");
        let after = credentials::load_all_passwords().expect("read keychain");
        assert!(!after.contains_key("c2"), "an unremembered password is never written");
        assert_eq!(state.session_password("c2").as_deref(), Some("s3cret"));
        assert_eq!(state.get_config("c2").map(|c| c.password).as_deref(), Some(""),
                   "nor does the cached config become its second home");

        // 4. `connect_postgres` would dial with the session password.
        assert_eq!(state.effective_password("c2", ""), "s3cret");
        // 5. And sleep drops both, leaving the Keychain alone.
        assert_eq!(state.clear_session_passwords(), 2);
        assert!(state.session_password("c2").is_none());

        // Leave nothing of this test behind.
        let mut cache = state.password_cache.lock().unwrap();
        let _ = credentials::delete_connection_secrets_with_cache("c1", &mut cache);
        let _ = credentials::delete_connection_secrets_with_cache("c2", &mut cache);
        drop(cache);
        let _ = std::fs::remove_dir_all(&dir);
        std::env::remove_var("PHAROS_KEYCHAIN_SERVICE");
    }
}

/// The SSH tunnel's OWN remember switch: `SshTunnelConfig::remember_secret`.
///
/// The database password's switch and this one are independent. Before this
/// existed the tunnel secret was written to the Keychain whatever the record
/// said, so a user who cleared the database switch expecting nothing of theirs
/// in the Keychain still had the bastion passphrase sitting there.
#[cfg(test)]
mod remember_ssh_secret_tests {
    use super::{connect_postgres_with_ssh_secret, save_connection};
    use crate::db::{credentials, sqlite};
    use crate::models::{ConnectionConfig, SshAuth, SshTunnelConfig, SslMode};
    use crate::state::AppState;
    use std::path::PathBuf;

    fn temp_db_dir(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("pharos_test_{}_{}", tag, uuid::Uuid::new_v4()))
    }

    /// A tunnel pointed at a REFUSED loopback port, so the one test below that
    /// really attempts a connect fails at once and needs no network.
    fn tunnel(secret: &str, remember: bool) -> SshTunnelConfig {
        SshTunnelConfig {
            host: "127.0.0.1".to_string(),
            port: crate::db::ssh_tunnel::pick_local_port().expect("a closed port"),
            user: Some("deploy".to_string()),
            auth: SshAuth::Password,
            key_path: None,
            secret: secret.to_string(),
            accept_new_host_keys: false,
            remember_secret: remember,
        }
    }

    /// `remember_password` is left ON throughout, so nothing below can be
    /// explained by the DATABASE switch: the two secrets are independent, and
    /// that is half of what this proves.
    fn config(id: &str, tunnel: Option<SshTunnelConfig>) -> ConnectionConfig {
        ConnectionConfig {
            id: id.to_string(),
            name: format!("conn-{}", id),
            host: "127.0.0.1".to_string(),
            port: 5432,
            database: "nfinn".to_string(),
            username: "nfinn".to_string(),
            password: "db-password".to_string(),
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

    /// An `ssh_tunnel` column written before this field had no `rememberSecret`
    /// key at all. It must read back as TRUE, which is the behaviour those
    /// records already have — the secret was always stored. No SQLite
    /// migration is involved: the flag rides inside the tunnel JSON.
    #[test]
    fn an_older_tunnel_document_remembers_its_secret() {
        let json = r#"{"host":"bastion","port":22,"auth":"agent","acceptNewHostKeys":false}"#;
        let tunnel: SshTunnelConfig = serde_json::from_str(json).expect("an older document loads");
        assert!(tunnel.remember_secret,
                "the default must be TODAY's behaviour: the secret was always stored");

        // And the key name on the wire is the camelCase one Swift decodes.
        let round = serde_json::to_string(&tunnel).expect("serialize");
        assert!(round.contains("\"rememberSecret\":true"), "got {round}");
    }

    /// With the switch off the `<id>/ssh` item is DELETED and never written,
    /// the session keeps the secret in the map that dies with the process, and
    /// the database password beside it is untouched.
    ///
    /// Against the real Keychain, under a service name of this test's own —
    /// `PHAROS_KEYCHAIN_SERVICE`, the same hook the re-identified test build
    /// uses. Serial: the env var is process-wide, and the suite is run with
    /// `--test-threads=1`.
    #[test]
    fn clearing_the_switch_deletes_the_stored_ssh_secret() {
        let service = format!("com.pharos.test.sshremember.{}", uuid::Uuid::new_v4());
        std::env::set_var("PHAROS_KEYCHAIN_SERVICE", &service);

        let dir = temp_db_dir("sshremember");
        let db = sqlite::init_database(&dir).expect("sqlite");
        let state = AppState::new(db);
        let rt = tokio::runtime::Runtime::new().expect("runtime");
        let ssh_key = credentials::ssh_secret_key("t1");

        // 1. Remembered: the Keychain holds it, under its own key.
        rt.block_on(save_connection(config("t1", Some(tunnel("bastion-pass", true))), &state))
            .expect("save with remember on");
        let stored = credentials::load_all_passwords().expect("read keychain");
        assert_eq!(stored.get(&ssh_key).map(String::as_str), Some("bastion-pass"),
                   "a remembered tunnel secret is written");
        assert!(state.session_password(&ssh_key).is_none(),
                "a remembered secret needs no process-only copy");

        // 2. The switch goes off with the field masked (empty), which is what
        // the form sends when the user only clicked the checkbox.
        rt.block_on(save_connection(config("t1", Some(tunnel("", false))), &state))
            .expect("save with remember off");

        let after = credentials::load_all_passwords().expect("read keychain");
        assert!(!after.contains_key(&ssh_key),
                "clearing the switch DELETES the stored tunnel secret");
        assert!(!state.password_cache.lock().unwrap().contains_key(&ssh_key),
                "and the cache that mirrors the Keychain agrees");
        assert_eq!(state.session_password(&ssh_key).as_deref(), Some("bastion-pass"),
                   "this session's tunnel keeps working, from the map that is never written down");
        assert_eq!(
            state.get_config("t1").and_then(|c| c.ssh_tunnel).map(|t| t.secret).as_deref(),
            Some(""),
            "nor does the cached config become the secret's second home");

        // The two switches are independent: the DATABASE password is still
        // remembered and still there.
        assert_eq!(after.get("t1").map(String::as_str), Some("db-password"),
                   "clearing the tunnel switch must not touch the database password");

        // 3. A save that ARRIVES with a secret and the switch off must not
        // write it either.
        rt.block_on(save_connection(config("t2", Some(tunnel("never-written", false))), &state))
            .expect("save a new record with remember off");
        let t2_key = credentials::ssh_secret_key("t2");
        let after = credentials::load_all_passwords().expect("read keychain");
        assert!(!after.contains_key(&t2_key), "an unremembered secret is never written");
        assert_eq!(state.session_password(&t2_key).as_deref(), Some("never-written"));

        // 4. `connect_postgres` would dial the tunnel with the session secret.
        assert_eq!(state.effective_password(&t2_key, ""), "never-written");

        // 5. A secret typed into the prompt sheet reaches the same map, and
        // nothing is written to the Keychain by that path.
        let before = credentials::load_all_passwords().expect("read keychain");
        // The connect itself cannot succeed here (there is no bastion), but the
        // secret is placed BEFORE the attempt, which is the part under test.
        let _ = rt.block_on(connect_postgres_with_ssh_secret(
            "t2".to_string(), "typed-at-the-sheet".to_string(), &state));
        assert_eq!(state.session_password(&t2_key).as_deref(), Some("typed-at-the-sheet"));
        assert_eq!(credentials::load_all_passwords().expect("read keychain"), before,
                   "typing a secret writes nothing to the Keychain");

        // 6. Removing the tunnel entirely still takes its secret with it —
        // from the Keychain and from the session map both.
        rt.block_on(save_connection(config("t1", Some(tunnel("back-again", true))), &state))
            .expect("re-save with a remembered secret");
        assert!(credentials::load_all_passwords().unwrap().contains_key(&ssh_key));
        rt.block_on(save_connection(config("t1", None), &state))
            .expect("save with the tunnel removed");
        assert!(!credentials::load_all_passwords().unwrap().contains_key(&ssh_key),
                "removing the tunnel deletes its secret, as it did before this switch");
        assert!(state.session_password(&ssh_key).is_none(),
                "and the process-only copy goes with it");

        // 7. Sleep drops the session secrets with the passwords: one map.
        assert!(state.clear_session_passwords() >= 1);
        assert!(state.session_password(&t2_key).is_none());

        // Leave nothing of this test behind.
        let mut cache = state.password_cache.lock().unwrap();
        let _ = credentials::delete_connection_secrets_with_cache("t1", &mut cache);
        let _ = credentials::delete_connection_secrets_with_cache("t2", &mut cache);
        drop(cache);
        let _ = std::fs::remove_dir_all(&dir);
        std::env::remove_var("PHAROS_KEYCHAIN_SERVICE");
    }
}
