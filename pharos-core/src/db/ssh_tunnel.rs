//! An SSH tunnel for one connection.
//!
//! Pharos runs the system `/usr/bin/ssh` as a child process:
//!
//! ```text
//! /usr/bin/ssh -N -L 127.0.0.1:<local>:<db host>:<db port> <user>@<ssh host>
//! ```
//!
//! The system binary reads `~/.ssh/config`, so `Host` aliases, `ProxyJump`,
//! `IdentityAgent` (1Password) and `IdentityFile` all apply with no code here.
//! That is the whole reason for a child process instead of an in-process SSH
//! library.
//!
//! The child is started with `kill_on_drop(true)`, so a dropped `SshTunnel`
//! can never leave an orphan `ssh` behind, and `close` waits for the process
//! to go so the local port is free again.

use std::io;
use std::net::TcpListener;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};

use crate::models::{SshAuth, SshTunnelConfig};

/// The system binary. A Homebrew `ssh` is out of scope: the path is fixed so
/// the app cannot be made to run a different program by the user's `PATH`.
const SSH_BINARY: &str = "/usr/bin/ssh";

/// How long `open` waits for the local listener to accept. It covers the TCP
/// connect to the bastion, the key exchange, the agent round trip and, for
/// 1Password, the user's approval of the key.
const SSH_OPEN_BUDGET: Duration = Duration::from_secs(15);

/// How often `open` tries the local port while it waits.
const READY_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// How long `close` waits for the killed child to be reaped.
const CLOSE_BUDGET: Duration = Duration::from_secs(2);

/// How much of the child's `stderr` is kept for a later failure message.
const STDERR_TAIL_LIMIT: usize = 2048;

/// A live `ssh` child and the local port it listens on.
pub struct SshTunnel {
    child: Child,
    /// The loopback port the pool connects to.
    pub local_port: u16,
    stderr_tail: Arc<Mutex<String>>,
}

impl SshTunnel {
    /// The last of the child's `stderr`.
    ///
    /// Phase 3 reads this after a POOL failure: `ExitOnForwardFailure` covers
    /// the local bind only, so when the bastion cannot reach the database the
    /// `ssh` process stays alive, accepts the local connection, and then
    /// writes `channel N: open failed: connect failed: ...`.
    pub fn stderr_tail(&self) -> String {
        self.stderr_tail
            .lock()
            .map(|t| t.clone())
            .unwrap_or_default()
    }

    /// Has the `ssh` child stopped?
    ///
    /// Non-blocking, and it reaps the process, so a dead tunnel does not stay
    /// a zombie. An I/O error asking the question is read as "stopped": the
    /// tunnel is unusable either way, and a connection that cannot be judged
    /// must not be reported as healthy.
    pub fn has_exited(&mut self) -> bool {
        !matches!(self.child.try_wait(), Ok(None))
    }

    /// One line saying why the tunnel stopped, for the user.
    pub fn exit_reason(&self) -> String {
        let tail = self.stderr_tail();
        let line = last_meaningful_line(&tail);
        if line.is_empty() {
            "the SSH process stopped".to_string()
        } else {
            line
        }
    }

    /// Ask the child to stop, without waiting. Shutdown uses this when it has
    /// no budget left to wait.
    pub fn start_kill(&mut self) {
        let _ = self.child.start_kill();
    }

    /// Stop the child and wait for it, so the local port is free again.
    pub async fn close(mut self) {
        let _ = self.child.start_kill();
        let _ = tokio::time::timeout(CLOSE_BUDGET, self.child.wait()).await;
    }
}

#[cfg(test)]
impl SshTunnel {
    /// A tunnel wrapped around any child process, with a given stderr tail.
    ///
    /// The state machine AROUND a tunnel — death detection, the reap, the
    /// message the user reads — is most of the risk in Phase 3, and none of it
    /// is about `ssh` in particular. `/bin/sleep` stands in for a healthy
    /// tunnel and a killed one for a dead tunnel, so those paths are tested
    /// with no server, no network and no timing.
    pub fn for_test(child: Child, local_port: u16, stderr_tail: &str) -> Self {
        SshTunnel {
            child,
            local_port,
            stderr_tail: Arc::new(Mutex::new(stderr_tail.to_string())),
        }
    }
}

/// Why a tunnel did not open.
///
/// Every case carries one sentence for the user. The text is NOT sanitized
/// here: `commands::connection::sanitize_error` does that on the way into
/// `ConnectionInfo.error`, the same pass every pool error already takes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TunnelError {
    /// `/usr/bin/ssh` could not be run at all.
    SpawnFailed(String),
    /// No local port could be reserved.
    LocalPortUnavailable(String),
    /// The server refused our identity.
    AuthFailed { target: String },
    /// The server's host key is unknown or has changed (D2).
    HostKeyRejected { target: String },
    /// The SSH host name does not resolve.
    HostNotFound { host: String },
    /// The SSH host does not answer on its port.
    HostUnreachable { host: String, port: u16 },
    /// The local forward port was taken. `open` retries this once.
    LocalPortInUse,
    /// `ssh` stopped before the tunnel was ready, for some other reason.
    ExitedEarly { tail: String },
    /// `ssh` is still running but the local port never accepted.
    TimedOut { tail: String },
}

