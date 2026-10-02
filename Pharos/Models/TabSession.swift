import Foundation

// The editor tab's own PostgreSQL connection, as pharos-core reports it
// (`commands/tab_session.rs`). Every report crosses the FFI in camelCase
// (`rename_all`), so JSONDecoder.pharos decodes it with no CodingKeys. The
// results that carry one are the pool's result types — snake_case, with
// their own CodingKeys — plus a `session` key.

/// Whether the tab's connection is in a transaction.
enum TabSessionTxn: String, Codable, Equatable, Sendable {
    case idle
    case inTransaction
    /// An error aborted the open transaction: only Roll Back works now.
    case failed
    /// The connection is gone or did not answer.
    case unknown
}

/// Why the tab's connection was replaced. Its settings, temp tables and any
/// open transaction are gone.
struct TabSessionReset: Codable, Equatable, Sendable {
    let reason: String
    let at: String
}

struct TabSessionReport: Codable, Equatable, Sendable {
    let sessionId: String
    let connectionId: String
    let open: Bool
    let generation: UInt64
    let backendPid: Int32
    let txn: TabSessionTxn
    /// Seconds the open transaction had been open when the report was made.
    let txnElapsedSeconds: Double?
    /// The server ends the session after this long idle in a transaction; 0 = never.
    let idleInTransactionTimeoutSeconds: UInt32
    let readOnly: Bool
    /// Operations waiting behind the running one.
    let waiting: Int
    let reset: TabSessionReset?

    /// A transaction is open (healthy or failed): closing the tab would roll it back.
    var hasOpenTransaction: Bool { open && (txn == .inTransaction || txn == .failed) }
}

/// A result type plus the session report beside its fields.
struct SessionResult<Payload: Decodable>: Decodable {
    let payload: Payload
    let session: TabSessionReport

    private enum CodingKeys: String, CodingKey { case session }

    init(from decoder: Decoder) throws {
        payload = try Payload(from: decoder)
        session = try decoder.container(keyedBy: CodingKeys.self).decode(TabSessionReport.self, forKey: .session)
    }
}

struct SessionExplainResult: Decodable {
    let plan: String
    let session: TabSessionReport
}

/// Cell edits on the tab's connection: in an open transaction they are saved
/// when the user commits.
struct SessionRowUpdate: Decodable {
    let result: RowUpdateResult
    let inTransaction: Bool

    private enum CodingKeys: String, CodingKey { case inTransaction }

    init(from decoder: Decoder) throws {
        result = try RowUpdateResult(from: decoder)
        inTransaction = try decoder.container(keyedBy: CodingKeys.self).decode(Bool.self, forKey: .inTransaction)
    }
}

struct SessionEndTransactionResult: Decodable {
    let committed: Bool
    let rolledBack: Bool
    let session: TabSessionReport
}

struct TabSessionCloseOutcome: Decodable, Equatable {
    let closed: Bool
    let hadOpenTransaction: Bool
    let rolledBack: Bool
}

/// The markers pharos-core puts on a refusal that means "run this on the pool".
enum TabSessionMarker {
    /// The server already has its share of tab connections (Settings ▸ Connections).
    static let limit = "[PHAROS_SESSION_LIMIT]"
    /// The server cannot hold a tab connection.
    static let unavailable = "[PHAROS_SESSION_UNAVAILABLE]"

    static func isLimit(_ message: String) -> Bool { message.hasPrefix(limit) }
    static func isUnavailable(_ message: String) -> Bool { message.hasPrefix(unavailable) }

    /// The message without its marker, for the user.
    static func stripped(_ message: String) -> String {
        for marker in [limit, unavailable] where message.hasPrefix(marker) {
            return String(message.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return message
    }
}
