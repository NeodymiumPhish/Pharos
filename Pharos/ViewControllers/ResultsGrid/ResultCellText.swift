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
/// hostile scalar, `·` / `→` for an edge space / a tab. Copy, export, find, filter and sort all read the RAW
/// `AnyCodable` off the model and never come through this type — see the note on
/// `ResultsCopyExport` — because an escaped indicator pasted into another system
/// is a corrupt indicator, and a search against an escaped string answers a
/// different question than the user asked.
enum ResultCellText {
    /// - Parameters:
    ///   - maximumCharacters: Settings ▸ Results ▸ Cells. 0 is no limit. A
    ///     longer value is cut and gains an ellipsis. Counted in `Character`s,
    ///     so an accented letter or an emoji is one, not two or four.
    ///   - showInvisibles: Settings ▸ Results ▸ Cells ▸ Show invisible
    ///     characters. Off, only tier A (`DisplayEscape.changesLayout`) is
    ///     disclosed; on, tier B is too, as dimmed marks. The newline
    ///     flattening stays either way, because a single-line label that
    ///     silently becomes two is a layout fault, not a fidelity one.
    ///   - kind: The column's declared type, finer than `category`, so a
    ///     `date` can be told from a `timestamptz` and an `interval` from
    ///     either. `.other` — the default — is never reformatted.
    ///   - dateStyle: Settings ▸ Results ▸ Formatting. `.asReturned`, the
    ///     default, leaves PostgreSQL's own text alone.
    ///   - numberStyle: Settings ▸ Results ▸ Formatting, same terms.
    ///
    /// Returns the text and the ranges of it the cell draws dimmed. The width
    /// measurer reads `.text` only: a mark is one glyph of the cell font
    /// either way.
    static func renderedCell(value: AnyCodable, category: PGTypeCategory,
                             boolTrue: String, boolFalse: String, nullString: String,
                             maximumCharacters: UInt32 = 0, showInvisibles: Bool = false,
                             kind: ResultValueKind = .other,
                             dateStyle: ResultDateStyle = .asReturned,
                             numberStyle: ResultNumberStyle = .asReturned) -> DisplayEscape.CellText {
        // `nullString`, `boolTrue` and `boolFalse` come from AppSettings enums,
        // never from the result set, so they are neither escaped nor truncated
        // — a "NUL…" in place of "NULL" would be the app misreporting itself.
        if value.isNull { return appText(nullString) }
        let raw = value.displayString
        switch category {
        case .boolean:
            switch raw.lowercased() {
            case "t", "true": return appText(boolTrue)
            case "f", "false": return appText(boolFalse)
            // Anything else in a boolean column is data, not a keyword.
            default: return finish(raw, showInvisibles, maximumCharacters)
            }
        case .string, .json, .array:
            // Flatten FIRST: `↵` is the established, more readable marker for a
            // newline, and after flattening there is no newline scalar left for
            // the C0 branch of `DisplayEscape` to turn into `<U+000A>`.
            return finish(raw.flattenedForCell, showInvisibles, maximumCharacters)
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
                return appText(truncated(shown, to: maximumCharacters))
            }
            // Escaped, like any other data. A "numeric" category is inferred
            // from the column's declared type, and every cell value crosses
            // the FFI as a string — so neither category is a guarantee about
            // the bytes.
            return finish(raw, showInvisibles, maximumCharacters)
        }
    }

    /// `renderedCell`'s text alone, for a caller that draws no marks.
    static func rendered(value: AnyCodable, category: PGTypeCategory,
                         boolTrue: String, boolFalse: String, nullString: String,
                         maximumCharacters: UInt32 = 0, showInvisibles: Bool = false,
                         kind: ResultValueKind = .other,
                         dateStyle: ResultDateStyle = .asReturned,
                         numberStyle: ResultNumberStyle = .asReturned) -> String {
        renderedCell(value: value, category: category,
                     boolTrue: boolTrue, boolFalse: boolFalse, nullString: nullString,
                     maximumCharacters: maximumCharacters, showInvisibles: showInvisibles,
                     kind: kind, dateStyle: dateStyle, numberStyle: numberStyle).text
    }

    /// What VoiceOver reads for a cell with marks; nil for a cell without, so
    /// the label's own text is read. A mark is a GLYPH standing for a
    /// character, and read as itself it would be "middle dot" or "right
    /// arrow": each run of marks is named for what it stands for instead.
    static func accessibilityText(_ cell: DisplayEscape.CellText) -> String? {
        guard !cell.dimmedRanges.isEmpty else { return nil }
        let text = cell.text as NSString
        var parts: [String] = []
        var cursor = 0
        for range in cell.dimmedRanges where NSMaxRange(range) <= text.length {
            if range.location > cursor {
                parts.append(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            parts.append(describeMarks(text.substring(with: range)))
            cursor = NSMaxRange(range)
        }
        if cursor < text.length { parts.append(text.substring(from: cursor)) }
        return parts.joined(separator: " ")
    }

    /// One dimmed range in words. Adjacent marks share a range, so a range can
    /// hold dots, arrows and `<U+XXXX>` tokens together; each run is named on
    /// its own. A token is left as it is — it already names its character.
    private static func describeMarks(_ marks: String) -> String {
        var words: [String] = []
        var rest = Substring(marks)
        while let first = rest.first {
            let run = rest.prefix(while: { $0 == first })
            switch first {
            case "\u{00B7}":
                words.append(run.count == 1 ? String(localized: "space")
                                            : String(localized: "\(run.count) spaces"))
                rest = rest.dropFirst(run.count)
            case "\u{2192}":
                words.append(run.count == 1 ? String(localized: "tab")
                                            : String(localized: "\(run.count) tabs"))
                rest = rest.dropFirst(run.count)
            default:
                let token = rest.prefix(while: { $0 != "\u{00B7}" && $0 != "\u{2192}" })
                words.append(String(token))
                rest = rest.dropFirst(token.count)
            }
        }
        return words.joined(separator: ", ")
    }

    /// Text the app wrote itself: never escaped, never marked.
    private static func appText(_ text: String) -> DisplayEscape.CellText {
        DisplayEscape.CellText(text: text, dimmedRanges: [])
    }

    /// Escape, then truncate. That order is deliberate: the limit is a limit
    /// on what is DRAWN, and `<U+202E>` is eight drawn characters where the
    /// scalar was one. Truncating first would let a value at the limit still
    /// render far past it.
    ///
    /// A mark the ellipsis cuts off loses its range; one it cuts through keeps
    /// the part still drawn.
    private static func finish(_ text: String, _ showInvisibles: Bool,
                               _ maximumCharacters: UInt32) -> DisplayEscape.CellText {
        let escaped = DisplayEscape.escapedCell(text, showInvisibles: showInvisibles)
        let shown = truncated(escaped.text, to: maximumCharacters)
        guard !escaped.dimmedRanges.isEmpty, shown != escaped.text else {
            return DisplayEscape.CellText(text: shown, dimmedRanges: escaped.dimmedRanges)
        }
        let kept = shown.utf16.count - 1   // the ellipsis is one UTF-16 unit
        let ranges = escaped.dimmedRanges.compactMap { range -> NSRange? in
            guard range.location < kept else { return nil }
            return NSRange(location: range.location, length: min(range.length, kept - range.location))
        }
        return DisplayEscape.CellText(text: shown, dimmedRanges: ranges)
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
