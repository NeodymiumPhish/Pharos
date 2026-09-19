import AppKit

/// Settings ▸ Export & Import. The export sheet's starting point, the CSV
/// dialect both halves share, and how an import handles a row the server
/// refuses.
///
/// Every default is what the app did before the setting existed — the Rust
/// doc comments in `pharos-core/src/models/export_import.rs` and
/// `settings.rs` name the line each one was read from, and a Rust test pins
/// the default dialect's output to the bytes the old writer produced.
///
/// The dialect lives HERE rather than in the two sheets: a delimiter or an
/// encoding is a standing preference, not a per-export decision, and a sheet
/// control for each would ask the same question on every export.
final class ExportImportSettingsPaneVC: SettingsFormPaneVC {

    init() { super.init(paneId: .exportImport) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var sections: [SettingsSection] {
        [
            SettingsSection(title: String(localized: "Export"), items: [
                SettingsItem(
                    id: "defaultFormat",
                    title: String(localized: "Default format"),
                    caption: String(localized: "The format the Export Data sheet opens on. You can still pick another one for any single export."),
                    icon: "doc.badge.arrow.up",
                    kind: .popup(.cases(\.dataExport.defaultFormat, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "includeHeaderRow",
                    title: String(localized: "Include a header row"),
                    caption: String(localized: "Writes the column names as the first row. CSV, TSV and Excel only — the other formats name every column on every row."),
                    icon: "tablecells.badge.ellipsis",
                    kind: .toggle(.settings(\.dataExport.includeHeaderRow))),
                SettingsItem(
                    id: "defaultFolder",
                    title: String(localized: "Default folder"),
                    caption: String(localized: "Where the save panel opens. Leave it empty to open wherever you saved last. A folder that is no longer there is ignored."),
                    icon: "folder",
                    kind: .path(.settings(\.dataExport.defaultFolder), directories: true)),
                SettingsItem(
                    id: "rememberLastChoices",
                    title: String(localized: "Remember last choices"),
                    caption: String(localized: "Writes the format, the header row, the NULL text and the folder you chose back into these settings when an export runs, so the next one opens where the last left off."),
                    icon: "clock.arrow.circlepath",
                    kind: .toggle(.settings(\.dataExport.rememberLastChoices))),
                SettingsItem(
                    id: "batchSize",
                    title: String(localized: "Rows per batch"),
                    caption: String(localized: "How many rows an export fetches per round trip. A larger batch is fewer round trips and more memory at once. 5000 is what every export used before this was a setting."),
                    icon: "square.stack.3d.down.right",
                    kind: .stepper(.settings(\.dataExport.batchSize), range: 100...100_000,
                                   unit: String(localized: "rows"))),
            ]),

            SettingsSection(title: String(localized: "CSV Format"), items: [
                SettingsItem(
                    id: "delimiter",
                    title: String(localized: "Delimiter"),
                    caption: String(localized: "What separates fields in a CSV file, on the way out and on the way in. A TSV export always uses a tab, whatever this says."),
                    icon: "text.justify.left",
                    kind: .popup(.cases(\.dataExport.dialect.delimiter, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "customDelimiter",
                    title: String(localized: "Custom delimiter"),
                    caption: String(localized: "One ASCII character, used when the delimiter above is Custom. Anything else falls back to a comma."),
                    icon: "character.cursor.ibeam",
                    kind: .text(.settings(\.dataExport.dialect.customDelimiter), width: 60)),
                SettingsItem(
                    id: "quoteChar",
                    title: String(localized: "Quote character"),
                    caption: String(localized: "One ASCII character. A quote inside a quoted field is written twice, which is what every CSV reader expects."),
                    icon: "quote.opening",
                    kind: .text(.settings(\.dataExport.dialect.quoteChar), width: 60)),
                SettingsItem(
                    id: "quoteStyle",
                    title: String(localized: "Quote fields"),
                    caption: String(localized: "Only when needed quotes a field that holds the delimiter, a quote or a line break — this is what Pharos has always written. Never writes nothing around a field, so it suits only data that cannot hold any of those."),
                    icon: "quote.bubble",
                    kind: .popup(.cases(\.dataExport.dialect.quoteStyle, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "nullLiteral",
                    title: String(localized: "NULL is written as"),
                    caption: String(localized: "What a NULL becomes in an exported file, and what a field must equal in an imported one to become a real NULL. Empty is what Pharos has always used."),
                    icon: "questionmark.square.dashed",
                    kind: .text(.settings(\.dataExport.dialect.nullLiteral), width: 120)),
                SettingsItem(
                    id: "encoding",
                    title: String(localized: "Encoding"),
                    caption: String(localized: "UTF-8 is what Pharos has always written. UTF-8 with BOM is what Excel on Windows expects. Latin-1 cannot carry every character: an export says how many it replaced with a question mark. An imported file that starts with a byte-order mark is read in the encoding that mark names, whatever this says."),
                    icon: "textformat",
                    kind: .popup(.cases(\.dataExport.dialect.encoding, title: { $0.displayLabel }))),
            ]),

            SettingsSection(title: String(localized: "Import"), items: [
                SettingsItem(
                    id: "onError",
                    title: String(localized: "When a row fails"),
                    caption: String(localized: "Stop and undo everything is what Pharos has always done: one refused row and the whole file is rolled back. Skip the row runs every row inside its own savepoint, so a bad row is undone on its own and the import carries on; the alert afterwards names how many were skipped and why."),
                    icon: "exclamationmark.triangle",
                    kind: .popup(.cases(\.dataImport.onError, title: { $0.displayLabel }))),
                SettingsItem(
                    id: "commitEvery",
                    title: String(localized: "Commit every"),
                    caption: String(localized: "Rows per transaction. 0 is one transaction for the whole file, which is what Pharos has always done — nothing lands until everything does. A number commits as it goes, so the batches that finished stay on the server even if a later row stops the import."),
                    icon: "checkmark.seal",
                    kind: .stepper(.settings(\.dataImport.commitEvery), range: 0...1_000_000,
                                   unit: String(localized: "rows"))),
                SettingsItem(
                    id: "importDialect",
                    title: String(localized: "Import uses the same CSV format"),
                    caption: String(localized: "The delimiter, quote character and NULL text above apply to reading a file as well as writing one, so a file Pharos exported imports back without a second set of choices."),
                    icon: "arrow.triangle.2.circlepath",
                    kind: .display),
            ]),
        ]
    }
}

// MARK: - Remembering the sheet's choices

extension DataExportSettings {

    /// Writes what the user just chose in the export sheet back into
    /// Settings, when "Remember last choices" asks for it.
    ///
    /// Takes the whole request rather than the sheet, so the one place that
    /// knows what was chosen is the request that is about to run.
    ///
    /// `nonisolated`, and it hops to the main actor itself, because the
    /// sheet's completion closure is not actor-isolated. Only value types
    /// cross that hop.
    static func rememberIfAsked(_ options: ExportTableOptions) {
        let format = options.format
        let includeHeaders = options.includeHeaders
        let nullLiteral = options.csv.nullLiteral
        let folder = (options.filePath as NSString).deletingLastPathComponent

        Task { @MainActor in
            let manager = AppStateManager.shared
            var updated = manager.settings
            guard updated.dataExport.rememberLastChoices else { return }
            updated.dataExport.defaultFormat = format
            updated.dataExport.includeHeaderRow = includeHeaders
            updated.dataExport.dialect.nullLiteral = nullLiteral
            if !folder.isEmpty {
                updated.dataExport.defaultFolder = folder
            }
            guard updated != manager.settings else { return }
            manager.saveSettings(updated)
        }
    }
}
