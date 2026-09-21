use sqlx::postgres::types::Oid;
use sqlx::postgres::PgPoolOptions;
use sqlx::{Executor, PgPool, Row, ValueRef};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use crate::models::{AnalyzeResult, ColumnInfo, ConnectionConfig, ConstraintInfo, FunctionInfo, IndexInfo, KeyCandidate, PartitionMechanism, PartitionRef, PartitionStrategy, SchemaColumnInfo, SchemaInfo, SslMode, TableInfo, TableKeyInfo, TableType};
use crate::models::ConnectionSettings;
use crate::commands::ddl::{DdlColumn, DdlConstraint, TableDdlParts};

/// Escape a string for safe use as a SQL string literal (防 SQL injection).
/// Replaces single quotes with doubled single quotes.
fn escape_sql_literal(s: &str) -> String {
    s.replace('\'', "''")
}

/// Read a column value as a raw text string, bypassing type OID checks.
/// Works reliably with non-PG servers (ClickHouse, CockroachDB) that may
/// report non-standard type OIDs via the simple query protocol.
fn raw_str(row: &sqlx::postgres::PgRow, col: &str) -> Option<String> {
    match row.try_get_raw(col) {
        Ok(raw) => {
            if raw.is_null() {
                None
            } else {
                raw.as_str().ok().map(|s| s.to_string())
            }
        }
        Err(_) => None,
    }
}

/// How long a whole connect attempt may take before it is reported as a
/// failure. This is the budget the app has always used, and a Require or a
/// Disable connection still gets all of it in one attempt.
const CONNECT_BUDGET: Duration = Duration::from_secs(10);

/// How long the FIRST attempt of an `sslmode=prefer` connection may take, at
/// the default budget.
///
/// libpq's `prefer` means "try TLS, then fall back to plaintext", and the
/// fallback has to happen while the user is still waiting. So the TLS probe
/// gets the larger part of the budget and the plaintext retry gets the rest;
/// the two together never exceed the budget a single attempt had before.
/// `PoolTuning::prefer_probe_budget` is the rule that produces this number
/// from any budget, and a test pins the two together.
#[cfg(test)]
const PREFER_PROBE_BUDGET: Duration = Duration::from_secs(6);

/// Build a connection string with proper URL encoding, using `ssl_mode` in
/// place of the mode stored on the config.
///
/// The mode is a parameter and not read from `config`, so the `prefer`
/// fallback can re-issue the identical connection with TLS switched off.
fn build_connection_string(config: &ConnectionConfig, ssl_mode: SslMode) -> String {
    // URL encode all user-provided fields to prevent parameter injection
    let username = urlencoding::encode(&config.username);
    let password = urlencoding::encode(&config.password);
    let host = urlencoding::encode(&config.host);
    let database = urlencoding::encode(&config.database);

    format!(
        "postgres://{}:{}@{}:{}/{}?sslmode={}",
        username,
        password,
        host,
        config.port,
        database,
        ssl_mode
    )
}

/// The connect options for one attempt: the URL as before, plus the session
/// values in the STARTUP packet.
///
/// `PgConnectOptions::from_str` keeps `build_connection_string` as the single
/// place that URL-encodes the user's fields, so the escaping cannot drift
/// between the two paths. The GUCs are added afterwards because `options` has
/// no place in a URL that sqlx would parse.
///
/// A malformed URL is returned as `sqlx::Error::Configuration`, which the
/// callers already surface as a connection error.
fn connect_options(
    config: &ConnectionConfig,
    ssl_mode: SslMode,
    session: &SessionOptions,
) -> Result<sqlx::postgres::PgConnectOptions, sqlx::Error> {
    use std::str::FromStr;
    let mut options = sqlx::postgres::PgConnectOptions::from_str(
        &build_connection_string(config, ssl_mode),
    )?;
    // The PAIRS, not a pre-rendered string. `PgConnectOptions::options`
    // builds `-c name=value` itself; handing it one string under an empty key
    // produced `-c =…`, and the server answered
    // `unrecognized configuration parameter ""` — caught by the live test,
    // invisible to every unit test, because only a real server parses this.
    let gucs = startup_gucs(session);
    if !gucs.is_empty() {
        options = options.options(gucs.iter().map(|(name, value)| (*name, value.as_str())));
    }
    // `application_name` is a startup parameter of its own, not a `-c` option:
    // sqlx has a setter for it and does NOT claim the name itself, so unlike
    // `TimeZone` this one reaches the server exactly as asked. It is what
    // `pg_stat_activity.application_name` shows.
    if let Some(name) = &session.application_name {
        options = options.application_name(name);
    }
    // The root certificate for `verify-ca` and `verify-full`. Nothing is
    // checked here: a path that does not exist, or is not a certificate, fails
    // the CONNECT with sqlx's own message, which is already reported.
    if let Some(path) = &session.ssl_root_cert {
        options = options.ssl_root_cert(path);
    }

    Ok(options)
}

