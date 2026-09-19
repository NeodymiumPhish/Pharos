import AppKit

/// Settings ▸ Advanced. The knobs and the buttons that are about Pharos
/// itself rather than about a database.
///
/// The three footer buttons are the pane's reason to exist: a place to look
/// at the logs, a way to make Pharos re-read a schema it has cached, and the
/// way back to a clean slate.
final class AdvancedSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .advanced) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// 0 is "never expire" and the default; the top is a day.
    static let cacheTtlRange = 0...1440

    /// Every `UserDefaults` key Pharos writes that is a PREFERENCE or a piece
    /// of window memory, so "Reset All Settings" can put them back too.
    ///
    /// One named list rather than the keys spelled out at the call site: a
    /// preference added anywhere else has exactly one place to be registered,
    /// and `grep resettableDefaultsKeys` finds it. The strings are repeated
    /// rather than referred to because most of the owners keep them private,
    /// and widening them so this list could name them would be the larger
    /// change; `AdvancedSettingsPaneVCTests` is where a drift would be caught
    /// if one is ever written.
    ///
    /// The split-view autosave keys are the names given to
    /// `NSSplitView.autosaveName`; AppKit stores them under a prefix of its
    /// own, so they are removed by prefix below rather than by exact key.
    static let resettableDefaultsKeys: [String] = [
        // Where the Settings window was left.
        "PharosSettingsPane",
        // The result-tabs panel's width.
        "ResultTabsPanelWidth",
        // Which navigator the sidebar was showing.
        "SidebarLastNavigator2",
        // The editor / results split position.
        "PharosEditorSplitRatio",
        // The update checker's memory: when it last looked, and what it last
        // said. Clearing them means the next check reports again.
        "updateCheckerLastCheckedAt",
        "updateCheckerLastNotifiedVersion",
    ]

    /// The `NSSplitView.autosaveName`s Pharos sets. AppKit writes each one
    /// under `NSSplitView Subview Frames <name>`, so the reset removes by
    /// prefix instead of guessing at AppKit's spelling.
    static let resettableSplitAutosaveNames: [String] = [
        "PharosMainSplit",
        "PharosSettingsSplit",
        "PharosHistoryPreviewSplit",
    ]

    // MARK: - The footer buttons

    private func revealLogs() {
        guard let dir = Diagnostics.logsDirectory() else {
            presentFailure(String(localized: "The logs folder could not be found."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func clearMetadataCache() {
        MetadataCache.shared.clearAll()
        Toast.show(in: view,
                   message: String(localized: "Cached schema metadata cleared."),
                   style: .success)
    }

    /// Put every setting back to its default, after asking once.
    ///
    /// Critical, and not the default button: this is the one control in the
    /// window that cannot be undone by clicking it again.
    private func resetAllSettings() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Reset all settings?")
        alert.informativeText = String(localized: "Every preference goes back to its default, and Pharos forgets where its windows and panels were left. Your connections, saved queries, history and tags are not touched.")
        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Self.applyReset()
            // The panes read the store on every refresh, so the whole window
            // redraws from the defaults with nothing else to press.
            self?.reloadFromSettings()
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    /// The reset itself, with no user interface: the settings record, then the
    /// window memory. Static so a test can reach it without a window.
    static func applyReset(in defaults: UserDefaults = .standard) {
        AppStateManager.shared.saveSettings(AppSettings())
        for key in resettableDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        // AppKit's own key for a split view's stored frames carries a prefix
        // and the autosave name. Removing by prefix survives a change to the
        // rest of that spelling.
        let stored = defaults.dictionaryRepresentation().keys
        for name in resettableSplitAutosaveNames {
            for key in stored where key.hasSuffix(name) && key.contains("Subview Frames") {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - The form

    override var sections: [SettingsSection] {
        [
            SettingsSection(
                title: String(localized: "Schema cache"),
                items: [
                    SettingsItem(
                        id: "metadataCacheTtlMinutes",
                        title: String(localized: "Refetch metadata after"),
                        caption: String(localized: "How old a connection's cached schema may be before Pharos fetches it again. 0 keeps it until the connection closes, which is what Pharos has always done."),
                        icon: "clock.arrow.circlepath",
                        kind: .stepper(.settings(\.diagnostics.metadataCacheTtlMinutes),
                                       range: Self.cacheTtlRange,
                                       unit: String(localized: "minutes"))),
                ],
                footerButtons: [
                    SettingsFooterButton(
                        id: "clearMetadataCache",
                        title: String(localized: "Clear Metadata Cache")) { [weak self] in
                            self?.clearMetadataCache()
                        },
                ]),
            SettingsSection(
                title: String(localized: "Logs"),
                items: [
                    SettingsItem(
                        id: "logsLocation",
                        title: String(localized: "Logs folder"),
                        caption: String(localized: "Crash logs and, where they are collected, the system's performance reports are written to ~/Library/Logs/Pharos."),
                        icon: "doc.text.magnifyingglass",
                        kind: .display),
                ],
                footerButtons: [
                    SettingsFooterButton(
                        id: "revealLogs",
                        title: String(localized: "Reveal Logs in Finder")) { [weak self] in
                            self?.revealLogs()
                        },
                ]),
            SettingsSection(
                title: String(localized: "Reset"),
                items: [
                    SettingsItem(
                        id: "resetNote",
                        title: String(localized: "Start again"),
                        caption: String(localized: "Puts every preference back to its default and forgets where the windows and panels were left. Connections, saved queries, history and tags stay."),
                        icon: "arrow.counterclockwise",
                        kind: .display),
                ],
                footerButtons: [
                    SettingsFooterButton(
                        id: "resetAllSettings",
                        title: String(localized: "Reset All Settings\u{2026}"),
                        destructive: true) { [weak self] in
                            self?.resetAllSettings()
                        },
                ]),
        ]
    }
}
