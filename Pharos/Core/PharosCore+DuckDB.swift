import Foundation
import CPharosCore

// MARK: - DuckDB

/// The editor's DuckDB vocabulary for one connected database.
struct DuckDBVocabulary: Decodable, Equatable {
    let keywords: [String]
    let functions: [String]
}

/// A PostgreSQL connection attached to a DuckDB database
/// (`pharos-core` `duck_attach::AttachmentInfo`, camelCase).
struct DuckDBAttachment: Decodable, Equatable {
    /// The DuckDB database name: its schemas show as `alias.schema`.
    let alias: String
    let pgId: String
    let pgName: String
    let readOnly: Bool
}

extension PharosCore {

    /// Attach a CONNECTED PostgreSQL connection to an open DuckDB database.
    /// The password goes into a temporary DuckDB secret, never into SQL text
    /// or history. `alias` empty = a default from the connection's name.
    static func duckAttachPostgres(duckConnectionId: String, pgConnectionId: String, alias: String,
                                   readOnly: Bool) async throws -> DuckDBAttachment {
        try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in
                pgConnectionId.withCString { p in
                    alias.withCString { a in
                        pharos_duck_attach_postgres(d, p, a, readOnly, callback, context)
                    }
                }
            }
        }
    }

    /// Detach a PostgreSQL connection Pharos attached.
    static func duckDetach(duckConnectionId: String, alias: String) async throws {
        let _: EmptyResult = try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in
                alias.withCString { a in pharos_duck_detach(d, a, callback, context) }
            }
        }
    }

    /// The PostgreSQL connections attached to a DuckDB database.
    static func duckAttachments(duckConnectionId: String) async throws -> [DuckDBAttachment] {
        try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in pharos_duck_attachments(d, callback, context) }
        }
    }

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

    /// A running query's progress, read at once (the card header polls it).
    /// nil when the query is not running, its engine reports none
    /// (PostgreSQL), or the engine has no estimate yet.
    static func queryProgress(queryId: String) -> QueryProgress? {
        let result: QueryProgress?? = try? callSync { queryId.withCString { pharos_query_progress($0) } }
        return result ?? nil
    }

    /// The DuckDB library version Pharos links, e.g. "v1.5.6".
    static func duckDBVersion() -> String {
        (try? callSync { pharos_duckdb_version() }) ?? "unknown"
    }
}
