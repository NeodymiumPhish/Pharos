import Foundation
import CPharosCore

// MARK: - Schema Introspection

extension PharosCore {

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
}
