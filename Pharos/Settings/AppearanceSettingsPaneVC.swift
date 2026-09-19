import AppKit

/// Settings ▸ Appearance. The colour scheme, how NULL and booleans render,
/// and the layout switches.
final class AppearanceSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .appearance) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Theme"), items: [
                SettingsItem(
                    id: "appearance",
                    title: String(localized: "Appearance"),
                    caption: String(localized: "Auto follows the system."),
                    icon: "circle.lefthalf.filled",
                    kind: .segmented(.values(\.theme, options: [
                        (title: String(localized: "Auto"), value: .auto),
                        (title: String(localized: "Light"), value: .light),
                        (title: String(localized: "Dark"), value: .dark),
                    ]))),
            ]),
            SettingsSection(title: String(localized: "Values"), items: [
                SettingsItem(
                    id: "nullDisplay",
                    title: String(localized: "NULL display"),
                    caption: String(localized: "How NULL renders in the grid and the Inspector."),
                    icon: "circle.slash",
                    kind: .popup(.cases(\.nullDisplay, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "boolDisplay",
                    title: String(localized: "Boolean display"),
                    icon: "checkmark.square",
                    kind: .popup(.cases(\.boolDisplay, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "nullStyle",
                    title: String(localized: "NULL style"),
                    caption: String(localized: "How a NULL is set apart from a real value. Differentiate Without Color keeps the italic face whatever this says."),
                    icon: "textformat.abc.dottedunderline",
                    kind: .popup(.cases(\.results.nullStyle, title: { $0.displayLabel }))),
            ]),
            SettingsSection(title: String(localized: "Layout"), items: [
                SettingsItem(
                    id: "verticalResultTabs",
                    title: String(localized: "Show result tabs in a vertical panel"),
                    caption: String(localized: "Off lists them along a bar above the results grid instead."),
                    icon: "sidebar.right",
                    kind: .toggle(.settings(\.verticalResultTabs))),
                SettingsItem(
                    id: "alwaysShowScrollBars",
                    title: String(localized: "Always show scroll bars"),
                    caption: String(localized: "In the editor and the results. Off follows the system's scroll-bar preference."),
                    icon: "scroll",
                    kind: .toggle(.settings(\.alwaysShowScrollBars))),
            ]),
        ]
    }
}
