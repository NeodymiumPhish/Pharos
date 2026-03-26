import Foundation
import CPharosCore

// MARK: - Connection Operations

extension PharosCore {

    /// Load all connection configurations.
    static func loadConnections() throws -> [ConnectionConfig] {
        try callSync { pharos_load_connections() }
    }

    /// Save a connection configuration.
    static func saveConnection(_ config: ConnectionConfig) throws {
        try callSyncVoid(input: config) { pharos_save_connection($0) }
    }

    /// Delete a connection.
    static func deleteConnection(id: String) throws {
        try callSyncVoid(id: id) { pharos_delete_connection($0) }
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
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(config), as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            jsonStr.withCString { cJson in
                pharos_test_connection(cJson, callback, context)
            }
        }
    }
}
