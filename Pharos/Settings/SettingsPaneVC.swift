import AppKit

/// Shared scaffolding for the panes of the Settings window.
///
/// The window has no Save button: every control writes its one field into
/// `AppSettings` and persists it the moment it changes. That is what the base
/// class exists for.
///
///  - `apply` reads the CURRENT published settings, mutates the one field the
///    control owns and saves. It never writes a whole snapshot taken when the
///    pane was built, so two panes cannot overwrite each other's fields.
///  - `populating` suppresses the writes that setting a control's value
///    triggers, so refreshing a pane from the store never writes back to it.
///
/// Most panes are `SettingsFormPaneVC` subclasses and describe themselves as
/// `[SettingsSection]`; a hand-built pane (the Shortcuts table) subclasses
/// this directly. The key view loop is AppKit's automatic one: rows are in
/// reading order with one focusable control each, and the automatic loop
/// skips hidden and disabled controls, which dependent rows need.
@MainActor
class SettingsPaneVC: NSViewController {

    let stateManager = AppStateManager.shared

    private(set) var isPopulating = false

    // MARK: - Applying

    /// Persist one change. The mutation is applied to the settings as they
    /// stand right now, not to a copy held by the pane.
    func apply(_ mutate: (inout AppSettings) -> Void) {
        guard !isPopulating else { return }
        let current = stateManager.settings
        var updated = current
        mutate(&updated)
        guard updated != current else { return }
        stateManager.saveSettings(updated)
    }

    /// Run `body` with writes suppressed — for putting stored values INTO the
    /// controls, which fires their actions.
    func populating(_ body: () -> Void) {
        isPopulating = true
        body()
        isPopulating = false
    }

    /// Refresh every control from the store. Called when the window is shown
    /// and whenever the pane appears.
    func reloadFromSettings() {}

    // MARK: - Lifecycle

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadFromSettings()
    }
}
