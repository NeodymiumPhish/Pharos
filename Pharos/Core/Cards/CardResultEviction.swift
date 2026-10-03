import Foundation

/// Which results to let go when a tab holds more than Settings ▸ Results
/// allows. The card stays; it shows "Results removed" and can run again.
enum CardResultEviction {
    struct Candidate: Equatable {
        let cardId: String
        /// The result's age: lower is older.
        let order: Int
        let hasBeenViewed: Bool
        let isDisplayed: Bool
    }

    /// The cards whose results go, oldest first, until the tab is at `limit`
    /// (0 = no limit). Only results nobody has looked at go: a result the
    /// user has seen, or is looking at, is theirs. When only
    /// those are left, the tab goes over the limit.
    static func toEvict(_ held: [Candidate], limit: Int) -> [String] {
        guard limit > 0, held.count > limit else { return [] }
        let removable = held
            .filter { !$0.hasBeenViewed && !$0.isDisplayed }
            .sorted { $0.order < $1.order }
        return removable.prefix(held.count - limit).map(\.cardId)
    }
}
