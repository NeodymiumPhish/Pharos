import Foundation
import CPharosCore

// MARK: - Table Metadata

extension PharosCore {

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
}
