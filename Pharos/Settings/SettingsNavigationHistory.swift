import Foundation

/// The back/forward history of the Settings window, like a browser's: a
/// visit made from the middle of the list drops what was ahead of it.
///
/// Pure value type; `scripts/test-settings-navigation.sh` covers it.
struct SettingsNavigationHistory: Equatable {

    static let capacity = 50

    private(set) var entries: [SettingsPaneID] = []
    /// Index of the current pane in `entries`, or -1 before the first visit.
    private(set) var index: Int = -1

    var current: SettingsPaneID? { index >= 0 && index < entries.count ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Record a pane the USER chose. Visiting the current pane again is a
    /// no-op; the list is capped at `capacity` by dropping the oldest.
    mutating func visit(_ id: SettingsPaneID) {
        if current == id { return }
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(id)
        index = entries.count - 1
        if entries.count > Self.capacity {
            let excess = entries.count - Self.capacity
            entries.removeFirst(excess)
            index -= excess
        }
    }

    /// Step back. Returns the pane to show, or nil at the start.
    mutating func goBack() -> SettingsPaneID? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    /// Step forward. Returns the pane to show, or nil at the end.
    mutating func goForward() -> SettingsPaneID? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
