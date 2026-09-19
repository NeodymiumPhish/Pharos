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
