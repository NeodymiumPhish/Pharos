import Foundation

/// Where a result stands against "more rows": all loaded, more the user can
/// load, or more that the Load All limit (Settings ▸ Query) keeps out.
///
/// Pure and Foundation-only, so `scripts/test-result-load-state.sh` pins it.
/// The row count's suffix and the Load More / Load All buttons both read it,
/// so the two never disagree.
enum ResultLoadState: Equatable {
    case complete
    case more
    case limitReached

    init(hasMore: Bool, limitReached: Bool) {
        self = !hasMore ? .complete : (limitReached ? .limitReached : .more)
    }

    /// After the row count: " (more available)", " (limit reached)" or nothing.
    var statusSuffix: String {
        switch self {
        case .complete: return ""
        case .more: return String(localized: " (more available)")
        case .limitReached: return String(localized: " (limit reached)")
        }
    }

    /// Load More and Load All are offered only while there is more to load
    /// within the limit.
    var showsLoadButtons: Bool { self == .more }

    /// Whether a result of `rowCount` rows, with more still on the server, is
    /// at the Load All limit: Load All stopped there, or Load More pages grew
    /// the result to it.
    static func isAtLimit(rowCount: Int, hasMore: Bool, limit: Int) -> Bool {
        hasMore && rowCount >= limit
    }

    /// The Load All limit from the setting, kept inside the range the
    /// settings pane offers (a hand-edited blob can hold anything).
    static func clampedLimit(_ setting: UInt32) -> Int {
        min(max(Int(setting), 1_000), 5_000_000)
    }
}