/// True when a first attempt made with `mode` failed in a way that libpq's
/// `prefer` answers by retrying without TLS.
///
/// `sqlx` already falls back on its own when the server *refuses* the
/// SSLRequest, so the case left to catch is the one it cannot see: a TLS
/// handshake that never finishes. The pool reports that as `PoolTimedOut`,
/// because it keeps retrying the connect until the acquire deadline and never
/// gets a verdict.
///
/// A `Database` error (wrong password, unknown database) and an `Io` error are
/// deliberately excluded: neither is a TLS problem, so a plaintext retry would
/// repeat the same failure and only lengthen the wait. The pool returns both
/// of those immediately rather than retrying them
/// (`sqlx_core::pool::inner::connect`), so the exclusion is reachable.
///
/// One case does NOT reach that exclusion, and it is worth stating: a REFUSED
/// connection. The pool treats `ConnectionRefused` as "the server is still
/// starting up", retries it with backoff to the deadline, and reports it as
/// `PoolTimedOut` — indistinguishable here from the stall. So a closed port
/// does take the plaintext retry. It costs nothing: the probe and the retry
/// share one budget, so the user waits exactly as long as before.
fn should_retry_without_tls(mode: SslMode, err: &sqlx::Error) -> bool {
    if mode != SslMode::Prefer {
        return false;
    }
    match err {
        sqlx::Error::PoolTimedOut => true,
        sqlx::Error::Tls(_) => true,
        sqlx::Error::Protocol(message) => {
            let lowered = message.to_ascii_lowercase();
            lowered.contains("tls") || lowered.contains("ssl")
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Session options (plan §5.1): the values every pooled connection must carry
// ---------------------------------------------------------------------------

/// The per-connection session values Pharos asks PostgreSQL for.
///
/// These go in the STARTUP packet (`options=-c name=value`), not in a `SET`
/// after the connect. Three reasons, and each of them was a defect:
///
///  * A `SET` on one acquired connection reaches ONE of the five in the pool.
///    The existing idle-in-transaction guard below does exactly that, so four
///    connections out of five never had it.
///  * A startup value becomes the session's RESET value, so `RESET ALL` — or
///    a `DISCARD ALL` from a pooler — returns to what the user asked for
///    rather than to the server's default.
///  * A bad value fails the CONNECT with the server's own message, which the
///    caller already turns into `ConnectionStatus::Error`. A failed `SET`
///    can leave the connection unusable and reports nothing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionOptions {
    /// `default_transaction_read_only`.
    pub read_only: bool,
    /// `TimeZone`, e.g. "Asia/Tokyo". None leaves the server's own.
    pub time_zone: Option<String>,
    /// `DateStyle`, e.g. "ISO, MDY".
    pub date_style: Option<String>,
    /// `IntervalStyle`, e.g. "postgres".
    pub interval_style: Option<String>,
    /// `idle_in_transaction_session_timeout`, in milliseconds. 0 = off.
    pub idle_in_transaction_ms: u32,
    /// `tcp_keepalives_idle` / `_interval` / `_count`, in seconds and count.
    /// sqlx 0.8 has no CLIENT-side keepalive, so these are the server-side
    /// probes instead; they keep a NAT or an SSH tunnel from going quiet.
    pub keepalive: Option<(u32, u32, u32)>,
    /// `application_name`. NOT a startup GUC: sqlx has a setter for it, so it
    /// is applied in `connect_options` rather than in `startup_gucs`. None
    /// sends no parameter at all, which is what the app did before.
    pub application_name: Option<String>,
    /// A PEM root certificate for `verify-ca` / `verify-full`. None uses the
    /// system trust store.
    pub ssl_root_cert: Option<String>,
}

impl SessionOptions {
    /// The session one connect asks for: the app-wide Connections settings,
    /// with the per-connection fields on top.
    ///
    /// The only per-connection overrides are the two that belong to one
    /// database rather than to the app: `read_only` and `session_time_zone`.
    /// Everything else is the same for every connection, because it tunes the
    /// client and not the server.
    pub fn from_settings(settings: &ConnectionSettings, config: &ConnectionConfig) -> SessionOptions {
        let per_connection_zone = config
            .session_time_zone
            .as_deref()
            .map(str::trim)
            .filter(|z| !z.is_empty());
        let app_zone = {
            let z = settings.default_time_zone.trim();
            if z.is_empty() { None } else { Some(z) }
        };
        // Any one of the three set means "ask the server for keepalives"; a
        // zero among them is PostgreSQL's own "use the system default", so it
        // is sent as written rather than guessed at.
        let keepalive = if settings.keepalive_idle_seconds > 0
            || settings.keepalive_interval_seconds > 0
            || settings.keepalive_count > 0
        {
            Some((
                settings.keepalive_idle_seconds,
                settings.keepalive_interval_seconds,
                settings.keepalive_count,
            ))
        } else {
            None
        };

        SessionOptions {
            read_only: config.read_only,
            time_zone: per_connection_zone.or(app_zone).map(str::to_string),
            date_style: None,
            interval_style: None,
            idle_in_transaction_ms: settings
                .idle_in_transaction_seconds
                .saturating_mul(1000),
            keepalive,
            application_name: Some(settings.effective_application_name()),
            ssl_root_cert: config
                .ssl_root_cert_path
                .as_deref()
                .map(str::trim)
                .filter(|p| !p.is_empty())
                .map(str::to_string),
        }
    }
}

/// How the pool itself is tuned. `Default` is what `pool_options` and
/// `CONNECT_BUDGET` hard-coded before Settings ▸ Connections existed, and
/// `pool_tuning_defaults_match_todays_literals` pins that.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PoolTuning {
    pub max_connections: u32,
    /// The whole budget for one connect attempt.
    pub connect_timeout: Duration,
    pub idle_timeout: Duration,
    pub max_lifetime: Duration,
}

impl Default for PoolTuning {
    fn default() -> Self {
        PoolTuning {
            max_connections: 5,
            connect_timeout: CONNECT_BUDGET,
            idle_timeout: Duration::from_secs(600),
            max_lifetime: Duration::from_secs(1800),
        }
    }
}

impl From<&ConnectionSettings> for PoolTuning {
    fn from(settings: &ConnectionSettings) -> Self {
        let fallback = PoolTuning::default();
        PoolTuning {
            // A pool of zero can never hand out a connection, so one is the
            // floor. The Settings stepper has the same floor; this is the
            // guard for a blob that came from somewhere else.
            max_connections: settings.max_connections.max(1),
            connect_timeout: if settings.connect_timeout_seconds == 0 {
                fallback.connect_timeout
            } else {
                Duration::from_secs(settings.connect_timeout_seconds as u64)
            },
            idle_timeout: Duration::from_secs(settings.idle_timeout_seconds as u64),
            max_lifetime: Duration::from_secs(settings.max_lifetime_seconds as u64),
        }
    }
}

impl PoolTuning {
    /// How much of the budget the TLS probe of an `sslmode=prefer` connect
    /// may take, leaving the rest for the plaintext retry.
    ///
    /// Three fifths, which is exactly the 6 seconds of 10 the two constants
    /// hard-coded before the budget could be changed.
    fn prefer_probe_budget(&self) -> Duration {
        self.connect_timeout * 3 / 5
    }
}

/// The GUCs Pharos can put in the STARTUP packet, as `(name, value)` pairs.
///
/// `TimeZone` and `DateStyle` are NOT here, and that is a fact about sqlx,
/// not a choice. `sqlx-postgres 0.8.6` writes its own startup parameters
/// before ours (`connection/establish.rs:26-45`):
///
/// ```text
/// ("DateStyle", "ISO, MDY"), ("client_encoding", "UTF8"), ("TimeZone", "UTC")
/// ```
///
/// and appends our `options` after them, where the server lets the explicit
/// parameters win. A live test proved it: the connection succeeded and then
/// answered `SHOW TimeZone` with `UTC`. There is no `timezone()` setter on
/// `PgConnectOptions` in 0.8, so those two are applied per connection by
/// `session_setup_sql` instead. Everything else really does travel in the
/// startup packet.

///
/// Values are escaped the way libpq's `options` parameter needs: a space is
/// the separator between options, so a space INSIDE a value must be
/// backslash-escaped — `DateStyle=ISO, MDY` has to be sent as `ISO,\ MDY`.
/// Getting this wrong does not fail loudly; the server sees a truncated
/// value and a stray option, and the connection is refused with a message
/// about the wrong thing.
pub fn startup_gucs(options: &SessionOptions) -> Vec<(&'static str, String)> {
    let mut out: Vec<(&'static str, String)> = Vec::new();
    if options.read_only {
        out.push(("default_transaction_read_only", "on".to_string()));
    }
    // TimeZone and DateStyle are deliberately absent — see the note above.
    if let Some(style) = &options.interval_style {
        out.push(("IntervalStyle", style.clone()));
    }
    if options.idle_in_transaction_ms > 0 {
        out.push((
            "idle_in_transaction_session_timeout",
            options.idle_in_transaction_ms.to_string(),
        ));
    }
    if let Some((idle, interval, count)) = options.keepalive {
        out.push(("tcp_keepalives_idle", idle.to_string()));
        out.push(("tcp_keepalives_interval", interval.to_string()));
        out.push(("tcp_keepalives_count", count.to_string()));
    }
    out
}

/// The `SET` statements that must run on every connection the pool opens,
/// because sqlx claims these two names in its own startup packet and we
/// cannot outbid it (see `startup_gucs`).
///
/// This runs from `PgPoolOptions::after_connect`, which fires for EVERY
/// connection the pool creates — unlike the acquire-one-and-SET pattern this
/// replaces, which reached one connection of five. The one property it
/// cannot have is the startup packet's: `RESET TimeZone` returns to sqlx's
/// `UTC`, not to the user's value, because the reset value is whatever the
/// startup packet carried. Nothing in Pharos issues `RESET ALL` or
/// `DISCARD ALL`, and the live tests pin both halves of this.
///
/// Values are single-quoted with `''` doubling, so a value can never end the
/// literal and start a statement.
pub fn session_setup_sql(options: &SessionOptions) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(tz) = &options.time_zone {
        out.push(format!("SET TimeZone = '{}'", tz.replace('\'', "''")));
    }
    if let Some(style) = &options.date_style {
        out.push(format!("SET DateStyle = '{}'", style.replace('\'', "''")));
    }
    out
}

/// Render the GUCs as the libpq `options` string, or None when there is
/// nothing to say. Emitting an empty `options` would be harmless but noisy in
/// `pg_stat_activity`, and None keeps the unchanged case byte-identical to
/// what the app sent before this existed.
pub fn options_string(options: &SessionOptions) -> Option<String> {
    let gucs = startup_gucs(options);
    if gucs.is_empty() {
        return None;
    }
    Some(
        gucs.iter()
            .map(|(name, value)| format!("-c {}={}", name, escape_option_value(value)))
            .collect::<Vec<_>>()
            .join(" "),
    )
}

/// Backslash-escape the characters libpq's `options` parser treats specially:
/// a space (the separator) and a backslash (the escape itself).
fn escape_option_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch == '\\' || ch == ' ' {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod session_options_tests {
    use super::*;

    /// The default asks for nothing at all, so a connection made with no
    /// settings changed is byte-identical to what the app sent before.
    #[test]
    fn default_emits_no_options() {
        let options = SessionOptions::default();
        assert!(startup_gucs(&options).is_empty());
        assert_eq!(options_string(&options), None);
    }

    #[test]
    fn read_only_is_on_not_true() {
        let options = SessionOptions { read_only: true, ..Default::default() };
        assert_eq!(startup_gucs(&options), vec![("default_transaction_read_only", "on".to_string())]);
        assert_eq!(options_string(&options).as_deref(), Some("-c default_transaction_read_only=on"));
    }

    /// The escaping this function exists for. A value with a space in it must
    /// not end the option early — libpq reads a space as the separator.
    #[test]
    fn a_space_inside_a_value_is_escaped() {
        let options = SessionOptions {
            interval_style: Some("postgres verbose".to_string()),
            ..Default::default()
        };
        assert_eq!(startup_gucs(&options), vec![("IntervalStyle", "postgres verbose".to_string())],
                   "the pair keeps the real value; only the rendered string escapes");
        assert_eq!(options_string(&options).as_deref(), Some("-c IntervalStyle=postgres\\ verbose"));
    }

    #[test]
    fn a_backslash_is_escaped_too() {
        let options = SessionOptions {
            interval_style: Some("a\\b".to_string()),
            ..Default::default()
        };
        assert_eq!(options_string(&options).as_deref(), Some("-c IntervalStyle=a\\\\b"));
    }

    /// The finding that reshaped this primitive: sqlx writes `TimeZone` and
    /// `DateStyle` into its OWN startup parameters and appends ours after
    /// them, where the server lets its win. So those two must never appear in
    /// the startup GUCs — they go through `session_setup_sql` — and an edit
    /// that "helpfully" puts them back fails here.
    #[test]
    fn time_zone_and_date_style_are_not_startup_gucs() {
        let options = SessionOptions {
            time_zone: Some("Asia/Tokyo".to_string()),
            date_style: Some("ISO, DMY".to_string()),
            ..Default::default()
        };
        assert!(startup_gucs(&options).is_empty(), "sqlx claims both names; see startup_gucs");
        assert_eq!(options_string(&options), None);
        assert_eq!(
            session_setup_sql(&options),
            vec![
                "SET TimeZone = 'Asia/Tokyo'".to_string(),
                "SET DateStyle = 'ISO, DMY'".to_string(),
            ]
        );
    }

    /// A quote in a value cannot end the literal and start a statement.
    #[test]
    fn a_quote_in_a_session_value_is_doubled() {
        let options = SessionOptions {
            time_zone: Some("a'; DROP TABLE t; --".to_string()),
            ..Default::default()
        };
        assert_eq!(
            session_setup_sql(&options),
            vec!["SET TimeZone = 'a''; DROP TABLE t; --'".to_string()]
        );
    }

    /// Nothing asked for means no per-connection SQL at all, so a default
    /// pool makes exactly the calls it made before this existed.
    #[test]
    fn default_session_runs_no_setup_sql() {
        assert!(session_setup_sql(&SessionOptions::default()).is_empty());
    }

    #[test]
    fn zero_idle_in_transaction_is_off_not_zero_milliseconds() {
        let off = SessionOptions { idle_in_transaction_ms: 0, ..Default::default() };
        assert!(startup_gucs(&off).is_empty(), "0 means leave it alone");
        let on = SessionOptions { idle_in_transaction_ms: 30_000, ..Default::default() };
        assert_eq!(
            startup_gucs(&on),
            vec![("idle_in_transaction_session_timeout", "30000".to_string())]
        );
    }

    #[test]
    fn keepalive_emits_all_three_gucs() {
        let options = SessionOptions { keepalive: Some((60, 10, 6)), ..Default::default() };
        assert_eq!(
            startup_gucs(&options),
            vec![
                ("tcp_keepalives_idle", "60".to_string()),
                ("tcp_keepalives_interval", "10".to_string()),
                ("tcp_keepalives_count", "6".to_string()),
            ]
        );
    }

    /// Everything at once, in a stable order, so a connection string can be
    /// compared byte for byte in a live test.
    #[test]
    fn full_options_render_in_a_stable_order() {
        let options = SessionOptions {
            read_only: true,
            time_zone: Some("Asia/Tokyo".to_string()),
            date_style: Some("ISO, DMY".to_string()),
            interval_style: Some("postgres".to_string()),
            idle_in_transaction_ms: 15_000,
            keepalive: Some((60, 10, 6)),
            // Neither is a startup GUC, so neither may appear in the string.
            application_name: Some("Pharos".to_string()),
            ssl_root_cert: Some("/etc/ssl/root.crt".to_string()),
        };
        assert_eq!(
            options_string(&options).as_deref(),
            Some(
                "-c default_transaction_read_only=on \
                 -c IntervalStyle=postgres \
                 -c idle_in_transaction_session_timeout=15000 \
                 -c tcp_keepalives_idle=60 \
                 -c tcp_keepalives_interval=10 \
                 -c tcp_keepalives_count=6"
                    .replace("                 ", "")
                    .as_str()
            )
        );
        assert_eq!(session_setup_sql(&options).len(), 2,
                   "and both sqlx-claimed values go through the per-connection SQL");
    }
}

/// The pool settings shared by every connect attempt. Only the connection
/// ceiling and the acquire budget differ between the app pool and the
/// short-lived pool the Test button uses.
fn pool_options(tuning: &PoolTuning, budget: Duration) -> PgPoolOptions {
    PgPoolOptions::new()
        .max_connections(tuning.max_connections)
        .acquire_timeout(budget)
        .idle_timeout(tuning.idle_timeout)
        .max_lifetime(tuning.max_lifetime)
}

/// `pool_options`, plus the per-connection `SET`s sqlx forces on us. A
/// failure here fails the ACQUIRE with the server's message, which is the
/// same place a bad startup value would surface.
fn pool_options_with_session(
    tuning: &PoolTuning,
    budget: Duration,
    session: &SessionOptions,
) -> PgPoolOptions {
    let statements = session_setup_sql(session);
    let base = pool_options(tuning, budget);
    if statements.is_empty() {
        return base;
    }
    base.after_connect(move |conn, _meta| {
        let statements = statements.clone();
        Box::pin(async move {
            for sql in statements {
                conn.execute(sqlx::raw_sql(&sql)).await?;
            }
            Ok(())
        })
    })
}

/// Connect, giving `prefer` the meaning libpq gives it: one TLS probe, then
/// one plaintext retry. Returns the pool and the SSL mode that actually
/// carried it, which is the configured mode unless the fallback fired.
///
/// Require and Disable take exactly one attempt with the full budget, so their
/// behaviour is unchanged.
async fn connect_with_prefer_fallback(
    config: &ConnectionConfig,
    tuning: &PoolTuning,
    session: &SessionOptions,
) -> Result<(PgPool, SslMode), sqlx::Error> {
    let mode = config.ssl_mode;
    let first_budget = if mode == SslMode::Prefer {
        tuning.prefer_probe_budget()
    } else {
        tuning.connect_timeout
    };

    let first = pool_options_with_session(tuning, first_budget, session)
        .connect_with(connect_options(config, mode, session)?)
        .await;

    match first {
        Ok(pool) => Ok((pool, mode)),
        Err(e) if should_retry_without_tls(mode, &e) => {
            log::warn!(
                "TLS negotiation with {}:{} did not complete ({}). \
                 sslmode=prefer allows plaintext, so retrying without TLS.",
                config.host,
                config.port,
                e
            );
            let pool = pool_options_with_session(
                tuning, tuning.connect_timeout - first_budget, session)
                .connect_with(connect_options(config, SslMode::Disable, session)?)
                .await?;
            log::warn!(
                "Connected to {}:{} WITHOUT TLS (sslmode=prefer fell back).",
                config.host,
                config.port
            );
            Ok((pool, SslMode::Disable))
        }
        Err(e) => Err(e),
    }
}

/// Create a PostgreSQL connection pool for the given configuration, asking
/// for nothing in particular and tuned the way the app was tuned before
/// Settings ▸ Connections existed.
pub async fn create_pool(config: &ConnectionConfig) -> Result<PgPool, sqlx::Error> {
    create_pool_with_session(config, &SessionOptions::default()).await
}

/// `create_pool_with`, with the default pool tuning.
pub async fn create_pool_with_session(
    config: &ConnectionConfig,
    session: &SessionOptions,
) -> Result<PgPool, sqlx::Error> {
    create_pool_with(config, session, &PoolTuning::default()).await
}

/// Create the pool, asking the server for `session` on every connection it
/// opens and tuning the pool itself with `tuning`.
///
/// This is the one `connect_postgres` calls, with both built from the user's
/// settings and the connection record.
pub async fn create_pool_with(
    config: &ConnectionConfig,
    session: &SessionOptions,
    tuning: &PoolTuning,
) -> Result<PgPool, sqlx::Error> {
    let (pool, _mode_used) = connect_with_prefer_fallback(config, tuning, session).await?;

    // Try to set a session-level idle-in-transaction guard. This is
    // PostgreSQL-specific and will fail (and may kill the connection) on
    // non-PG servers like ClickHouse, so we run it after pool creation on a
    // separate connection rather than in after_connect where a failure
    // poisons every connection. The query timeout is applied per query on
    // the executing connection (see commands/query.rs), not here.
    // Only when the startup packet carried nothing. With `options` set, the
    // guard is a startup GUC on EVERY connection in the pool; this `SET`
    // reaches exactly one of the five, which is why it is a fallback and not
    // the mechanism.
    if session.idle_in_transaction_ms == 0 {
        if let Ok(mut conn) = pool.acquire().await {
            let _ = (&mut *conn)
                .execute(sqlx::raw_sql(
                    "SET idle_in_transaction_session_timeout = '30s'",
                ))
                .await;
        }
    }

    Ok(pool)
}

/// Test a PostgreSQL connection and return latency
pub async fn test_connection(config: &ConnectionConfig) -> Result<u64, sqlx::Error> {
    let start = Instant::now();

    // The same prefer fallback as create_pool, so the Test button cannot
    // report a failure for a configuration that Connect would accept.
    let probe_tuning = PoolTuning { max_connections: 1, ..PoolTuning::default() };
    let (pool, _mode_used) =
        connect_with_prefer_fallback(config, &probe_tuning, &SessionOptions::default()).await?;

    // Use raw_sql (simple query protocol) for compatibility with
    // non-PostgreSQL servers (e.g. ClickHouse) that don't support
    // the extended query protocol's ParameterDescription message.
    sqlx::raw_sql("SELECT 1").execute(&pool).await?;

    let latency = start.elapsed().as_millis() as u64;

    // Close the test pool
    pool.close().await;

    Ok(latency)
}

/// The schema listing statement.
///
/// Pure, so the two shapes can be pinned by a unit test without a server.
///
/// `include_system` false is what Pharos has always sent: the three system
/// schemas are named and excluded. True lets `pg_catalog` and
/// `information_schema` through — they are worth browsing — but NEVER the
/// storage schemas. `pg_toast*` holds the out-of-line halves of wide rows and
/// `pg_temp_*` one namespace per backend that has made a temporary table:
/// there can be thousands, none of them is anything a person reads, and a
/// tree full of them is worse than no tree. The backslash is LIKE's default
/// escape character, so `pg\_temp\_%` matches a real underscore rather than
/// any character at all.
pub(crate) fn schemas_sql(include_system: bool) -> &'static str {
    if include_system {
        "SELECT schema_name, schema_owner \
         FROM information_schema.schemata \
         WHERE schema_name NOT LIKE 'pg\\_toast%' \
           AND schema_name NOT LIKE 'pg\\_temp\\_%' \
         ORDER BY schema_name"
    } else {
        "SELECT schema_name, schema_owner \
         FROM information_schema.schemata \
         WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast') \
         ORDER BY schema_name"
    }
}

/// Get all schemas in the database. `include_system` follows
/// Settings ▸ Navigator ▸ Show system schemas.
pub async fn get_schemas(
    pool: &PgPool,
    include_system: bool,
) -> Result<Vec<SchemaInfo>, sqlx::Error> {
    // No parameters needed — use raw_sql for simple protocol compatibility
    let rows = sqlx::raw_sql(schemas_sql(include_system))
        .fetch_all(pool)
        .await?;

    let schemas = rows
        .into_iter()
        .filter_map(|row| {
            Some(SchemaInfo {
                name: raw_str(&row, "schema_name")?,
                owner: raw_str(&row, "schema_owner"),
            })
        })
        .collect();

    Ok(schemas)
}

/// Analyze tables in a schema that have never been analyzed (reltuples = -1).
/// Returns which tables were attempted and which had permission errors.
/// Tables in `skip_denied` are known to be permission-denied from a previous
/// attempt in this session and are excluded from re-analysis.
pub async fn analyze_schema(
    pool: &PgPool,
    schema_name: &str,
    skip_denied: &HashSet<String>,
    inheritance: bool,
) -> Result<AnalyzeResult, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let sql = format!(
        "SELECT c.relname as table_name \
         FROM pg_catalog.pg_class c \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         WHERE n.nspname = '{}' \
           AND c.relkind = 'r' \
           AND c.reltuples = -1",
        escaped_schema
    );

    // pg_catalog may not exist on non-PG servers — return empty result on failure
    let unanalyzed: Vec<String> = match sqlx::raw_sql(&sql).fetch_all(pool).await {
        Ok(rows) => rows.into_iter().map(|row| row.get::<String, _>("table_name")).collect(),
        Err(_) => return Ok(AnalyzeResult {
            had_unanalyzed: false,
            permission_denied_tables: vec![],
            tables: vec![],
        }),
    };

    let had_unanalyzed = !unanalyzed.is_empty();
    let mut permission_denied_tables = Vec::new();

    // Filter out tables already known to be permission-denied
    let to_analyze: Vec<&String> = unanalyzed.iter()
        .filter(|t| !skip_denied.contains(*t))
        .collect();
    for t in &unanalyzed {
        if skip_denied.contains(t) {
            permission_denied_tables.push(t.clone());
        }
    }

    if !to_analyze.is_empty() {
        // Try batched ANALYZE first (single round-trip for all tables)
        let escaped_schema_ident = schema_name.replace('"', "\"\"");
        let table_list: Vec<String> = to_analyze.iter()
            .map(|t| format!("\"{}\".\"{}\"", escaped_schema_ident, t.replace('"', "\"\"")))
            .collect();
        let batch_sql = format!("ANALYZE {}", table_list.join(", "));

        if let Err(_) = sqlx::raw_sql(&batch_sql).execute(pool).await {
            // Batch failed (likely permission denied on one+ tables).
            // Fall back to per-table ANALYZE to identify which ones failed.
            for table_name in &to_analyze {
                let analyze_sql = format!(
                    "ANALYZE \"{}\".\"{}\"",
                    escaped_schema_ident,
                    table_name.replace('"', "\"\"")
                );
                if let Err(e) = sqlx::raw_sql(&analyze_sql).execute(pool).await {
                    let msg = e.to_string().to_lowercase();
                    if msg.contains("permission denied") || msg.contains("only table or database owner can analyze") {
                        permission_denied_tables.push((*table_name).clone());
                    }
                }
            }
        }
    }

    // Re-fetch tables so callers get the post-ANALYZE row count estimates in
    // the same FFI round-trip. Falls back to an empty vec on read failure —
    // the caller still gets a valid AnalyzeResult.
    let tables = get_tables(pool, schema_name, inheritance).await.unwrap_or_default();

    Ok(AnalyzeResult {
        had_unanalyzed,
        permission_denied_tables,
        tables,
    })
}

