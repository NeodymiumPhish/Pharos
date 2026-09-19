import Foundation

// MARK: - Connection Config

enum SslMode: String, Codable {
    case disable
    case prefer
    case require
}

// MARK: - SSH Tunnel

/// How the spawned `ssh` proves who we are.
///
/// The raw values match the Rust `SshAuth` enum's camelCase wire form exactly
/// (`pharos-core/src/models/connection.rs`). A value this build does not know
/// makes the whole connection document fail to decode, which is the loud
/// failure we want: an unknown mode must never fall back to a different one.
enum SshAuthMethod: String, Codable {
    case agent
    case keyFile
    case password
}

/// An SSH tunnel for one connection.
///
/// Pharos runs the system `/usr/bin/ssh`, so `~/.ssh/config` supplies anything
/// left out here: `host` may be a `Host` alias, and `user` may be nil.
struct SshTunnelConfig: Codable, Equatable {
    /// The SSH server, or a `Host` alias from `~/.ssh/config`.
    var host: String
    var port: UInt16 = 22
    /// `nil` lets `~/.ssh/config` choose the user.
    var user: String?
    var auth: SshAuthMethod = .agent
    /// Path to a private key, for `.keyFile`.
    var keyPath: String?
    /// The SSH password, or the private key's passphrase. Like
    /// `ConnectionConfig.password` this lives in the Keychain, never in
    /// SQLite; the field carries it to and from the core only.
    var secret: String = ""
    /// Record an UNKNOWN server key on the first connection. A CHANGED key is
    /// still refused, so this never weakens a key that is already known.
    var acceptNewHostKeys: Bool = false

    // Rust skips `user`, `keyPath` and `secret` when they are empty, and a
    // record written before this feature has none of these keys at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user)
        auth = try c.decodeIfPresent(SshAuthMethod.self, forKey: .auth) ?? .agent
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath)
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        acceptNewHostKeys = try c.decodeIfPresent(Bool.self, forKey: .acceptNewHostKeys) ?? false
    }

    init(host: String, port: UInt16 = 22, user: String? = nil,
         auth: SshAuthMethod = .agent, keyPath: String? = nil,
         secret: String = "", acceptNewHostKeys: Bool = false) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.keyPath = keyPath
        self.secret = secret
        self.acceptNewHostKeys = acceptNewHostKeys
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, user, auth, keyPath, secret, acceptNewHostKeys
    }
}

// MARK: - Connection Config

struct ConnectionConfig: Codable, Identifiable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var database: String
    var username: String
    var password: String = ""
    var sslMode: SslMode = .prefer
    var color: String?
    var defaultSchema: String?

    /// Ask the device owner to authenticate (Touch ID, Apple Watch or the login
    /// password) before connecting with this record and before showing its
    /// stored password.
    ///
    /// The gate guards the two places the app ACTS on the password; it does not
    /// change where the password lives. The Keychain item is written and read
    /// exactly as before, so anything else on the machine that can read that
    /// item still can. The flag buys a shoulder-surfing and walk-up barrier, not
    /// storage protection.
    var requiresAuthentication: Bool = false

    /// Reach the database through an SSH tunnel. `nil` is a direct connection,
    /// which is every record written before this feature.
    var sshTunnel: SshTunnelConfig?

    // Custom decoder: Rust skips "password" when empty and "color" when nil,
    // so these keys may be absent in the JSON.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        database = try c.decode(String.self, forKey: .database)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        sslMode = try c.decodeIfPresent(SslMode.self, forKey: .sslMode) ?? .prefer
        color = try c.decodeIfPresent(String.self, forKey: .color)
        defaultSchema = try c.decodeIfPresent(String.self, forKey: .defaultSchema)
        // `decodeIfPresent`, so a record written before the column existed —
        // and any producer that still omits the key — reads back ungated.
        requiresAuthentication = try c.decodeIfPresent(Bool.self, forKey: .requiresAuthentication) ?? false
        // Rust omits the key entirely when there is no tunnel, so absent must
        // mean "direct connection" and not a decode failure.
        sshTunnel = try c.decodeIfPresent(SshTunnelConfig.self, forKey: .sshTunnel)
    }

    init(id: String, name: String, host: String, port: UInt16, database: String,
         username: String, password: String = "", sslMode: SslMode = .prefer,
         color: String? = nil, defaultSchema: String? = nil,
         requiresAuthentication: Bool = false, sshTunnel: SshTunnelConfig? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.sslMode = sslMode
        self.color = color
        self.defaultSchema = defaultSchema
        self.requiresAuthentication = requiresAuthentication
        self.sshTunnel = sshTunnel
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, password, sslMode, color, defaultSchema
        case requiresAuthentication, sshTunnel
    }
}

// MARK: - Equality (drives the connections form's dirty state)

extension ConnectionConfig: Equatable {
    public static func == (a: ConnectionConfig, b: ConnectionConfig) -> Bool {
        a.id == b.id && a.name == b.name && a.host == b.host && a.port == b.port
            && a.database == b.database && a.username == b.username
            && a.password == b.password && a.sslMode == b.sslMode
            && a.color == b.color && a.defaultSchema == b.defaultSchema
            && a.requiresAuthentication == b.requiresAuthentication
            && a.sshTunnel == b.sshTunnel
    }
}

// MARK: - Connection Status

enum ConnectionStatus: String, Codable {
    case disconnected
    case connecting
    case connected
    case error
}

struct ConnectionInfo: Codable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let database: String
    let status: ConnectionStatus
    let error: String?
    let latencyMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, status, error
        case latencyMs = "latency_ms"
    }
}

struct TestConnectionResult: Codable {
    let success: Bool
    let latencyMs: UInt64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case success, error
        case latencyMs = "latency_ms"
    }
}
