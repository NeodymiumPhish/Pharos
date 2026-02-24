import Foundation
import CPharosCore

// MARK: - PharosCore

/// Swift bridge to the Rust pharos-core static library.
/// Wraps C FFI functions with type-safe Swift interfaces.
enum PharosCore {

    // MARK: - SQL Formatting

    /// Format SQL with PostgreSQL conventions (uppercase keywords, 2-space indent).
    static func formatSQL(_ sql: String) -> String {
        guard let result = sql.withCString({ pharos_format_sql($0) }) else { return sql }
        defer { pharos_free_string(result) }
        return String(cString: result)
    }

    // MARK: - Synchronous Operations

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

    /// Reorder connections.
    static func reorderConnections(ids: [String]) throws {
        let json = try JSONEncoder.pharos.encode(ids)
        let jsonStr = String(data: json, encoding: .utf8)!
        let error = jsonStr.withCString { pharos_reorder_connections($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }

    /// Load application settings.
    static func loadSettings() throws -> AppSettings {
        guard let ptr = pharos_load_settings() else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        return try JSONDecoder.pharos.decode(AppSettings.self, from: Data(json.utf8))
    }

    /// Save application settings.
    static func saveSettings(_ settings: AppSettings) throws {
        let json = try JSONEncoder.pharos.encode(settings)
        let jsonStr = String(data: json, encoding: .utf8)!
        let error = jsonStr.withCString { pharos_save_settings($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }

    /// Load saved queries.
    static func loadSavedQueries() throws -> [SavedQuery] {
        guard let ptr = pharos_load_saved_queries() else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        return try JSONDecoder.pharos.decode([SavedQuery].self, from: Data(json.utf8))
    }

    /// Create a saved query.
    static func createSavedQuery(_ query: CreateSavedQuery) throws -> SavedQuery {
        let json = try JSONEncoder.pharos.encode(query)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_create_saved_query($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        return try JSONDecoder.pharos.decode(SavedQuery.self, from: Data(result.utf8))
    }

    /// Update a saved query.
    static func updateSavedQuery(_ query: UpdateSavedQuery) throws -> SavedQuery {
        let json = try JSONEncoder.pharos.encode(query)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_update_saved_query($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        return try JSONDecoder.pharos.decode(SavedQuery.self, from: Data(result.utf8))
    }

    /// Delete a saved query.
    static func deleteSavedQuery(id: String) throws -> Bool {
        guard let ptr = id.withCString({ pharos_delete_saved_query($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        return String(cString: ptr) == "true"
    }

    // MARK: - Async Operations

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

    /// Execute a SQL query.
    static func executeQuery(
        connectionId: String,
        sql: String,
        queryId: String? = nil,
        limit: Int32 = 1000,
        schema: String? = nil
    ) async throws -> QueryResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                sql.withCString { cSql in
                    withOptionalCString(queryId) { cQid in
                        withOptionalCString(schema) { cSchema in
                            pharos_execute_query(cConn, cSql, cQid, limit, cSchema, callback, context)
                        }
                    }
                }
            }
        }
    }

    /// Execute a statement (INSERT/UPDATE/DELETE).
    static func executeStatement(connectionId: String, sql: String, schema: String? = nil) async throws -> ExecuteResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                sql.withCString { cSql in
                    withOptionalCString(schema) { cSchema in
                        pharos_execute_statement(cConn, cSql, cSchema, callback, context)
                    }
                }
            }
        }
    }

    /// Fetch more rows for pagination.
    static func fetchMoreRows(
        connectionId: String,
        sql: String,
        limit: Int64,
        offset: Int64,
        schema: String? = nil
    ) async throws -> QueryResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                sql.withCString { cSql in
                    withOptionalCString(schema) { cSchema in
                        pharos_fetch_more_rows(cConn, cSql, limit, offset, cSchema, callback, context)
                    }
                }
            }
        }
    }

