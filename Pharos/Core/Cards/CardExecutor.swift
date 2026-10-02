import Foundation

/// Where a card's run goes: its tab's own connection, or the shared pool
/// when the tab cannot have one (the server's share of tab connections is
/// used, or the server cannot hold one).
enum CardRunRoute: Equatable {
    case session
    /// `reason` is said to the user once: SET, temp tables and transactions
    /// do not carry between cards on the pool.
    case pool(reason: String?)
}

/// Runs a card on its tab's connection, falling back to the pool on the two
/// refusals that mean "no tab connection for you".
@MainActor
enum CardExecutor {
    struct QueryOutcome {
        let result: QueryResult
        let route: CardRunRoute
    }

    struct StatementOutcome {
        let result: ExecuteResult
        let route: CardRunRoute
    }

    static func query(target: TabSessionTarget, sql: String, limit: Int32) async throws -> QueryOutcome {
        let monitor = TabSessionMonitor.shared
        if monitor.canUseSession(connectionId: target.connectionId) {
            do {
                let r = try await PharosCore.sessionExecuteQuery(target, sql: sql, limit: limit)
                monitor.record(r.session)
                return QueryOutcome(result: r.payload, route: .session)
            } catch {
                guard let reason = fallbackReason(error, connectionId: target.connectionId) else {
                    monitor.refresh(target.sessionId)
                    throw error
                }
                let result = try await PharosCore.executeQuery(
                    connectionId: target.connectionId, sql: sql, queryId: target.queryId, limit: limit, schema: target.schema)
                return QueryOutcome(result: result, route: .pool(reason: reason))
            }
        }
        let result = try await PharosCore.executeQuery(
            connectionId: target.connectionId, sql: sql, queryId: target.queryId, limit: limit, schema: target.schema)
        return QueryOutcome(result: result, route: .pool(reason: nil))
    }

    static func statement(target: TabSessionTarget, sql: String) async throws -> StatementOutcome {
        let monitor = TabSessionMonitor.shared
        if monitor.canUseSession(connectionId: target.connectionId) {
            do {
                let r = try await PharosCore.sessionExecuteStatement(target, sql: sql)
                monitor.record(r.session)
                return StatementOutcome(result: r.payload, route: .session)
            } catch {
                guard let reason = fallbackReason(error, connectionId: target.connectionId) else {
                    monitor.refresh(target.sessionId)
                    throw error
                }
                let result = try await PharosCore.executeStatement(
                    connectionId: target.connectionId, sql: sql, queryId: target.queryId, schema: target.schema)
                return StatementOutcome(result: result, route: .pool(reason: reason))
            }
        }
        let result = try await PharosCore.executeStatement(
            connectionId: target.connectionId, sql: sql, queryId: target.queryId, schema: target.schema)
        return StatementOutcome(result: result, route: .pool(reason: nil))
    }

    /// The message to show when this error means "run it on the pool", else nil.
    private static func fallbackReason(_ error: Error, connectionId: String) -> String? {
        guard case let PharosCoreError.rustError(message) = error else { return nil }
        if TabSessionMarker.isUnavailable(message) {
            TabSessionMonitor.shared.markUnavailable(connectionId)
            return String(localized: "This server cannot hold a connection for each tab. Cards run on shared connections: SET, temporary tables and transactions do not carry from card to card.")
        }
        if TabSessionMarker.isLimit(message) {
            return TabSessionMarker.stripped(message) + " "
                + String(localized: "This card ran on a shared connection.")
        }
        return nil
    }

    /// The target for Pharos's own work on a tab (Load More, Load All, Explain,
    /// cell edits): the tab's connection when it has one open, else nil (use the pool).
    static func auxTarget(tabId: String, connectionId: String, schema: String?, queryId: String? = nil) -> TabSessionTarget? {
        guard let report = TabSessionMonitor.shared.report(for: tabId), report.open,
              report.connectionId == connectionId else { return nil }
        return TabSessionTarget(sessionId: tabId, connectionId: connectionId, schema: schema, queryId: queryId)
    }
}