impl TunnelError {
    /// One sentence for the user.
    pub fn user_message(&self) -> String {
        match self {
            TunnelError::SpawnFailed(e) => {
                format!("Pharos could not start {SSH_BINARY}: {e}")
            }
            TunnelError::LocalPortUnavailable(e) => {
                format!("Pharos could not reserve a local port for the SSH tunnel: {e}")
            }
            TunnelError::AuthFailed { target } => {
                format!("SSH authentication failed for {target}.")
            }
            TunnelError::HostKeyRejected { target } => format!(
                "Pharos does not accept new host keys for this connection. \
                 Turn on Accept new host keys, or connect once from Terminal: ssh {target}"
            ),
            TunnelError::HostNotFound { host } => format!("SSH host {host} not found."),
            TunnelError::HostUnreachable { host, port } => {
                format!("SSH host {host}:{port} did not answer.")
            }
            TunnelError::LocalPortInUse => {
                "Pharos could not open a local port for the SSH tunnel.".to_string()
            }
            TunnelError::ExitedEarly { tail } => {
                let reason = last_meaningful_line(tail);
                if reason.is_empty() {
                    "The SSH tunnel stopped without a reason.".to_string()
                } else {
                    format!("SSH tunnel failed: {reason}")
                }
            }
            TunnelError::TimedOut { tail } => {
                let reason = last_meaningful_line(tail);
                if reason.is_empty() {
                    format!(
                        "The SSH tunnel did not open in {} seconds.",
                        SSH_OPEN_BUDGET.as_secs()
                    )
                } else {
                    format!(
                        "The SSH tunnel did not open in {} seconds: {reason}",
                        SSH_OPEN_BUDGET.as_secs()
                    )
                }
            }
        }
    }
}

impl std::fmt::Display for TunnelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.user_message())
    }
}

impl std::error::Error for TunnelError {}

/// `user@host`, or `host` alone when the ssh config supplies the user.
pub fn ssh_target(cfg: &SshTunnelConfig) -> String {
    match cfg.user.as_deref().map(str::trim).filter(|u| !u.is_empty()) {
        Some(user) => format!("{}@{}", user, cfg.host),
        None => cfg.host.clone(),
    }
}

/// The exact argument list for one tunnel.
///
/// Pure, so the whole command line is testable without a server. The order is
/// fixed and asserted, because a flag that moves after the target would be
/// read by `ssh` as a remote command instead of an option.
pub fn ssh_args(
    cfg: &SshTunnelConfig,
    db_host: &str,
    db_port: u16,
    local_port: u16,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();

    // No remote command: this process only forwards.
    args.push("-N".to_string());
    args.push("-L".to_string());
    args.push(format!("127.0.0.1:{local_port}:{db_host}:{db_port}"));

    // Fail instead of running a tunnel that forwards nothing.
    args.push("-o".to_string());
    args.push("ExitOnForwardFailure=yes".to_string());
    // Notice a dead bastion instead of holding a pool open on a dead socket.
    args.push("-o".to_string());
    args.push("ServerAliveInterval=15".to_string());
    args.push("-o".to_string());
    args.push("ServerAliveCountMax=3".to_string());
    args.push("-o".to_string());
    args.push("ConnectTimeout=10".to_string());

    // D2. ON records an UNKNOWN key on the first connection; a CHANGED key
    // still fails. OFF adds nothing, so whatever `~/.ssh/config` sets applies.
    if cfg.accept_new_host_keys {
        args.push("-o".to_string());
        args.push("StrictHostKeyChecking=accept-new".to_string());
    }

    let key_path = cfg
        .key_path
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty());

    if cfg.auth == SshAuth::KeyFile {
        if let Some(path) = key_path {
            args.push("-i".to_string());
            args.push(path.to_string());
            // Offer only this key, so an agent with many keys cannot use up
            // the server's authentication attempts before this one is tried.
            args.push("-o".to_string());
            args.push("IdentitiesOnly=yes".to_string());
        }
    }

    // A secret means a prompt is coming, and a prompt needs the askpass helper
    // (Phase 6). BatchMode would refuse that prompt, so it is only set where
    // no prompt can happen — otherwise `ssh` would fail instead of ask.
    if needs_askpass(cfg) {
        args.push("-o".to_string());
        args.push("NumberOfPasswordPrompts=1".to_string());
    } else {
        args.push("-o".to_string());
        args.push("BatchMode=yes".to_string());
    }

    args.push("-p".to_string());
    args.push(cfg.port.to_string());

    // Last: everything after the target is a remote command.
    args.push(ssh_target(cfg));
    args
}

