import AppKit

/// Settings ▸ Query. What Cmd+Return runs, the row limit and timeout, the
/// destructive-statement guard, and how a failure interrupts.
final class QuerySettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .query) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    static let limitRange = 1...100_000
    static let timeoutRange = 1...3600

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Run"), items: [
                SettingsItem(
                    id: "runScope",
                    title: String(localized: "⌘↩ runs"),
                    caption: String(localized: "The statement at the cursor is what Pharos has always run. Run All Queries always runs every statement, whatever this says."),
                    icon: "play.rectangle",
                    kind: .popup(.cases(\.query.runScope, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "Rows"), items: [
                SettingsItem(
                    id: "defaultLimit",
                    title: String(localized: "Row limit"),
                    caption: String(localized: "Rows returned per query page. Load More fetches the next page."),
                    icon: "tablecells",
                    kind: .stepper(.settings(\.query.defaultLimit), range: Self.limitRange, unit: String(localized: "rows"))),
                SettingsItem(
                    id: "timeout",
                    title: String(localized: "Statement timeout"),
                    caption: String(localized: "PostgreSQL cancels a query that runs longer than this."),
                    icon: "timer",
                    kind: .stepper(.settings(\.query.timeoutSeconds), range: Self.timeoutRange, unit: String(localized: "seconds"))),
            ]),

            SettingsSection(title: String(localized: "Safety"), items: [
                SettingsItem(
                    id: "confirmDestructive",
                    title: String(localized: "Confirm queries that change the database"),
                    caption: String(localized: "Also guards the destructive actions in the Database Navigator. Detection ignores keywords inside strings, comments and quoted identifiers."),
                    icon: "exclamationmark.shield",
                    kind: .toggle(.settings(\.query.confirmDestructive))),
                SettingsItem(
                    id: "confirmDrop",
                    title: String(localized: "DROP"),
                    icon: "trash",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.dropObject)),
                    dependsOn: "confirmDestructive"),
                SettingsItem(
                    id: "confirmAlter",
                    title: String(localized: "ALTER"),
                    icon: "pencil.and.outline",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.alter)),
                    dependsOn: "confirmDestructive"),
                SettingsItem(
                    id: "confirmTruncate",
                    title: String(localized: "TRUNCATE"),
                    icon: "xmark.bin",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.truncate)),
                    dependsOn: "confirmDestructive"),
                SettingsItem(
                    id: "confirmDelete",
                    title: String(localized: "DELETE"),
                    icon: "minus.circle",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.delete)),
                    dependsOn: "confirmDestructive"),
                SettingsItem(
                    id: "confirmUpdate",
                    title: String(localized: "UPDATE"),
                    icon: "arrow.triangle.2.circlepath",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.update)),
                    dependsOn: "confirmDestructive"),
                SettingsItem(
                    id: "confirmInsert",
                    title: String(localized: "INSERT"),
                    icon: "plus.circle",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.insert)),
                    dependsOn: "confirmDestructive"),
                SettingsItem(
                    id: "confirmGrant",
                    title: String(localized: "GRANT and REVOKE"),
                    icon: "key",
                    kind: .toggle(.settings(\.query.destructiveConfirmations.grant)),
                    dependsOn: "confirmDestructive"),
            ]),

            SettingsSection(title: String(localized: "Errors"), items: [
                SettingsItem(
                    id: "failureAlertStyle",
                    title: String(localized: "When a query fails"),
                    caption: String(localized: "The failure is recorded on its tab whatever this says, and the tab's error badge always opens the full list."),
                    icon: "exclamationmark.triangle",
                    kind: .popup(.cases(\.query.failureAlertStyle, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "errorSheetTrigger",
                    title: String(localized: "Open the error sheet on"),
                    caption: String(localized: "The second failure is what Pharos has always done: the first one gets a banner instead, so the editor stays usable."),
                    icon: "doc.text.magnifyingglass",
                    kind: .popup(.cases(\.query.errorSheetTrigger, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "showCancelledDialog",
                    title: String(localized: "Show details when you cancel a query"),
                    caption: String(localized: "The cancellation is recorded on its tab either way."),
                    icon: "xmark.circle",
                    kind: .toggle(.settings(\.query.showCancelledQueryDialog))),
            ]),
        ]
    }
}
