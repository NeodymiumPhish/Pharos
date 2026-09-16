import Foundation

// MARK: - Connection Config

enum SslMode: String, Codable {
    case disable
    case prefer
    case require
}

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
    }

    init(id: String, name: String, host: String, port: UInt16, database: String,
         username: String, password: String = "", sslMode: SslMode = .prefer,
         color: String? = nil, defaultSchema: String? = nil,
         requiresAuthentication: Bool = false) {
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, password, sslMode, color, defaultSchema
        case requiresAuthentication
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