/// True when `ssh` may stop and ask for a secret, so the child needs the
/// askpass helper and must NOT run with `BatchMode=yes`.
pub fn needs_askpass(cfg: &SshTunnelConfig) -> bool {
    match cfg.auth {
        SshAuth::Agent => false,
        // A key with no passphrase needs nothing; a key with one needs a prompt.
        SshAuth::KeyFile => !cfg.secret.is_empty(),
        SshAuth::Password => true,
    }
}

/// Reserve a free loopback port.
///
/// Bind, read the port, then let the listener go, so `ssh` can take it. The
/// gap between the two is a race that `open` covers with one retry.
pub fn pick_local_port() -> io::Result<u16> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

/// Open a tunnel to `db_host:db_port` through the configured SSH server.
///
/// Returns only when the local port accepts a connection. `ssh` binds that
/// listener AFTER authentication succeeds, so an accepted connection means the
/// tunnel is usable — there is no need to guess a settle time.
pub async fn open(
    cfg: &SshTunnelConfig,
    db_host: &str,
    db_port: u16,
) -> Result<SshTunnel, TunnelError> {
    match open_once(cfg, db_host, db_port).await {
        // The port we reserved was taken between the bind and the spawn.
        // A second draw from the ephemeral range is almost certainly free.
        Err(TunnelError::LocalPortInUse) => {
            log::warn!("The SSH tunnel's local port was taken; trying another one");
            open_once(cfg, db_host, db_port).await
        }
        other => other,
    }
}

async fn open_once(
    cfg: &SshTunnelConfig,
    db_host: &str,
    db_port: u16,
) -> Result<SshTunnel, TunnelError> {
    let local_port =
        pick_local_port().map_err(|e| TunnelError::LocalPortUnavailable(e.to_string()))?;
    let args = ssh_args(cfg, db_host, db_port, local_port);
    log::debug!("Opening an SSH tunnel: {} {}", SSH_BINARY, args.join(" "));

    let mut command = Command::new(SSH_BINARY);
    command
        .args(&args)
        // No terminal, so `ssh` cannot stop on a prompt we cannot answer.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        // A dropped tunnel must never leave an orphan `ssh` behind.
        .kill_on_drop(true);
    // The environment is INHERITED on purpose: `ssh` needs HOME to find
    // ~/.ssh/config, SSH_AUTH_SOCK to reach the agent, and PATH for ProxyJump
    // helpers. Phase 6 adds the askpass variables here.

    let mut child = command
        .spawn()
        .map_err(|e| TunnelError::SpawnFailed(e.to_string()))?;

    let stderr_tail = Arc::new(Mutex::new(String::new()));
    if let Some(stderr) = child.stderr.take() {
        let sink = Arc::clone(&stderr_tail);
        tokio::spawn(async move { drain_stderr(stderr, sink).await });
    }

    let ready = tokio::time::timeout(SSH_OPEN_BUDGET, async {
        loop {
            tokio::select! {
                // `Child::wait` is cancel safe, so losing the race costs
                // nothing and the next turn of the loop re-arms it.
                _ = child.wait() => return false,
                _ = tokio::time::sleep(READY_POLL_INTERVAL) => {}
            }
            if TcpStream::connect(("127.0.0.1", local_port)).await.is_ok() {
                return true;
            }
        }
    })
    .await;

    match ready {
        Ok(true) => Ok(SshTunnel {
            child,
            local_port,
            stderr_tail,
        }),
        Ok(false) => {
            let tail = stderr_tail.lock().map(|t| t.clone()).unwrap_or_default();
            Err(classify_exit(&tail, cfg))
        }
        Err(_elapsed) => {
            // Still running, but nothing is listening. Stop it, or it stays
            // for the life of the app with no pool attached.
            let _ = child.start_kill();
            let _ = tokio::time::timeout(CLOSE_BUDGET, child.wait()).await;
            let tail = stderr_tail.lock().map(|t| t.clone()).unwrap_or_default();
            Err(TunnelError::TimedOut { tail })
        }
    }
}

async fn drain_stderr(stderr: tokio::process::ChildStderr, sink: Arc<Mutex<String>>) {
    let mut reader = BufReader::new(stderr);
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {
                let text = String::from_utf8_lossy(&line);
                if let Ok(mut tail) = sink.lock() {
                    tail.push_str(&text);
                    trim_tail(&mut tail, STDERR_TAIL_LIMIT);
                }
            }
        }
    }
}

/// Keep the LAST `limit` bytes, starting at a whole line where possible.
fn trim_tail(tail: &mut String, limit: usize) {
    if tail.len() <= limit {
        return;
    }
    let mut cut = tail.len() - limit;
    while cut < tail.len() && !tail.is_char_boundary(cut) {
        cut += 1;
    }
    if let Some(newline) = tail[cut..].find('\n') {
        cut += newline + 1;
    }
    *tail = tail[cut..].to_string();
}

/// The last line that says something, for a message the user reads.
fn last_meaningful_line(tail: &str) -> String {
    tail.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .next_back()
        .unwrap_or("")
        .to_string()
}

