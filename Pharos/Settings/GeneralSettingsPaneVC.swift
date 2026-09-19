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
            SettingsSection(title: String(localized: "Session"), items: [
                SettingsItem(
                    id: "restoreWindowFrames",
                    title: String(localized: "Restore window positions"),
                    caption: String(localized: "Puts a restored window back where it was. Off still restores the tabs, and lets macOS place the window — which is what you want after the displays change."),
                    icon: "macwindow",
                    kind: .toggle(.settings(\.session.restoreWindowFrames)),
                    dependsOn: "restoreOpenTabs"),
                SettingsItem(
                    id: "autosaveInterval",
                    title: String(localized: "Autosave the session"),
                    caption: String(localized: "How often the open tabs are written down. Off still saves at quit, so turning it off does not lose the session."),
                    icon: "arrow.clockwise.circle",
                    kind: .popup(.values(\.session.autosaveIntervalSeconds, options: [
                        (title: String(localized: "Every 10 seconds"), value: UInt32(10)),
                        (title: String(localized: "Every 30 seconds"), value: UInt32(30)),
                        (title: String(localized: "Every minute"), value: UInt32(60)),
                        (title: String(localized: "Off"), value: UInt32(0)),
                    ]))),
                // Deliberately NOT `dependsOn: "restoreOpenTabs"`. The warning
                // is worth MORE when restore is off, not less: that is the
                // setting under which a dirty scratch tab is gone for good.
                // Dimming it there would hide the control in exactly the case
                // it matters most. See `UnsavedWorkPolicy`, which is where the
                // two settings actually meet.
                SettingsItem(
                    id: "warnBeforeClosingUnsavedTabs",
                    title: String(localized: "Warn before closing unsaved tabs"),
                    caption: String(localized: "Asks before closing a tab, a window or Pharos itself when a tab has edits that have not been written back to its saved query or its file. A tab that has never been saved is only mentioned while Restore open tabs is off."),
                    icon: "exclamationmark.triangle",
                    kind: .toggle(.settings(\.session.warnBeforeClosingUnsavedTabs))),
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
