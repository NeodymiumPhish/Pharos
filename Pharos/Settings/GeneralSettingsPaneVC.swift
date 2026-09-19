import AppKit

/// Settings ▸ General. What happens at launch, and the update check.
final class GeneralSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .general) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// What the last check said, shown under Check Now. Nil until the user
    /// presses it in this session; the caption then falls back to the stored
    /// timestamp.
    private var lastOutcomeMessage: String?

    /// "Last checked: …", or the outcome of a check made from this pane.
    private func updateStatusCaption() -> String {
        if let lastOutcomeMessage { return lastOutcomeMessage }
        guard let date = UpdateChecker.shared.lastCheckedAt else {
            return String(localized: "Not checked yet.")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return String(localized: "Last checked: \(formatter.string(from: date))")
    }

    private func checkNow() {
        lastOutcomeMessage = String(localized: "Checking…")
        reloadFromSettings()
        Task { @MainActor in
            let outcome = await UpdateChecker.shared.checkNow(force: true)
            self.lastOutcomeMessage = outcome.message
            self.reloadFromSettings()
        }
    }

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
                SettingsItem(
                    id: "updateFrequency",
                    title: String(localized: "Frequency"),
                    icon: "calendar",
                    kind: .popup(.cases(\.updates.checkFrequency, title: { $0.displayLabel })),
                    dependsOn: "checkForUpdates"),
                SettingsItem(
                    id: "updateChannel",
                    title: String(localized: "Channel"),
                    caption: String(localized: "Pre-release offers beta builds as soon as they are published."),
                    icon: "shippingbox",
                    kind: .popup(.cases(\.updates.channel, title: { $0.displayLabel })),
                    dependsOn: "checkForUpdates"),
                SettingsItem(
                    id: "checkNow",
                    title: String(localized: "Check now"),
                    dynamicCaption: { [weak self] in self?.updateStatusCaption() ?? "" },
                    icon: "arrow.clockwise",
                    kind: .action(title: String(localized: "Check Now"), destructive: false) { [weak self] in
                        self?.checkNow()
                    }),
            ]),
        ]
    }
}