/// The statement the table list sends when `pg_catalog` is readable, kept
/// in one place the way `schemas_sql` is: a shape this exact has to be
/// pinned by a test, not read out of a `format!` in the middle of a
/// function. `escaped_schema` is already through `escape_sql_literal`.
pub(crate) fn tables_sql(escaped_schema: &str, inheritance: bool) -> String {
    // Settings ▸ Navigator ▸ Group inherited tables. Off, every fragment
    // below is empty and the statement is the one Pharos has always sent.
    //
    // On, a recursive walk of `pg_inherits` treats a legacy inheritance tree
    // the way `pg_partition_tree` already treats a declarative one: the root
    // reports the whole tree's rows and size, and the children come out of
    // the top level, because they belong under their parent.
    //
    // Only TRUE roots seed the walk. Seeding every relation would give the
    // mid-level tables their own sums, but `pg_total_relation_size` would
    // then be called once per level of depth rather than once per relation,
    // and those sums are not needed here: `get_partitions` computes them one
    // parent at a time, as a folder is opened.
    //
    // `UNION`, not `UNION ALL`: a relation that inherits from two tables in
    // the same tree must not be counted twice.
    let prelude = if inheritance {
        format!(
            "WITH RECURSIVE inh_root AS ( \
                 SELECT c.oid \
                 FROM pg_catalog.pg_class c \
                 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
                 WHERE n.nspname = '{schema}' \
                   AND c.relkind IN ('r', 'f', 'm') \
                   AND c.relispartition = false \
                   AND NOT EXISTS ( \
                       SELECT 1 FROM pg_catalog.pg_inherits i \
                       JOIN pg_catalog.pg_class p ON p.oid = i.inhparent \
                       JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace \
                       WHERE i.inhrelid = c.oid AND pn.nspname = '{schema}' \
                         AND p.relkind <> 'p') \
             ), inh(root, relid) AS ( \
                 SELECT oid, oid FROM inh_root \
                 UNION \
                 SELECT t.root, i.inhrelid \
                 FROM pg_catalog.pg_inherits i \
                 JOIN inh t ON i.inhparent = t.relid \
             ), inh_tree AS ( \
                 SELECT t.root, \
                        count(*) FILTER (WHERE t.relid <> t.root)::bigint as desc_count, \
                        SUM(CASE WHEN ic.reltuples >= 0 THEN ic.reltuples::bigint \
                                 ELSE COALESCE(ist.n_live_tup, 0) END)::bigint as sum_tuples, \
                        SUM(CASE WHEN ic.relkind IN ('r', 'm') \
                                 THEN pg_total_relation_size(ic.oid) \
                                 ELSE 0 END)::bigint as sum_bytes \
                 FROM inh t \
                 JOIN pg_catalog.pg_class ic ON ic.oid = t.relid \
                 LEFT JOIN pg_catalog.pg_stat_all_tables ist ON ist.relid = t.relid \
                 GROUP BY t.root \
             ), inh_child AS ( \
                 SELECT DISTINCT i.inhrelid as oid \
                 FROM pg_catalog.pg_inherits i \
                 JOIN pg_catalog.pg_class p ON p.oid = i.inhparent \
                 JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace \
                 WHERE pn.nspname = '{schema}' AND p.relkind <> 'p' \
             ) ",
            schema = escaped_schema
        )
    } else {
        String::new()
    };
    let tree_rows = if inheritance {
        "WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_tuples "
    } else {
        ""
    };
    let tree_size = if inheritance {
        "WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_bytes "
    } else {
        ""
    };
    let parent_test = if inheritance {
        "(c.relkind = 'p' OR COALESCE(st.desc_count, 0) > 0)"
    } else {
        "(c.relkind = 'p')"
    };
    let count_test = if inheritance {
        "c.relkind = 'p' OR COALESCE(st.desc_count, 0) > 0"
    } else {
        "c.relkind = 'p'"
    };
    let tree_joins = if inheritance {
        "LEFT JOIN inh_tree st ON st.root = c.oid \
         LEFT JOIN inh_child ihc ON ihc.oid = c.oid "
    } else {
        ""
    };
    // The test is deliberately schema-local: a child whose parent lives in
    // another schema stays visible here, because hiding it would leave no
    // way to reach it at all.
    let child_filter = if inheritance { "AND ihc.oid IS NULL " } else { "" };

    format!(
        "{prelude}SELECT \
            c.relname as table_name, \
            CASE c.relkind \
                WHEN 'r' THEN 'BASE TABLE' \
                WHEN 'v' THEN 'VIEW' \
                WHEN 'm' THEN 'VIEW' \
                WHEN 'f' THEN 'FOREIGN TABLE' \
                WHEN 'p' THEN 'PARTITIONED TABLE' \
                ELSE 'BASE TABLE' \
            END as table_type, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(lc.reltuples), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt \
                    JOIN pg_class lc ON lc.oid = pt.relid \
                    WHERE pt.isleaf) \
                {tree_rows}\
                WHEN c.reltuples >= 0 THEN c.reltuples::bigint \
                WHEN s.n_live_tup IS NOT NULL THEN s.n_live_tup \
                ELSE NULL \
            END as row_estimate, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(pg_total_relation_size(pt.relid)), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt WHERE pt.isleaf) \
                {tree_size}\
                WHEN c.relkind IN ('r', 'm') THEN pg_total_relation_size(c.oid) \
                ELSE NULL \
            END as total_size_bytes, \
            (c.relkind <> 'p' AND EXISTS ( \
                SELECT 1 FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = c.oid)) as has_child_tables, \
            {parent_test} as is_partitioned, \
            CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text ELSE NULL END as part_strat, \
            CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) ELSE NULL END as part_key, \
            CASE WHEN {count_test} THEN ( \
                SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid)::bigint \
                ELSE NULL END as part_count \
         FROM pg_catalog.pg_class c \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         LEFT JOIN pg_catalog.pg_stat_all_tables s ON s.relid = c.oid \
         LEFT JOIN pg_catalog.pg_partitioned_table pt2 ON pt2.partrelid = c.oid \
         {tree_joins}\
         WHERE n.nspname = '{schema}' \
           AND c.relkind IN ('r', 'v', 'm', 'f', 'p') \
           AND c.relispartition = false \
           {child_filter}\
         ORDER BY \
            CASE c.relkind \
                WHEN 'r' THEN 1 \
                WHEN 'p' THEN 1 \
                WHEN 'f' THEN 2 \
                WHEN 'v' THEN 3 \
                WHEN 'm' THEN 4 \
            END, \
            c.relname",
        schema = escaped_schema
    )
}

/// Get all tables and views in a schema
pub async fn get_tables(
    pool: &PgPool,
    schema_name: &str,
    inheritance: bool,
) -> Result<Vec<TableInfo>, sqlx::Error> {
    let escaped = escape_sql_literal(schema_name);

    // Try pg_catalog first for full metadata (row estimates, sizes, foreign tables)
    let pg_catalog_sql = tables_sql(&escaped, inheritance);

    if let Ok(rows) = sqlx::raw_sql(&pg_catalog_sql).fetch_all(pool).await {
        let tables = rows
            .into_iter()
            .map(|row| {
                let table_type_str: String = row.get("table_type");
                let is_partitioned: bool = row.try_get("is_partitioned").unwrap_or(false);
                let part_strat: Option<String> = row.try_get("part_strat").ok().flatten();
                let partition_strategy = part_strat
                    .as_deref()
                    .and_then(|s| s.chars().next())
                    .and_then(PartitionStrategy::from_pg_char);
                // relkind='p' is the only thing the statement maps to
                // PARTITIONED TABLE, so the type already says which mechanism
                // a parent uses — no second column needed, and the shape the
                // `tables_sql` test pins stays as it is.
                let partition_mechanism = if !is_partitioned {
                    None
                } else if table_type_str == "PARTITIONED TABLE" {
                    Some(PartitionMechanism::Declarative)
                } else {
                    Some(PartitionMechanism::Inheritance)
                };
                TableInfo {
                    name: row.get("table_name"),
                    schema_name: schema_name.to_string(),
                    table_type: match table_type_str.as_str() {
                        "VIEW" => TableType::View,
                        "FOREIGN TABLE" => TableType::ForeignTable,
                        "PARTITIONED TABLE" => TableType::PartitionedTable,
                        _ => TableType::Table,
                    },
                    row_count_estimate: row.try_get("row_estimate").ok(),
                    total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
                    is_partitioned,
                    is_partition: false,
                    partition_strategy,
                    partition_key: row.try_get("part_key").ok().flatten(),
                    partition_bound: None,
                    partition_count: row.try_get("part_count").ok().flatten(),
                    partition_mechanism,
                    has_child_tables: row.try_get("has_child_tables").unwrap_or(false),
                }
            })
            .collect();

        return Ok(tables);
    }

    // Fallback: use information_schema (works on ClickHouse and other PG-compatible servers)
    let fallback_sql = format!(
        "SELECT table_name, table_type \
         FROM information_schema.tables \
         WHERE table_schema = '{}' \
         ORDER BY table_type, table_name",
        escaped
    );

    let rows = sqlx::raw_sql(&fallback_sql).fetch_all(pool).await?;

    let tables = rows
        .into_iter()
        .filter_map(|row| {
            let table_type_str = raw_str(&row, "table_type").unwrap_or_default();
            Some(TableInfo {
                name: raw_str(&row, "table_name")?,
                schema_name: schema_name.to_string(),
                table_type: match table_type_str.as_str() {
                    "VIEW" => TableType::View,
                    "FOREIGN TABLE" => TableType::ForeignTable,
                    _ => TableType::Table,
                },
                row_count_estimate: None,
                total_size_bytes: None,
                is_partitioned: false,
                is_partition: false,
                partition_strategy: None,
                partition_key: None,
                partition_bound: None,
                partition_count: None,
                partition_mechanism: None,
                has_child_tables: false,
            })
        })
        .collect();

    Ok(tables)
}

/// The statement behind `get_partitions`, kept beside `tables_sql` and
/// pinned by a test for the same reason. Both names arrive already through
/// `escape_sql_literal`.
///
/// With `inheritance` on, the walk is seeded with the parent's DIRECT
/// children, whose subtrees are disjoint — so each descendant is measured
/// once, and a mid-level table (a year, a month) reports the rows and size
/// of everything under it, exactly as the root does in the table list.
pub(crate) fn partitions_sql(
    escaped_schema: &str,
    escaped_parent: &str,
    inheritance: bool,
) -> String {
    let prelude = if inheritance {
        format!(
            "WITH RECURSIVE kin AS ( \
                 SELECT c.oid \
                 FROM pg_catalog.pg_inherits i \
                 JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
                 JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
                 JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
                 WHERE pn.nspname = '{schema}' AND parent.relname = '{parent}' \
             ), inh(root, relid) AS ( \
                 SELECT oid, oid FROM kin \
                 UNION \
                 SELECT t.root, i.inhrelid \
                 FROM pg_catalog.pg_inherits i \
                 JOIN inh t ON i.inhparent = t.relid \
             ), inh_tree AS ( \
                 SELECT t.root, \
                        count(*) FILTER (WHERE t.relid <> t.root)::bigint as desc_count, \
                        SUM(CASE WHEN ic.reltuples >= 0 THEN ic.reltuples::bigint \
                                 ELSE COALESCE(ist.n_live_tup, 0) END)::bigint as sum_tuples, \
                        SUM(CASE WHEN ic.relkind IN ('r', 'm') \
                                 THEN pg_total_relation_size(ic.oid) \
                                 ELSE 0 END)::bigint as sum_bytes \
                 FROM inh t \
                 JOIN pg_catalog.pg_class ic ON ic.oid = t.relid \
                 LEFT JOIN pg_catalog.pg_stat_all_tables ist ON ist.relid = t.relid \
                 GROUP BY t.root \
             ) ",
            schema = escaped_schema,
            parent = escaped_parent
        )
    } else {
        String::new()
    };
    let tree_rows = if inheritance {
        "WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_tuples "
    } else {
        ""
    };
    let tree_size = if inheritance {
        "WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_bytes "
    } else {
        ""
    };
    let parent_test = if inheritance {
        "(c.relkind = 'p' OR COALESCE(st.desc_count, 0) > 0)"
    } else {
        "(c.relkind = 'p')"
    };
    let count_test = if inheritance {
        "c.relkind = 'p' OR COALESCE(st.desc_count, 0) > 0"
    } else {
        "c.relkind = 'p'"
    };
    let tree_join = if inheritance {
        "LEFT JOIN inh_tree st ON st.root = c.oid "
    } else {
        ""
    };

    format!(
        "{prelude}SELECT \
            c.relname as table_name, \
            c.relkind::text as relkind, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(lc.reltuples), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt \
                    JOIN pg_class lc ON lc.oid = pt.relid WHERE pt.isleaf) \
                {tree_rows}\
                WHEN c.reltuples >= 0 THEN c.reltuples::bigint \
                ELSE NULL \
            END as row_estimate, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(pg_total_relation_size(pt.relid)), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt WHERE pt.isleaf) \
                {tree_size}\
                WHEN c.relkind = 'r' THEN pg_total_relation_size(c.oid) \
                ELSE NULL \
            END as total_size_bytes, \
            pg_get_expr(c.relpartbound, c.oid) as part_bound, \
            (c.relkind <> 'p' AND EXISTS ( \
                SELECT 1 FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = c.oid)) as has_child_tables, \
            {parent_test} as is_partitioned, \
            CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text ELSE NULL END as part_strat, \
            CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) ELSE NULL END as part_key, \
            CASE WHEN {count_test} THEN ( \
                SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid)::bigint \
                ELSE NULL END as part_count, \
            cn.nspname as child_schema \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace \
         LEFT JOIN pg_catalog.pg_partitioned_table pt2 ON pt2.partrelid = c.oid \
         {tree_join}\
         WHERE pn.nspname = '{schema}' AND parent.relname = '{parent}' \
         ORDER BY c.relname",
        schema = escaped_schema,
        parent = escaped_parent
    )
}

/// Get the direct child partitions of a partitioned parent table.
pub async fn get_partitions(
    pool: &PgPool,
    schema_name: &str,
    parent_table: &str,
    inheritance: bool,
) -> Result<Vec<TableInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_parent = escape_sql_literal(parent_table);

    let sql = partitions_sql(&escaped_schema, &escaped_parent, inheritance);

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;
    let partitions = rows
        .into_iter()
        .map(|row| {
            let relkind: String = row.get("relkind");
            let is_partitioned: bool = row.try_get("is_partitioned").unwrap_or(false);
            let part_strat: Option<String> = row.try_get("part_strat").ok().flatten();
            let partition_strategy = part_strat
                .as_deref()
                .and_then(|s| s.chars().next())
                .and_then(PartitionStrategy::from_pg_char);
            let table_type = match relkind.as_str() {
                "p" => TableType::PartitionedTable,
                "f" => TableType::ForeignTable,
                _ => TableType::Table,
            };
            TableInfo {
                name: row.get("table_name"),
                schema_name: row.get("child_schema"),
                table_type,
                row_count_estimate: row.try_get("row_estimate").ok().flatten(),
                total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
                is_partitioned,
                is_partition: true,
                partition_strategy,
                partition_key: row.try_get("part_key").ok().flatten(),
                partition_bound: row.try_get("part_bound").ok().flatten(),
                partition_count: row.try_get("part_count").ok().flatten(),
                partition_mechanism: if !is_partitioned {
                    None
                } else if relkind == "p" {
                    Some(PartitionMechanism::Declarative)
                } else {
                    Some(PartitionMechanism::Inheritance)
                },
                has_child_tables: row.try_get("has_child_tables").unwrap_or(false),
            }
        })
        .collect();

    Ok(partitions)
}

/// Get a flat parent→child name map for all partitioned parents in a schema.
/// Used to populate the sidebar filter index without loading full partition detail.
pub async fn get_partition_map(
    pool: &PgPool,
    schema_name: &str,
    inheritance: bool,
) -> Result<Vec<PartitionRef>, sqlx::Error> {
    let escaped = escape_sql_literal(schema_name);
    // The index is what lets the sidebar filter find a name that is hidden
    // inside a collapsed folder, so it must cover exactly the parents that
    // HAVE a folder. Indexing an inheritance child while the setting is off
    // would point a match at a row with nothing to open.
    let declarative_only = if inheritance { "" } else { " AND parent.relkind = 'p'" };
    let sql = format!(
        "SELECT parent.relname as parent_name, c.relname as name \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         WHERE pn.nspname = '{escaped}'{declarative_only}"
    );
    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;
    let refs = rows
        .into_iter()
        .map(|row| PartitionRef {
            parent_name: row.get("parent_name"),
            name: row.get("name"),
        })
        .collect();
    Ok(refs)
}

