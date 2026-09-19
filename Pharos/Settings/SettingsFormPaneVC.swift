import AppKit
import Combine

/// A Settings pane described by `sections`. Subclasses override `sections`
/// and nothing else; the builder makes the furniture and the scroll view.
///
/// The pane refreshes from the store on every appearance and on every
/// published settings change — but a control the user is typing in is left
/// alone, or the republishing store would eat the field being edited.
@MainActor
class SettingsFormPaneVC: SettingsPaneVC {

    let paneId: SettingsPaneID
    let builder = SettingsFormBuilder()
    private var settingsCancellable: AnyCancellable?

    init(paneId: SettingsPaneID) {
        self.paneId = paneId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// The pane's content. Bindings must read the CURRENT settings on every
    /// `get`, which `SettingsBinding.settings(_:)` does.
    var sections: [SettingsSection] { [] }

    override func loadView() {
        builder.isPopulating = { [unowned self] in self.isPopulating }
        let sectionViews = builder.buildSectionViews(sections, paneId: paneId.rawValue)
        view = SettingsFormScroll.makePane(sections: sectionViews)
        view.setAccessibilityIdentifier("settings.form.\(paneId.rawValue)")
        reloadFromSettings()

        settingsCancellable = stateManager.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromSettings() }
    }

    override func reloadFromSettings() {
        populating { builder.refreshAll() }
    }
}
