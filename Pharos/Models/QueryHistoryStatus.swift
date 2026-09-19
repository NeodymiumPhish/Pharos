import Foundation

/// How a recorded run ENDED.
///
/// A file of its own, with no dependency but Foundation, because two models
/// that share nothing else both need it: `QueryHistoryEntry` (the navigator's
/// rows) and `WorkspaceResultMeta` (a workspace's children). Several standalone
/// harnesses compile one without the other.
///
/// Mirrors the `HISTORY_STATUS_*` constants in
/// `pharos-core/src/models/query_history.rs`. The SQLite column is plain TEXT,
/// so those two lists are the whole contract between the sides.
enum QueryHistoryStatus {
    /// A run that produced a result. Every row recorded before the column
    /// existed is this one, because a failure left no row at all.
    static let ok = "ok"
    /// A run the server (or the client) refused or failed.
    static let error = "error"
    /// A run the user stopped.
    static let cancelled = "cancelled"
}

/// Which rows a history load asks for — the Results History navigator's scope
/// control, and the `status` field of `QueryHistoryFilter`.
///
/// `succeeded` is `status = 'ok'` and `failed` is everything else, so a row
/// carrying a status this build has never heard of is still reachable: it
/// counts as a failure rather than falling out of both lists.
enum QueryHistoryStatusScope: String, Codable, CaseIterable {
    case all
    case succeeded
    case failed

    /// The scope control's segment title.
    var displayLabel: String {
        switch self {
        case .all: return String(localized: "All")
        case .succeeded: return String(localized: "Succeeded")
        case .failed: return String(localized: "Failed")
        }
    }
}
