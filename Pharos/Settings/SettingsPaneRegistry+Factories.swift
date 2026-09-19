import AppKit

extension SettingsPaneRegistry {

    /// The view controller for a pane. One arm per case: the compiler makes
    /// a new `SettingsPaneID` case fail to build until its pane exists.
    @MainActor
    static func makePane(_ id: SettingsPaneID) -> SettingsPaneVC {
        switch id {
        case .general: return GeneralSettingsPaneVC()
        case .appearance: return AppearanceSettingsPaneVC()
        case .editor: return EditorSettingsPaneVC()
        case .query: return QuerySettingsPaneVC()
        case .results: return ResultsSettingsPaneVC()
        case .navigator: return NavigatorSettingsPaneVC()
        case .library: return SettingsPlaceholderPaneVC(paneId: id)
        case .connections: return SettingsPlaceholderPaneVC(paneId: id)
        case .security: return SettingsPlaceholderPaneVC(paneId: id)
        case .exportImport: return SettingsPlaceholderPaneVC(paneId: id)
        case .charts: return ChartsSettingsPaneVC()
        case .tags: return SettingsPlaceholderPaneVC(paneId: id)
        case .intelligence: return IntelligenceSettingsPaneVC()
        case .notifications: return NotificationsSettingsPaneVC()
        case .shortcuts: return SettingsPlaceholderPaneVC(paneId: id)
        case .advanced: return SettingsPlaceholderPaneVC(paneId: id)
        }
    }
}

/// A pane with nothing in it yet. Shows the "No Items" row the HIG asks for
/// instead of an empty surface.
final class SettingsPlaceholderPaneVC: SettingsFormPaneVC {
    override var sections: [SettingsSection] {
        [SettingsSection(title: nil, items: [
            SettingsItem(id: "empty", title: "", kind: .empty(String(localized: "No Items"))),
        ])]
    }
}