/// The reason a POOL failed, when the tunnel itself is healthy.
///
/// `ExitOnForwardFailure` covers the LOCAL bind only. When the SSH server
/// cannot reach the database, `ssh` stays alive, accepts the local connection,
/// and then writes `channel N: open failed: connect failed: ...` before it
/// closes the channel — so the pool reports a plain socket error and the real
/// reason is only in the tail. Returns `None` when the tail says nothing about
/// a forward, so the caller keeps the pool's own message.
pub fn forward_failure(tail: &str, db_host: &str, db_port: u16) -> Option<String> {
    if tail.to_lowercase().contains("open failed") {
        Some(format!(
            "The SSH server could not reach {db_host}:{db_port}."
        ))
    } else {
        None
    }
}

/// Turn the child's `stderr` into one reason.
///
/// The local-bind case is tested FIRST because it is the only retryable one;
/// `ssh` reports it together with "Could not request local forwarding", which
/// on its own says nothing about the cause.
pub fn classify_exit(tail: &str, cfg: &SshTunnelConfig) -> TunnelError {
    let lower = tail.to_lowercase();
    let target = ssh_target(cfg);

    if lower.contains("address already in use") || lower.contains("cannot listen to port") {
        return TunnelError::LocalPortInUse;
    }
    if lower.contains("permission denied")
        || lower.contains("too many authentication failures")
        || lower.contains("no supported authentication methods")
    {
        return TunnelError::AuthFailed { target };
    }
    if lower.contains("host key verification failed")
        || lower.contains("remote host identification has changed")
        || lower.contains("no matching host key type found")
    {
        return TunnelError::HostKeyRejected { target };
    }
    if lower.contains("could not resolve hostname") || lower.contains("name or service not known") {
        return TunnelError::HostNotFound {
            host: cfg.host.clone(),
        };
    }
    if lower.contains("connection refused")
        || lower.contains("connection timed out")
        || lower.contains("operation timed out")
        || lower.contains("no route to host")
        || lower.contains("network is unreachable")
    {
        return TunnelError::HostUnreachable {
            host: cfg.host.clone(),
            port: cfg.port,
        };
    }
    TunnelError::ExitedEarly {
        tail: tail.to_string(),
    }
}

/// The command line, the port picker, the tail and the error table — all
/// without a server.
#[cfg(test)]
mod ssh_tunnel_tests {
    use super::*;

    fn agent(user: Option<&str>) -> SshTunnelConfig {
        SshTunnelConfig {
            host: "bastion.example.com".to_string(),
            port: 2222,
            user: user.map(str::to_string),
            auth: SshAuth::Agent,
            key_path: None,
            secret: String::new(),
            accept_new_host_keys: false,
        }
    }

    fn args_of(cfg: &SshTunnelConfig) -> Vec<String> {
        ssh_args(cfg, "db.internal", 5433, 61234)
    }

    fn has(args: &[String], value: &str) -> bool {
        args.iter().any(|a| a == value)
    }

    /// The whole command line for the common case, asserted as one list. A
    /// `contains` test would pass on a line with the flags in a broken order;
    /// this one cannot.
    #[test]
    fn the_agent_command_line_is_exact() {
        assert_eq!(
            args_of(&agent(Some("deploy"))),
            vec![
                "-N",
                "-L",
                "127.0.0.1:61234:db.internal:5433",
                "-o",
                "ExitOnForwardFailure=yes",
                "-o",
                "ServerAliveInterval=15",
                "-o",
                "ServerAliveCountMax=3",
                "-o",
                "ConnectTimeout=10",
                "-o",
                "BatchMode=yes",
                "-p",
                "2222",
                "deploy@bastion.example.com",
            ]
        );
    }

    /// `ssh` reads everything after the target as a remote command, so a flag
    /// that drifted past it would be sent to the server instead of used.
    #[test]
    fn the_target_is_the_last_argument_in_every_mode() {
        for cfg in [
            agent(Some("deploy")),
            agent(None),
            key_file(Some("/k"), ""),
            key_file(Some("/k"), "passphrase"),
            password("pw"),
        ] {
            let args = args_of(&cfg);
            assert_eq!(
                args.last().map(String::as_str),
                Some(ssh_target(&cfg).as_str()),
                "the target must be last for {:?}",
                cfg.auth
            );
        }
    }

    /// With no user the ssh config chooses one, so the target is the bare host
    /// — and a stray `@` would make `ssh` look for a user named "".
    #[test]
    fn a_missing_or_blank_user_leaves_the_target_bare() {
        assert_eq!(ssh_target(&agent(None)), "bastion.example.com");
        assert_eq!(ssh_target(&agent(Some("   "))), "bastion.example.com");
        assert_eq!(ssh_target(&agent(Some("deploy"))), "deploy@bastion.example.com");
    }

