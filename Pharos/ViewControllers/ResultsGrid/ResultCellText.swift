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
    ///   - kind: The column's declared type, finer than `category`, so a
    ///     `date` can be told from a `timestamptz` and an `interval` from
    ///     either. `.other` — the default — is never reformatted.
    ///   - dateStyle: Settings ▸ Results ▸ Formatting. `.asReturned`, the
    ///     default, leaves PostgreSQL's own text alone.
    ///   - numberStyle: Settings ▸ Results ▸ Formatting, same terms.
    static func rendered(value: AnyCodable, category: PGTypeCategory,
                         boolTrue: String, boolFalse: String, nullString: String,
                         maximumCharacters: UInt32 = 0, escapeControls: Bool = true,
                         kind: ResultValueKind = .other,
                         dateStyle: ResultDateStyle = .asReturned,
                         numberStyle: ResultNumberStyle = .asReturned) -> String {
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
            // Settings ▸ Results ▸ Formatting. `ResultValueFormatter` parses
            // PostgreSQL's text and writes it out again; anything it does not
            // fully recognise comes back byte for byte, which is also what
            // every style returns while both settings sit at `.asReturned` —
            // the default, so an existing user sees no change.
            let shown = ResultValueFormatter.formatted(
                raw, kind: kind, dateStyle: dateStyle, numberStyle: numberStyle)
            if shown != raw {
                // Truncated, but NOT escaped. This string is the app's own
                // output, built from a value the formatter validated as ASCII
                // digits and separators, so no hostile scalar from the data
                // can have survived into it — while the locale's own grouping
                // separator very much can (U+202F in fr, U+00A0 in ru, and in
                // recent ICU before `AM`/`PM` in en_US). All three are in
                // `DisplayEscape.mustEscape`, so escaping here would render
                // every grouped number as `1<U+202F>234`. Same reasoning as
                // `nullString` and the two boolean words above: app text is
                // not data.
                return truncated(shown, to: maximumCharacters)
            }
            // Escaped, like any other data. A "numeric" category is inferred
            // from the column's declared type, and every cell value crosses
            // the FFI as a string — so neither category is a guarantee about
            // the bytes.
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
