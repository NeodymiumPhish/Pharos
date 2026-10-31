import Foundation
import CPharosCore

// MARK: - DuckDB

/// The editor's DuckDB vocabulary for one connected database.
struct DuckDBVocabulary: Decodable, Equatable {
    let keywords: [String]
    let functions: [String]
}

/// What Query ▸ Attach Database… attaches (`duck_attach::AttachSource`).
enum DuckDBAttachSource: Equatable {
    /// A saved PostgreSQL connection, by id. It must be connected.
    case postgres(String)
    /// A DuckDB or SQLite database file.
    case file(String)

    fileprivate var ffi: (kind: String, value: String) {
        switch self {
        case .postgres(let id): return ("postgres", id)
        case .file(let path): return ("file", path)
        }
    }
}

/// What a PostgreSQL connect restored on one DuckDB database
/// (`duck_attach::RestoreOutcome`, camelCase).
struct DuckDBRestoreOutcome: Decodable, Equatable {
    let duckConnectionId: String
    let alias: String
    let error: String?
}

extension PharosCore {

    /// Connect a DuckDB record and create its file if it is missing, for this
    /// connect only (File ▸ New, Save of a new record, Create Empty Database).
    /// Every other connect refuses a missing file (`DuckDBOpenError.isMissing`).
    static func connectCreate(connectionId: String) async throws -> ConnectionInfo {
        try await withAsyncCallback { callback, context in
            connectionId.withCString { cId in
                pharos_connect_create(cId, callback, context)
            }
        }
    }

    /// Attach a database to an open DuckDB database and remember it, so the
    /// database attaches it again each time it opens. A PostgreSQL source must
    /// be CONNECTED; its password goes into a temporary DuckDB secret, never
    /// into SQL text or history. `alias` empty = a default from the source's
    /// name.
    static func duckAttach(duckConnectionId: String, source: DuckDBAttachSource, alias: String,
                           readOnly: Bool) async throws -> DuckDBAttachment {
        let (kind, value) = source.ffi
        return try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in
                kind.withCString { k in
                    value.withCString { v in
                        alias.withCString { a in
                            pharos_duck_attach(d, k, v, a, readOnly, callback, context)
                        }
                    }
                }
            }
        }
    }

    /// Attach the DuckDB database file at `url` (http/https) read-only as
    /// `alias`, outside every card and history path (`pharos://duckdb/attach`).
    /// Returns the alias.
    static func duckAttachRemote(duckConnectionId: String, url: String, alias: String) async throws -> String {
        try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in
                url.withCString { u in
                    alias.withCString { a in
                        pharos_duck_attach_remote(d, u, a, callback, context)
                    }
                }
            }
        }
    }

    /// How many tables and views of its own an in-memory DuckDB database
    /// holds: what Disconnect, Quit or Delete would lose (F7).
    static func duckUserTableCount(connectionId: String) async throws -> UInt64 {
        try await withAsyncCallback { callback, context in
            connectionId.withCString { pharos_duckdb_user_table_count($0, callback, context) }
        }
    }

    /// Save an in-memory DuckDB database to a new file (F7).
    static func duckSaveInMemory(connectionId: String, filePath: String) async throws {
        let _: Bool = try await withAsyncCallback { callback, context in
            connectionId.withCString { c in
                filePath.withCString { p in pharos_duckdb_save_in_memory(c, p, callback, context) }
            }
        }
    }

    /// Detach a database and forget it: the DuckDB database does not attach
    /// it again on its next open.
    static func duckDetach(duckConnectionId: String, alias: String) async throws {
        let _: EmptyResult = try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in
                alias.withCString { a in pharos_duck_detach(d, a, callback, context) }
            }
        }
    }

    /// The databases attached to a DuckDB database, then its remembered
    /// attaches that are not attached now.
    static func duckAttachments(duckConnectionId: String) async throws -> [DuckDBAttachment] {
        try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in pharos_duck_attachments(d, callback, context) }
        }
    }

    /// A PostgreSQL connection has just connected: attach it to each
    /// connected DuckDB database that remembers it.
    static func duckRestoreAttachments(forPostgres pgConnectionId: String) async throws -> [DuckDBRestoreOutcome] {
        try await withAsyncCallback { callback, context in
            pgConnectionId.withCString { p in pharos_duck_restore_for_pg(p, callback, context) }
        }
    }

    /// The remembered attaches the last connect of a DuckDB database could
    /// not restore ("alias: message"), once.
    static func duckTakeRestoreFailures(duckConnectionId: String) async throws -> [String] {
        try await withAsyncCallback { callback, context in
            duckConnectionId.withCString { d in pharos_duck_take_restore_failures(d, callback, context) }
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
    static func exportParquet(connectionId: String, sql: String, schema: String?, filePath: String,
                              queryId: String? = nil) async throws -> ExportTableResult {
        struct Options: Encodable {
            let sql: String
            let schema: String?
            let filePath: String
            let queryId: String?
        }
        let json = String(data: try JSONEncoder().encode(Options(sql: sql, schema: schema, filePath: filePath, queryId: queryId)),
                          encoding: .utf8) ?? "{}"
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

    /// Another process's lock on a DuckDB file (its lock message), or nil
    /// when the file is free (a read-only open, closed at once).
    static func duckDBLockHolder(path: String) -> String? {
        let result: String?? = try? callSync { path.withCString { pharos_duckdb_lock_holder($0) } }
        return result ?? nil
    }

    /// The DuckDB library version Pharos links, e.g. "v2.0.0".
    static func duckDBVersion() -> String {
        (try? callSync { pharos_duckdb_version() }) ?? "unknown"
    }

    // MARK: - Cloud storage credentials (Settings ▸ Connections ▸ DuckDB)

    /// Keep a cloud credential's secret key in the Keychain; false when the
    /// Keychain refused it.
    @discardableResult
    static func storeDuckDBCloudSecret(id: String, secret: String) -> Bool {
        id.withCString { cId in secret.withCString { cSecret in pharos_duckdb_cloud_secret_store(cId, cSecret) } }
    }

    @discardableResult
    static func deleteDuckDBCloudSecret(id: String) -> Bool {
        id.withCString { pharos_duckdb_cloud_secret_delete($0) }
    }

    static func duckDBCloudSecretExists(id: String) -> Bool {
        id.withCString { pharos_duckdb_cloud_secret_exists($0) }
    }
}