/// Get all columns for a table
pub async fn get_columns(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<ColumnInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    // Try the full query with PK detection first
    let full_sql = format!(
        "SELECT \
            c.column_name, \
            c.data_type, \
            c.is_nullable, \
            c.ordinal_position, \
            c.column_default, \
            CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key \
         FROM information_schema.columns c \
         LEFT JOIN ( \
            SELECT kcu.column_name \
            FROM information_schema.table_constraints tc \
            JOIN information_schema.key_column_usage kcu \
                ON tc.constraint_name = kcu.constraint_name \
                AND tc.table_schema = kcu.table_schema \
            WHERE tc.constraint_type = 'PRIMARY KEY' \
                AND tc.table_schema = '{}' \
                AND tc.table_name = '{}' \
         ) pk ON c.column_name = pk.column_name \
         WHERE c.table_schema = '{}' \
           AND c.table_name = '{}' \
         ORDER BY c.ordinal_position",
        escaped_schema, escaped_table, escaped_schema, escaped_table
    );

    if let Ok(rows) = sqlx::raw_sql(&full_sql).fetch_all(pool).await {
        let columns: Vec<ColumnInfo> = rows
            .into_iter()
            .filter_map(|row| {
                let is_pk_str = raw_str(&row, "is_primary_key").unwrap_or_default();
                Some(ColumnInfo {
                    name: raw_str(&row, "column_name")?,
                    data_type: raw_str(&row, "data_type").unwrap_or_default(),
                    is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                    is_primary_key: matches!(is_pk_str.as_str(), "t" | "true" | "1"),
                    ordinal_position: raw_str(&row, "ordinal_position")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                    column_default: raw_str(&row, "column_default"),
                })
            })
            .collect();
        if !columns.is_empty() {
            return Ok(columns);
        }
    }

    // Fallback: simpler query without PK detection
    let fallback_sql = format!(
        "SELECT \
            column_name, \
            data_type, \
            is_nullable, \
            ordinal_position, \
            column_default \
         FROM information_schema.columns \
         WHERE table_schema = '{}' \
           AND table_name = '{}' \
         ORDER BY ordinal_position",
        escaped_schema, escaped_table
    );

    let rows = sqlx::raw_sql(&fallback_sql).fetch_all(pool).await?;

    let columns = rows
        .into_iter()
        .filter_map(|row| {
            Some(ColumnInfo {
                name: raw_str(&row, "column_name")?,
                data_type: raw_str(&row, "data_type").unwrap_or_default(),
                is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                is_primary_key: false,
                ordinal_position: raw_str(&row, "ordinal_position")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
                column_default: raw_str(&row, "column_default"),
            })
        })
        .collect();

    Ok(columns)
}

/// Get all columns for all tables in a schema (batch query).
/// Returns columns grouped by table name via the table_name field on each row.
pub async fn get_schema_columns(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<SchemaColumnInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);

    // Try the full query with PK detection first
    let full_sql = format!(
        "SELECT \
            c.table_name, \
            c.column_name, \
            c.data_type, \
            c.is_nullable, \
            c.ordinal_position, \
            c.column_default, \
            CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key \
         FROM information_schema.columns c \
         LEFT JOIN ( \
            SELECT kcu.table_name, kcu.column_name \
            FROM information_schema.table_constraints tc \
            JOIN information_schema.key_column_usage kcu \
                ON tc.constraint_name = kcu.constraint_name \
                AND tc.table_schema = kcu.table_schema \
            WHERE tc.constraint_type = 'PRIMARY KEY' \
                AND tc.table_schema = '{}' \
         ) pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name \
         WHERE c.table_schema = '{}' \
         ORDER BY c.table_name, c.ordinal_position",
        escaped_schema, escaped_schema
    );

    if let Ok(rows) = sqlx::raw_sql(&full_sql).fetch_all(pool).await {
        let columns: Vec<SchemaColumnInfo> = rows
            .into_iter()
            .filter_map(|row| {
                let is_pk_str = raw_str(&row, "is_primary_key").unwrap_or_default();
                Some(SchemaColumnInfo {
                    table_name: raw_str(&row, "table_name")?,
                    name: raw_str(&row, "column_name")?,
                    data_type: raw_str(&row, "data_type").unwrap_or_default(),
                    is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                    is_primary_key: matches!(is_pk_str.as_str(), "t" | "true" | "1"),
                    ordinal_position: raw_str(&row, "ordinal_position")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                    column_default: raw_str(&row, "column_default"),
                })
            })
            .collect();
        if !columns.is_empty() {
            return Ok(columns);
        }
    }

    // Fallback: simpler query without PK detection
    let fallback_sql = format!(
        "SELECT \
            table_name, \
            column_name, \
            data_type, \
            is_nullable, \
            ordinal_position, \
            column_default \
         FROM information_schema.columns \
         WHERE table_schema = '{}' \
         ORDER BY table_name, ordinal_position",
        escaped_schema
    );

    let rows = sqlx::raw_sql(&fallback_sql).fetch_all(pool).await?;

    let columns = rows
        .into_iter()
        .filter_map(|row| {
            Some(SchemaColumnInfo {
                table_name: raw_str(&row, "table_name")?,
                name: raw_str(&row, "column_name")?,
                data_type: raw_str(&row, "data_type").unwrap_or_default(),
                is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                is_primary_key: false,
                ordinal_position: raw_str(&row, "ordinal_position")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
                column_default: raw_str(&row, "column_default"),
            })
        })
        .collect();

    Ok(columns)
}