    /// D2. The flag is present only when the user turned the checkbox on.
    #[test]
    fn accept_new_host_keys_adds_exactly_one_option() {
        let mut cfg = agent(Some("deploy"));
        assert!(
            !has(&args_of(&cfg), "StrictHostKeyChecking=accept-new"),
            "strict host keys are the default"
        );

        cfg.accept_new_host_keys = true;
        let args = args_of(&cfg);
        assert!(has(&args, "StrictHostKeyChecking=accept-new"));
        assert!(
            !args.iter().any(|a| a.starts_with("StrictHostKeyChecking=") && a != "StrictHostKeyChecking=accept-new"),
            "no second, weaker setting: {args:?}"
        );
    }

    fn key_file(path: Option<&str>, secret: &str) -> SshTunnelConfig {
        SshTunnelConfig {
            auth: SshAuth::KeyFile,
            key_path: path.map(str::to_string),
            secret: secret.to_string(),
            ..agent(Some("deploy"))
        }
    }

    fn password(secret: &str) -> SshTunnelConfig {
        SshTunnelConfig {
            auth: SshAuth::Password,
            secret: secret.to_string(),
            ..agent(Some("deploy"))
        }
    }

    /// A key with no passphrase can never prompt, so `BatchMode` is safe and
    /// makes a hang impossible.
    #[test]
    fn a_key_file_without_a_passphrase_stays_in_batch_mode() {
        let args = args_of(&key_file(Some("/Users/x/.ssh/id_ed25519"), ""));
        assert!(has(&args, "-i"));
        assert!(has(&args, "/Users/x/.ssh/id_ed25519"));
        assert!(has(&args, "IdentitiesOnly=yes"));
        assert!(has(&args, "BatchMode=yes"));
        assert!(!has(&args, "NumberOfPasswordPrompts=1"));
    }

    /// `BatchMode=yes` REFUSES every prompt, so leaving it on would make the
    /// askpass helper (Phase 6) dead code and the password modes impossible.
    #[test]
    fn a_secret_removes_batch_mode_and_allows_one_prompt() {
        for cfg in [key_file(Some("/k"), "passphrase"), password("pw")] {
            let args = args_of(&cfg);
            assert!(
                !has(&args, "BatchMode=yes"),
                "{:?} must be able to answer a prompt: {args:?}",
                cfg.auth
            );
            assert!(has(&args, "NumberOfPasswordPrompts=1"), "{args:?}");
        }
    }

    /// Password auth uses no key, so `-i` and `IdentitiesOnly` must not appear
    /// — `IdentitiesOnly=yes` with no `-i` would offer no identity at all.
    #[test]
    fn password_auth_offers_no_identity_file() {
        let args = args_of(&password("pw"));
        assert!(!has(&args, "-i"), "{args:?}");
        assert!(!has(&args, "IdentitiesOnly=yes"), "{args:?}");
    }

    /// Key-file mode with an empty path is a half-filled form. Emitting
    /// `IdentitiesOnly=yes` alone would stop the agent AND supply no key, so
    /// the connection could not authenticate at all.
    #[test]
    fn key_file_mode_without_a_path_adds_no_identity_options() {
        for cfg in [key_file(None, ""), key_file(Some("   "), "")] {
            let args = args_of(&cfg);
            assert!(!has(&args, "-i"), "{args:?}");
            assert!(!has(&args, "IdentitiesOnly=yes"), "{args:?}");
        }
    }

    #[test]
    fn needs_askpass_follows_the_mode_and_the_secret() {
        assert!(!needs_askpass(&agent(Some("deploy"))));
        assert!(!needs_askpass(&key_file(Some("/k"), "")));
        assert!(needs_askpass(&key_file(Some("/k"), "passphrase")));
        assert!(needs_askpass(&password("pw")));
        // A password mode with no secret yet still needs the prompt path: the
        // helper answers with an empty string and `ssh` reports the failure,
        // instead of `ssh` hanging with no way to fail.
        assert!(needs_askpass(&password("")));
    }

    /// The forward must bind the LOOPBACK only. `-L <port>:host:port` would
    /// bind every interface and put the database on the local network.
    #[test]
    fn the_forward_binds_only_the_loopback() {
        let args = args_of(&agent(Some("deploy")));
        let spec = args
            .iter()
            .position(|a| a == "-L")
            .and_then(|i| args.get(i + 1))
            .expect("-L has a value");
        assert_eq!(spec, "127.0.0.1:61234:db.internal:5433");
    }

    /// The port must really be free after the picker lets it go, or `ssh`
    /// could never bind it.
    #[test]
    fn pick_local_port_returns_a_port_a_second_bind_accepts() {
        let port = pick_local_port().expect("pick a port");
        assert_ne!(port, 0);
        let again = TcpListener::bind(("127.0.0.1", port))
            .unwrap_or_else(|e| panic!("port {port} was not released: {e}"));
        assert_eq!(again.local_addr().expect("addr").port(), port);
    }

