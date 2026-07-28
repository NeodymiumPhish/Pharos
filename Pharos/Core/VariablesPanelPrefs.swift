import Foundation

/// `UserDefaults`-backed preferences for the query variables panel. Both keys
/// live here so panel width and default visibility cannot drift apart.
///
/// Width is app-wide. Visibility is per-tab (`QueryTab.variablesPanelVisible`);
/// `visibleByDefault` is only the value a *new* tab starts from, rewritten
/// whenever the user toggles the panel, so new tabs inherit the last choice.
enum VariablesPanelPrefs {

    private static let widthKey = "QueryVariablesPanelWidth"
    private static let visibleByDefaultKey = "QueryVariablesPanelVisibleByDefault"

    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 600
    static let defaultWidth: CGFloat = 260

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
