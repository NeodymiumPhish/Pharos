import Foundation

/// Preferences for the vertical result-tabs panel.
///
/// Width is app-wide and still lives in `UserDefaults`: it is window memory,
/// set by dragging a divider, not something anybody would look for in
/// Settings. Visibility is per-tab (`QueryTab.resultTabsPanelVisible`);
/// `visibleByDefault` is only the value a *new* tab starts from.
enum ResultTabsPanelPrefs {

    private static let widthKey = "ResultTabsPanelWidth"

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

    /// Whether a newly created tab shows the panel.
    ///
    /// The value LIVES in `AppSettings.results.showResultTabsPanelByDefault`
    /// (Settings ▸ Results ▸ Result tabs); it used to be a `UserDefaults` key
    /// of this file's own, which is what `SettingsMigration` moves across.
    /// This is the model layer's MIRROR of it, written only by
    /// `AppStateManager.settings.didSet`.
    ///
    /// A mirror rather than a direct read because `QueryTab`'s property
    /// default is evaluated wherever a tab is made — including in the
    /// standalone `swiftc` harnesses, which compile the model without any
    /// settings store behind it. `true` is the value the panel shipped with,
    /// so a harness and a first launch see the same thing.
    ///
    /// Not `UserDefaults`-backed any more: writing it here as well would be a
    /// second home for one preference, which is exactly what the migration was
    /// for.
    static var visibleByDefault = true

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minWidth), maxWidth)
    }
}
