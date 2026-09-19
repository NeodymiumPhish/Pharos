import AppKit

/// Settings ▸ General. What happens at launch, and the update check.
final class GeneralSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .general) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Startup"), items: [
                SettingsItem(
                    id: "restoreOpenTabs",
                    title: String(localized: "Restore open tabs"),
                    caption: String(localized: "Reopen the editor tabs that were open when you last quit, with their results. No connection is opened."),
                    icon: "macwindow.on.rectangle",
                    kind: .toggle(.settings(\.query.restoreOpenTabs))),
            ]),
            SettingsSection(title: String(localized: "Updates"), items: [
                SettingsItem(
                    id: "checkForUpdates",
                    title: String(localized: "Check for updates in the background"),
                    caption: String(localized: "Checks GitHub Releases after launch and posts one notification per new version. Nothing is downloaded or installed."),
                    icon: "arrow.down.circle",
                    kind: .toggle(.settings(\.checkForUpdates))),
            ]),
        ]
    }
}
