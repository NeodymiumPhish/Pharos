import Foundation

/// Whether a failed query is worth a row in Query History.
///
/// A failure the SERVER answered is history: the SQL reached PostgreSQL, it
/// ran, and what came back is something the user may well want to find again.
/// A refusal that never left this Mac is not: "connect to a database first"
/// says nothing about the SQL, and a history full of those buries the real
/// failures.
///
/// Pure, and tested by `scripts/test-history-failure-filter.sh`, because the
/// list of client-side refusals is a judgement that will be argued with and
/// should be arguable against a test rather than against a running app.
enum HistoryFailureFilter {

    /// The messages the app itself produces when it will not even try. Each
    /// is matched case-insensitively as a substring, so the caller may pass a
    /// message that has been wrapped in context.
    static let clientSideRefusals: [String] = [
        // No pool at all: the core's own words, and the toast's.
        "not connected to",
        "connect to a database",
        // The tunnel died, so nothing was sent (D4 of the SSH work).
        "ssh tunnel closed",
        "ssh tunnel failed",
        // The variable gate refused before the SQL was rendered.
        "unresolved variable",
        "unresolved variables",
        // The user's own cancellation, which is on the tab already.
        "cancelled by user",
        // Nothing to run.
        "no sql to run",
    ]

    /// True when this failure belongs in Query History.
    ///
    /// An empty or blank message is recorded: an unexplained failure is
    /// exactly the kind a user goes looking for later.
    static func shouldRecord(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return !clientSideRefusals.contains { lowered.contains($0) }
    }
}
