import AppKit

/// Settings ▸ Security & Privacy. What Pharos does with your data on this Mac.
///
/// Both switches take effect while the window is open: `SettingsEffects`
/// follows the stored values and starts or stops the service behind each one.
/// Neither sends anything anywhere, which is what the section caption says in
/// as few words as it can be said.
final class SecuritySettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .security) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Privacy"), items: [
                SettingsItem(
                    id: "privacyNote",
                    title: String(localized: "Nothing leaves this Mac."),
                    caption: String(localized: "Pharos has no account, no telemetry and no analytics. Everything below is written to your own disk and read by your own Mac."),
                    icon: "lock.shield",
                    kind: .display),
            ]),
            SettingsSection(title: String(localized: "Spotlight"), items: [
                SettingsItem(
                    id: "indexSavedQueriesInSpotlight",
                    title: String(localized: "Find saved queries in Spotlight"),
                    caption: String(localized: "Puts each saved query's name, folder and SQL in the system index, so Spotlight opens it. Turning this off removes them again."),
                    icon: "magnifyingglass",
                    kind: .toggle(.settings(\.security.indexSavedQueriesInSpotlight))),
            ]),
            SettingsSection(title: String(localized: "Diagnostics"), items: [
                SettingsItem(
                    id: "collectPerformanceMetrics",
                    title: String(localized: "Collect performance reports"),
                    caption: String(localized: "Writes the system's daily hang and performance payloads to ~/Library/Logs/Pharos, for you to read or attach to a bug report. Nothing is uploaded."),
                    icon: "waveform.path.ecg",
                    kind: .toggle(.settings(\.security.collectPerformanceMetrics))),
            ]),
        ]
    }
}
