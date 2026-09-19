import Foundation

// What the user is told after an export or an import. Pure and Foundation
// only, so the sentence can be tested without a database, a file or AppKit.

/// The line the "Export Successful" alert shows.
enum ExportOutcomeText {

    /// Rows first, then — only when the encoding could not carry something —
    /// how many characters were replaced. A count of 0 is never mentioned:
    /// UTF-8 and UTF-16 LE carry anything, and a Latin-1 export that lost
    /// nothing is not a partial success.
    static func message(for result: ExportTableResult) -> String {
        let rows = String(localized: "\(result.rowsExported) rows exported.")
        guard result.charactersSubstituted > 0 else { return rows }
        let substituted = String(
            localized: "\(result.charactersSubstituted) characters the chosen encoding cannot carry were written as ?.")
        return "\(rows) \(substituted)"
    }
}

/// The line the "Import Successful" alert shows.
enum ImportOutcomeText {

    /// The most an alert can usefully say: rows in, rows passed over, the
    /// first few reasons, and — when the file was committed in batches —
    /// that the rows are already on the server.
    ///
    /// The reasons come from the server, so they are escaped before they are
    /// shown, like every other server string in the app.
    static func message(for result: ImportCsvResult) -> String {
        var lines = [String(localized: "\(result.rowsImported) rows imported.")]

        if result.rowsSkipped > 0 {
            lines.append(String(localized: "\(result.rowsSkipped) rows were skipped."))
        }
        if result.committedBatches > 0 {
            lines.append(String(
                localized: "\(result.committedBatches) batches were committed as the file was read."))
        }
        if !result.errors.isEmpty {
            lines.append("")
            lines.append(contentsOf: result.errors.map { DisplayEscape.escapedMultiline($0) })
            // The core reports at most twenty; `rowsSkipped` is the real count.
            if result.rowsSkipped > UInt64(result.errors.count) {
                lines.append(String(
                    localized: "\(result.rowsSkipped - UInt64(result.errors.count)) further failures are not listed."))
            }
        }
        return lines.joined(separator: "\n")
    }
}