/// Get indexes for a table
pub async fn get_table_indexes(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<IndexInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    let sql = format!(
        "SELECT \
            i.relname AS index_name, \
            am.amname AS index_type, \
            ix.indisunique AS is_unique, \
            ix.indisprimary AS is_primary, \
            pg_relation_size(i.oid) AS size_bytes, \
            ARRAY( \
                SELECT a.attname \
                FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) \
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum \
                ORDER BY k.ord \
            ) AS columns \
         FROM pg_index ix \
         JOIN pg_class t ON t.oid = ix.indrelid \
         JOIN pg_class i ON i.oid = ix.indexrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         JOIN pg_am am ON am.oid = i.relam \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
         ORDER BY ix.indisprimary DESC, i.relname",
        escaped_schema, escaped_table
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;

    let indexes = rows
        .into_iter()
        .map(|row| IndexInfo {
            name: row.get("index_name"),
            columns: row.get("columns"),
            is_unique: row.get("is_unique"),
            is_primary: row.get("is_primary"),
            index_type: row.get("index_type"),
            size_bytes: row.try_get("size_bytes").ok(),
        })
        .collect();

    Ok(indexes)
}

/// Get constraints for a table
pub async fn get_table_constraints(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<ConstraintInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    let sql = format!(
        "SELECT \
            con.conname AS constraint_name, \
            CASE con.contype \
                WHEN 'p' THEN 'PRIMARY KEY' \
                WHEN 'f' THEN 'FOREIGN KEY' \
                WHEN 'u' THEN 'UNIQUE' \
                WHEN 'c' THEN 'CHECK' \
                WHEN 'x' THEN 'EXCLUSION' \
                ELSE 'OTHER' \
            END AS constraint_type, \
            ARRAY( \
                SELECT a.attname \
                FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) \
                JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum \
                ORDER BY k.ord \
            ) AS columns, \
            CASE WHEN con.contype = 'f' THEN \
                (SELECT n2.nspname || '.' || c2.relname \
                 FROM pg_class c2 \
                 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace \
                 WHERE c2.oid = con.confrelid) \
            ELSE NULL END AS referenced_table, \
            CASE WHEN con.contype = 'f' THEN \
                ARRAY( \
                    SELECT a.attname \
                    FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord) \
                    JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum \
                    ORDER BY k.ord \
                ) \
            ELSE NULL END AS referenced_columns, \
            CASE WHEN con.contype = 'c' THEN \
                pg_get_constraintdef(con.oid) \
            ELSE NULL END AS check_clause \
         FROM pg_constraint con \
         JOIN pg_class t ON t.oid = con.conrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
         ORDER BY \
            CASE con.contype \
                WHEN 'p' THEN 1 \
                WHEN 'u' THEN 2 \
                WHEN 'f' THEN 3 \
                WHEN 'c' THEN 4 \
                ELSE 5 \
            END, \
            con.conname",
        escaped_schema, escaped_table
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;

    let constraints = rows
        .into_iter()
        .map(|row| ConstraintInfo {
            name: row.get("constraint_name"),
            constraint_type: row.get("constraint_type"),
            columns: row.get("columns"),
            referenced_table: row.try_get("referenced_table").ok().flatten(),
            referenced_columns: row.try_get("referenced_columns").ok().flatten(),
            check_clause: row.try_get("check_clause").ok().flatten(),
        })
        .collect();

    Ok(constraints)
}

/// Read the raw parts (columns, constraints, non-constraint indexes) needed to
/// reconstruct a table's CREATE TABLE DDL.
pub async fn get_table_ddl_parts(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<TableDdlParts, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    // Columns — precise types via format_type, defaults via pg_get_expr,
    // identity/generated via attidentity/attgenerated (cast ::text).
    let col_sql = format!(
        "SELECT \
            a.attname AS name, \
            pg_catalog.format_type(a.atttypid, a.atttypmod) AS type, \
            a.attnotnull AS not_null, \
            pg_get_expr(ad.adbin, ad.adrelid) AS default_expr, \
            a.attidentity::text AS identity, \
            a.attgenerated::text AS generated \
         FROM pg_attribute a \
         JOIN pg_class t ON t.oid = a.attrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
           AND a.attnum > 0 AND NOT a.attisdropped \
         ORDER BY a.attnum",
        escaped_schema, escaped_table
    );
    let col_rows = sqlx::raw_sql(&col_sql).fetch_all(pool).await?;
    let columns: Vec<DdlColumn> = col_rows
        .into_iter()
        .filter_map(|row| {
            Some(DdlColumn {
                name: raw_str(&row, "name")?,
                type_str: raw_str(&row, "type").unwrap_or_default(),
                not_null: raw_str(&row, "not_null").as_deref() == Some("t"),
                default_expr: raw_str(&row, "default_expr"),
                identity: raw_str(&row, "identity").unwrap_or_default(),
                generated: raw_str(&row, "generated").unwrap_or_default(),
            })
        })
        .collect();

    // Constraints — full definitions via pg_get_constraintdef, ordered PK, UNIQUE, CHECK, FK.
    // EXCLUDE ('x') constraints are out of scope for reconstructed DDL.
    let con_sql = format!(
        "SELECT con.conname AS name, pg_get_constraintdef(con.oid) AS def \
         FROM pg_constraint con \
         JOIN pg_class t ON t.oid = con.conrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
           AND con.contype IN ('p', 'u', 'c', 'f') \
         ORDER BY CASE con.contype \
             WHEN 'p' THEN 1 WHEN 'u' THEN 2 WHEN 'c' THEN 3 WHEN 'f' THEN 4 ELSE 5 END, \
           con.conname",
        escaped_schema, escaped_table
    );
    let con_rows = sqlx::raw_sql(&con_sql).fetch_all(pool).await?;
    let constraints: Vec<DdlConstraint> = con_rows
        .into_iter()
        .filter_map(|row| {
            Some(DdlConstraint {
                name: raw_str(&row, "name")?,
                definition: raw_str(&row, "def").unwrap_or_default(),
            })
        })
        .collect();

    // Non-constraint indexes only — exclude the PK index and any index backing a
    // constraint (those are already emitted as constraints).
    let idx_sql = format!(
        "SELECT pg_get_indexdef(ix.indexrelid) AS def \
         FROM pg_index ix \
         JOIN pg_class i ON i.oid = ix.indexrelid \
         JOIN pg_class t ON t.oid = ix.indrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
           AND NOT ix.indisprimary \
           AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = ix.indexrelid) \
         ORDER BY i.relname",
        escaped_schema, escaped_table
    );
    let idx_rows = sqlx::raw_sql(&idx_sql).fetch_all(pool).await?;
    let index_defs: Vec<String> = idx_rows
        .into_iter()
        .filter_map(|row| raw_str(&row, "def"))
        .collect();

    // Partition clause (NULL for non-partitioned tables).
    let part_sql = format!(
        "SELECT pg_get_partkeydef(t.oid) AS def \
         FROM pg_class t \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}'",
        escaped_schema, escaped_table
    );
    let part_rows = sqlx::raw_sql(&part_sql).fetch_all(pool).await?;
    let partition_by: Option<String> = part_rows.into_iter().next().and_then(|row| raw_str(&row, "def"));

    // The tables this one INHERITS from, in the order PostgreSQL merges
    // their columns. Legacy partitioning is built out of these, and without
    // the clause the DDL of a child reads as an unrelated standalone table.
    let inherits_sql = format!(
        "SELECT pn.nspname AS parent_schema, p.relname AS parent_name \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         JOIN pg_catalog.pg_class p ON p.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace \
         WHERE n.nspname = '{}' AND c.relname = '{}' AND c.relispartition = false \
         ORDER BY i.inhseqno",
        escaped_schema, escaped_table
    );
    let inherits_rows = sqlx::raw_sql(&inherits_sql).fetch_all(pool).await?;
    let inherits: Vec<(String, String)> = inherits_rows
        .into_iter()
        .filter_map(|row| {
            Some((raw_str(&row, "parent_schema")?, raw_str(&row, "parent_name")?))
        })
        .collect();

    Ok(TableDdlParts {
        columns,
        constraints,
        index_defs,
        partition_by,
        inherits,
    })
}

/// Get functions and procedures in a schema
pub async fn get_schema_functions(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<FunctionInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);

    let sql = format!(
        "SELECT \
            p.proname AS func_name, \
            n.nspname AS schema_name, \
            pg_catalog.format_type(p.prorettype, NULL) AS return_type, \
            pg_catalog.pg_get_function_arguments(p.oid) AS argument_types, \
            CASE p.prokind \
                WHEN 'f' THEN 'function' \
                WHEN 'p' THEN 'procedure' \
                WHEN 'a' THEN 'aggregate' \
                WHEN 'w' THEN 'window' \
                ELSE 'function' \
            END AS function_type, \
            l.lanname AS language \
         FROM pg_catalog.pg_proc p \
         JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace \
         JOIN pg_catalog.pg_language l ON l.oid = p.prolang \
         WHERE n.nspname = '{}' AND p.prokind IN ('f', 'p') \
         ORDER BY p.proname",
        escaped_schema
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;

    let functions = rows
        .into_iter()
        .map(|row| FunctionInfo {
            name: row.get("func_name"),
            schema_name: row.get("schema_name"),
            return_type: row.get("return_type"),
            argument_types: row.get("argument_types"),
            function_type: row.get("function_type"),
            language: row.get("language"),
        })
        .collect();

    Ok(functions)
}

/// Fetch the display name and the key indexes of each table OID.
///
/// The OIDs are formatted into the SQL, not bound. `raw_sql` (the simple query
/// protocol this codebase uses for metadata) accepts no bind parameter. The
/// OIDs arrive from the server as `u32`, so a formatted integer list is safe;
/// they never pass through a string escape.
pub async fn get_table_key_info(
    pool: &PgPool,
    oids: &[u32],
) -> Result<HashMap<u32, TableKeyInfo>, sqlx::Error> {
    if oids.is_empty() {
        return Ok(HashMap::new());
    }
    let oid_list = oids
        .iter()
        .map(|o| o.to_string())
        .collect::<Vec<_>>()
        .join(", ");

    // 1. Display names. A table with no row here was dropped between the query
    //    and this lookup; it simply gets no entry.
    //    This query MUST run before query 2: query 2 only fills candidates into
    //    entries this loop created. That is safe rather than merely lucky — a
    //    table absent from pg_class has no pg_index rows either — but the order
    //    is a real dependency, so do not reorder the two.
    let name_sql = format!(
        "SELECT c.oid AS oid, n.nspname || '.' || c.relname AS display \
         FROM pg_class c \
         JOIN pg_namespace n ON n.oid = c.relnamespace \
         WHERE c.oid IN ({})",
        oid_list
    );
    let mut out: HashMap<u32, TableKeyInfo> = HashMap::new();
    let name_rows = sqlx::raw_sql(&name_sql).fetch_all(pool).await?;
    for row in name_rows {
        let oid: Oid = row.try_get("oid")?;
        let display: String = row.try_get("display")?;
        out.insert(oid.0, TableKeyInfo { display, candidates: Vec::new() });
    }

    // 2. Key indexes.
    //    - `k.ord <= ix.indnkeyatts` drops INCLUDE columns: PostgreSQL 11 and
    //      later put them into indkey AFTER the key columns.
    //    - `indisvalid` drops a failed CREATE INDEX CONCURRENTLY, which is not
    //      unique in fact. `indimmediate` drops a DEFERRABLE INITIALLY
    //      DEFERRED constraint, which permits duplicate rows inside a
    //      transaction. It does NOT drop DEFERRABLE INITIALLY IMMEDIATE, which
    //      SET CONSTRAINTS can still defer; accepted, because we read
    //      committed data.
    //    - `indexprs IS NULL` is load-bearing for a MIXED index, NOT for a pure
    //      expression index. Do not remove it. The full reasoning lives in the
    //      failure message of `live_key_info_tests`, which is what you will be
    //      reading if you break it.
    //    - `unnest(...) WITH ORDINALITY` keeps the key column order, the same
    //      idiom `get_table_indexes` uses above.
    let index_sql = format!(
        "SELECT ix.indrelid AS table_oid, \
                ix.indisprimary AS is_primary, \
                bool_and(a.attnotnull) AS all_not_null, \
                array_agg(k.attnum ORDER BY k.ord) AS key_attnums \
         FROM pg_index ix \
         CROSS JOIN unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) \
         JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum \
         WHERE ix.indrelid IN ({}) \
           AND k.ord <= ix.indnkeyatts \
           AND (ix.indisprimary OR ix.indisunique) \
           AND ix.indisvalid AND ix.indimmediate \
           AND ix.indpred IS NULL AND ix.indexprs IS NULL \
         GROUP BY ix.indrelid, ix.indexrelid, ix.indisprimary \
         ORDER BY ix.indrelid, ix.indisprimary DESC, key_attnums",
        oid_list
    );
    let index_rows = sqlx::raw_sql(&index_sql).fetch_all(pool).await?;
    for row in index_rows {
        // Every value decodes with `?`. A decode fault must surface as an
        // error, never as a plausible-looking key: a SHORT attnum list is not a
        // missing key but a WRONG one, claiming fewer columns are unique than
        // really are. `false` for all_not_null is just as harmful, because
        // `choose_candidates` filters on it and would demote a good key to the
        // weakest identity tier with nothing reported.
        let oid: Oid = row.try_get("table_oid")?;
        let is_primary: bool = row.try_get("is_primary")?;
        let all_not_null: bool = row.try_get("all_not_null")?;
        let column_attnums: Vec<i16> = row.try_get("key_attnums")?;

        if column_attnums.is_empty() {
            continue;
        }
        if let Some(info) = out.get_mut(&oid.0) {
            info.candidates.push(KeyCandidate { column_attnums, is_primary, all_not_null });
        }
    }

    Ok(out)
}

/// The `sslmode=prefer` fallback decision, offline.
#[cfg(test)]
mod ssl_fallback_tests {
    use super::{
        build_connection_string, should_retry_without_tls, Duration, PoolTuning, CONNECT_BUDGET,
        PREFER_PROBE_BUDGET,
    };
    use crate::models::{ConnectionConfig, SslMode};

    fn config(ssl_mode: SslMode) -> ConnectionConfig {
        ConnectionConfig {
            id: "c1".to_string(),
            name: "local".to_string(),
            host: "localhost".to_string(),
            port: 5432,
            database: "nfinn".to_string(),
            username: "nfinn".to_string(),
            password: String::new(),
            ssl_mode,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    fn timed_out() -> sqlx::Error {
        sqlx::Error::PoolTimedOut
    }

    /// An `Io` error the POOL passes straight through. `ConnectionRefused`
    /// would be the obvious fixture and is the wrong one: the pool swallows
    /// that kind, retries it to the deadline and reports `PoolTimedOut`, so a
    /// test built on it could never tell the two rules apart.
    fn unreachable() -> sqlx::Error {
        sqlx::Error::Io(std::io::Error::new(
            std::io::ErrorKind::HostUnreachable,
            "No route to host (os error 65)",
        ))
    }

    // The stall this fallback exists for: an established socket, no backend,
    // and the pool giving up at its acquire deadline.
    #[test]
    fn prefer_retries_when_the_pool_times_out() {
        assert!(should_retry_without_tls(SslMode::Prefer, &timed_out()));
    }

    #[test]
    fn prefer_retries_on_a_tls_error() {
        assert!(should_retry_without_tls(
            SslMode::Prefer,
            &sqlx::Error::Tls("handshake failed".into())
        ));
    }

    #[test]
    fn prefer_retries_on_a_protocol_error_that_names_ssl() {
        assert!(should_retry_without_tls(
            SslMode::Prefer,
            &sqlx::Error::Protocol("unexpected response to SSLRequest".to_string())
        ));
    }

    // The rule is "a TLS problem", not "any protocol problem" — a mismatched
    // wire protocol must fail as itself rather than being retried in plaintext.
    #[test]
    fn prefer_does_not_retry_on_an_unrelated_protocol_error() {
        assert!(!should_retry_without_tls(
            SslMode::Prefer,
            &sqlx::Error::Protocol("unexpected message: b'Z'".to_string())
        ));
    }

    // An unreachable host is not a TLS problem, and the pool hands this one
    // back at once. The rule must key on the KIND of failure, not on "the
    // first attempt did not work", or every dead host would be retried.
    #[test]
    fn prefer_does_not_retry_an_unreachable_host() {
        assert!(!should_retry_without_tls(SslMode::Prefer, &unreachable()));
    }

    // Require means require. The SAME error that makes Prefer retry must not
    // move Require or Disable, or the app would silently downgrade a
    // connection the user asked to be encrypted.
    #[test]
    fn require_never_falls_back() {
        assert!(!should_retry_without_tls(SslMode::Require, &timed_out()));
        assert!(!should_retry_without_tls(
            SslMode::Require,
            &sqlx::Error::Tls("handshake failed".into())
        ));
    }

    #[test]
    fn disable_never_falls_back() {
        assert!(!should_retry_without_tls(SslMode::Disable, &timed_out()));
    }

    // The fallback is issued with Disable even though the config still says
    // Prefer; if the mode were read from the config the retry would repeat the
    // attempt that just hung.
    #[test]
    fn the_fallback_url_asks_for_no_tls() {
        let cfg = config(SslMode::Prefer);
        assert!(build_connection_string(&cfg, cfg.ssl_mode).ends_with("sslmode=prefer"));
        assert!(build_connection_string(&cfg, SslMode::Disable).ends_with("sslmode=disable"));
    }

    // `connect_timeout - probe` is a Duration subtraction, which PANICS on
    // underflow. Shrinking the total below the probe would take the app down
    // on every fallback.
    #[test]
    fn the_retry_keeps_a_share_of_the_budget() {
        let tuning = PoolTuning::default();
        assert!(
            tuning.prefer_probe_budget() < tuning.connect_timeout,
            "the probe must leave time for the plaintext retry"
        );
        assert!((tuning.connect_timeout - tuning.prefer_probe_budget()).as_secs() >= 2);
    }

    /// The share rule reproduces the two constants it replaced: 6 seconds of
    /// 10. Without this, "three fifths" is a number nobody checked.
    #[test]
    fn the_probe_share_is_the_old_six_of_ten() {
        let tuning = PoolTuning::default();
        assert_eq!(tuning.connect_timeout, CONNECT_BUDGET);
        assert_eq!(tuning.prefer_probe_budget(), PREFER_PROBE_BUDGET);
    }

    /// The share never underflows, whatever the user sets the budget to. A
    /// one-second budget is the smallest the Settings stepper allows.
    #[test]
    fn the_share_never_underflows_at_any_budget() {
        for seconds in 1..=120u64 {
            let tuning = PoolTuning {
                connect_timeout: Duration::from_secs(seconds),
                ..PoolTuning::default()
            };
            assert!(
                tuning.prefer_probe_budget() <= tuning.connect_timeout,
                "budget {seconds}s: the probe must not exceed the whole budget"
            );
        }
    }
}

/// The Connections settings, turned into the two structs a connect needs
/// (plan §2.8). Pure: no server, no pool.
#[cfg(test)]
mod connection_settings_tests {
    use super::*;
    use crate::models::{ConnectionSettings, SshTunnelConfig};

    fn config() -> ConnectionConfig {
        ConnectionConfig {
            id: "c1".to_string(),
            name: "c1".to_string(),
            host: "db".to_string(),
            port: 5432,
            database: "nbt".to_string(),
            username: "app".to_string(),
            password: String::new(),
            ssl_mode: SslMode::Prefer,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None::<SshTunnelConfig>,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    /// The whole point of the defaults: at `ConnectionSettings::default()` the
    /// pool is tuned EXACTLY as `pool_options` and `CONNECT_BUDGET` tuned it
    /// before the settings existed, so an existing user sees no change.
    #[test]
    fn pool_tuning_defaults_match_todays_literals() {
        let from_settings = PoolTuning::from(&ConnectionSettings::default());
        assert_eq!(from_settings, PoolTuning::default());
        assert_eq!(from_settings.max_connections, 5, "create_pool's literal 5");
        assert_eq!(from_settings.connect_timeout, Duration::from_secs(10), "CONNECT_BUDGET");
        assert_eq!(from_settings.idle_timeout, Duration::from_secs(600), "pool_options");
        assert_eq!(from_settings.max_lifetime, Duration::from_secs(1800), "pool_options");
    }

    #[test]
    fn pool_tuning_follows_the_settings() {
        let settings = ConnectionSettings {
            max_connections: 12,
            connect_timeout_seconds: 25,
            idle_timeout_seconds: 60,
            max_lifetime_seconds: 120,
            ..Default::default()
        };
        let tuning = PoolTuning::from(&settings);
        assert_eq!(tuning.max_connections, 12);
        assert_eq!(tuning.connect_timeout, Duration::from_secs(25));
        assert_eq!(tuning.idle_timeout, Duration::from_secs(60));
        assert_eq!(tuning.max_lifetime, Duration::from_secs(120));
    }

    /// A pool of zero could never hand out a connection, and a zero budget
    /// would fail every connect at once. Both take the floor rather than the
    /// user's number.
    #[test]
    fn zero_max_connections_and_zero_budget_take_a_floor() {
        let settings = ConnectionSettings {
            max_connections: 0,
            connect_timeout_seconds: 0,
            ..Default::default()
        };
        let tuning = PoolTuning::from(&settings);
        assert_eq!(tuning.max_connections, 1);
        assert_eq!(tuning.connect_timeout, CONNECT_BUDGET);
    }

    /// The default session asks the server for the one thing the app already
    /// asked for — the 30-second idle-in-transaction guard — and for nothing
    /// else, except the application name, which is new and which no server
    /// can refuse.
    #[test]
    fn the_default_session_is_todays_behaviour() {
        let session = SessionOptions::from_settings(&ConnectionSettings::default(), &config());
        assert!(!session.read_only);
        assert_eq!(session.time_zone, None, "the server's own time zone");
        assert_eq!(session.idle_in_transaction_ms, 30_000, "the old SET '30s'");
        assert_eq!(session.keepalive, None, "the server's own keepalives");
        assert_eq!(session.ssl_root_cert, None);
        assert_eq!(
            session.application_name.as_deref(),
            Some(concat!("Pharos ", env!("CARGO_PKG_VERSION")))
        );
        assert_eq!(
            startup_gucs(&session),
            vec![("idle_in_transaction_session_timeout", "30000".to_string())],
            "nothing but the guard travels in the startup packet by default"
        );
    }

    #[test]
    fn zero_idle_in_transaction_seconds_turns_the_guard_off() {
        let settings = ConnectionSettings { idle_in_transaction_seconds: 0, ..Default::default() };
        let session = SessionOptions::from_settings(&settings, &config());
        assert_eq!(session.idle_in_transaction_ms, 0);
        assert!(startup_gucs(&session).is_empty(), "0 asks the server for nothing");
    }

    /// The per-connection time zone wins; with none, the app-wide one; with
    /// neither, the server's own. A blank string is not a value.
    #[test]
    fn the_connection_time_zone_overrides_the_app_wide_one() {
        let settings = ConnectionSettings {
            default_time_zone: "Europe/London".to_string(),
            ..Default::default()
        };
        let mut c = config();
        assert_eq!(
            SessionOptions::from_settings(&settings, &c).time_zone.as_deref(),
            Some("Europe/London")
        );

        c.session_time_zone = Some("Asia/Tokyo".to_string());
        assert_eq!(
            SessionOptions::from_settings(&settings, &c).time_zone.as_deref(),
            Some("Asia/Tokyo")
        );

        c.session_time_zone = Some("   ".to_string());
        assert_eq!(
            SessionOptions::from_settings(&settings, &c).time_zone.as_deref(),
            Some("Europe/London"),
            "a blank per-connection zone falls back rather than blanking the app's"
        );

        let bare = ConnectionSettings { default_time_zone: " ".to_string(), ..Default::default() };
        c.session_time_zone = None;
        assert_eq!(SessionOptions::from_settings(&bare, &c).time_zone, None);
    }

    /// Any one of the three keepalive numbers asks the server for keepalives;
    /// all three at zero leaves the server's own, which is the default.
    #[test]
    fn keepalives_are_asked_for_when_any_one_is_set() {
        let off = ConnectionSettings::default();
        assert_eq!(SessionOptions::from_settings(&off, &config()).keepalive, None);

        let on = ConnectionSettings {
            keepalive_idle_seconds: 60,
            keepalive_interval_seconds: 10,
            keepalive_count: 6,
            ..Default::default()
        };
        let session = SessionOptions::from_settings(&on, &config());
        assert_eq!(session.keepalive, Some((60, 10, 6)));

        let partial = ConnectionSettings { keepalive_idle_seconds: 60, ..Default::default() };
        assert_eq!(
            SessionOptions::from_settings(&partial, &config()).keepalive,
            Some((60, 0, 0)),
            "a zero among them is PostgreSQL's own default, sent as written"
        );
    }

    #[test]
    fn read_only_and_the_root_certificate_come_from_the_connection() {
        let mut c = config();
        c.read_only = true;
        c.ssl_root_cert_path = Some("/etc/ssl/root.crt".to_string());
        let session = SessionOptions::from_settings(&ConnectionSettings::default(), &c);
        assert!(session.read_only);
        assert_eq!(session.ssl_root_cert.as_deref(), Some("/etc/ssl/root.crt"));
        assert!(
            startup_gucs(&session).contains(&("default_transaction_read_only", "on".to_string())),
            "read-only must travel in the startup packet"
        );

        c.ssl_root_cert_path = Some("  ".to_string());
        assert_eq!(
            SessionOptions::from_settings(&ConnectionSettings::default(), &c).ssl_root_cert,
            None,
            "a blank path is no path"
        );
    }

    /// An empty `applicationName` means `Pharos <version>`; a typed one is
    /// sent trimmed, and one typed as spaces is the same as empty.
    #[test]
    fn the_application_name_falls_back_to_pharos_and_the_version() {
        assert_eq!(
            ConnectionSettings::default().effective_application_name(),
            concat!("Pharos ", env!("CARGO_PKG_VERSION"))
        );
        let typed = ConnectionSettings {
            application_name: "  Pharos (staging)  ".to_string(),
            ..Default::default()
        };
        assert_eq!(typed.effective_application_name(), "Pharos (staging)");
        let blank = ConnectionSettings { application_name: "   ".to_string(), ..Default::default() };
        assert_eq!(
            blank.effective_application_name(),
            concat!("Pharos ", env!("CARGO_PKG_VERSION"))
        );
    }

    /// The application name is NOT a startup GUC — sqlx sets it as a
    /// parameter of its own — so it must never appear in the `-c` options.
    /// Putting it there would send `-c application_name=Pharos\ 0.1.0` as well
    /// as the parameter.
    #[test]
    fn the_application_name_is_not_a_startup_guc() {
        let session = SessionOptions::from_settings(&ConnectionSettings::default(), &config());
        assert!(
            !startup_gucs(&session)
                .iter()
                .any(|(name, _)| *name == "application_name"),
            "application_name has its own setter in sqlx"
        );
    }

    /// The two verifying modes render as the hyphenated names libpq parses.
    /// `rename_all = "lowercase"` alone would give `verifyca`, which sqlx
    /// rejects as an unknown sslmode.
    #[test]
    fn the_verifying_ssl_modes_render_the_way_libpq_reads_them() {
        let mut c = config();
        c.ssl_mode = SslMode::VerifyCa;
        assert!(build_connection_string(&c, c.ssl_mode).ends_with("sslmode=verify-ca"));
        c.ssl_mode = SslMode::VerifyFull;
        assert!(build_connection_string(&c, c.ssl_mode).ends_with("sslmode=verify-full"));
    }

    /// A verifying mode never falls back to plaintext. Only `prefer` does,
    /// and that is unchanged.
    #[test]
    fn a_verifying_mode_never_retries_without_tls() {
        for mode in [SslMode::VerifyCa, SslMode::VerifyFull, SslMode::Require] {
            assert!(
                !should_retry_without_tls(mode, &sqlx::Error::PoolTimedOut),
                "{mode} must not fall back to plaintext"
            );
        }
        assert!(should_retry_without_tls(SslMode::Prefer, &sqlx::Error::PoolTimedOut));
    }
}

/// Opt-in live tests of the session-options primitive (plan §5.1). `cargo
/// test` skips them; run them against a real server with
///
///   cargo test --release live_session -- --ignored --nocapture
///
/// They exist because the thing being claimed — that a startup GUC reaches
/// EVERY connection of the pool, where the old per-query `SET` reached one of
/// five — cannot be observed without a pool and a server.
#[cfg(test)]
mod live_session_options_tests {
    use super::{create_pool_with_session, SessionOptions};
    use crate::models::{ConnectionConfig, SslMode};

    fn env_or(key: &str, fallback: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| fallback.to_string())
    }

    fn live_config() -> ConnectionConfig {
        ConnectionConfig {
            id: "live-session".to_string(),
            name: "live-session".to_string(),
            host: env_or("PHAROS_TEST_PG_HOST", "localhost"),
            port: env_or("PHAROS_TEST_PG_PORT", "5432").parse().unwrap_or(5432),
            database: env_or("PHAROS_TEST_PG_DB", "nfinn"),
            username: env_or("PHAROS_TEST_PG_USER", "nfinn"),
            password: std::env::var("PHAROS_TEST_PG_PASSWORD").unwrap_or_default(),
            ssl_mode: SslMode::Prefer,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    /// The claim that matters: the time zone is on EVERY connection, not on
    /// whichever one a `SET` happened to reach. Three are acquired at once so
    /// the pool cannot hand back the same one three times.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_session_time_zone_reaches_every_pooled_connection() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let session = SessionOptions {
                time_zone: Some("Asia/Tokyo".to_string()),
                ..Default::default()
            };
            let pool = create_pool_with_session(&live_config(), &session)
                .await
                .expect("connect with a time zone");

            let mut held = Vec::new();
            for _ in 0..3 {
                held.push(pool.acquire().await.expect("acquire"));
            }
            for (i, conn) in held.iter_mut().enumerate() {
                let row: (String,) = sqlx::query_as("SHOW TimeZone")
                    .fetch_one(&mut **conn)
                    .await
                    .expect("SHOW TimeZone");
                assert_eq!(row.0, "Asia/Tokyo", "connection {i} did not get the time zone");
            }
            drop(held);
            pool.close().await;
        });
    }

    /// The two halves of the split, measured rather than assumed.
    ///
    /// `IntervalStyle` travels in the STARTUP packet, so it is the session's
    /// reset value and `RESET` returns to it. `TimeZone` is applied by
    /// `after_connect`, so its reset value is still sqlx's `UTC` — the one
    /// property the startup packet has that a `SET` cannot. Nothing in
    /// Pharos issues `RESET ALL` or `DISCARD ALL`, which is why this is a
    /// documented caveat and not a defect.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_reset_behaviour_differs_for_the_two_paths() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let session = SessionOptions {
                time_zone: Some("Asia/Tokyo".to_string()),
                interval_style: Some("iso_8601".to_string()),
                ..Default::default()
            };
            let pool = create_pool_with_session(&live_config(), &session)
                .await
                .expect("connect with a session");
            let mut conn = pool.acquire().await.expect("acquire");

            // The startup GUC: RESET goes back to OUR value.
            let before: (String,) = sqlx::query_as("SHOW IntervalStyle").fetch_one(&mut *conn).await.unwrap();
            assert_eq!(before.0, "iso_8601", "the startup GUC did not take");
            sqlx::raw_sql("SET IntervalStyle = 'postgres'").execute(&mut *conn).await.unwrap();
            sqlx::raw_sql("RESET IntervalStyle").execute(&mut *conn).await.unwrap();
            let after: (String,) = sqlx::query_as("SHOW IntervalStyle").fetch_one(&mut *conn).await.unwrap();
            assert_eq!(after.0, "iso_8601", "RESET must return to the startup value");

            // The after_connect SET: RESET goes back to sqlx's UTC.
            let tz: (String,) = sqlx::query_as("SHOW TimeZone").fetch_one(&mut *conn).await.unwrap();
            assert_eq!(tz.0, "Asia/Tokyo", "the per-connection SET did not take");
            sqlx::raw_sql("RESET TimeZone").execute(&mut *conn).await.unwrap();
            let reset: (String,) = sqlx::query_as("SHOW TimeZone").fetch_one(&mut *conn).await.unwrap();
            assert_eq!(reset.0, "UTC", "documented caveat: TimeZone resets to sqlx's startup value");

            drop(conn);
            pool.close().await;
        });
    }

    /// A read-only pool refuses a write with SQLSTATE 25006, which is the
    /// error the Swift side maps to "This connection is read-only."
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_read_only_refuses_a_write() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let session = SessionOptions { read_only: true, ..Default::default() };
            let pool = create_pool_with_session(&live_config(), &session)
                .await
                .expect("connect read-only");

            let result = sqlx::raw_sql("CREATE TEMP TABLE pharos_ro_probe (x int)")
                .execute(&pool)
                .await;
            let err = result.expect_err("a write must be refused on a read-only connection");
            let code = err
                .as_database_error()
                .and_then(|e| e.code())
                .map(|c| c.to_string())
                .unwrap_or_default();
            assert_eq!(code, "25006", "expected read_only_sql_transaction, got: {err}");
            pool.close().await;
        });
    }

    /// A value the server will not accept fails the CONNECT, with the
    /// server's own message. That is the whole reason these go in the startup
    /// packet: a bad `SET` after the fact can leave a connection unusable and
    /// report nothing.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_a_bad_time_zone_fails_the_connect() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let session = SessionOptions {
                time_zone: Some("Not/AZone".to_string()),
                ..Default::default()
            };
            let result = create_pool_with_session(&live_config(), &session).await;
            assert!(result.is_err(), "an invalid time zone must fail the connect");
        });
    }

    /// The application name the Connections settings ask for is the one
    /// `pg_stat_activity` reports. This is the only way to know: sqlx writes
    /// its own startup parameters, and a name it claimed for itself would be
    /// invisible to every unit test.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_application_name_reaches_pg_stat_activity() {
        use crate::models::ConnectionSettings;
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let settings = ConnectionSettings {
                application_name: "Pharos live probe".to_string(),
                ..Default::default()
            };
            let session = super::SessionOptions::from_settings(&settings, &live_config());
            let pool = create_pool_with_session(&live_config(), &session)
                .await
                .expect("connect with an application name");

            let row: (String,) = sqlx::query_as(
                "SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()",
            )
            .fetch_one(&pool)
            .await
            .expect("read pg_stat_activity");
            assert_eq!(row.0, "Pharos live probe");
            pool.close().await;
        });
    }

    /// The default `application_name` — `Pharos <version>` — also arrives.
    /// A space in it is the interesting part: a value that travelled in the
    /// `options` string would be cut at the space.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_the_default_application_name_survives_its_space() {
        use crate::models::ConnectionSettings;
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let settings = ConnectionSettings::default();
            let session = super::SessionOptions::from_settings(&settings, &live_config());
            let pool = create_pool_with_session(&live_config(), &session)
                .await
                .expect("connect with the default application name");

            let row: (String,) = sqlx::query_as(
                "SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()",
            )
            .fetch_one(&pool)
            .await
            .expect("read pg_stat_activity");
            assert_eq!(row.0, settings.effective_application_name());
            assert!(row.0.contains(' '), "the probe is worthless without a space: {}", row.0);
            pool.close().await;
        });
    }

    /// The quoted `search_path` statement the suffix setting builds is one
    /// the server accepts, and it lands in the order it was written.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_search_path_suffix_is_accepted_by_the_server() {
        use crate::commands::query::search_path_sql;
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = create_pool_with_session(&live_config(), &SessionOptions::default())
                .await
                .expect("connect");
            let mut conn = pool.acquire().await.expect("acquire");

            let sql = search_path_sql("public", "pg_catalog").expect("pure builder");
            sqlx::raw_sql(&sql).execute(&mut *conn).await.expect("the server accepts it");
            let row: (String,) = sqlx::query_as("SHOW search_path").fetch_one(&mut *conn).await.unwrap();
            assert_eq!(row.0, "public, pg_catalog", "got {}", row.0);

            // No suffix means the schema alone.
            let bare = search_path_sql("public", "").expect("pure builder");
            sqlx::raw_sql(&bare).execute(&mut *conn).await.expect("the server accepts it");
            let row: (String,) = sqlx::query_as("SHOW search_path").fetch_one(&mut *conn).await.unwrap();
            assert_eq!(row.0, "public", "got {}", row.0);

            drop(conn);
            pool.close().await;
        });
    }

    /// The pool really is the size the settings asked for: N connections can
    /// be held at once, and they are N different backends.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_pool_tuning_sets_the_connection_ceiling() {
        use crate::models::ConnectionSettings;
        use std::collections::HashSet;
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let settings = ConnectionSettings { max_connections: 3, ..Default::default() };
            let tuning = super::PoolTuning::from(&settings);
            assert_eq!(tuning.max_connections, 3);
            let pool = super::create_pool_with(&live_config(), &SessionOptions::default(), &tuning)
                .await
                .expect("connect with a tuned pool");

            let mut held = Vec::new();
            let mut pids = HashSet::new();
            for _ in 0..3 {
                let mut conn = pool.acquire().await.expect("acquire");
                let row: (i32,) = sqlx::query_as("SELECT pg_backend_pid()")
                    .fetch_one(&mut *conn)
                    .await
                    .expect("pid");
                pids.insert(row.0);
                held.push(conn);
            }
            assert_eq!(pids.len(), 3, "three held connections must be three backends");
            drop(held);
            pool.close().await;
        });
    }

    /// The whole read-only chain, end to end: a connection marked read-only
    /// gets SQLSTATE 25006, the core tags it, and the Swift side's marker is
    /// in the text that crosses the FFI.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_a_read_only_connection_tags_its_refusal_for_the_front_end() {
        use crate::commands::query::{format_db_error, READ_ONLY_MARKER};
        use crate::models::ConnectionSettings;
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let mut config = live_config();
            config.read_only = true;
            let session =
                super::SessionOptions::from_settings(&ConnectionSettings::default(), &config);
            assert!(session.read_only, "the connection's flag must reach the session");

            let pool = create_pool_with_session(&config, &session)
                .await
                .expect("connect read-only");
            let err = sqlx::raw_sql("CREATE TEMP TABLE pharos_ro_chain (x int)")
                .execute(&pool)
                .await
                .expect_err("a write must be refused");

            let message = format_db_error(&err);
            assert!(
                message.starts_with(READ_ONLY_MARKER),
                "the front end reads this marker; got: {message}"
            );
            pool.close().await;
        });
    }

    /// Nothing asked for must behave exactly as before this primitive existed.
    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn live_default_session_connects_as_before() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = create_pool_with_session(&live_config(), &SessionOptions::default())
                .await
                .expect("a default session connects");
            let row: (i32,) = sqlx::query_as("SELECT 1").fetch_one(&pool).await.unwrap();
            assert_eq!(row.0, 1);
            pool.close().await;
        });
    }
}

