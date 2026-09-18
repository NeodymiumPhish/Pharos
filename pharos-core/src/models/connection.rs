use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SslMode {
    Disable,
    #[default]
    Prefer,
    Require,
}

impl std::fmt::Display for SslMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SslMode::Disable => write!(f, "disable"),
            SslMode::Prefer => write!(f, "prefer"),
            SslMode::Require => write!(f, "require"),
        }
    }
}

/// How the spawned `ssh` proves who we are.
///
/// `Agent` and `KeyFile` with no passphrase need no secret, so the child runs
/// with `BatchMode=yes` and can never stop on a prompt. `Password`, and
/// `KeyFile` with a passphrase, need the askpass helper.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum SshAuth {
    #[default]
    Agent,
    KeyFile,
    Password,
}

/// An SSH tunnel for one connection. Pharos runs the system `/usr/bin/ssh`, so
/// `~/.ssh/config` supplies anything this struct leaves out: `host` can be a
/// `Host` alias, `user` can be empty, and `ProxyJump` and `IdentityAgent`
/// apply with no code here.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshTunnelConfig {
    /// The SSH server, or a `Host` alias from `~/.ssh/config`.
    pub host: String,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    /// `None` lets the ssh config choose the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    #[serde(default)]
    pub auth: SshAuth,
    /// Path to a private key, for `SshAuth::KeyFile`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_path: Option<String>,
    /// The SSH password, or the private key's passphrase. Like
    /// `ConnectionConfig::password` this lives in the Keychain, never in
    /// SQLite; the field carries it between the front end and the core only.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub secret: String,
    /// When true the child gets `StrictHostKeyChecking=accept-new`, so an
    /// UNKNOWN server key is recorded on the first connection. A CHANGED key
    /// still fails, so the flag never weakens a key that is already known.
    #[serde(default)]
    pub accept_new_host_keys: bool,
}

