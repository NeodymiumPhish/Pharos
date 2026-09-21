import AppKit

/// Settings ▸ Library & History. The Query Library navigator and the Save
/// Query sheet, then the Results History navigator.
///
/// Every default is what these two navigators did before the setting existed.
/// Retention and the result-cache ceiling are not here: both are decided in
/// `pharos-core`, and a control for a rule the core does not read yet would
/// do nothing.
final class LibrarySettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .library) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Query Library"), items: [
                SettingsItem(
                    id: "defaultFolder",
                    title: String(localized: "Default folder"),
                    caption: String(localized: "The folder the Save Query sheet opens on."),
                    icon: "folder",
                    help: String(localized: "Leave it empty to open on No Folder. A name no folder carries yet is ignored — the sheet lists the folders your saved queries are in, and New Folder… still makes one."),
                    kind: .text(.settings(\.library.defaultFolder), width: 180)),
                SettingsItem(
                    id: "sortMode",
                    title: String(localized: "Order queries by"),
                    caption: String(localized: "Folder, then name is the grouped tree with a row per folder."),
                    icon: "arrow.up.arrow.down",
                    help: String(localized: "Name and Recently updated are one flat list, with no folder rows — the folder a query is in is unchanged, only hidden."),
                    kind: .popup(.cases(\.library.sortMode, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "doubleClickAction",
                    title: String(localized: "On double-click"),
                    caption: String(localized: "Open in a tab and run it runs the query as soon as its tab is there."),
                    icon: "cursorarrow.click.2",
                    help: String(localized: "A tab with no connection opens the query and stops, and the context menu's Open in Tab always just opens."),
                    kind: .popup(.cases(\.library.doubleClickAction, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "History"), items: [
                SettingsItem(
                    id: "maximumEntries",
                    title: String(localized: "Entries to load"),
                    caption: String(localized: "How many of the newest entries the Results History navigator fetches."),
                    icon: "clock.arrow.circlepath",
                    help: String(localized: "The list is one fetch, not pages, so this is all of the history you can see at once. Nothing is deleted: a lower number only shows fewer."),
                    kind: .stepper(.settings(\.history.maximumEntries), range: 10...5000,
                                   unit: String(localized: "entries"))),
                SettingsItem(
                    id: "retentionDays",
                    title: String(localized: "Keep history for"),
                    caption: String(localized: "Older entries and their cached results are removed as new queries are recorded. Forever keeps everything."),
                    icon: "calendar.badge.clock",
                    kind: .popup(.values(\.history.retentionDays, options: [
                        (title: String(localized: "7 days"), value: UInt32(7)),
                        (title: String(localized: "30 days"), value: UInt32(30)),
                        (title: String(localized: "90 days"), value: UInt32(90)),
                        (title: String(localized: "A year"), value: UInt32(365)),
                        (title: String(localized: "Forever"), value: UInt32(0)),
                    ]))),
                SettingsItem(
                    id: "recordFailedQueries",
                    title: String(localized: "Record failed queries"),
                    caption: String(localized: "A query that fails leaves a row in the history, with the server's message, beside the ones that worked."),
                    icon: "exclamationmark.triangle",
                    help: String(localized: "The Results History navigator's Failed scope lists them on their own. Only answers from the server are kept — a refusal Pharos makes itself, such as running with no connection, is never recorded."),
                    kind: .toggle(.settings(\.history.recordFailedQueries))),
                SettingsItem(
                    id: "maximumStoredEntries",
                    title: String(localized: "Entries to keep"),
                    caption: String(localized: "A ceiling on the whole history, newest kept. 0 is no ceiling. Both limits apply: whichever removes an entry first wins."),
                    icon: "tray.full",
                    kind: .stepper(.settings(\.history.maximumStoredEntries), range: 0...100_000,
                                   unit: String(localized: "entries"))),
            ], footerButtons: [
                SettingsFooterButton(id: "clearHistory",
                                     title: String(localized: "Clear Query History…"),
                                     destructive: true) { [weak self] in
                    self?.confirmClearHistory()
                },
            ]),
        ]
    }

    // MARK: - Clearing

    /// Ask, then clear. The dialog names the COUNT first, read from the store
    /// with the same scope the clear will use, so the number the user agrees
    /// to is the number that goes. A clear cannot be undone, so it is a
    /// `.critical` alert and the destructive button is not the default.
    private func confirmClearHistory() {
        let count: Int
        do {
            count = try PharosCore.countQueryHistory()
        } catch {
            presentClearFailure(error)
            return
        }

        guard count > 0 else {
            let empty = NSAlert()
            empty.messageText = String(localized: "There is no query history to clear.")
            empty.alertStyle = .informational
            empty.addButton(withTitle: String(localized: "OK"))
            runAlert(empty)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Clear all query history?")
        alert.informativeText = String(
            localized: "\(count) entries will be deleted, with the cached results of each. Workspaces left with no entries are removed too. This cannot be undone.")
        let clear = alert.addButton(withTitle: String(localized: "Clear History"))
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        // Cancel is the safe answer, so Return must not fire the clear.
        alert.buttons.last?.keyEquivalent = "\r"
        clear.keyEquivalent = ""

        guard runAlert(alert) == .alertFirstButtonReturn else { return }

        do {
            let deleted = try PharosCore.clearQueryHistory()
            // The navigators watch this; without it a cleared history keeps
            // showing rows that are no longer there.
            NotificationCenter.default.post(name: .queryHistoryDidChange, object: nil)
            NotificationCenter.default.post(name: .workspaceHistoryDidChange, object: nil)
            Log.state.info("Cleared \(deleted, privacy: .public) query history entries")
        } catch {
            presentClearFailure(error)
        }
    }

    private func presentClearFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Query history could not be cleared.")
        alert.informativeText = DisplayEscape.escapedMultiline(error.localizedDescription)
        alert.addButton(withTitle: String(localized: "OK"))
        runAlert(alert)
    }

    /// As a sheet on the Settings window when there is one, modal otherwise.
    /// A sheet keeps the dialog attached to the window it came from.
    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard let window = view.window else { return alert.runModal() }
        var response: NSApplication.ModalResponse = .cancel
        alert.beginSheetModal(for: window) { response = $0; NSApp.stopModal() }
        NSApp.runModal(for: window)
        return response
    }
}
