import Foundation

// MARK: - Connection Config

/// The `sslmode` the connection asks for.
///
/// The raw values are what libpq reads and what the core's `SslMode` writes,
/// hyphens and all. `verifyCa` / `verifyFull` are the two modes that CHECK the
/// server's certificate, against `sslRootCertPath` or the system trust store.
enum SslMode: String, Codable, CaseIterable {
    case disable
    case prefer
    case require
    case verifyCa = "verify-ca"
    case verifyFull = "verify-full"

    var displayLabel: String {
        switch self {
        case .prefer: return String(localized: "Prefer")
        case .require: return String(localized: "Require")
        case .verifyCa: return String(localized: "Verify CA")
        case .verifyFull: return String(localized: "Verify Full")
        case .disable: return String(localized: "Disable")
        }
    }

    /// The order the Connections Manager's popup shows, weakest guarantee
    /// last, with the two verifying modes beside Require.
    static let formOrder: [SslMode] = [.prefer, .require, .verifyCa, .verifyFull, .disable]

    /// True for the two modes that verify the certificate, so the form can
    /// show the root-certificate row only when it is used.
    var verifiesCertificate: Bool { self == .verifyCa || self == .verifyFull }
}

/// A refusal that came from a read-only connection.
///
/// The core tags SQLSTATE 25006 (`read_only_sql_transaction`) before the
/// message crosses the FFI, because sqlx's own text leaves the code out and
/// the server's wording is localized. Matching the TAG rather than the words
/// is the only reading that holds on a non-English server.
///
/// Pure and Foundation-only, so it can be read by the one funnel every core
/// error passes through (`PharosCoreError.errorDescription`).
enum ReadOnlyConnectionError {

    /// The marker `pharos-core`'s `tagged_db_message` puts in front.
    static let marker = "[SQLSTATE 25006]"

    /// The sentence shown instead. The core's own `require_writable` answers
    /// with the same words, so the two paths read alike.
    static let sentence = String(localized: "This connection is read-only.")

    static func isReadOnly(_ message: String) -> Bool {
        message.contains(marker)
    }

    /// The message to show. A read-only refusal gets the sentence first and
    /// the server's own words after it, so nothing is hidden. Every other
    /// message is returned byte-for-byte.
    static func humanised(_ message: String) -> String {
        guard isReadOnly(message) else { return message }
        let detail = message
            .replacingOccurrences(of: marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? sentence : "\(sentence) \(detail)"
    }
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

    /// Keep this tunnel's `secret` in the keychain.
    ///
    /// The TUNNEL's own switch, separate from
    /// `ConnectionConfig.rememberPassword`: a user may want the database
    /// password kept and the bastion passphrase typed, or the other way round.
    /// Off means the secret is not written, the one already stored is DELETED
    /// on save, and Pharos asks for it the first time the tunnel fails to
    /// authenticate after a launch.
    ///
    /// Defaults to TRUE, because that is what every record written before this
    /// field did — the secret was stored whatever else the record said.
    var rememberSecret: Bool = true

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
        // A tunnel stored before this switch existed has no key here, and its
        // secret WAS remembered. The default has to be that behaviour.
        rememberSecret = try c.decodeIfPresent(Bool.self, forKey: .rememberSecret) ?? true
    }

    init(host: String, port: UInt16 = 22, user: String? = nil,
         auth: SshAuthMethod = .agent, keyPath: String? = nil,
         secret: String = "", acceptNewHostKeys: Bool = false,
         rememberSecret: Bool = true) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.keyPath = keyPath
        self.secret = secret
        self.acceptNewHostKeys = acceptNewHostKeys
        self.rememberSecret = rememberSecret
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, user, auth, keyPath, secret, acceptNewHostKeys, rememberSecret
    }
}

/// A connect failure that was the SSH tunnel refusing our identity.
///
/// `pharos-core` tags `TunnelError::AuthFailed` before the message crosses the
/// FFI (`db::ssh_tunnel::tagged_tunnel_message`), because its own sentence is
/// prose written for a human and names the bastion — nothing a front end can
/// match on. Matching the TAG is the only reading that holds.
///
/// It is the SSH sibling of `ReadOnlyConnectionError`, and deliberately the
/// same shape. Pure and Foundation-only.
enum SshTunnelAuthError {

    /// The marker `pharos-core`'s `tagged_tunnel_message` puts in front.
    static let marker = "[SSH AUTH]"

    /// Was this connect failure the tunnel refusing our identity? True for a
    /// MISSING secret and for a WRONG one alike — both raise the same
    /// question, and both are answered by typing the secret again.
    static func isAuthFailure(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.contains(marker)
    }

    /// The message to SHOW. The marker is for the app, not for the user, so it
    /// is taken off; every other message is returned byte for byte.
    static func humanised(_ message: String) -> String {
        guard isAuthFailure(message) else { return message }
        return message
            .replacingOccurrences(of: marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Open this connection's pool with `default_transaction_read_only=on`.
    /// The server then refuses every write with SQLSTATE 25006, and the core
    /// refuses its own write commands before they start.
    var readOnly: Bool = false

    /// Keep this connection's password in the keychain.
    ///
    /// STORED ONLY as of this slice: nothing reads it yet. Turning it off
    /// needs a password prompt at connect time, which is its own piece of
    /// work; until that lands the password is remembered whatever this says.
    var rememberPassword: Bool = true

    /// Connect to this database when Pharos starts.
    ///
    /// STORED ONLY as of this slice: nothing reads it yet. It needs a launch
    /// sequence that knows about the Touch ID gate and about tunnels.
    var connectOnLaunch: Bool = false

    /// `TimeZone` for this connection's sessions. `nil` or empty falls back to
    /// Settings ▸ Connections ▸ Default time zone, and then to the server's.
    var sessionTimeZone: String?

    /// A PEM root certificate for `verify-ca` and `verify-full`. `nil` uses
    /// the system trust store.
    var sslRootCertPath: String?

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
        // Each `decodeIfPresent ?? default`, so a record written before these
        // columns existed reads back doing exactly what it did: writes
        // allowed, password remembered, no connect at launch, no per-
        // connection time zone, the system trust store.
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        rememberPassword = try c.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? true
        connectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .connectOnLaunch) ?? false
        sessionTimeZone = try c.decodeIfPresent(String.self, forKey: .sessionTimeZone)
        sslRootCertPath = try c.decodeIfPresent(String.self, forKey: .sslRootCertPath)
    }

    init(id: String, name: String, host: String, port: UInt16, database: String,
         username: String, password: String = "", sslMode: SslMode = .prefer,
         color: String? = nil, defaultSchema: String? = nil,
         requiresAuthentication: Bool = false, sshTunnel: SshTunnelConfig? = nil,
         readOnly: Bool = false, rememberPassword: Bool = true,
         connectOnLaunch: Bool = false, sessionTimeZone: String? = nil,
         sslRootCertPath: String? = nil) {
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
        self.readOnly = readOnly
        self.rememberPassword = rememberPassword
        self.connectOnLaunch = connectOnLaunch
        self.sessionTimeZone = sessionTimeZone
        self.sslRootCertPath = sslRootCertPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, password, sslMode, color, defaultSchema
        case requiresAuthentication, sshTunnel
        case readOnly, rememberPassword, connectOnLaunch, sessionTimeZone, sslRootCertPath
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
            && a.readOnly == b.readOnly
            && a.rememberPassword == b.rememberPassword
            && a.connectOnLaunch == b.connectOnLaunch
            && a.sessionTimeZone == b.sessionTimeZone
            && a.sslRootCertPath == b.sslRootCertPath
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
