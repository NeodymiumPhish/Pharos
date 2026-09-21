import Foundation

/// Where the Settings window was left. Kept in `UserDefaults`, not in
/// `AppSettings`: it is where the user is looking, not a preference, and it
/// should not travel with the settings record.
///
/// The key is the one the old tab window used. That window stored the tab
/// INDEX; this stores the pane's `rawValue`. A stored integer is read once
/// through the old four-pane order and the next write replaces it.
enum SettingsPanePrefs {

    static let key = "PharosSettingsPane"

    /// The order the old `NSTabViewController` had, for a legacy integer.
    static let legacyOrder: [SettingsPaneID] = [.general, .editor, .query, .charts]

    static func lastPane(in defaults: UserDefaults = .standard) -> SettingsPaneID {
        switch defaults.object(forKey: key) {
        case let raw as String:
            return SettingsPaneID(rawValue: raw) ?? .general
        case let legacy as Int:
            return legacy >= 0 && legacy < legacyOrder.count ? legacyOrder[legacy] : .general
        default:
            return .general
        }
    }

    static func setLastPane(_ id: SettingsPaneID, in defaults: UserDefaults = .standard) {
        defaults.set(id.rawValue, forKey: key)
    }
}

/// What made the Settings window change pane, and therefore what the change
/// should leave behind: an entry in the Back/Forward history, and the
/// remembered pane ⌘, will open next time.
///
/// Here rather than beside `SettingsSplitViewController`, which is the one
/// place that acts on it: the two rules below are the whole of the policy, and
/// here they are Foundation-only and `scripts/test-settings-navigation.sh`
/// pins them. `SettingsSplitViewController.NavigationSource` is a typealias
/// for this.
enum SettingsNavigationSource {
    /// The user clicked a sidebar row.
    case user
    /// Back or Forward moved within the history.
    case history
    /// The window opening in the pane it was left in.
    case restore
    /// A menu item that names one pane — Pharos ▸ About Pharos, or a sheet's
    /// "Settings…" button.
    case deepLink

    /// Whether this navigation becomes a Back/Forward entry. `restore` does
    /// not: it IS the history's root, which `navigate` seeds separately.
    var recordsHistory: Bool {
        switch self {
        case .user, .deepLink: return true
        case .history, .restore: return false
        }
    }

    /// Whether ⌘, should open this pane next time.
    ///
    /// A deep link does NOT make the pane the remembered one. About, which is
    /// the first pane reached that way, is read once; the pane the user works
    /// in is the one ⌘, must go back to. Restoring remembers nothing either,
    /// because it is only reading what was already written down.
    var isRemembered: Bool {
        switch self {
        case .user, .history: return true
        case .restore, .deepLink: return false
        }
    }
}