/// Opt-in live test of the `sslmode=prefer` path. `cargo test` skips it; run it
/// with
///
///   cargo test --release prefer_connects -- --ignored --nocapture
///
/// Point it elsewhere with `PHAROS_TEST_PG_HOST`, `PHAROS_TEST_PG_PORT`,
/// `PHAROS_TEST_PG_USER` and `PHAROS_TEST_PG_DB`.
#[cfg(test)]
mod live_prefer_tests {
    use super::create_pool;
    use crate::models::{ConnectionConfig, SslMode};
    use std::time::{Duration, Instant};

    fn env_or(key: &str, fallback: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| fallback.to_string())
    }

    fn live_config(ssl_mode: SslMode) -> ConnectionConfig {
        ConnectionConfig {
            id: "live".to_string(),
            name: "live".to_string(),
            host: env_or("PHAROS_TEST_PG_HOST", "localhost"),
            port: env_or("PHAROS_TEST_PG_PORT", "5432").parse().unwrap_or(5432),
            database: env_or("PHAROS_TEST_PG_DB", "nfinn"),
            username: env_or("PHAROS_TEST_PG_USER", "nfinn"),
            password: std::env::var("PHAROS_TEST_PG_PASSWORD").unwrap_or_default(),
            ssl_mode,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            session_time_zone: None,
            ssl_root_cert_path: None,
        }
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app) on localhost:5432"]
    fn prefer_connects_and_runs_a_query() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let started = Instant::now();
            let pool = create_pool(&live_config(SslMode::Prefer))
                .await
                .unwrap_or_else(|e| panic!("sslmode=prefer connect failed: {e}"));
            let elapsed = started.elapsed();

            let row: (i32,) = sqlx::query_as("SELECT 1")
                .fetch_one(&pool)
                .await
                .expect("query on the prefer pool failed");
            assert_eq!(row.0, 1);

            // A stalled handshake used to sit here for the whole 10 s acquire
            // budget and then fail. The fallback has to be inside the budget,
            // not merely eventually successful.
            assert!(
                elapsed < Duration::from_secs(10),
                "prefer connect took {elapsed:?}; the fallback did not fire in time"
            );
            eprintln!("prefer connect took {elapsed:?}");
            pool.close().await;
        });
    }
}

/// Opt-in live test of the catalogue query. `cargo test` skips it; run it with
///
///   cargo test --release get_table_key_info -- --ignored --nocapture
///
/// This is the ONLY test of `get_table_key_info`. The function is pure I/O
/// against the catalogue, so there is nothing offline left to test: every value
/// it returns crosses the sqlx decode seam, and that seam has already hidden a
/// bug in this codebase, where a PostgreSQL internal type panicked or silently
/// yielded `None`. Only a real connection exercises it.
///
/// Fixture: `scripts/tagtest-schema.sql`.
#[cfg(test)]
mod live_key_info_tests {
    use super::get_table_key_info;
    use crate::models::KeyCandidate;
    use sqlx::postgres::types::Oid;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;
    use std::collections::HashMap;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";

    /// Look up the OIDs of the named `tagtest` tables. An empty map means the
    /// fixture schema is absent.
    async fn tagtest_oids(pool: &sqlx::PgPool) -> HashMap<String, u32> {
        let sql = "SELECT c.relname AS name, c.oid AS oid \
                   FROM pg_class c \
                   JOIN pg_namespace n ON n.oid = c.relnamespace \
                   WHERE n.nspname = 'tagtest' AND c.relkind = 'r'";
        let rows = sqlx::raw_sql(sql).fetch_all(pool).await.expect("catalogue lookup failed");
        let mut map = HashMap::new();
        for row in rows {
            let name: String = row.try_get("name").expect("name decode failed");
            let oid: Oid = row.try_get("oid").expect("oid decode failed");
            map.insert(name, oid.0);
        }
        map
    }

