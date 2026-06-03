import Foundation

/// Coalesces rapid-fire `NotificationCenter.post(name:)` calls so multiple
/// posts within the same main-loop tick fan out exactly once.
///
/// Several pathways (batch saved-query CRUD, history pruning, etc.) post the
/// same notification multiple times in immediate succession; each post used
/// to fully re-load the sidebar's outline view. This funnels those into one.
///
/// Usage: `NotificationCoalescer.post(.savedQueriesDidChange)` instead of
/// `NotificationCenter.default.post(name: .savedQueriesDidChange, object: nil)`.
enum NotificationCoalescer {
    private static var pendingNames: Set<String> = []

    /// Schedule a notification to be posted at the end of the current run-loop
    /// tick. Repeated calls with the same name before that tick fires collapse
    /// into a single post. Must be called on the main thread.
    static func post(_ name: Notification.Name) {
        assert(Thread.isMainThread, "NotificationCoalescer.post must be called on main")
        let key = name.rawValue
        let wasFirst = pendingNames.insert(key).inserted
        guard wasFirst else { return }
        DispatchQueue.main.async {
            pendingNames.remove(key)
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}
