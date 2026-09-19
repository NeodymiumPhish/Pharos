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

    /// Persist a new ordering of connections. `ids` is the full ordered list
    /// of connection IDs (top-to-bottom in the UI).
    static func reorderConnections(ids: [String]) throws {
        try callSyncVoid(input: ids) { pharos_reorder_connections($0) }
    }

    /// Connect to a PostgreSQL database.
    static func connect(connectionId: String) async throws -> ConnectionInfo {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                pharos_connect(cId, callback, context)
            }
        }
    }

    /// Connect with a password the user has just typed.
    ///
    /// The core holds it for this process only — it is never written to the
    /// Keychain by this call, and never logged. Storing it is a separate,
    /// deliberate act: a save with `rememberPassword` on.
    ///
    /// Two `withCString` calls nest, so both buffers are alive for the whole of
    /// `pharos_connect_with_password`, which copies them before it spawns.
    static func connect(connectionId: String, password: String) async throws -> ConnectionInfo {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                password.withCString { cPassword in
                    pharos_connect_with_password(cId, cPassword, callback, context)
                }
            }
        }
    }

    /// Connect with an SSH tunnel secret the user has just typed.
    ///
    /// The sibling of `connect(connectionId:password:)`, for the other secret,
    /// and the same contract: the core holds it for this process only, never
    /// writes it to the Keychain here, and never logs it. Storing it is a
    /// separate, deliberate act — a save with the tunnel's `rememberSecret` on.
    ///
    /// It retries the WHOLE connect, tunnel included. The tunnel opens before
    /// the pool, so there is no shorter path back.
    static func connect(connectionId: String, sshSecret: String) async throws -> ConnectionInfo {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                sshSecret.withCString { cSecret in
                    pharos_connect_with_ssh_secret(cId, cSecret, callback, context)
                }
            }
        }
    }

    /// Forget every password typed this run — database passwords and SSH
    /// tunnel secrets alike, because the core keeps both in one process-only
    /// map. The Keychain is untouched.
    /// Returns how many were dropped, so a caller can log a count, never a name.
    @discardableResult
    static func clearSessionPasswords() -> Int {
        Int(pharos_clear_session_passwords())
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
