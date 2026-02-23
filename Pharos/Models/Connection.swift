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
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly
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