    #[test]
    fn pick_local_port_does_not_repeat_itself_immediately() {
        let a = pick_local_port().expect("a");
        let _hold = TcpListener::bind(("127.0.0.1", a)).expect("hold a");
        let b = pick_local_port().expect("b");
        assert_ne!(a, b, "a held port must not be handed out again");
    }

    fn tail_of(lines: &[&str]) -> String {
        let mut s = lines.join("\n");
        s.push('\n');
        s
    }

    /// One fixture per branch, each taken from real `ssh` output.
    #[test]
    fn the_error_table_maps_every_reason() {
        let cfg = agent(Some("root"));
        let cases: Vec<(&str, TunnelError)> = vec![
            (
                "root@bastion.example.com: Permission denied (publickey).",
                TunnelError::AuthFailed { target: "root@bastion.example.com".to_string() },
            ),
            (
                "Host key verification failed.",
                TunnelError::HostKeyRejected { target: "root@bastion.example.com".to_string() },
            ),
            (
                "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@",
                TunnelError::HostKeyRejected { target: "root@bastion.example.com".to_string() },
            ),
            (
                "ssh: Could not resolve hostname bastion.example.com: nodename nor servname provided",
                TunnelError::HostNotFound { host: "bastion.example.com".to_string() },
            ),
            (
                "ssh: connect to host bastion.example.com port 2222: Connection refused",
                TunnelError::HostUnreachable { host: "bastion.example.com".to_string(), port: 2222 },
            ),
            (
                "ssh: connect to host bastion.example.com port 2222: Operation timed out",
                TunnelError::HostUnreachable { host: "bastion.example.com".to_string(), port: 2222 },
            ),
            (
                "bind [127.0.0.1]:61234: Address already in use",
                TunnelError::LocalPortInUse,
            ),
        ];

        for (line, expected) in cases {
            assert_eq!(
                classify_exit(&tail_of(&[line]), &cfg),
                expected,
                "for {line:?}"
            );
        }

        // Anything the table does not know keeps the raw text, so the user is
        // never told "unknown error" when `ssh` said something useful.
        let odd = tail_of(&["ssh: something nobody has seen before"]);
        assert_eq!(classify_exit(&odd, &cfg), TunnelError::ExitedEarly { tail: odd });
    }

    /// The local-bind case is checked FIRST, because it is the only one `open`
    /// retries. This input is synthetic: it holds two reasons at once so the
    /// two possible orders give different answers.
    #[test]
    fn a_local_bind_failure_outranks_an_auth_failure() {
        let both = tail_of(&[
            "root@bastion.example.com: Permission denied (publickey).",
            "bind [127.0.0.1]:61234: Address already in use",
        ]);
        assert_eq!(classify_exit(&both, &agent(Some("root"))), TunnelError::LocalPortInUse);

        // And the same two lines the other way round, so the answer comes from
        // the rule and not from the order of the input.
        let swapped = tail_of(&[
            "bind [127.0.0.1]:61234: Address already in use",
            "root@bastion.example.com: Permission denied (publickey).",
        ]);
        assert_eq!(classify_exit(&swapped, &agent(Some("root"))), TunnelError::LocalPortInUse);
    }

    /// The host-key sentence must name the checkbox and give the Terminal
    /// command, or the user has no way out (D2).
    #[test]
    fn the_host_key_message_names_the_checkbox_and_the_way_out() {
        let text = TunnelError::HostKeyRejected {
            target: "root@bastion.example.com".to_string(),
        }
        .user_message();
        assert!(text.contains("Accept new host keys"), "got {text}");
        assert!(text.contains("ssh root@bastion.example.com"), "got {text}");
    }

    #[test]
    fn the_other_messages_name_the_host_they_are_about() {
        assert_eq!(
            TunnelError::AuthFailed { target: "root@bastion".to_string() }.user_message(),
            "SSH authentication failed for root@bastion."
        );
        assert_eq!(
            TunnelError::HostNotFound { host: "bastion".to_string() }.user_message(),
            "SSH host bastion not found."
        );
        assert_eq!(
            TunnelError::HostUnreachable { host: "bastion".to_string(), port: 2222 }.user_message(),
            "SSH host bastion:2222 did not answer."
        );
    }

    /// An unknown failure must still say what `ssh` said. The LAST line is the
    /// reason; the lines before it are usually debug noise.
    #[test]
    fn an_unknown_failure_reports_the_last_line_of_stderr() {
        let tail = tail_of(&["debug1: something", "ssh: the real reason", ""]);
        let text = TunnelError::ExitedEarly { tail }.user_message();
        assert_eq!(text, "SSH tunnel failed: ssh: the real reason");

        let silent = TunnelError::ExitedEarly { tail: String::new() }.user_message();
        assert_eq!(silent, "The SSH tunnel stopped without a reason.");
    }

