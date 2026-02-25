import Foundation
import CPharosCore

// MARK: - Connection Operations

extension PharosCore {

    /// Load all connection configurations.
    static func loadConnections() throws -> [ConnectionConfig] {
        guard let ptr = pharos_load_connections() else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        return try JSONDecoder.pharos.decode([ConnectionConfig].self, from: Data(json.utf8))
    }

    /// Save a connection configuration.
    static func saveConnection(_ config: ConnectionConfig) throws {
        let json = try JSONEncoder.pharos.encode(config)
        let jsonStr = String(data: json, encoding: .utf8)!
        let error = jsonStr.withCString { pharos_save_connection($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }

    /// Delete a connection.
    static func deleteConnection(id: String) throws {
        let error = id.withCString { pharos_delete_connection($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }

    /// Connect to a PostgreSQL database.
    static func connect(connectionId: String) async throws -> ConnectionInfo {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                pharos_connect(cId, callback, context)
            }
        }
    }

    /// Disconnect from a PostgreSQL database.
    static func disconnect(connectionId: String) async throws {
        let _: EmptyResult = try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                pharos_disconnect(cId, callback, context)
            }
        }
    }

    /// Test a connection configuration.
    static func testConnection(_ config: ConnectionConfig) async throws -> TestConnectionResult {
        let json = try JSONEncoder.pharos.encode(config)
        let jsonStr = String(data: json, encoding: .utf8)!
        return try await withAsyncCallback { callback, context in
            jsonStr.withCString { cJson in
                pharos_test_connection(cJson, callback, context)
            }
        }
    }
}
