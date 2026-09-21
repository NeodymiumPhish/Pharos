import AppKit

/// Settings ▸ Results. Everything about the results grid: how a row looks,
/// how wide a column starts, how much of a cell is drawn, how Find matches,
/// what ⌘C writes, whether a cell can be edited in place, and how many result
/// tabs one editor tab keeps.
///
/// NULL display, boolean display and NULL style stay in Appearance: they are
/// value rendering, and they reach the Inspector too.
final class ResultsSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .results) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Grid"), items: [
                SettingsItem(
                    id: "density",
                    title: String(localized: "Density"),
                    caption: String(localized: "Row height, and a point off or on the text size."),
                    icon: "arrow.up.and.down.text.horizontal",
                    kind: .segmented(.cases(\.results.density, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "fontSize",
                    title: String(localized: "Text size"),
                    icon: "textformat.size",
                    kind: .stepper(.settings(\.results.fontSize),
                                   range: Int(ResultsGridStyle.fontSizeRange.lowerBound)
                                       ... Int(ResultsGridStyle.fontSizeRange.upperBound),
                                   unit: String(localized: "pt"))),
                SettingsItem(
                    id: "monospacedFont",
                    title: String(localized: "Use a monospaced font"),
                    caption: String(localized: "Digits share one advance, so a numeric column lines up on its last digit. Off uses the system font at the same size."),
                    icon: "character.cursor.ibeam",
                    kind: .toggle(.settings(\.results.monospacedFont))),
                SettingsItem(
                    id: "alternatingRowColors",
                    title: String(localized: "Alternating row colours"),
                    icon: "list.bullet.rectangle",
                    kind: .toggle(.settings(\.results.alternatingRowColors))),
                SettingsItem(
                    id: "gridLines",
                    title: String(localized: "Grid lines"),
                    caption: String(localized: "The rules drawn between cells."),
                    icon: "grid",
                    kind: .segmented(.cases(\.results.gridLines, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "showRowNumbers",
                    title: String(localized: "Show row numbers"),
                    caption: String(localized: "The leading # column."),
                    icon: "number",
                    kind: .toggle(.settings(\.results.showRowNumbers))),
                SettingsItem(
                    id: "showColumnTypeIcons",
                    title: String(localized: "Show column type icons"),
                    caption: String(localized: "A glyph for the data type beside its name in the column header."),
                    icon: "tag",
                    kind: .toggle(.settings(\.results.showColumnTypeIcons))),
            ]),

            SettingsSection(title: String(localized: "Columns"), items: [
                SettingsItem(
                    id: "columnWidthMode",
                    title: String(localized: "Column width"),
                    caption: String(localized: "Fit to content measures the header and a sample of the rows."),
                    icon: "arrow.left.and.right",
                    help: String(localized: "Double-clicking a column's right edge always re-fits it, whichever this says."),
                    kind: .segmented(.cases(\.results.columnWidthMode, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "fixedColumnWidth",
                    title: String(localized: "Fixed width"),
                    icon: "ruler",
                    kind: .stepper(.settings(\.results.fixedColumnWidth), range: 40...1000,
                                   unit: String(localized: "pt")),
                    availability: {
                        AppStateManager.shared.settings.results.columnWidthMode == .fixed
                            ? .available
                            : .unavailable(reason: String(localized: "Used only when columns take a fixed width."))
                    }),
                SettingsItem(
                    id: "maximumColumnWidth",
                    title: String(localized: "Maximum column width"),
                    caption: String(localized: "No column is ever made wider than this, by fitting or by dragging."),
                    icon: "arrow.right.to.line",
                    kind: .stepper(.settings(\.results.maximumColumnWidth), range: 100...4000,
                                   unit: String(localized: "pt"))),
            ]),

            SettingsSection(title: String(localized: "Cells"), items: [
                SettingsItem(
                    id: "maximumCellCharacters",
                    title: String(localized: "Maximum characters per cell"),
                    caption: String(localized: "Longer values are drawn cut short with an ellipsis."),
                    icon: "text.alignleft",
                    help: String(localized: "0 draws all of them. Copy, export, find and sort always use the whole value."),
                    kind: .stepper(.settings(\.results.maximumCellCharacters), range: 0...10000, unit: nil)),
                SettingsItem(
                    id: "escapeControlCharacters",
                    title: String(localized: "Escape control characters"),
                    caption: String(localized: "Shows invisible and direction-changing characters as <U+XXXX>."),
                    icon: "eye.trianglebadge.exclamationmark",
                    help: String(localized: "Turning this off lets a value DISPLAY as something it is not — a right-to-left override can make “safe␁gpj.exe” read as “safe.jpg” — so leave it on unless you are looking at text you trust. The escaping is display only. The pasteboard, every export, and find, filter and sort all read the raw value whatever this says."),
                    kind: .toggle(.settings(\.results.escapeControlCharacters))),
            ]),

            SettingsSection(title: String(localized: "Formatting"), items: [
                SettingsItem(
                    id: "dateStyle",
                    title: String(localized: "Dates and times"),
                    caption: String(localized: "As returned draws exactly what the server sent."),
                    icon: "calendar",
                    help: String(localized: "Short and Medium use your region's format and leave off the time-zone offset, so choose ISO 8601 or As returned to keep it. Display only. Copy, find, filter and sort always read the value the server sent, and an export is never reformatted. A value this app cannot read — an interval, a BC date, infinity — is always drawn exactly as it arrived."),
                    kind: .popup(.cases(\.results.dateStyle, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "numberStyle",
                    title: String(localized: "Numbers"),
                    caption: String(localized: "Grouped adds your region's thousands separators."),
                    icon: "number.square",
                    help: String(localized: "The number of decimal places the server sent is kept exactly, so a money column is never rounded. Display only, on the same terms as dates. NaN, Infinity and a value written in exponent form are drawn exactly as they arrived."),
                    kind: .popup(.cases(\.results.numberStyle, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "Find"), items: [
                SettingsItem(
                    id: "findMode",
                    title: String(localized: "Match"),
                    caption: String(localized: "How the find field matches a cell. An expression that cannot be read turns the field red and matches nothing."),
                    icon: "magnifyingglass",
                    kind: .popup(.cases(\.results.findMode, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "findMatchCase",
                    title: String(localized: "Match case"),
                    icon: "textformat",
                    kind: .toggle(.settings(\.results.findMatchCase))),
            ]),

            SettingsSection(title: String(localized: "Copy"), items: [
                SettingsItem(
                    id: "defaultCopyFormat",
                    title: String(localized: "Copy with ⌘C"),
                    caption: String(localized: "The Copy menu still offers every format."),
                    icon: "doc.on.doc",
                    help: String(localized: "A copy also carries the TSV form, so a paste into a spreadsheet lands as a table whichever this says."),
                    kind: .popup(.cases(\.results.defaultCopyFormat, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "copyIncludeHeaders",
                    title: String(localized: "Include column headers"),
                    icon: "tablecells",
                    kind: .toggle(.settings(\.results.copyIncludeHeaders))),
                SettingsItem(
                    id: "copyRichText",
                    title: String(localized: "Also copy as rich text"),
                    caption: String(localized: "Writes an HTML table beside the text, so a paste into Mail or Notes arrives as a table. Off leaves plain text only."),
                    icon: "textformat.alt",
                    kind: .toggle(.settings(\.results.copyRichText))),
            ]),

            SettingsSection(title: String(localized: "Editing"), items: [
                SettingsItem(
                    id: "allowInlineEditing",
                    title: String(localized: "Allow editing cells in the grid"),
                    caption: String(localized: "Off makes every result read-only. An edit is never written until you review and apply it, whichever this says."),
                    icon: "square.and.pencil",
                    kind: .toggle(.settings(\.results.allowInlineEditing))),
            ]),

            SettingsSection(title: String(localized: "Result tabs"), items: [
                SettingsItem(
                    id: "maximumResultTabs",
                    title: String(localized: "Maximum result tabs"),
                    caption: String(localized: "Per editor tab."),
                    icon: "rectangle.stack",
                    help: String(localized: "Reaching the limit closes the oldest result you have not looked at and have not renamed; 0 keeps them all."),
                    kind: .stepper(.settings(\.results.maximumResultTabs), range: 0...50, unit: nil)),
                SettingsItem(
                    id: "showResultTabsPanelByDefault",
                    title: String(localized: "Open new tabs with the result-tabs panel"),
                    caption: String(localized: "Toggling the panel in a tab also sets this. Only used while Appearance ▸ Show result tabs in a vertical panel is on."),
                    icon: "sidebar.right",
                    kind: .toggle(.settings(\.results.showResultTabsPanelByDefault))),
            ]),
        ]
    }
}
