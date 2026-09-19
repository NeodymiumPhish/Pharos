import Foundation

/// Moves the few preferences that predate the Settings window out of
/// `UserDefaults` and into `AppSettings`, where every other preference lives.
///
/// The old homes were written straight from the control that changed them —
/// a checkbox in the copy popover, the result-tabs panel's own toggle — so
/// they never appeared in Settings and never travelled with the rest of the
/// user's configuration. Each key is read once, clamped into the model, and
/// then REMOVED: the presence of the key is the only "not migrated yet"
/// signal there is, so leaving it behind would overwrite the user's choice on
/// every launch.
///
/// Foundation and the settings model only — no AppKit, no `AppStateManager` —
/// so `scripts/test-settings-migration.sh` compiles it standalone.
enum SettingsMigration {

    /// The legacy key for the copy popover's "Include Headers" checkbox.
    static let copyIncludeHeadersKey = "PharosCopyIncludeHeaders"

    /// The legacy key for whether a new editor tab opens with the vertical
    /// result-tabs panel.
    static let resultTabsPanelVisibleKey = "ResultTabsPanelVisibleByDefault"

    /// The legacy key for the editor / results divider position.
    static let editorSplitRatioKey = "PharosEditorSplitRatio"

    /// Copy the legacy values into `settings`, then remove their keys.
    ///
    /// - Returns: true when something moved, which is the caller's signal to
    ///   save. A run over already-migrated defaults changes nothing and
    ///   returns false, so this is safe to call on every launch.
    @discardableResult
    static func migrate(from defaults: UserDefaults, into settings: inout AppSettings) -> Bool {
        var changed = false

        if let value = bool(defaults, copyIncludeHeadersKey) {
            settings.results.copyIncludeHeaders = value
            defaults.removeObject(forKey: copyIncludeHeadersKey)
            changed = true
        }

        if let value = bool(defaults, resultTabsPanelVisibleKey) {
            settings.results.showResultTabsPanelByDefault = value
            defaults.removeObject(forKey: resultTabsPanelVisibleKey)
            changed = true
        }

        // Clamped, because this one is a number the user never typed: it was
        // written from a divider drag, and a stored 0 or 1 would give an
        // editor or a grid with no height at all.
        if let stored = defaults.object(forKey: editorSplitRatioKey) as? Double {
            let clamped = min(max(stored, 0.1), 0.9)
            if clamped > 0 {
                settings.session.defaultEditorSplitRatio = (clamped * 1000).rounded() / 1000
            }
            defaults.removeObject(forKey: editorSplitRatioKey)
            changed = true
        }

        return changed
    }

    /// The stored value as a Bool, or nil when the key is absent.
    ///
    /// `object(forKey:)` rather than `bool(forKey:)`: the latter cannot tell
    /// an absent key from a stored `false`, and absence is precisely what this
    /// file keys off. A value of another type (a string, a dictionary — a
    /// hand-edited plist, or a key another build once used differently) is
    /// treated as absent rather than crashing or guessing: the stored setting
    /// keeps its own value, which is the safe answer when the legacy one
    /// cannot be read.
    private static func bool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        guard let object = defaults.object(forKey: key) else { return nil }
        switch object {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return nil
        }
    }
}
