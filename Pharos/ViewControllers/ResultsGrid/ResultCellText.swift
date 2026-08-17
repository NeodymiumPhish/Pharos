import Foundation

extension String {
    /// Replaces newlines with a visible ↵ so multi-line data shows as one line in
    /// the results grid. (Moved here from ResultsDataSource so the width measurement
    /// can share it; internal, not private.)
    var flattenedForCell: String {
        guard contains(where: \.isNewline) else { return self }
        return replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
    }
}

/// The exact string a result cell renders for a value — shared by the grid's cell
/// styling (`styleCell`) and the column-width measurement, so what's measured
/// always equals what's drawn.
///
/// DISPLAY ONLY. Everything here is one-way: `↵` for a newline, `<U+XXXX>` for a
/// hostile scalar. Copy, export, find, filter and sort all read the RAW
/// `AnyCodable` off the model and never come through this type — see the note on
/// `ResultsCopyExport` — because an escaped indicator pasted into another system
/// is a corrupt indicator, and a search against an escaped string answers a
/// different question than the user asked.
enum ResultCellText {
    static func rendered(value: AnyCodable, category: PGTypeCategory,
                         boolTrue: String, boolFalse: String, nullString: String) -> String {
        // `nullString`, `boolTrue` and `boolFalse` come from AppSettings enums,
        // never from the result set, so they are not escaped.
        if value.isNull { return nullString }
        let raw = value.displayString
        switch category {
        case .boolean:
            switch raw.lowercased() {
            case "t", "true": return boolTrue
            case "f", "false": return boolFalse
            // Anything else in a boolean column is data, not a keyword.
            default: return DisplayEscape.escaped(raw)
            }
        case .string, .json, .array:
            // Flatten FIRST: `↵` is the established, more readable marker for a
            // newline, and after flattening there is no newline scalar left for
            // the C0 branch of `DisplayEscape` to turn into `<U+000A>`.
            return DisplayEscape.escaped(raw.flattenedForCell)
        case .numeric, .temporal:
            // Escaped too. A "numeric" category is inferred from the column's
            // declared type, and every cell value crosses the FFI as a string —
            // so neither category is a guarantee about the bytes.
            return DisplayEscape.escaped(raw)
        }
    }
}
