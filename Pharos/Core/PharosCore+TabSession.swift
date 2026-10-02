import Foundation
import CPharosCore

// MARK: - Tab session (one PostgreSQL connection per editor tab)

/// Which tab connection an operation runs on. `sessionId` is the editor tab's id.
struct TabSessionTarget: Encodable, Equatable, Sendable {
    let sessionId: String
    let connectionId: String
    var schema: String?
    var queryId: String?
}

private struct SessionRunBody: Encodable {
    let sessionId: String
    let connectionId: String
    let schema: String?
    let queryId: String?
    let sql: String
    let limit: Int32?
    let source: String?
    let aux: Bool
}

extension PharosCore {

    /// Every session call takes one camelCase JSON request.
    private static func sessionCall<T: Decodable, R: Encodable>(
        _ request: R,
        _ ffi: @escaping (UnsafePointer<CChar>, AsyncCallback, UnsafeMutableRawPointer) -> Void
    ) async throws -> T {
        let json = try String(decoding: JSONEncoder().encode(request), as: UTF8.self)
        return try await withAsyncCallback { callback, context in
            json.withCString { ffi($0, callback, context) }
        }
    }

    private static func runBody(_ t: TabSessionTarget, sql: String, limit: Int32?, source: String?, aux: Bool) -> SessionRunBody {
        SessionRunBody(sessionId: t.sessionId, connectionId: t.connectionId, schema: t.schema, queryId: t.queryId,
                       sql: sql, limit: limit, source: source, aux: aux)
    }

    /// Run a card's row-returning statement on its tab's connection.
    static func sessionExecuteQuery(
        _ target: TabSessionTarget, sql: String, limit: Int32 = 1000, source: String? = nil, aux: Bool = false
    ) async throws -> SessionResult<QueryResult> {
        try await sessionCall(runBody(target, sql: sql, limit: limit, source: source, aux: aux)) {
            pharos_session_execute_query($0, $1, $2)
        }
    }

    /// Run a card's other statement on its tab's connection.
    static func sessionExecuteStatement(
        _ target: TabSessionTarget, sql: String, source: String? = nil
    ) async throws -> SessionResult<ExecuteResult> {
        try await sessionCall(runBody(target, sql: sql, limit: nil, source: source, aux: false)) {
            pharos_session_execute_statement($0, $1, $2)
        }
    }

    private struct FetchMoreBody: Encodable {
        let sessionId: String, connectionId: String, schema: String?, queryId: String?
        let sql: String, limit: Int64, offset: Int64
    }

    /// Load More on the tab's connection (sees its temp tables and uncommitted rows).
    static func sessionFetchMoreRows(
        _ t: TabSessionTarget, sql: String, limit: Int64, offset: Int64
    ) async throws -> SessionResult<QueryResult> {
        let body = FetchMoreBody(sessionId: t.sessionId, connectionId: t.connectionId, schema: t.schema,
                                 queryId: t.queryId, sql: sql, limit: limit, offset: offset)
        return try await sessionCall(body) { pharos_session_fetch_more_rows($0, $1, $2) }
    }

    private struct FetchAllBody: Encodable {
        let sessionId: String, connectionId: String, schema: String?, queryId: String?
        let sql: String, maxRows: Int64
    }

    /// Load All on the tab's connection: one snapshot through a server cursor.
    static func sessionFetchAllRows(
        _ t: TabSessionTarget, sql: String, maxRows: Int64,
        onProgress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> SessionResult<QueryResult> {
        let body = FetchAllBody(sessionId: t.sessionId, connectionId: t.connectionId, schema: t.schema,
                                queryId: t.queryId, sql: sql, maxRows: maxRows)
        let json = try String(decoding: JSONEncoder().encode(body), as: UTF8.self)
        return try await withAsyncCallback(onProgress: onProgress) { callback, progress, context in
            json.withCString { pharos_session_fetch_all_rows($0, progress, callback, context) }
        }
    }

    private struct ExplainBody: Encodable {
        let sessionId: String, connectionId: String, schema: String?, queryId: String?
        let sql: String, analyze: Bool
    }

    /// Explain a card on the tab's connection. ANALYZE is undone, and an
    /// open transaction stays open.
    static func sessionExplain(_ t: TabSessionTarget, sql: String, analyze: Bool) async throws -> SessionExplainResult {
        let body = ExplainBody(sessionId: t.sessionId, connectionId: t.connectionId, schema: t.schema,
                               queryId: t.queryId, sql: sql, analyze: analyze)
        return try await sessionCall(body) { pharos_session_explain($0, $1, $2) }
    }

    private struct ValidateBody: Encodable {
        let sessionId: String, connectionId: String, schema: String?, sql: String
    }

    /// Validate a card on the tab's connection. Never waits behind a run.
    static func sessionValidateSQL(_ t: TabSessionTarget, sql: String) async throws -> ValidationResult {
        let body = ValidateBody(sessionId: t.sessionId, connectionId: t.connectionId, schema: t.schema, sql: sql)
        return try await sessionCall(body) { pharos_session_validate_sql($0, $1, $2) }
    }

    private struct RowUpdateBody: Encodable {
        let sessionId: String, connectionId: String, schema: String?, queryId: String?
        let request: RowUpdateRequest
    }

    /// Cell edits on the tab's connection. In an open transaction they become
    /// part of it (`inTransaction`), saved when the user commits.
    static func sessionApplyRowUpdates(
        _ t: TabSessionTarget, request: RowUpdateRequest
    ) async throws -> (result: RowUpdateResult, inTransaction: Bool, session: TabSessionReport) {
        let body = RowUpdateBody(sessionId: t.sessionId, connectionId: t.connectionId, schema: t.schema,
                                 queryId: t.queryId, request: request)
        let r: SessionResult<SessionRowUpdate> = try await sessionCall(body) { pharos_session_apply_row_updates($0, $1, $2) }
        return (r.payload.result, r.payload.inTransaction, r.session)
    }

    private struct EndTransactionBody: Encodable {
        let sessionId: String
        let commit: Bool
    }

    /// The banner's Commit / Roll Back.
    static func sessionEndTransaction(tabId: String, commit: Bool) async throws -> SessionEndTransactionResult {
        try await sessionCall(EndTransactionBody(sessionId: tabId, commit: commit)) {
            pharos_session_end_transaction($0, $1, $2)
        }
    }

    /// Close a tab's connection, rolling back an open transaction. Nil when the
    /// tab had none.
    static func closeTabSession(tabId: String) async -> TabSessionCloseOutcome? {
        // `try?` flattens: a failed call and a `null` answer are both nil.
        try? await withAsyncCallback { callback, context in
            tabId.withCString { pharos_tab_session_close($0, callback, context) }
        }
    }

    /// A tab connection's last report, or nil when the tab has none. Synchronous and cheap.
    static func tabSessionState(tabId: String) -> TabSessionReport? {
        try? callSync { tabId.withCString { pharos_tab_session_state($0) } }
    }
}
