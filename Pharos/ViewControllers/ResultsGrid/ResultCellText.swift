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
    /// - Parameters:
    ///   - maximumCharacters: Settings ▸ Results ▸ Cells. 0 is no limit. A
    ///     longer value is cut and gains an ellipsis. Counted in `Character`s,
    ///     so an accented letter or an emoji is one, not two or four.
    ///   - escapeControls: Settings ▸ Results ▸ Cells. Off stops the
    ///     `<U+XXXX>` substitution — the newline flattening stays, because a
    ///     single-line label that silently becomes two is a layout fault, not
    ///     a fidelity one.
    static func rendered(value: AnyCodable, category: PGTypeCategory,
                         boolTrue: String, boolFalse: String, nullString: String,
                         maximumCharacters: UInt32 = 0, escapeControls: Bool = true) -> String {
        // `nullString`, `boolTrue` and `boolFalse` come from AppSettings enums,
        // never from the result set, so they are neither escaped nor truncated
        // — a "NUL…" in place of "NULL" would be the app misreporting itself.
        if value.isNull { return nullString }
        let raw = value.displayString
        switch category {
        case .boolean:
            switch raw.lowercased() {
            case "t", "true": return boolTrue
            case "f", "false": return boolFalse
            // Anything else in a boolean column is data, not a keyword.
            default: return finish(raw, escapeControls, maximumCharacters)
            }
        case .string, .json, .array:
            // Flatten FIRST: `↵` is the established, more readable marker for a
            // newline, and after flattening there is no newline scalar left for
            // the C0 branch of `DisplayEscape` to turn into `<U+000A>`.
            return finish(raw.flattenedForCell, escapeControls, maximumCharacters)
        case .numeric, .temporal:
            // Escaped too. A "numeric" category is inferred from the column's
            // declared type, and every cell value crosses the FFI as a string —
            // so neither category is a guarantee about the bytes.
            return finish(raw, escapeControls, maximumCharacters)
        }
    }

    /// Escape, then truncate. That order is deliberate: the limit is a limit
    /// on what is DRAWN, and `<U+202E>` is eight drawn characters where the
    /// scalar was one. Truncating first would let a value at the limit still
    /// render far past it.
    private static func finish(_ text: String, _ escapeControls: Bool, _ maximumCharacters: UInt32) -> String {
        truncated(escapeControls ? DisplayEscape.escaped(text) : text, to: maximumCharacters)
    }

    /// The display truncation. Internal so the grid's width measurer and the
    /// tests reach the same rule the cell does.
    ///
    /// DISPLAY ONLY, like everything else in this type: copy, export, find,
    /// filter and sort read the raw `AnyCodable` and never come through here.
    static func truncated(_ text: String, to maximumCharacters: UInt32) -> String {
        guard maximumCharacters > 0 else { return text }
        let limit = Int(maximumCharacters)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
