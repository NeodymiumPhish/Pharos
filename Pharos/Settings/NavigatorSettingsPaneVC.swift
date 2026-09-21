import AppKit

/// Settings ▸ Navigator. What the Database Navigator shows, in what order,
/// and what a double-click on a row does.
///
/// Every default is what the Navigator did before the setting existed, so an
/// existing user sees no change until they touch a control. The ordering
/// rules themselves are `NavigatorOrdering` and `PartitionOrdering`, both
/// tested on their own.
final class NavigatorSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .navigator) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// The preset sets the "View Contents (Limit…)" submenu can offer. A set
    /// at a time, not a list the user edits: a four-row submenu is furniture,
    /// and a list editor for it would be more machinery than the choice is
    /// worth. The first set is what the submenu was hard-coded to.
    private static let limitPresetSets: [(title: String, value: [UInt32])] = [
        (String(localized: "10 / 100 / 1,000 / 10,000"), [10, 100, 1000, 10000]),
        (String(localized: "10 / 50 / 100 / 500"), [10, 50, 100, 500]),
        (String(localized: "100 / 1,000 / 10,000 / 100,000"), [100, 1000, 10000, 100000]),
        (String(localized: "1,000 only"), [1000]),
    ]

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Schemas"), items: [
                SettingsItem(
                    id: "schemaSort",
                    title: String(localized: "Order schemas by"),
                    caption: String(localized: "Default schema first lifts the schema the connection names to the top, and leaves the rest by name."),
                    icon: "list.bullet.indent",
                    help: String(localized: "A connection that names none keeps every schema by name."),
                    kind: .popup(.cases(\.navigator.schemaSort, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "showSystemSchemas",
                    title: String(localized: "Show system schemas"),
                    caption: String(localized: "Lists pg_catalog and information_schema beside your own."),
                    icon: "gearshape.2",
                    help: String(localized: "The storage schemas — pg_toast and the per-session pg_temp ones — stay hidden whichever way this is set: there can be thousands, and none of them holds anything to read."),
                    kind: .toggle(.settings(\.navigator.showSystemSchemas))),
            ]),

            SettingsSection(title: String(localized: "Objects"), items: [
                SettingsItem(
                    id: "objectSort",
                    title: String(localized: "Order objects by"),
                    caption: String(localized: "Size and Row estimate put the largest first and leave objects that have not been measured at the end, by name — an unmeasured table is not a small one."),
                    icon: "arrow.up.arrow.down",
                    kind: .popup(.cases(\.navigator.objectSort, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "showLeafPartitions",
                    title: String(localized: "Show leaf partitions"),
                    caption: String(localized: "A Partitions folder under each partitioned table."),
                    icon: "square.split.2x2",
                    kind: .toggle(.settings(\.showLeafPartitions))),
                SettingsItem(
                    id: "partitionSort",
                    title: String(localized: "Order partitions by"),
                    caption: String(localized: "Partition bound reads each partition's own FROM or IN value, so a range-partitioned table reads in date order; DEFAULT comes last."),
                    icon: "square.split.2x2",
                    kind: .popup(.cases(\.navigator.partitionSort, title: { $0.displayLabel })),
                    dependsOn: "showLeafPartitions"),
                SettingsItem(
                    id: "autoExpandDefaultSchema",
                    title: String(localized: "Open the default schema"),
                    caption: String(localized: "Expands the schema the connection names — or public, when it names none — as soon as the tree is built."),
                    icon: "chevron.down.square",
                    kind: .toggle(.settings(\.navigator.autoExpandDefaultSchema))),
                SettingsItem(
                    id: "autoExpandThreshold",
                    title: String(localized: "Only below"),
                    caption: String(localized: "Objects."),
                    icon: "number.square",
                    help: String(localized: "Opening one row with more children than this blocks the app for seconds, so a schema above the ceiling waits for you to click its disclosure triangle."),
                    kind: .stepper(.settings(\.navigator.autoExpandThreshold), range: 0...100000,
                                   unit: String(localized: "objects")),
                    dependsOn: "autoExpandDefaultSchema"),
            ]),

            SettingsSection(title: String(localized: "Actions"), items: [
                SettingsItem(
                    id: "doubleClickAction",
                    title: String(localized: "On double-click"),
                    caption: String(localized: "Every action but Expand runs exactly what the row's context menu runs."),
                    icon: "cursorarrow.click.2",
                    help: String(localized: "A row the action means nothing for — a schema, a column — still expands. Describe opens the table's DDL sheet, and only a plain table has one."),
                    kind: .popup(.cases(\.navigator.doubleClickAction, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "viewContentsUsesRowLimit",
                    title: String(localized: "Limit the rows View contents fetches"),
                    caption: String(localized: "Uses Settings ▸ Query ▸ Default row limit."),
                    icon: "arrow.down.to.line",
                    help: String(localized: "Off selects every row, which is what the context menu's View All Contents does."),
                    kind: .toggle(.settings(\.navigator.viewContentsUsesRowLimit)),
                    availability: {
                        AppStateManager.shared.settings.navigator.doubleClickAction == .viewContents
                            ? .available
                            : .unavailable(reason: String(localized: "Used only while a double-click views contents."))
                    }),
                SettingsItem(
                    id: "limitPresets",
                    title: String(localized: "Row counts in the Limit menu"),
                    caption: String(localized: "The rows the Navigator's “View Contents (Limit…)” submenu offers on a table, a view or a partition."),
                    icon: "list.number",
                    kind: .popup(.values(\.navigator.limitPresets, options: Self.limitPresetSets))),
            ]),
        ]
    }
}
