import AppKit

/// Settings ▸ Query. Row limit, timeout, the destructive-statement guard and
/// the cancel dialog.
final class QuerySettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .query) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    static let limitRange = 1...100_000
    static let timeoutRange = 1...3600

    override var sections: [SettingsSection] {
        [
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
                    caption: String(localized: "Asks before DROP, DELETE, TRUNCATE, UPDATE, ALTER, INSERT or GRANT, and before destructive Navigator actions."),
                    icon: "exclamationmark.shield",
                    kind: .toggle(.settings(\.query.confirmDestructive))),
            ]),
            SettingsSection(title: String(localized: "Errors"), items: [
                SettingsItem(
                    id: "showCancelledDialog",
                    title: String(localized: "Show details when you cancel a query"),
                    caption: String(localized: "The failure is recorded on its tab either way."),
                    icon: "xmark.circle",
                    kind: .toggle(.settings(\.query.showCancelledQueryDialog))),
            ]),
        ]
    }
}
