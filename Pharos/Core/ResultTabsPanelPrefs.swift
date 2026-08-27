import Foundation

/// `UserDefaults`-backed preferences for the vertical result-tabs panel. Both
/// keys live here so panel width and default visibility cannot drift apart.
/// Mirrors `VariablesPanelPrefs`, which established the pattern.
///
/// Width is app-wide. Visibility is per-tab (`QueryTab.resultTabsPanelVisible`);
/// `visibleByDefault` is only the value a *new* tab starts from, rewritten
/// whenever the user toggles the panel, so new tabs inherit the last choice.
enum ResultTabsPanelPrefs {

    private static let widthKey = "ResultTabsPanelWidth"
    private static let visibleByDefaultKey = "ResultTabsPanelVisibleByDefault"

    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 600
    static let defaultWidth: CGFloat = 220

    static var width: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: widthKey)
            let value = stored == 0 ? defaultWidth : CGFloat(stored)
            return clamp(value)
        }
        set {
            UserDefaults.standard.set(Double(clamp(newValue)), forKey: widthKey)
        }
    }

    /// Whether a newly created tab shows the panel. Seeded `true` so the panel
    /// is open out of the box; an absent key is "not yet chosen", which is why
    /// this reads `object(forKey:)` rather than `bool(forKey:)` (the latter
    /// returns `false` for a missing key).
    static var visibleByDefault: Bool {
        get {
            guard UserDefaults.standard.object(forKey: visibleByDefaultKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: visibleByDefaultKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: visibleByDefaultKey) }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minWidth), maxWidth)
    }
}
