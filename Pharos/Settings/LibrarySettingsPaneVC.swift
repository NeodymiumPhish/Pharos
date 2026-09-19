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
                    caption: String(localized: "The folder the Save Query sheet opens on. Leave it empty to open on No Folder. A name no folder carries yet is ignored — the sheet lists the folders your saved queries are in, and New Folder… still makes one."),
                    icon: "folder",
                    kind: .text(.settings(\.library.defaultFolder), width: 180)),
                SettingsItem(
                    id: "sortMode",
                    title: String(localized: "Order queries by"),
                    caption: String(localized: "Folder, then name is the grouped tree with a row per folder. Name and Recently updated are one flat list, with no folder rows — the folder a query is in is unchanged, only hidden."),
                    icon: "arrow.up.arrow.down",
                    kind: .popup(.cases(\.library.sortMode, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "doubleClickAction",
                    title: String(localized: "On double-click"),
                    caption: String(localized: "Open in a tab and run it runs the query as soon as its tab is there. A tab with no connection opens the query and stops, and the context menu's Open in Tab always just opens."),
                    icon: "cursorarrow.click.2",
                    kind: .popup(.cases(\.library.doubleClickAction, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "History"), items: [
                SettingsItem(
                    id: "maximumEntries",
                    title: String(localized: "Entries to load"),
                    caption: String(localized: "How many of the newest entries the Results History navigator fetches. The list is one fetch, not pages, so this is all of the history you can see at once. Nothing is deleted: a lower number only shows fewer."),
                    icon: "clock.arrow.circlepath",
                    kind: .stepper(.settings(\.history.maximumEntries), range: 10...5000,
                                   unit: String(localized: "entries"))),
            ]),
        ]
    }
}
