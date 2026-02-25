import Foundation
import CPharosCore

// MARK: - Table Operations

extension PharosCore {

    /// Clone a table structure (with optional data).
    static func cloneTable(connectionId: String, options: CloneTableOptions) async throws -> CloneTableResult {
        let json = try JSONEncoder.pharos.encode(options)
        let jsonStr = String(data: json, encoding: .utf8)!
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
        let jsonStr = String(data: json, encoding: .utf8)!
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
        let jsonStr = String(data: json, encoding: .utf8)!
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                jsonStr.withCString { cJson in
                    pharos_import_csv(cConn, cJson, callback, context)
                }
            }
        }
    }
}