    /// The tail keeps the END of the output, because that is where the reason
    /// is, and it starts at a whole line so no message is cut in half.
    #[test]
    fn trim_tail_keeps_the_end_and_starts_at_a_line() {
        let mut tail = String::new();
        for i in 0..500 {
            tail.push_str(&format!("debug1: line {i}\n"));
        }
        tail.push_str("ssh: the real reason\n");
        trim_tail(&mut tail, 64);

        assert!(tail.len() <= 64, "kept {} bytes", tail.len());
        assert!(tail.ends_with("ssh: the real reason\n"), "got {tail:?}");
        assert!(!tail.starts_with("bug1"), "a line was cut in half: {tail:?}");
        assert!(tail.starts_with("debug1: line "), "got {tail:?}");
    }

    /// A tail with a multi-byte character must not panic the trim. The cut
    /// lands inside the emoji unless the code walks to a character boundary.
    #[test]
    fn trim_tail_survives_a_multi_byte_character_at_the_cut() {
        let mut tail = format!("{}\u{1F600}abcdefgh\n", "x".repeat(40));
        trim_tail(&mut tail, 12);
        assert!(tail.len() <= 12, "kept {} bytes", tail.len());
    }
}

/// `open` against a real `/usr/bin/ssh`.
///
/// The first test needs no server: a refused loopback port makes `ssh` stop at
/// once, which exercises the spawn, the stderr drain, the error table and the
/// promise that no child is left behind. The live tests need the user's
/// bastion and are `#[ignore]`d.
#[cfg(test)]
mod ssh_tunnel_process_tests {
    use super::*;

    /// Put a name nothing can resolve in the FORWARD, not in the SSH target.
    /// `ssh` never looks it up — the bastion would — so it is a safe, unique
    /// marker to find a leftover child by.
    const ORPHAN_MARKER: &str = "pharos-orphan-check.invalid";

    fn ssh_children_with(marker: &str) -> String {
        let output = std::process::Command::new("/usr/bin/pgrep")
            .args(["-fl", marker])
            .output()
            .expect("pgrep must run");
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    fn a_closed_loopback_port() -> u16 {
        pick_local_port().expect("a free port that nothing listens on")
    }

    /// A refused SSH port must fail with the reason, well inside the budget,
    /// and leave nothing running.
    #[test]
    fn a_refused_ssh_port_fails_fast_and_leaves_no_child() {
        let closed = a_closed_loopback_port();
        let cfg = SshTunnelConfig {
            host: "127.0.0.1".to_string(),
            port: closed,
            user: Some("nobody".to_string()),
            auth: SshAuth::Agent,
            key_path: None,
            secret: String::new(),
            accept_new_host_keys: false,
        };

        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        let started = std::time::Instant::now();
        let error = rt.block_on(open(&cfg, ORPHAN_MARKER, 5432));
        let elapsed = started.elapsed();

        assert_eq!(
            error.err(),
            Some(TunnelError::HostUnreachable {
                host: "127.0.0.1".to_string(),
                port: closed
            }),
            "a refused port must be reported as such"
        );
        assert!(
            elapsed < SSH_OPEN_BUDGET,
            "a refused port must not wait out the {}s budget; took {elapsed:?}",
            SSH_OPEN_BUDGET.as_secs()
        );
        assert_eq!(
            ssh_children_with(ORPHAN_MARKER),
            "",
            "a failed open left an ssh child behind"
        );
    }
}

/// The user's bastion. Read the target from the environment with the same
/// `env_or` pattern as `postgres::live_prefer_tests`; the credentials live in
/// `tasks/live-test.env` and never in this file.
///
///   set -a; source tasks/live-test.env; set +a
///   cargo test --release live_tunnel -- --ignored --nocapture
#[cfg(test)]
mod live_tunnel_tests {
    use super::*;
    use crate::db::postgres::create_pool;
    use crate::models::{ConnectionConfig, SslMode};

    fn env_or(key: &str, fallback: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| fallback.to_string())
    }

    fn live_tunnel() -> SshTunnelConfig {
        SshTunnelConfig {
            host: env_or("PHAROS_TEST_SSH_HOST", "localhost"),
            port: env_or("PHAROS_TEST_SSH_PORT", "22").parse().unwrap_or(22),
            user: std::env::var("PHAROS_TEST_SSH_USER")
                .ok()
                .filter(|u| !u.is_empty()),
            auth: SshAuth::Agent,
            key_path: None,
            secret: String::new(),
            accept_new_host_keys: false,
        }
    }

    fn db_host() -> String {
        env_or("PHAROS_TEST_PG_HOST", "localhost")
    }

    fn db_port() -> u16 {
        env_or("PHAROS_TEST_PG_PORT", "5432").parse().unwrap_or(5432)
    }

    /// The pool talks to the LOCAL end of the tunnel. Phase 3 builds the same
    /// effective config in `connect_postgres`.
    fn config_through(local_port: u16) -> ConnectionConfig {
        ConnectionConfig {
            id: "live-tunnel".to_string(),
            name: "live-tunnel".to_string(),
            host: "127.0.0.1".to_string(),
            port: local_port,
            database: env_or("PHAROS_TEST_PG_DB", "postgres"),
            username: env_or("PHAROS_TEST_PG_USER", "postgres"),
            password: std::env::var("PHAROS_TEST_PG_PASSWORD").unwrap_or_default(),
            ssl_mode: SslMode::Prefer,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: None,
        }
    }

