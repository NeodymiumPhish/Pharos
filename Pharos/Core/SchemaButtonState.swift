import Foundation

/// What the toolbar's schema pull-down shows for the active tab: its title,
/// whether it can be pressed, and whether the loading spinner turns.
///
/// Pure, so the rule is pinned by `scripts/test-schema-button-state.sh`
/// without a toolbar, a session or the metadata cache.
struct SchemaButtonState: Equatable {
    let title: String
    let isEnabled: Bool
    let showsSpinner: Bool

    /// - Parameters:
    ///   - hasConnection: the active tab names a connection at all.
    ///   - isConnected: …and that connection is open.
    ///   - isLoading: the metadata cache is fetching. Only shown for a tab that
    ///     has a connection: a tab with none has nothing to wait for, and the
    ///     cache is shared across windows, so another window's fetch must not
    ///     put "Loading…" on this one's empty tab.
    ///   - hasSchemas: the cache holds at least one schema.
    ///   - activeSchema: the tab's pinned schema, nil for "All Schemas".
    init(hasConnection: Bool, isConnected: Bool, isLoading: Bool, hasSchemas: Bool, activeSchema: String?) {
        if hasConnection && isLoading {
            title = String(localized: "Loading\u{2026}")
            isEnabled = false
            showsSpinner = true
        } else if !isConnected || !hasSchemas {
            title = String(localized: "No Schema")
            isEnabled = false
            showsSpinner = false
        } else {
            title = DisplayEscape.escaped(activeSchema ?? String(localized: "All Schemas"))
            isEnabled = true
            showsSpinner = false
        }
    }
}
