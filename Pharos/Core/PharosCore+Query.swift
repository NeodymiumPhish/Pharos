import Foundation
import CPharosCore

// MARK: - Query Operations

extension PharosCore {

    /// Format SQL with PostgreSQL conventions (uppercase keywords, 2-space indent).
    /// The FFI call itself is synchronous (sqlformat is CPU-only, no IO), but it can
    /// chew tens of ms on large queries — wrap it so callers can keep the UI responsive.
    /// This does not throw: the caller wants formatted text or the text it gave.
    /// The error check is still necessary, because the `ffi_sync!` macro turns a
    /// panic into `{"error": ...}` — without it, formatting would replace the
    /// user's query with that object.
    static func formatSQL(_ sql: String) async -> String {
        // Hop off the main actor for the FFI call.
        await Task.detached(priority: .userInitiated) {
            guard let result = sql.withCString({ pharos_format_sql($0) }) else { return sql }
            defer { pharos_free_string(result) }
            let text = String(cString: result)
            guard RustScalarError.message(in: text) == nil else { return sql }
            return text
        }.value
    }

    /// Execute a SQL query.
    static func executeQuery(
        connectionId: String,
        sql: String,
        queryId: String? = nil,
        limit: Int32 = 1000,
        schema: String? = nil,
        source: String? = nil
    ) async throws -> QueryResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                sql.withCString { cSql in
                    withOptionalCString(queryId) { cQid in
                        withOptionalCString(schema) { cSchema in
                            withOptionalCString(source) { cSource in
                                pharos_execute_query(cConn, cSql, cQid, limit, cSchema, cSource, callback, context)
                            }
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

    /// Re-run a statement through a server cursor inside one transaction and
    /// return every row up to `maxRows` as one consistent snapshot. Unlike
    /// `fetchMoreRows`, the rows come from a single execution, so they line
    /// up even without an ORDER BY. Cancellable through `queryId`.
    static func fetchAllRows(
        connectionId: String,
        sql: String,
        queryId: String,
        maxRows: Int64,
        schema: String? = nil
    ) async throws -> QueryResult {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                sql.withCString { cSql in
                    queryId.withCString { cQid in
                        withOptionalCString(schema) { cSchema in
                            pharos_fetch_all_rows(cConn, cSql, cQid, maxRows, cSchema, callback, context)
                        }
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
}
