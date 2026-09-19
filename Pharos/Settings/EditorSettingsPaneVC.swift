import AppKit

/// Settings ▸ Editor. Everything about the SQL editor itself: its font, what
/// Tab and Return write, what the gutter carries, when the completion list
/// opens, what a paste offers, and which colours the syntax takes.
///
/// Every default is what the editor did before the setting existed, so an
/// existing user sees no change until they touch a control.
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
                    id: "insertSpacesForTab",
                    title: String(localized: "Insert spaces for Tab"),
                    caption: String(localized: "Off writes one tab character instead. Shift-Tab takes back one level either way."),
                    icon: "space",
                    kind: .toggle(.settings(\.editor.insertSpacesForTab))),
                SettingsItem(
                    id: "autoIndent",
                    title: String(localized: "Indent new lines automatically"),
                    caption: String(localized: "Return copies the leading whitespace of the line you are leaving."),
                    icon: "increase.indent",
                    kind: .toggle(.settings(\.editor.autoIndent))),
                SettingsItem(
                    id: "autoPairBrackets",
                    title: String(localized: "Close brackets automatically"),
                    caption: String(localized: "Typing ( or [ also writes the closer, and Backspace over an empty pair takes both away. Typing straight before existing text never pairs."),
                    icon: "parentheses",
                    kind: .toggle(.settings(\.editor.autoPairBrackets))),
                SettingsItem(
                    id: "autoPairQuotes",
                    title: String(localized: "Close quotes automatically"),
                    caption: String(localized: "The same for '. An apostrophe typed after a letter is left alone."),
                    icon: "quote.opening",
                    kind: .toggle(.settings(\.editor.autoPairQuotes))),
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
                SettingsItem(
                    id: "highlightCurrentLine",
                    title: String(localized: "Highlight the current line"),
                    caption: String(localized: "A faint wash behind the line holding the caret."),
                    icon: "text.line.first.and.arrowtriangle.forward",
                    kind: .toggle(.settings(\.editor.highlightCurrentLine))),
                SettingsItem(
                    id: "showRunButtonsInGutter",
                    title: String(localized: "Show run buttons in the gutter"),
                    caption: String(localized: "The band beside each statement, and the play glyph it shows on hover. ⌘Return still runs the statement at the cursor."),
                    icon: "play.rectangle",
                    kind: .toggle(.settings(\.editor.showRunButtonsInGutter))),
                SettingsItem(
                    id: "codeFolding",
                    title: String(localized: "Allow code folding"),
                    caption: String(localized: "The chevrons that collapse a CTE, a subquery, a CASE or a BEGIN block. Turning this off opens everything that is folded."),
                    icon: "chevron.down.square",
                    kind: .toggle(.settings(\.editor.codeFolding))),
                SettingsItem(
                    id: "minimumLinesToFold",
                    title: String(localized: "Minimum lines to fold"),
                    caption: String(localized: "A shorter region gets no chevron."),
                    icon: "arrow.down.right.and.arrow.up.left",
                    kind: .stepper(.settings(\.editor.minimumLinesToFold), range: 2...50,
                                   unit: String(localized: "lines")),
                    dependsOn: "codeFolding"),
            ]),

            SettingsSection(title: String(localized: "Completion"), items: [
                SettingsItem(
                    id: "completionTrigger",
                    title: String(localized: "Open the list"),
                    caption: String(localized: "Control-Space always opens it, whichever this says. It never opens inside a string or a comment."),
                    icon: "text.append",
                    kind: .popup(.cases(\.editor.completionTrigger, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "completionMinimumCharacters",
                    title: String(localized: "Characters before suggesting"),
                    caption: String(localized: "Used only while the list opens “After a dot, and while typing”. A dot opens it whatever this says."),
                    icon: "character.cursor.ibeam",
                    kind: .stepper(.settings(\.editor.completionMinimumCharacters), range: 1...5, unit: nil)),
                SettingsItem(
                    id: "completionMaximumItems",
                    title: String(localized: "Maximum suggestions"),
                    caption: String(localized: "The most rows the list ever holds. A large schema can match thousands; building them all is work nobody sees."),
                    icon: "list.bullet",
                    kind: .stepper(.settings(\.editor.completionMaximumItems), range: 5...200, unit: nil)),
                SettingsItem(
                    id: "completionKeywordCase",
                    title: String(localized: "Keyword case"),
                    caption: String(localized: "Applied as a keyword is inserted. Schema, table and column names always keep the case the database gave them."),
                    icon: "textformat.abc",
                    kind: .popup(.cases(\.editor.completionKeywordCase, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "Paste"), items: [
                SettingsItem(
                    id: "offerSqlListChip",
                    title: String(localized: "Offer to format a pasted list"),
                    caption: String(localized: "A paste that looks like bare values offers a “Format as SQL list” button. Press Tab to take it, Esc to leave it. The paste itself is never changed on its own."),
                    icon: "list.bullet.rectangle.portrait",
                    kind: .toggle(.settings(\.editor.offerSqlListChip))),
                SettingsItem(
                    id: "sqlListQuoteStyle",
                    title: String(localized: "Quote values with"),
                    caption: String(localized: "A list that is all numbers, all booleans or all NULL is left bare whichever this says — quoting it would change what it means."),
                    icon: "quote.bubble",
                    kind: .popup(.cases(\.editor.sqlListQuoteStyle, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "Colours"), items: [
                SettingsItem(
                    id: "syntaxTheme",
                    title: String(localized: "Syntax colours"),
                    caption: String(localized: "System follows the macOS palette. Every theme reads in both light and dark appearance."),
                    icon: "paintpalette",
                    kind: .popup(.values(\.editor.syntaxTheme, options: SQLTheme.catalog.map {
                        (title: $0.displayLabel, value: $0.name)
                    }))),
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