fn default_ssh_port() -> u16 {
    22
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionConfig {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    /// Password is stored securely in OS keychain, not in this struct for persistence.
    /// This field is only used for transit between frontend and backend.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub password: String,
    #[serde(default)]
    pub ssl_mode: SslMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_schema: Option<String>,
    /// When true the app asks the device owner to authenticate (Touch ID, Apple
    /// Watch or the login password) before it connects with this record and
    /// before it shows the stored password. The gate is a UI decision only —
    /// the password stays in the Keychain exactly as before, and this flag adds
    /// no protection to the stored bytes.
    ///
    /// Not `skip_serializing_if`: Swift decodes it with `decodeIfPresent`, so an
    /// absent key is legal, but always writing the key keeps the false case
    /// visible on the wire.
    #[serde(default)]
    pub requires_authentication: bool,
    /// When set, the core opens an SSH tunnel before it makes the pool and
    /// points the pool at the local end. Absent on the wire when there is no
    /// tunnel, so a connection without one is byte-for-byte unchanged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_tunnel: Option<SshTunnelConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ConnectionStatus {
    Disconnected,
    Connecting,
    Connected,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionInfo {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub status: ConnectionStatus,
    pub error: Option<String>,
    pub latency_ms: Option<u64>,
}

impl From<&ConnectionConfig> for ConnectionInfo {
    fn from(config: &ConnectionConfig) -> Self {
        ConnectionInfo {
            id: config.id.clone(),
            name: config.name.clone(),
            host: config.host.clone(),
            port: config.port,
            database: config.database.clone(),
            status: ConnectionStatus::Disconnected,
            error: None,
            latency_ms: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestConnectionResult {
    pub success: bool,
    pub latency_ms: Option<u64>,
    pub error: Option<String>,
}

/// The SSH tunnel's shape on the wire.
///
/// Swift decodes `SshTunnelConfig` with plain `CodingKeys`, so every key name
/// here is a contract with `Pharos/Models/Connection.swift`. A mis-cased
/// OPTIONAL field fails silently — serde reports it as `None`, which cannot be
/// told from "the caller omitted it" — so the first test decodes a literal
/// document with EVERY key present and asserts each value. A round trip alone
/// could not see a rename, because both sides of it use the same `rename_all`.
#[cfg(test)]
mod ssh_tunnel_json_tests {
    use super::*;

    fn full_document() -> &'static str {
        r#"{
            "host": "bastion.example.com",
            "port": 2222,
            "user": "deploy",
            "auth": "keyFile",
            "keyPath": "/Users/x/.ssh/id_ed25519",
            "secret": "s3cret",
            "acceptNewHostKeys": true
        }"#
    }

    /// Every key present, every value asserted. This is the only test that can
    /// catch a renamed `keyPath` or `acceptNewHostKeys`.
    #[test]
    fn a_full_document_pins_every_key_name() {
        let tunnel: SshTunnelConfig =
            serde_json::from_str(full_document()).expect("the full document must decode");

        assert_eq!(tunnel.host, "bastion.example.com");
        assert_eq!(tunnel.port, 2222, "`port` must not fall back to 22 here");
        assert_eq!(tunnel.user.as_deref(), Some("deploy"), "`user` key name");
        assert_eq!(tunnel.auth, SshAuth::KeyFile, "`auth` value casing");
        assert_eq!(
            tunnel.key_path.as_deref(),
            Some("/Users/x/.ssh/id_ed25519"),
            "`keyPath` key name"
        );
        assert_eq!(tunnel.secret, "s3cret", "`secret` key name");
        assert!(
            tunnel.accept_new_host_keys,
            "`acceptNewHostKeys` key name — false here would read as the default"
        );
    }

    /// A sparse document proves the DEFAULTS, and nothing about the key names.
    /// The defaults matter on their own: the safe tunnel is agent auth, port
    /// 22, strict host keys.
    #[test]
    fn a_sparse_document_takes_the_safe_defaults() {
        let tunnel: SshTunnelConfig =
            serde_json::from_str(r#"{"host":"bastion"}"#).expect("host alone must decode");

        assert_eq!(tunnel.port, 22);
        assert_eq!(tunnel.user, None, "no user lets ~/.ssh/config choose");
        assert_eq!(tunnel.auth, SshAuth::Agent);
        assert_eq!(tunnel.key_path, None);
        assert_eq!(tunnel.secret, "");
        assert!(
            !tunnel.accept_new_host_keys,
            "host keys are strict unless the user turns the checkbox on"
        );
    }

    /// An auth mode this build does not know must fail loudly. Reading it as
    /// the default would run an agent tunnel where the user asked for a key.
    #[test]
    fn an_unknown_auth_value_is_an_error() {
        let result: Result<SshTunnelConfig, _> =
            serde_json::from_str(r#"{"host":"bastion","auth":"kerberos"}"#);
        assert!(result.is_err(), "an unknown auth mode must not decode");

        // The same value in the SNAKE case serde would use without
        // `rename_all` must fail too, which pins the camelCase contract.
        let snake: Result<SshTunnelConfig, _> =
            serde_json::from_str(r#"{"host":"bastion","auth":"key_file"}"#);
        assert!(snake.is_err(), "auth is camelCase on the wire, not snake_case");
    }

    fn config_with(tunnel: Option<SshTunnelConfig>) -> ConnectionConfig {
        ConnectionConfig {
            id: "c1".to_string(),
            name: "c1".to_string(),
            host: "db.internal".to_string(),
            port: 5432,
            database: "nbt".to_string(),
            username: "app".to_string(),
            password: String::new(),
            ssl_mode: SslMode::Prefer,
            color: None,
            default_schema: None,
            requires_authentication: false,
            ssh_tunnel: tunnel,
        }
    }

    /// A connection with no tunnel must be byte-for-byte what it was before
    /// this feature, so an older Swift build and the saved store both stay
    /// valid.
    #[test]
    fn a_connection_without_a_tunnel_writes_no_key_and_reads_back_none() {
        let json = serde_json::to_string(&config_with(None)).expect("serialize");
        assert!(
            !json.contains("sshTunnel"),
            "no tunnel must put no key on the wire, got {json}"
        );

        let legacy: ConnectionConfig = serde_json::from_str(
            r#"{"id":"c1","name":"c1","host":"db","port":5432,"database":"nbt","username":"app"}"#,
        )
        .expect("a document written before this feature must still decode");
        assert!(legacy.ssh_tunnel.is_none());
    }

    /// The tunnel survives the trip in both directions under the key Swift
    /// looks for.
    #[test]
    fn a_tunnel_round_trips_under_the_ssh_tunnel_key() {
        let tunnel: SshTunnelConfig = serde_json::from_str(full_document()).expect("decode");
        let json = serde_json::to_string(&config_with(Some(tunnel.clone()))).expect("serialize");
        assert!(json.contains("\"sshTunnel\""), "got {json}");

        let back: ConnectionConfig = serde_json::from_str(&json).expect("decode");
        assert_eq!(back.ssh_tunnel.as_ref(), Some(&tunnel));
    }

    /// `secret` follows `password`: it is omitted when empty, so a stored
    /// record carries no empty-string secret, but it IS written when set,
    /// because the front end must be able to send a new secret to the core.
    #[test]
    fn the_secret_is_omitted_when_empty_and_present_when_set() {
        let mut tunnel: SshTunnelConfig =
            serde_json::from_str(r#"{"host":"bastion"}"#).expect("decode");
        let empty = serde_json::to_string(&tunnel).expect("serialize");
        assert!(!empty.contains("secret"), "got {empty}");

        tunnel.secret = "s3cret".to_string();
        let filled = serde_json::to_string(&tunnel).expect("serialize");
        assert!(filled.contains("\"secret\":\"s3cret\""), "got {filled}");
    }
}
