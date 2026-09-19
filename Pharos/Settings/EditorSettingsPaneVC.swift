import AppKit

/// Settings ▸ Editor. The SQL editor's font, its tab width, and the two
/// display switches.
final class EditorSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .editor) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    static let fontSizeRange = 8...36

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Font"), items: [
                SettingsItem(
                    id: "font",
                    title: String(localized: "Font"),
                    caption: String(localized: "Only installed monospace fonts are listed."),
                    icon: "textformat",
                    kind: .popup(Self.fontChoice())),
                SettingsItem(
                    id: "fontSize",
                    title: String(localized: "Size"),
                    icon: "textformat.size",
                    kind: .stepper(.settings(\.editor.fontSize), range: Self.fontSizeRange, unit: String(localized: "pt"))),
            ]),
            SettingsSection(title: String(localized: "Text"), items: [
                SettingsItem(
                    id: "tabSize",
                    title: String(localized: "Tab size"),
                    icon: "arrow.right.to.line",
                    kind: .popup(.values(\.editor.tabSize, options: [
                        (title: String(localized: "2 spaces"), value: UInt32(2)),
                        (title: String(localized: "3 spaces"), value: UInt32(3)),
                        (title: String(localized: "4 spaces"), value: UInt32(4)),
                        (title: String(localized: "8 spaces"), value: UInt32(8)),
                    ]))),
                SettingsItem(
                    id: "wordWrap",
                    title: String(localized: "Wrap long lines"),
                    icon: "text.word.spacing",
                    kind: .toggle(.settings(\.editor.wordWrap))),
                SettingsItem(
                    id: "lineNumbers",
                    title: String(localized: "Show line numbers"),
                    icon: "list.number",
                    kind: .toggle(.settings(\.editor.lineNumbers))),
            ]),
        ]
    }

    // MARK: - Fonts

    private struct MonoFont {
        let displayName: String
        let postScriptName: String
    }

    static let systemMonospaceTitle = "System Monospace"

    private static let monoFonts: [MonoFont] = [
        MonoFont(displayName: "Menlo", postScriptName: "Menlo-Regular"),
        MonoFont(displayName: "Monaco", postScriptName: "Monaco"),
        MonoFont(displayName: "SF Mono", postScriptName: "SFMono-Regular"),
        MonoFont(displayName: "JetBrains Mono", postScriptName: "JetBrainsMono-Regular"),
        MonoFont(displayName: "Fira Code", postScriptName: "FiraCode-Regular"),
        MonoFont(displayName: "Source Code Pro", postScriptName: "SourceCodePro-Regular"),
        MonoFont(displayName: "Courier New", postScriptName: "CourierNewPSMT"),
    ]

    /// The installed monospace fonts, System Monospace first. The stored
    /// `fontFamily` may be a CSS-style list ("JetBrains Mono, Monaco, …"):
    /// its first name selects the row; a name that is not installed shows as
    /// System Monospace and is left unchanged until the user picks one.
    @MainActor
    private static func fontChoice() -> SettingsChoice {
        var titles = [systemMonospaceTitle]
        titles += monoFonts.filter { NSFont(name: $0.postScriptName, size: 13) != nil }.map(\.displayName)
        let binding = SettingsBinding<String>.settings(\.editor.fontFamily).map(
            to: { family -> String in
                let first = family.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? family
                return titles.contains(first) ? first : systemMonospaceTitle
            },
            from: { $0 })
        return SettingsChoice(options: titles.map { (title: $0, value: $0) }, binding: binding)
    }
}
