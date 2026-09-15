import Foundation

/// The CSV an intent hands back for a query it ran.
///
/// The escaping is NOT re-implemented here: the text goes through
/// `ResultsCopyExport.csvText`, the same RFC 4180 rule behind the grid's Copy as
/// CSV, Export as CSV, Share… and drag-out. A query run from a Shortcut
/// therefore produces byte-identical text to the same query copied out of the
/// grid, and a change to the escaping cannot leave this path behind.
///
/// This file imports Foundation only — no AppIntents, no AppKit of its own — so
/// `scripts/test-intent-csv.sh` compiles it beside `ResultsCopyExport` without
/// pulling the app in. The `IntentFile` wrapper lives in
/// `PharosIntentSupport.swift`.
enum IntentResultCSV {

    /// `CopyData` for a whole result: every column, every loaded row, headers on.
    ///
    /// `nil` is SQL NULL and `""` an empty string, which is the distinction
    /// `CopyData` exists to carry — collapsing the two would export an empty
    /// text value and a NULL as the same thing.
    static func copyData(from result: QueryResult) -> CopyData {
        CopyData(
            columnNames: result.columns.map(\.name),
            columnIndices: Array(result.columns.indices),
            rows: result.rows.map { row in row.map { $0.isNull ? nil : $0.displayString } },
            includeHeaders: true
        )
    }

    static func csv(from result: QueryResult) -> String {
        ResultsCopyExport.csvText(data: copyData(from: result))
    }

    /// A filename the file system accepts: path separators, colons and NULs out,
    /// and never empty. A saved query's name is user text and can hold anything.
    static func sanitizedFilename(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Query" : String(cleaned.prefix(120))
    }
}
