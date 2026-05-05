import Foundation
import CPharosCore

// MARK: - Table Operations

extension PharosCore {

    /// Clone a table structure (with optional data).
    static func cloneTable(connectionId: String, options: CloneTableOptions) async throws -> CloneTableResult {
        let json = try JSONEncoder.pharos.encode(options)
        let jsonStr = String(decoding: json, as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                jsonStr.withCString { cJson in
                    pharos_clone_table(cConn, cJson, callback, context)
                }
            }
        }
    }

    /// Export table data to a file.
    static func exportTable(connectionId: String, options: ExportTableOptions) async throws -> ExportTableResult {
        let json = try JSONEncoder.pharos.encode(options)
        let jsonStr = String(decoding: json, as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                jsonStr.withCString { cJson in
                    pharos_export_table(cConn, cJson, callback, context)
                }
            }
        }
    }

    /// Import CSV data into a table.
    static func importCsv(connectionId: String, options: ImportCsvOptions) async throws -> ImportCsvResult {
        let json = try JSONEncoder.pharos.encode(options)
        let jsonStr = String(decoding: json, as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                jsonStr.withCString { cJson in
                    pharos_import_csv(cConn, cJson, callback, context)
                }
            }
        }
    }

    /// Read live row count for an in-progress import. Returns nil if no active import.
    static func getImportProgress(connectionId: String, schema: String, table: String) -> Int64? {
        let key = "\(connectionId)|\(schema)|\(table)"
        let result = key.withCString { pharos_get_import_progress($0) }
        return result < 0 ? nil : result
    }
}