    /// The candidate whose `column_attnums` match, or a panic naming what the
    /// table actually returned. A blind `candidates[0]` would hide an ordering
    /// change; this reports the whole set on failure.
    fn candidate_with<'a>(
        candidates: &'a [KeyCandidate],
        attnums: &[i16],
        table: &str,
    ) -> &'a KeyCandidate {
        candidates
            .iter()
            .find(|c| c.column_attnums == attnums)
            .unwrap_or_else(|| {
                panic!("{}: no candidate with attnums {:?}; got {:?}", table, attnums, candidates)
            })
    }

    #[test]
    #[ignore = "needs a live PostgreSQL with scripts/tagtest-schema.sql loaded"]
    fn get_table_key_info_reads_the_live_catalogue() {
        let url = std::env::var("PHAROS_TEST_DATABASE_URL")
            .unwrap_or_else(|_| DEFAULT_URL.to_string());
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");

        rt.block_on(async move {
            let pool = PgPoolOptions::new()
                .max_connections(1)
                // Without this a dead host takes the 30s default to fail.
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| {
                    panic!(
                        "cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.",
                        url, e
                    )
                });

            let oids = tagtest_oids(&pool).await;
            if oids.is_empty() {
                eprintln!(
                    "SKIP: schema `tagtest` not found in {}. Load the fixture first: \
                     psql -d <db> -f scripts/tagtest-schema.sql",
                    url
                );
                return;
            }
            for needed in [
                "users",
                "memberships",
                "include_demo",
                "nullable_codes",
                "excluded",
                "three_keys",
                "codes",
            ] {
                if !oids.contains_key(needed) {
                    eprintln!(
                        "SKIP: schema `tagtest` is present but table `{}` is missing. \
                         Reload scripts/tagtest-schema.sql",
                        needed
                    );
                    return;
                }
            }

            let users_oid = oids["users"];
            let memberships_oid = oids["memberships"];
            let include_oid = oids["include_demo"];
            let nullable_oid = oids["nullable_codes"];
            let excluded_oid = oids["excluded"];
            let three_keys_oid = oids["three_keys"];
            let codes_oid = oids["codes"];

            let info = get_table_key_info(
                &pool,
                &[
                    users_oid,
                    memberships_oid,
                    include_oid,
                    nullable_oid,
                    excluded_oid,
                    three_keys_oid,
                    codes_oid,
                ],
            )
            .await
            .expect("get_table_key_info failed");

            // --- users: a primary key AND a unique key ----------------------
            let users = info.get(&users_oid).expect("no entry for tagtest.users");
            assert_eq!(users.display, "tagtest.users", "display name");
            assert_eq!(
                users.candidates.len(),
                2,
                "users should have 2 candidates, got {:?}",
                users.candidates
            );
            let pk = candidate_with(&users.candidates, &[1], "users");
            assert!(pk.is_primary, "users {{1}} should be the primary key");
            assert!(pk.all_not_null, "users.id is NOT NULL");
            let uq = candidate_with(&users.candidates, &[2], "users");
            assert!(!uq.is_primary, "users {{2}} is a unique key, not the pk");
            assert!(uq.all_not_null, "users.email is NOT NULL");

            // --- memberships: a COMPOUND primary key, order matters ---------
            let memberships =
                info.get(&memberships_oid).expect("no entry for tagtest.memberships");
            assert_eq!(
                memberships.candidates.len(),
                1,
                "memberships should have 1 candidate, got {:?}",
                memberships.candidates
            );
            let compound = &memberships.candidates[0];
            assert!(compound.is_primary, "memberships candidate is the pk");
            assert_eq!(
                compound.column_attnums,
                vec![1, 2],
                "compound key must keep index order (user_id, team_id)"
            );

            // --- include_demo: the INCLUDE-column guard ---------------------
            // Without `k.ord <= ix.indnkeyatts` this reads {1,2} and
            // all_not_null flips to false, discarding a good key.
            let include = info.get(&include_oid).expect("no entry for tagtest.include_demo");
            assert_eq!(
                include.candidates.len(),
                1,
                "include_demo should have 1 candidate, got {:?}",
                include.candidates
            );
            assert_eq!(
                include.candidates[0].column_attnums,
                vec![1],
                "INCLUDE column must not enter the key: {:?}",
                include.candidates
            );
            assert!(
                include.candidates[0].all_not_null,
                "include_demo.k is NOT NULL; payload's nullability must not leak in"
            );

            // --- nullable_codes: reported, but all_not_null = false ---------
            let nullable =
                info.get(&nullable_oid).expect("no entry for tagtest.nullable_codes");
            assert_eq!(
                nullable.candidates.len(),
                1,
                "nullable_codes should have 1 candidate, got {:?}",
                nullable.candidates
            );
            let nullable_key = candidate_with(&nullable.candidates, &[1], "nullable_codes");
            assert!(
                !nullable_key.all_not_null,
                "a unique index on a NULLABLE column must report all_not_null = false"
            );

            // --- three_keys: the FULL candidate set, not a truncated one -----
            // The only fixture table with more than two candidates. If anyone
            // adds a cap or a LIMIT to the SQL, every other assertion here
            // still passes while `choose_candidates` quietly loses the narrowest
            // unique index — exactly the case the feature exists for, a later
            // query that drops the primary-key column. Widening happens in the
            // Rust chooser, never in this function: it returns everything.
            let three = info.get(&three_keys_oid).expect("no entry for tagtest.three_keys");
            assert_eq!(
                three.candidates.len(),
                3,
                "three_keys must return ALL 3 candidates; a smaller set means the SQL grew a cap \
                 or a LIMIT. Got {:?}",
                three.candidates
            );
            let three_pk = candidate_with(&three.candidates, &[1], "three_keys");
            assert!(three_pk.is_primary, "three_keys {{1}} is the primary key");
            let three_a = candidate_with(&three.candidates, &[2], "three_keys");
            assert!(!three_a.is_primary, "three_keys_a is a unique key, not the pk");
            assert!(three_a.all_not_null, "three_keys.a is NOT NULL");
            let three_bc = candidate_with(&three.candidates, &[3, 4], "three_keys");
            assert!(!three_bc.is_primary, "three_keys_bc is a unique key, not the pk");
            assert!(three_bc.all_not_null, "three_keys.b and .c are NOT NULL");

            // --- codes: a unique key and NO primary key ----------------------
            let codes = info.get(&codes_oid).expect("no entry for tagtest.codes");
            assert_eq!(
                codes.candidates.len(),
                1,
                "codes should have 1 candidate, got {:?}",
                codes.candidates
            );
            let codes_key = candidate_with(&codes.candidates, &[1], "codes");
            assert!(!codes_key.is_primary, "codes has no primary key");
            assert!(codes_key.all_not_null, "codes.code is NOT NULL");

            // --- excluded: the three exclusion guards -----------------------
            // This one assertion defends `indpred IS NULL`, `indexprs IS NULL`
            // and `indimmediate` at once. tagtest.excluded carries four unique
            // indexes, every one of which must be filtered out: partial, pure
            // expression, MIXED expression, and DEFERRABLE INITIALLY DEFERRED.
            //
            // The mixed index is why this matters most. `UNIQUE (n, lower(tag))`
            // has indkey "1 0". The pg_attribute join drops only the expression
            // half, so without `indexprs IS NULL` the index is reported as
            // column_attnums = [1] — a claim that `n` alone is unique, which is
            // false. A row key built from it would not identify a row, and a
            // tag would attach to the WRONG row. A pure expression index drops
            // out by itself (indkey entry 0 matches no pg_attribute row), so
            // anyone who tests only that case concludes the clause is dead and
            // deletes it. This assertion is what stops that.
            //
            // It also proves an incidental point the fingerprint tier depends
            // on: a table with NO usable key still gets an entry, with a
            // correct display, instead of being dropped from the map.
            let excluded = info.get(&excluded_oid).expect(
                "tagtest.excluded must still get an entry: a table with no usable key needs a \
                 display for the fingerprint tier",
            );
            assert_eq!(excluded.display, "tagtest.excluded", "display name");
            assert!(
                excluded.candidates.is_empty(),
                "tagtest.excluded must yield no candidates: its indexes are partial, expression, \
                 mixed-expression and deferred. A non-empty set means an exclusion guard was \
                 removed. Which attnum leaked names the guard: [1] is column `n`, so either \
                 `indpred IS NULL` (the partial index) or `indexprs IS NULL` (the MIXED index \
                 leaking its plain half, falsely claiming `n` alone is unique); [3] is column \
                 `defcol`, so `indimmediate` (the DEFERRABLE INITIALLY DEFERRED constraint). \
                 Verified by deleting each guard in turn. Got {:?}",
                excluded.candidates
            );

            println!("live catalogue read OK:");
            for (oid, entry) in &info {
                println!("  {} oid={} candidates={:?}", entry.display, oid, entry.candidates);
            }
        });
    }
}

/// Live tests for legacy inheritance grouping. They need a real PostgreSQL,
/// so they are `#[ignore]`d:
/// `cargo test --lib live_inheritance_tests -- --ignored --nocapture`.
///
/// The default URL is a local Postgres.app; `PHAROS_TEST_DATABASE_URL`
/// overrides it. The tests make and drop their OWN schema.
#[cfg(test)]
mod live_inheritance_tests {
    use super::*;
    use sqlx::postgres::PgPoolOptions;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";
    /// One schema per test: the tests run in parallel, and a shared name
    /// means one test drops the schema another is reading.
    const FLAT: &str = "pharos_inh_flat";
    const GROUPED: &str = "pharos_inh_grouped";
    const NESTED: &str = "pharos_inh_nested";
    const AWKWARD: &str = "pharos_inh_awkward";

    fn url() -> String {
        std::env::var("PHAROS_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_URL.to_string())
    }

    async fn live_pool() -> PgPool {
        let u = url();
        PgPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect(&u)
            .await
            .unwrap_or_else(|e| panic!("cannot connect to {u}: {e}. Set PHAROS_TEST_DATABASE_URL."))
    }

    /// A root, two year children, one month under the first year, two day
    /// tables holding the rows, and one unrelated table for company. Three
    /// levels below the root, which is what the database that prompted this
    /// looks like.
    async fn build_tree(pool: &PgPool, schema: &str) {
        let sql = format!(
            "DROP SCHEMA IF EXISTS {s} CASCADE; \
             CREATE SCHEMA {s}; \
             CREATE TABLE {s}.logs (id integer, seen timestamptz); \
             CREATE TABLE {s}.logs_2013 () INHERITS ({s}.logs); \
             CREATE TABLE {s}.logs_2014 () INHERITS ({s}.logs); \
             CREATE TABLE {s}.logs_201301 () INHERITS ({s}.logs_2013); \
             CREATE TABLE {s}.logs_20130101 () INHERITS ({s}.logs_201301); \
             CREATE TABLE {s}.logs_20130102 () INHERITS ({s}.logs_201301); \
             CREATE TABLE {s}.unrelated (id integer); \
             INSERT INTO {s}.logs_20130101 (id) SELECT generate_series(1, 3); \
             INSERT INTO {s}.logs_20130102 (id) SELECT generate_series(4, 5); \
             INSERT INTO {s}.unrelated (id) VALUES (1); \
             ANALYZE {s}.logs; ANALYZE {s}.logs_2013; ANALYZE {s}.logs_2014; \
             ANALYZE {s}.logs_201301; ANALYZE {s}.logs_20130101; \
             ANALYZE {s}.logs_20130102; ANALYZE {s}.unrelated;",
            s = schema
        );
        sqlx::raw_sql(&sql).execute(pool).await.expect("build the tree");
    }

    async fn drop_tree(pool: &PgPool, schema: &str) {
        let sql = format!("DROP SCHEMA IF EXISTS {} CASCADE", schema);
        sqlx::raw_sql(&sql).execute(pool).await.expect("drop the schema");
    }

    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn the_flag_off_lists_every_table_in_the_tree_flat() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_tree(&pool, FLAT).await;

            let tables = get_tables(&pool, FLAT, false).await.expect("get_tables");
            let names: Vec<&str> = tables.iter().map(|t| t.name.as_str()).collect();
            assert_eq!(
                names,
                vec![
                    "logs",
                    "logs_2013",
                    "logs_201301",
                    "logs_20130101",
                    "logs_20130102",
                    "logs_2014",
                    "unrelated"
                ],
                "the flat list is what Pharos has always shown"
            );
            let root = tables.iter().find(|t| t.name == "logs").unwrap();
            assert!(!root.is_partitioned, "nothing is a parent while the flag is off");
            assert_eq!(root.row_count_estimate, Some(0), "the root holds no rows itself");
            // TRUNCATE would still empty the whole tree, so this must be
            // true whichever way the setting points.
            assert!(root.has_child_tables, "the truncate warning does not read the setting");
            let leaf = tables.iter().find(|t| t.name == "logs_20130101").unwrap();
            assert!(!leaf.has_child_tables, "a leaf takes nothing with it");
            let stranger = tables.iter().find(|t| t.name == "unrelated").unwrap();
            assert!(!stranger.has_child_tables);

            drop_tree(&pool, FLAT).await;
        });
    }

    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn the_flag_on_lifts_the_root_and_sums_the_tree() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_tree(&pool, GROUPED).await;

            let tables = get_tables(&pool, GROUPED, true).await.expect("get_tables");
            let names: Vec<&str> = tables.iter().map(|t| t.name.as_str()).collect();
            assert_eq!(names, vec!["logs", "unrelated"], "only the root and the stranger");

            let root = tables.iter().find(|t| t.name == "logs").unwrap();
            assert!(root.is_partitioned, "the root is a parent now");
            assert_eq!(root.partition_count, Some(2), "two DIRECT children, not five");
            assert_eq!(
                root.partition_mechanism,
                Some(PartitionMechanism::Inheritance),
                "the pill says INHERITS, not RANGE"
            );
            assert!(root.partition_strategy.is_none(), "there is no strategy to read");
            assert!(root.partition_key.is_none(), "there is no key to read");

            // What a query on the parent returns, which is the point.
            let counted: i64 = sqlx::raw_sql(&format!("SELECT count(*) AS n FROM {}.logs", GROUPED))
                .fetch_one(&pool)
                .await
                .expect("count")
                .try_get("n")
                .expect("n");
            assert_eq!(counted, 5);
            assert_eq!(root.row_count_estimate, Some(counted), "the root reports its tree");
            assert!(
                root.total_size_bytes.unwrap_or(0) > 0,
                "the size is the tree's, and the leaves hold pages"
            );

            let stranger = tables.iter().find(|t| t.name == "unrelated").unwrap();
            assert!(!stranger.is_partitioned, "a table with no children is untouched");
            assert_eq!(stranger.row_count_estimate, Some(1));

            drop_tree(&pool, GROUPED).await;
        });
    }

    /// The mid-level tables are reached through the parent, and each one
    /// carries its own sums and its own child count — without them the tree
    /// is a dead end one level down, because the Navigator decides whether to
    /// give a child a folder of its own from exactly those numbers.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn a_year_table_is_itself_a_parent() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_tree(&pool, NESTED).await;

            let years = get_partitions(&pool, NESTED, "logs", true).await.expect("get_partitions");
            let names: Vec<&str> = years.iter().map(|t| t.name.as_str()).collect();
            assert_eq!(names, vec!["logs_2013", "logs_2014"]);
            assert!(years.iter().all(|c| c.is_partition));
            assert!(years.iter().all(|c| c.partition_bound.is_none()), "no bounds to read");

            let y13 = years.iter().find(|t| t.name == "logs_2013").unwrap();
            assert!(y13.is_partitioned, "1 direct child, so it opens");
            assert_eq!(y13.partition_count, Some(1));
            assert_eq!(y13.partition_mechanism, Some(PartitionMechanism::Inheritance));
            assert_eq!(y13.row_count_estimate, Some(5), "its own subtree, not the root's");

            let y14 = years.iter().find(|t| t.name == "logs_2014").unwrap();
            assert!(!y14.is_partitioned, "no children, so it is a leaf");
            assert_eq!(y14.partition_count, None);
            assert_eq!(y14.partition_mechanism, None);
            assert_eq!(y14.row_count_estimate, Some(0));

            // Level 3: the month opens into two days, and they are leaves.
            let months = get_partitions(&pool, NESTED, "logs_2013", true).await.expect("months");
            assert_eq!(months.len(), 1);
            assert!(months[0].is_partitioned);
            assert_eq!(months[0].partition_count, Some(2));
            assert_eq!(months[0].row_count_estimate, Some(5));

            let days = get_partitions(&pool, NESTED, "logs_201301", true).await.expect("days");
            let day_names: Vec<&str> = days.iter().map(|t| t.name.as_str()).collect();
            assert_eq!(day_names, vec!["logs_20130101", "logs_20130102"]);
            assert!(days.iter().all(|d| !d.is_partitioned), "the leaves stop here");
            assert_eq!(days[0].row_count_estimate, Some(3));
            assert_eq!(days[1].row_count_estimate, Some(2));

            // With the setting off, the children still come back — nothing
            // reads them, because the parent gets no folder — but not one of
            // them is a parent, and each reports only its own rows.
            let off = get_partitions(&pool, NESTED, "logs", false).await.expect("off");
            assert_eq!(off.len(), 2);
            assert!(off.iter().all(|c| !c.is_partitioned));
            assert!(off.iter().all(|c| c.partition_mechanism.is_none()));
            assert_eq!(off.iter().find(|t| t.name == "logs_2013").unwrap().row_count_estimate, Some(0));

            // The filter index covers every pair in the tree, so a name
            // inside a collapsed folder is still findable.
            let map = get_partition_map(&pool, NESTED, true).await.expect("map on");
            let mut pairs: Vec<String> = map.iter().map(|r| format!("{}>{}", r.parent_name, r.name)).collect();
            pairs.sort();
            assert_eq!(
                pairs,
                vec![
                    "logs>logs_2013",
                    "logs>logs_2014",
                    "logs_201301>logs_20130101",
                    "logs_201301>logs_20130102",
                    "logs_2013>logs_201301",
                ]
            );
            // Off, the index holds nothing: there is no folder to look into.
            let map_off = get_partition_map(&pool, NESTED, false).await.expect("map off");
            assert!(map_off.is_empty(), "{map_off:?}");

            drop_tree(&pool, NESTED).await;
        });
    }

    /// The three cases that are easy to get wrong: a child of two parents, a
    /// child whose parent is in another schema, and a declarative tree in the
    /// same schema that must not be touched at all.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn the_awkward_cases_are_counted_once_and_stay_reachable() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            let elsewhere = format!("{AWKWARD}_elsewhere");
            let sql = format!(
                "DROP SCHEMA IF EXISTS {s} CASCADE; \
                 DROP SCHEMA IF EXISTS {e} CASCADE; \
                 CREATE SCHEMA {s}; CREATE SCHEMA {e}; \
                 CREATE TABLE {s}.logs (id integer); \
                 CREATE TABLE {s}.logs_a () INHERITS ({s}.logs); \
                 CREATE TABLE {s}.logs_b () INHERITS ({s}.logs); \
                 CREATE TABLE {s}.logs_both () INHERITS ({s}.logs_a, {s}.logs_b); \
                 CREATE TABLE {e}.over_there (id integer); \
                 CREATE TABLE {s}.orphan () INHERITS ({e}.over_there); \
                 CREATE TABLE {s}.events (id integer, seen date) PARTITION BY RANGE (seen); \
                 CREATE TABLE {s}.events_2013 PARTITION OF {s}.events \
                     FOR VALUES FROM ('2013-01-01') TO ('2014-01-01'); \
                 INSERT INTO {s}.logs_both (id) SELECT generate_series(1, 4); \
                 INSERT INTO {s}.orphan (id) VALUES (1); \
                 INSERT INTO {s}.events_2013 (id, seen) VALUES (1, '2013-06-01'); \
                 ANALYZE {s}.logs; ANALYZE {s}.logs_a; ANALYZE {s}.logs_b; \
                 ANALYZE {s}.logs_both; ANALYZE {s}.orphan; ANALYZE {s}.events;",
                s = AWKWARD,
                e = elsewhere
            );
            sqlx::raw_sql(&sql).execute(&pool).await.expect("build the awkward tree");

            let tables = get_tables(&pool, AWKWARD, true).await.expect("get_tables");
            let names: Vec<&str> = tables.iter().map(|t| t.name.as_str()).collect();
            assert_eq!(
                names,
                vec!["events", "logs", "orphan"],
                "the root, the declarative parent, and the child whose parent is elsewhere"
            );

            // PostgreSQL expands an inheritance tree once per descendant, and
            // so must the walk: logs_both is reached through logs_a AND
            // logs_b, but its four rows are four rows.
            let counted: i64 = sqlx::raw_sql(&format!("SELECT count(*) AS n FROM {}.logs", AWKWARD))
                .fetch_one(&pool)
                .await
                .expect("count")
                .try_get("n")
                .expect("n");
            assert_eq!(counted, 4);
            let root = tables.iter().find(|t| t.name == "logs").unwrap();
            assert_eq!(root.row_count_estimate, Some(counted), "not 8");
            assert_eq!(root.partition_count, Some(2), "logs_a and logs_b");

            // The declarative tree is exactly as it was.
            let events = tables.iter().find(|t| t.name == "events").unwrap();
            assert!(
                !events.has_child_tables,
                "a declarative parent's partitions are not INHERITS children"
            );
            assert_eq!(events.table_type, TableType::PartitionedTable);
            assert_eq!(events.partition_mechanism, Some(PartitionMechanism::Declarative));
            assert_eq!(events.partition_strategy, Some(PartitionStrategy::Range));
            assert_eq!(events.partition_count, Some(1));
            assert_eq!(events.row_count_estimate, Some(1), "summed over its leaves");

            // The stranger is listed, and is not mistaken for a parent.
            let orphan = tables.iter().find(|t| t.name == "orphan").unwrap();
            assert!(!orphan.is_partitioned);
            assert_eq!(orphan.row_count_estimate, Some(1));

            sqlx::raw_sql(&format!(
                "DROP SCHEMA IF EXISTS {} CASCADE; DROP SCHEMA IF EXISTS {} CASCADE",
                AWKWARD, elsewhere
            ))
            .execute(&pool)
            .await
            .expect("drop");
        });
    }
}