    fn ssh_children_on(local_port: u16) -> String {
        let output = std::process::Command::new("/usr/bin/pgrep")
            .args(["-fl", &format!("ssh -N -L 127.0.0.1:{local_port}:")])
            .output()
            .expect("pgrep must run");
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    /// The whole path: open, query through it, close, nothing left running.
    #[test]
    #[ignore = "needs the user's bastion and 1Password agent; see tasks/live-test.env"]
    fn a_tunnel_carries_a_query_and_closes_cleanly() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let started = std::time::Instant::now();
            let tunnel = open(&live_tunnel(), &db_host(), db_port())
                .await
                .unwrap_or_else(|e| panic!("the tunnel did not open: {e}"));
            let local_port = tunnel.local_port;
            println!(
                "tunnel up on 127.0.0.1:{local_port} in {:?}",
                started.elapsed()
            );

            // The positive control for the assertion at the end: prove the
            // check can SEE a live child before it is used to prove there is
            // none.
            let running = ssh_children_on(local_port);
            assert!(
                !running.is_empty(),
                "pgrep cannot see the running tunnel, so its later silence proves nothing"
            );

            let pool = create_pool(&config_through(local_port))
                .await
                .unwrap_or_else(|e| panic!("the pool did not connect through the tunnel: {e}"));
            let row: (i32,) = sqlx::query_as("SELECT 1")
                .fetch_one(&pool)
                .await
                .expect("SELECT 1 through the tunnel");
            assert_eq!(row.0, 1);

            let database: (String,) = sqlx::query_as("SELECT current_database()")
                .fetch_one(&pool)
                .await
                .expect("current_database through the tunnel");
            println!("connected to {}", database.0);

            pool.close().await;
            tunnel.close().await;

            assert_eq!(
                ssh_children_on(local_port),
                "",
                "close left an ssh child behind"
            );
        });
    }

    /// A user the bastion refuses must give the authentication sentence, not a
    /// timeout, and must leave nothing running.
    #[test]
    #[ignore = "needs the user's bastion; see tasks/live-test.env"]
    fn a_refused_user_reports_an_authentication_failure() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let mut cfg = live_tunnel();
            cfg.user = Some("pharos-no-such-user".to_string());

            let started = std::time::Instant::now();
            let error = open(&cfg, &db_host(), db_port())
                .await
                .err()
                .expect("a refused user must not open a tunnel");
            println!("{} (in {:?})", error.user_message(), started.elapsed());

            assert_eq!(
                error,
                TunnelError::AuthFailed {
                    target: format!("pharos-no-such-user@{}", cfg.host)
                }
            );
        });
    }

    /// `kill_on_drop` is the net under every other path: a panic, an early
    /// return, or an `SshTunnel` that nobody closes. Nothing else in the suite
    /// can see it — the failure paths all exit `ssh` first — so it is proved
    /// here, by dropping a LIVE tunnel and looking for the child.
    #[test]
    #[ignore = "needs the user's bastion; see tasks/live-test.env"]
    fn a_dropped_tunnel_takes_its_child_with_it() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let tunnel = open(&live_tunnel(), &db_host(), db_port())
                .await
                .unwrap_or_else(|e| panic!("the tunnel did not open: {e}"));
            let local_port = tunnel.local_port;
            assert!(
                !ssh_children_on(local_port).is_empty(),
                "the child must be visible before the drop, or the check proves nothing"
            );

            drop(tunnel); // no close(), as a panic or an early return would do

            // The kill is a signal, so the process needs a moment to go.
            for _ in 0..40 {
                if ssh_children_on(local_port).is_empty() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            panic!("a dropped tunnel left {}", ssh_children_on(local_port));
        });
    }

    /// `ExitOnForwardFailure` covers the LOCAL bind only. When the bastion
    /// cannot reach the database the tunnel opens, the pool then fails, and
    /// the reason is only in the stderr tail — which is what Phase 3 reads.
    #[test]
    #[ignore = "needs the user's bastion; see tasks/live-test.env"]
    fn a_database_the_bastion_cannot_reach_leaves_its_reason_in_the_tail() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            // A port on the real database host that nothing listens on.
            let tunnel = open(&live_tunnel(), &db_host(), 5599)
                .await
                .unwrap_or_else(|e| panic!("the tunnel itself must still open: {e}"));

            let pool_result = create_pool(&config_through(tunnel.local_port)).await;
            assert!(pool_result.is_err(), "the pool must not connect to a closed port");

            let tail = tunnel.stderr_tail();
            println!("stderr tail: {tail}");
            assert!(
                tail.to_lowercase().contains("open failed"),
                "Phase 3 reads this tail for 'open failed'; got {tail:?}"
            );

            tunnel.close().await;
        });
    }
}
