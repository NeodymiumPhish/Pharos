import AppKit

/// The ONE list of panes. Adding a pane = one `SettingsPaneID` case, one line
/// here, one arm in `SettingsPaneRegistry+Factories.swift` (the compiler
/// insists on the arm) and one view-controller file.
enum SettingsPaneRegistry {

    static let all: [SettingsPaneSpec] = [
        SettingsPaneSpec(id: .general, title: String(localized: "General"),
                         symbol: "gearshape", tint: .systemGray),
        SettingsPaneSpec(id: .appearance, title: String(localized: "Appearance"),
                         symbol: "circle.lefthalf.filled", tint: .systemBlue),
        SettingsPaneSpec(id: .editor, title: String(localized: "Editor"),
                         symbol: "text.cursor", tint: .systemOrange),
        SettingsPaneSpec(id: .query, title: String(localized: "Query"),
                         symbol: "play.rectangle", tint: .systemGreen),
        SettingsPaneSpec(id: .results, title: String(localized: "Results"),
                         symbol: "tablecells", tint: .systemTeal),
        SettingsPaneSpec(id: .navigator, title: String(localized: "Navigator"),
                         symbol: "sidebar.left", tint: .systemPurple),
        SettingsPaneSpec(id: .library, title: String(localized: "Library & History"),
                         symbol: "books.vertical", tint: .systemBrown),
        SettingsPaneSpec(id: .connections, title: String(localized: "Connections"),
                         symbol: "server.rack", tint: .systemIndigo),
        SettingsPaneSpec(id: .security, title: String(localized: "Security & Privacy"),
                         symbol: "lock.shield", tint: .systemRed),
        SettingsPaneSpec(id: .exportImport, title: String(localized: "Export & Import"),
                         symbol: "square.and.arrow.up", tint: .systemCyan),
        SettingsPaneSpec(id: .charts, title: String(localized: "Charts"),
                         symbol: "chart.bar", tint: .systemPink),
        SettingsPaneSpec(id: .tags, title: String(localized: "Tags"),
                         symbol: "tag", tint: .systemYellow),
        SettingsPaneSpec(id: .intelligence, title: String(localized: "Intelligence"),
                         symbol: "sparkles", tint: NSColor(srgbRed: 0.58, green: 0.40, blue: 0.93, alpha: 1)),
        SettingsPaneSpec(id: .notifications, title: String(localized: "Notifications"),
                         symbol: "bell.badge", tint: .systemRed),
        SettingsPaneSpec(id: .shortcuts, title: String(localized: "Shortcuts"),
                         symbol: "keyboard", tint: .systemGray),
        SettingsPaneSpec(id: .advanced, title: String(localized: "Advanced"),
                         symbol: "wrench.and.screwdriver", tint: .systemGray),
    ]

    static func spec(for id: SettingsPaneID) -> SettingsPaneSpec {
        // `all` covers every case; the test pins it.
        all.first { $0.id == id } ?? all[0]
    }
}