#[cfg(test)]
mod tables_sql_tests {
    use super::tables_sql;

    #[test]
    fn the_default_shape_is_the_statement_pharos_has_always_sent() {
        let sql = tables_sql("public", false);
        assert!(sql.starts_with("SELECT c.relname as table_name,"), "{sql}");
        assert!(sql.contains("(c.relkind = 'p') as is_partitioned"), "{sql}");
        assert!(sql.contains("AND c.relispartition = false"), "{sql}");
        assert!(sql.contains("AND c.relkind IN ('r', 'v', 'm', 'f', 'p')"), "{sql}");
        assert!(sql.ends_with("c.relname"), "the order is kind then name: {sql}");
        // The one thing the off shape gained: TRUNCATE has no ONLY, so the
        // confirmation must know about child tables whatever the Navigator
        // is set to show. It is an EXISTS, not the walk.
        assert!(sql.contains("as has_child_tables"), "{sql}");
        // Not one trace of the inheritance walk while the setting is off.
        assert!(!sql.contains("inh_"), "{sql}");
        assert!(!sql.contains("RECURSIVE"), "{sql}");
        assert!(!sql.contains("desc_count"), "{sql}");
    }

    /// The danger is not a display fact: it is there whichever way the
    /// setting points, and a declarative parent is not an INHERITS parent.
    #[test]
    fn the_child_table_test_is_in_both_shapes_and_skips_declarative() {
        for on in [false, true] {
            let sql = tables_sql("public", on);
            assert!(
                sql.contains("(c.relkind <> 'p' AND EXISTS ( SELECT 1 FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = c.oid)) as has_child_tables"),
                "{sql}"
            );
        }
    }

    #[test]
    fn the_schema_arrives_already_escaped_and_is_written_once_per_mention() {
        // The caller runs `escape_sql_literal`; a second pass here would
        // double the quotes. O'Hara must appear exactly as it was handed in.
        let off = tables_sql("O''Hara", false);
        assert_eq!(off.matches("O''Hara").count(), 1, "{off}");
        assert!(off.contains("WHERE n.nspname = 'O''Hara'"), "{off}");
        // On: the two `inh_root` mentions, `inh_child`, and the main statement.
        let on = tables_sql("O''Hara", true);
        assert_eq!(on.matches("O''Hara").count(), 4, "{on}");
        assert!(!on.contains("O''''Hara"), "no second escaping pass: {on}");
    }

    #[test]
    fn the_declarative_totals_come_from_the_partition_tree() {
        // A partitioned parent holds no rows of its own: both figures are the
        // sum over its leaves. Legacy inheritance has no such function.
        let sql = tables_sql("public", false);
        assert_eq!(sql.matches("pg_partition_tree(c.oid)").count(), 2, "{sql}");
        assert!(sql.contains("WHERE pt.isleaf"), "{sql}");
    }

    #[test]
    fn the_walk_is_seeded_with_true_roots_only() {
        let sql = tables_sql("public", true);
        assert!(sql.starts_with("WITH RECURSIVE inh_root AS ("), "{sql}");
        // A seed must have no non-declarative parent in this schema.
        assert!(sql.contains("AND NOT EXISTS ("), "{sql}");
        assert!(sql.contains("AND p.relkind <> 'p')"), "{sql}");
        // One walk per relation, so one size call per relation.
        assert_eq!(sql.matches("SELECT oid, oid FROM inh_root").count(), 1, "{sql}");
    }

    #[test]
    fn a_diamond_is_counted_once() {
        let sql = tables_sql("public", true);
        assert!(sql.contains("UNION SELECT t.root, i.inhrelid"), "{sql}");
        assert!(!sql.contains("UNION ALL"), "a relation must not be summed twice: {sql}");
    }

    #[test]
    fn an_inheritance_root_reports_its_whole_tree() {
        let sql = tables_sql("public", true);
        assert!(sql.contains("WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_tuples"), "{sql}");
        assert!(sql.contains("WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_bytes"), "{sql}");
        assert!(
            sql.contains("(c.relkind = 'p' OR COALESCE(st.desc_count, 0) > 0) as is_partitioned"),
            "{sql}"
        );
        // The declarative arm still comes first, so a declarative parent is
        // unaffected by the walk.
        let leaves = sql.find("SELECT COALESCE(SUM(lc.reltuples), 0)").unwrap();
        let tree = sql.find("THEN st.sum_tuples").unwrap();
        assert!(leaves < tree, "the partition-tree arm must win: {sql}");
    }

    #[test]
    fn an_inheritance_child_leaves_the_top_level() {
        let sql = tables_sql("public", true);
        assert!(sql.contains("LEFT JOIN inh_child ihc ON ihc.oid = c.oid"), "{sql}");
        assert!(sql.contains("AND ihc.oid IS NULL"), "{sql}");
        // Both filters stand: a declarative child is already excluded by the
        // older one, and the two test different things.
        assert!(sql.contains("AND c.relispartition = false"), "{sql}");
    }

    #[test]
    fn the_partition_count_is_the_direct_children_either_way() {
        // The subtitle says "N partitions" and the folder holds exactly those,
        // so the count is of direct children, not of the whole tree.
        for on in [false, true] {
            let sql = tables_sql("public", on);
            assert!(
                sql.contains("SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid"),
                "{sql}"
            );
        }
    }

    #[test]
    fn an_unanalyzed_child_falls_back_to_the_live_tuple_count() {
        // reltuples is -1 until ANALYZE runs; summing that as it stands would
        // report fewer rows than the tree holds.
        let sql = tables_sql("public", true);
        assert!(sql.contains("ELSE COALESCE(ist.n_live_tup, 0) END"), "{sql}");
    }
}

#[cfg(test)]
mod partitions_sql_tests {
    use super::partitions_sql;

    #[test]
    fn the_default_shape_is_the_statement_pharos_has_always_sent() {
        let sql = partitions_sql("public", "logs", false);
        assert!(sql.starts_with("SELECT c.relname as table_name,"), "{sql}");
        assert!(sql.contains("(c.relkind = 'p') as is_partitioned"), "{sql}");
        assert!(sql.contains("as has_child_tables"), "the truncate warning needs it: {sql}");
        assert!(sql.contains("WHERE pn.nspname = 'public' AND parent.relname = 'logs'"), "{sql}");
        assert!(!sql.contains("RECURSIVE"), "{sql}");
        assert!(!sql.contains("desc_count"), "{sql}");
    }

    #[test]
    fn the_walk_is_seeded_with_the_parents_direct_children() {
        // Sibling subtrees are disjoint, so each descendant is measured once.
        let sql = partitions_sql("public", "logs", true);
        assert!(sql.starts_with("WITH RECURSIVE kin AS ("), "{sql}");
        assert!(sql.contains("SELECT oid, oid FROM kin"), "{sql}");
        assert!(!sql.contains("UNION ALL"), "{sql}");
    }

    #[test]
    fn a_mid_level_child_reports_its_own_subtree_and_its_direct_children() {
        let sql = partitions_sql("public", "logs", true);
        assert!(sql.contains("WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_tuples"), "{sql}");
        assert!(sql.contains("WHEN COALESCE(st.desc_count, 0) > 0 THEN st.sum_bytes"), "{sql}");
        assert!(
            sql.contains("(c.relkind = 'p' OR COALESCE(st.desc_count, 0) > 0) as is_partitioned"),
            "{sql}"
        );
        assert!(sql.contains("SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid"), "{sql}");
    }

    #[test]
    fn both_names_arrive_already_escaped() {
        let on = partitions_sql("O''Hara", "l''ogs", true);
        assert_eq!(on.matches("O''Hara").count(), 2, "the seed and the statement: {on}");
        assert_eq!(on.matches("l''ogs").count(), 2, "{on}");
        assert!(!on.contains("O''''Hara"), "{on}");
    }

    #[test]
    fn the_strategy_and_the_key_stay_declarative_whichever_way_the_flag_points() {
        // An inheritance parent has neither, and a nil strategy is what makes
        // the inspector print the mechanism instead of an em-dash.
        for on in [false, true] {
            let sql = partitions_sql("public", "logs", on);
            assert!(sql.contains("CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text"), "{sql}");
            assert!(sql.contains("CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid)"), "{sql}");
        }
    }
}

#[cfg(test)]
mod schemas_sql_tests {
    use super::schemas_sql;

    #[test]
    fn the_default_shape_is_the_statement_pharos_has_always_sent() {
        let sql = schemas_sql(false);
        assert!(
            sql.contains("NOT IN ('pg_catalog', 'information_schema', 'pg_toast')"),
            "the default must not change: {sql}"
        );
        assert!(!sql.contains("LIKE"), "the default shape uses no LIKE: {sql}");
    }

    #[test]
    fn showing_system_schemas_drops_the_not_in_list() {
        let sql = schemas_sql(true);
        assert!(!sql.contains("pg_catalog"), "pg_catalog must be let through: {sql}");
        assert!(!sql.contains("NOT IN"), "nothing is named and excluded now: {sql}");
        // The only mention of information_schema left is the FROM clause.
        assert_eq!(sql.matches("information_schema").count(), 1, "{sql}");
    }

    #[test]
    fn the_storage_schemas_are_hidden_whichever_way_the_flag_points() {
        // Off: named in the NOT IN list. On: matched by the two LIKE patterns.
        assert!(schemas_sql(false).contains("'pg_toast'"));
        let on = schemas_sql(true);
        assert!(on.contains(r"NOT LIKE 'pg\_toast%'"), "{on}");
        assert!(on.contains(r"NOT LIKE 'pg\_temp\_%'"), "{on}");
    }

    #[test]
    fn the_like_patterns_escape_their_underscores() {
        // An unescaped `_` is LIKE's single-character wildcard, so
        // `pg_temp_%` would also hide a user schema called `pgXtempY`.
        let on = schemas_sql(true);
        assert!(!on.contains("LIKE 'pg_toast"), "unescaped underscore: {on}");
        assert!(!on.contains("LIKE 'pg_temp"), "unescaped underscore: {on}");
    }

    #[test]
    fn both_shapes_order_by_name() {
        for include_system in [false, true] {
            assert!(schemas_sql(include_system).ends_with("ORDER BY schema_name"));
        }
    }
}

#[cfg(test)]
mod live_schemas_tests {
    use super::get_schemas;
    use sqlx::postgres::PgPoolOptions;
    use std::time::Duration;

    fn url() -> String {
        std::env::var("PHAROS_TEST_DATABASE_URL")
            .unwrap_or_else(|_| "postgres://nfinn@localhost:5432/nfinn".to_string())
    }

    /// What the flag does against a real server: `pg_catalog` appears only
    /// with it on, and no `pg_toast` or `pg_temp_` schema appears either way.
    #[test]
    #[ignore = "needs a live PostgreSQL on localhost:5432"]
    fn the_flag_reveals_pg_catalog_and_never_the_storage_schemas() {
        let rt = tokio::runtime::Runtime::new().expect("runtime");
        rt.block_on(async {
            let pool = PgPoolOptions::new()
                .max_connections(1)
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url())
                .await
                .expect("connect to the live server");

            let hidden: Vec<String> =
                get_schemas(&pool, false).await.expect("hidden").into_iter().map(|s| s.name).collect();
            let shown: Vec<String> =
                get_schemas(&pool, true).await.expect("shown").into_iter().map(|s| s.name).collect();

            println!("include_system = false -> {hidden:?}");
            println!("include_system = true  -> {shown:?}");

            assert!(!hidden.iter().any(|n| n == "pg_catalog"), "pg_catalog leaked with the flag off");
            assert!(!hidden.iter().any(|n| n == "information_schema"), "information_schema leaked");
            assert!(shown.iter().any(|n| n == "pg_catalog"), "pg_catalog missing with the flag on");
            assert!(shown.iter().any(|n| n == "information_schema"), "information_schema missing");

            for list in [&hidden, &shown] {
                assert!(
                    !list.iter().any(|n| n.starts_with("pg_toast")),
                    "a pg_toast schema reached the tree: {list:?}"
                );
                assert!(
                    !list.iter().any(|n| n.starts_with("pg_temp_")),
                    "a pg_temp_ schema reached the tree: {list:?}"
                );
            }
        });
    }
}
