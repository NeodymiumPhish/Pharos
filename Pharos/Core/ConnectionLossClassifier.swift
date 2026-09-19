import Foundation

/// Whether a failed query means the CONNECTION is gone, rather than the query
/// being wrong.
///
/// This exists because of a defect the SSH tunnel work recorded: nothing in
/// the app ever moved a connection to Error because of a failed query — only
/// the connect path did — so a dead tunnel showed a green glyph, and Connect
/// then did nothing because a `.connected` connection looks busy.
///
/// Matching is on the message because that is all the FFI returns. It is
/// deliberately narrow: a false positive drops a pool the user still has, so
/// a phrase only earns a place here when it cannot be produced by a bad
/// query. Tested by `scripts/test-connection-loss-classifier.sh`.
enum ConnectionLossClassifier {

    /// Phrases that mean the road to the server is gone. Matched
    /// case-insensitively as substrings.
    static let lossPhrases: [String] = [
        // The core's own answer when there is no pool for the id.
        "not connected to",
        // The SSH child exited; the core reports the reason it kept.
        "ssh tunnel closed",
        // sqlx / tokio socket failures.
        "connection closed",
        "connection reset by peer",
        "connection refused",
        "broken pipe",
        "no route to host",
        "software caused connection abort",
        "io error",
        "pool timed out",
        "pooltimedout",
        // PostgreSQL shutting down or killing the backend underneath us.
        "server closed the connection unexpectedly",
        "terminating connection due to administrator command",
        "the database system is shutting down",
        "terminating connection because of crash",
    ]

    /// Phrases that look like a loss but are not. A statement timeout kills
    /// the STATEMENT, not the session, and the pool is still good; the same
    /// goes for a query the user cancelled.
    static let notLossPhrases: [String] = [
        "canceling statement due to statement timeout",
        "canceling statement due to user request",
        "query was cancelled",
    ]

    static func isConnectionLoss(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if notLossPhrases.contains(where: { lowered.contains($0) }) { return false }
        return lossPhrases.contains { lowered.contains($0) }
    }
}
