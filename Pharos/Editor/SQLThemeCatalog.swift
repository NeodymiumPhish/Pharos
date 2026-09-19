import AppKit

// The named syntax colour schemes offered by Settings ▸ Editor ▸ Colours.
//
// `SQLTheme` itself stays a plain bag of colours in SQLSyntaxHighlighter.swift;
// this file is the catalogue that turns a STORED NAME into one. The stored
// value is a name rather than an index so a theme can be added, reordered or
// removed without rewriting everyone's settings.

extension SQLTheme {

    /// One entry of the catalogue: what is stored, what is shown, and the
    /// colours themselves.
    struct Named {
        /// The value written to settings. Never localised.
        let name: String
        /// The row title in Settings. Localised.
        let displayLabel: String
        let theme: SQLTheme
    }

    /// The name every new install starts on, and the one an unreadable stored
    /// name falls back to.
    static let systemThemeName = "system"

    /// Every theme on offer, in the order the popup lists them.
    static let catalog: [Named] = [
        Named(name: systemThemeName,
              displayLabel: String(localized: "System"),
              theme: .default),
        Named(name: "vivid",
              displayLabel: String(localized: "Vivid"),
              theme: .vivid),
        Named(name: "dusk",
              displayLabel: String(localized: "Dusk"),
              theme: .dusk),
    ]

    /// The stored names, in catalogue order.
    static var availableNames: [String] { catalog.map(\.name) }

    /// The theme stored under `name`, or the System theme when the name is
    /// not one this build knows — a settings file written by a newer build,
    /// or a theme that has since been withdrawn.
    static func named(_ name: String) -> SQLTheme {
        catalog.first { $0.name == name }?.theme ?? .default
    }

    /// The title shown for `name`, or the System title for an unknown one.
    static func displayLabel(for name: String) -> String {
        catalog.first { $0.name == name }?.displayLabel
            ?? catalog[0].displayLabel
    }

    // MARK: - The extra themes

    /// Saturated and high-contrast: the roles pull as far apart as the system
    /// palette allows, for a large display or a bright room.
    static let vivid = SQLTheme(
        keyword: dynamic(light: 0x0A46D6, dark: 0x6EA8FF),
        function: dynamic(light: 0x0B7A75, dark: 0x4FD6CE),
        string: dynamic(light: 0x0E7A2E, dark: 0x5BE07C),
        number: dynamic(light: 0xB3541E, dark: 0xFFA759),
        comment: dynamic(light: 0x6E6E73, dark: 0x9A9AA0),
        type: dynamic(light: 0x7A1FA2, dark: 0xD08CFF),
        variable: dynamic(light: 0x3A2ECC, dark: 0x9E96FF),
        variableUnresolved: dynamic(light: 0xC1121F, dark: 0xFF6B6B)
    )

    /// Low-chroma: the colours stay distinguishable but stop competing with
    /// the text, for long editing sessions.
    static let dusk = SQLTheme(
        keyword: dynamic(light: 0x4A5C7A, dark: 0x9FB3D1),
        function: dynamic(light: 0x4A6F6B, dark: 0x9BC4BE),
        string: dynamic(light: 0x5A7052, dark: 0xA9C59B),
        number: dynamic(light: 0x8A6A45, dark: 0xD4B78F),
        comment: dynamic(light: 0x8E8E93, dark: 0x7C7C82),
        type: dynamic(light: 0x6B5A7A, dark: 0xBCA9D1),
        variable: dynamic(light: 0x55568A, dark: 0xADAED6),
        variableUnresolved: dynamic(light: 0x9C4F4F, dark: 0xD79A9A)
    )

    /// A colour that follows the window's appearance. Both halves are given
    /// as sRGB hex so the two themes read the same way on every Mac, whatever
    /// the accent colour is set to.
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return srgb(isDark ? dark : light)
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
