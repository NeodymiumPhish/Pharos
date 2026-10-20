import Foundation
import CPharosCore

// MARK: - DuckDB

/// The editor's DuckDB vocabulary for one connected database.
struct DuckDBVocabulary: Decodable, Equatable {
    let keywords: [String]
    let functions: [String]
}

extension PharosCore {

    /// Connect a DuckDB record READ-ONLY, for this connect only — the
    /// "Open Read-Only" answer to a file another process holds for writing.
    static func connectReadOnly(connectionId: String) async throws -> ConnectionInfo {
        try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                pharos_connect_read_only(cId, callback, context)
            }
        }
    }

    /// DuckDB's keywords and function names, for the editor's completion and
    /// highlighting.
    static func duckDBVocabulary(connectionId: String) async throws -> DuckDBVocabulary {
        try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                pharos_duckdb_vocabulary(cId, callback, context)
            }
        }
    }

    /// Write a query's whole result to a Parquet file with DuckDB's own writer.
    static func exportParquet(connectionId: String, sql: String, schema: String?, filePath: String) async throws -> ExportTableResult {
        struct Options: Encodable {
            let sql: String
            let schema: String?
            let filePath: String
        }
        let json = String(data: try JSONEncoder().encode(Options(sql: sql, schema: schema, filePath: filePath)), encoding: .utf8) ?? "{}"
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                json.withCString { cJson in
                    pharos_export_parquet(cId, cJson, callback, context)
                }
            }
        }
    }

    /// The DuckDB library version Pharos links, e.g. "v1.5.6".
    static func duckDBVersion() -> String {
        (try? callSync { pharos_duckdb_version() }) ?? "unknown"
    }
}
