import AppKit

/// Settings ▸ Navigator. What the Database Navigator shows.
final class NavigatorSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .navigator) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Objects"), items: [
                SettingsItem(
                    id: "showLeafPartitions",
                    title: String(localized: "Show leaf partitions"),
                    caption: String(localized: "A Partitions folder under each partitioned table."),
                    icon: "square.split.2x2",
                    kind: .toggle(.settings(\.showLeafPartitions))),
            ]),
        ]
    }
}
