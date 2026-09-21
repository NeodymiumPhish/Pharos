import AppKit

/// The panes of the Settings window, in sidebar order.
///
/// The raw value is what `SettingsPanePrefs` stores, so a case is renamed
/// only with a migration. `CaseIterable` order IS the sidebar order.
enum SettingsPaneID: String, CaseIterable {
    case general
    case appearance
    case editor
    case query
    case results
    case navigator
    case library
    case connections
    case security
    case exportImport
    case charts
    case tags
    case intelligence
    case notifications
    case shortcuts
    case advanced
    /// Last, and deliberately so: it is the end of the list, not a setting.
    case about

    /// The accessibility identifier of this pane's sidebar row. The four
    /// panes that existed before the sidebar keep the identifiers the AX
    /// scripts already use.
    var rowIdentifier: String { "settings.pane.\(rawValue)" }
}

/// What the sidebar and the detail header need to know about one pane. The
/// view controller is made elsewhere (`SettingsPaneRegistry.makePane`), so
/// this file compiles with no AppKit view code behind it.
struct SettingsPaneSpec {
    let id: SettingsPaneID
    let title: String
    let symbol: String
    let tint: NSColor
}
