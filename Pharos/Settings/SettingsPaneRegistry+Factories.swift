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
        case .library: return LibrarySettingsPaneVC()
        case .connections: return ConnectionsSettingsPaneVC()
        case .security: return SecuritySettingsPaneVC()
        case .exportImport: return ExportImportSettingsPaneVC()
        case .charts: return ChartsSettingsPaneVC()
        case .tags: return TagsSettingsPaneVC()
        case .intelligence: return IntelligenceSettingsPaneVC()
        case .notifications: return NotificationsSettingsPaneVC()
        case .shortcuts: return ShortcutsSettingsPaneVC()
        case .advanced: return AdvancedSettingsPaneVC()
        }
    }
}

// `SettingsPlaceholderPaneVC` used to live here, showing a "No Items" row for
// a pane not built yet. Every pane is real now, so it was dead code and has
// gone. `SettingsItemKind.empty` still exists for a pane whose CONTENT can be
// empty at run time — a list with nothing in it — which is a different thing
// from a pane nobody has written.