    /// Cancel a running query.
    static func cancelQuery(connectionId: String, queryId: String) async throws -> Bool {
        let result: String = try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                queryId.withCString { cQid in
                    pharos_cancel_query(cConn, cQid, callback, context)
                }
            }
        }
        return result == "true"
    }

    /// Validate SQL syntax.
    static func validateSQL(connectionId: String, sql: String, schema: String? = nil) async throws -> ValidationResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                sql.withCString { cSql in
                    withOptionalCString(schema) { cSchema in
                        pharos_validate_sql(cConn, cSql, cSchema, callback, context)
                    }
                }
            }
        }
    }

    /// Get schemas for a connection.
    static func getSchemas(connectionId: String) async throws -> [SchemaInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                pharos_get_schemas(cConn, callback, context)
            }
        }
    }

    /// Get tables for a schema.
    static func getTables(connectionId: String, schema: String) async throws -> [TableInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    pharos_get_tables(cConn, cSchema, callback, context)
                }
            }
        }
    }

    /// Get columns for a table.
    static func getColumns(connectionId: String, schema: String, table: String) async throws -> [ColumnInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    table.withCString { cTable in
                        pharos_get_columns(cConn, cSchema, cTable, callback, context)
                    }
                }
            }
        }
    }

    /// Get all columns for all tables in a schema (batch).
    static func getSchemaColumns(connectionId: String, schema: String) async throws -> [SchemaColumnInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    pharos_get_schema_columns(cConn, cSchema, callback, context)
                }
            }
        }
    }

    /// Analyze a schema (populate row count estimates).
    static func analyzeSchema(connectionId: String, schema: String) async throws -> AnalyzeResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    pharos_analyze_schema(cConn, cSchema, callback, context)
                }
            }
        }
    }

    /// Get indexes for a table.
    static func getTableIndexes(connectionId: String, schema: String, table: String) async throws -> [IndexInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    table.withCString { cTable in
                        pharos_get_table_indexes(cConn, cSchema, cTable, callback, context)
                    }
                }
            }
        }
    }

    /// Generate CREATE TABLE DDL.
    static func generateTableDDL(connectionId: String, schema: String, table: String) async throws -> String {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    table.withCString { cTable in
                        pharos_generate_table_ddl(cConn, cSchema, cTable, callback, context)
                    }
                }
            }
        }
    }

    /// Generate CREATE INDEX DDL.
    static func generateIndexDDL(connectionId: String, schema: String, index: String) async throws -> String {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    index.withCString { cIndex in
                        pharos_generate_index_ddl(cConn, cSchema, cIndex, callback, context)
                    }
                }
            }
        }
    }

    /// Get constraints for a table.
    static func getTableConstraints(connectionId: String, schema: String, table: String) async throws -> [ConstraintInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    table.withCString { cTable in
                        pharos_get_table_constraints(cConn, cSchema, cTable, callback, context)
                    }
                }
            }
        }
    }

    /// Get functions for a schema.
    static func getSchemaFunctions(connectionId: String, schema: String) async throws -> [FunctionInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    pharos_get_schema_functions(cConn, cSchema, callback, context)
                }
            }
        }
    }

    /// Load query history with optional filters.
    static func loadQueryHistory(filter: QueryHistoryFilter = QueryHistoryFilter()) throws -> [QueryHistoryEntry] {
        let json = try JSONEncoder.pharos.encode(filter)
        let jsonStr = String(data: json, encoding: .utf8)!
        guard let ptr = jsonStr.withCString({ pharos_load_query_history($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let result = String(cString: ptr)
        return try JSONDecoder.pharos.decode([QueryHistoryEntry].self, from: Data(result.utf8))
    }

    /// Delete a query history entry.
    static func deleteQueryHistoryEntry(id: String) throws -> Bool {
        guard let ptr = id.withCString({ pharos_delete_query_history_entry($0) }) else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        return String(cString: ptr) == "true"
    }

    /// Clear all query history.
    static func clearQueryHistory() throws {
        let error = pharos_clear_query_history()
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }
}

// MARK: - Async Callback Bridge

/// Type-erased box to carry a callback handler through a void* context pointer.
/// The handler closure captures the generic type and continuation,
/// keeping the C function pointer free of generic parameters.
private class CallbackBox {
    let handler: (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    init(handler: @escaping (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void) {
        self.handler = handler
    }
}

/// Bridge between C callback pattern and Swift async/await.
/// Wraps a C function that takes (callback, context) into an async throwing call.
private func withAsyncCallback<T: Decodable>(
    _ invoke: @escaping (AsyncCallback, UnsafeMutableRawPointer) -> Void
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        let box = CallbackBox { resultJson, errorMsg in
            if let errorMsg {
                let error = String(cString: errorMsg)
                continuation.resume(throwing: PharosCoreError.rustError(error))
            } else if let resultJson {
                let json = String(cString: resultJson)
                do {
                    let decoded = try JSONDecoder.pharos.decode(T.self, from: Data(json.utf8))
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: PharosCoreError.decodingError(json, error))
                }
            } else {
                continuation.resume(throwing: PharosCoreError.nullResult)
            }
        }
        let context = Unmanaged.passRetained(box).toOpaque()

        let callback: AsyncCallback = { ctx, resultJson, errorMsg in
            guard let ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeRetainedValue()
            box.handler(resultJson, errorMsg)
        }

        invoke(callback, context)
    }
}

/// Dummy Decodable type for void-returning async operations.
private struct EmptyResult: Decodable {
    init(from decoder: Decoder) throws {
        // Accept "null" or any value
    }
}

// MARK: - Helpers

/// Call a closure with an optional C string (NULL if nil).
private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let string {
        return string.withCString { body($0) }
    } else {
        return body(nil)
    }
}

// MARK: - JSON Coding

extension JSONDecoder {
    /// Decoder for Rust JSON. No key strategy — models use explicit CodingKeys where needed.
    static let pharos = JSONDecoder()
}

extension JSONEncoder {
    /// Encoder for Rust JSON. No key strategy — models use explicit CodingKeys where needed.
    static let pharos = JSONEncoder()
}

// MARK: - Errors

enum PharosCoreError: LocalizedError {
    case rustError(String)
    case decodingError(String, Error)
    case nullResult

    var errorDescription: String? {
        switch self {
        case .rustError(let msg): return msg
        case .decodingError(let json, let error): return "Failed to decode: \(error). JSON: \(json.prefix(200))"
        case .nullResult: return "Unexpected null result from Rust"
        }
    }
}
