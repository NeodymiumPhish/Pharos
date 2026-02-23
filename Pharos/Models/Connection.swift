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
    }

    init(id: String, name: String, host: String, port: UInt16, database: String,
         username: String, password: String = "", sslMode: SslMode = .prefer, color: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.sslMode = sslMode
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, username, password, sslMode, color
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
