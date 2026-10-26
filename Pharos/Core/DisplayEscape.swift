import Foundation

/// Makes hostile text safe to LOOK AT.
///
/// This app inspects somebody else's dataset, so every string it draws is
/// attacker-controlled until proven otherwise, and an AppKit label obeys what
/// it is given. Four families were measured rendering wrong on real labels:
///
/// - **Bidi controls.** `safe\u{202E}gpj.exe` DISPLAYS as `safeexe.jpg`. The
///   reader sees a different filename than the data holds. This is the one that
///   turns a label into a lie.
/// - **Zero-width and unusual spaces.** `10.0.0.1`, `10.0.0.1\u{200B}`,
///   `10.0.0\u{A0}.1` and `10.0.0.1 ` otherwise render identically, so
///   genuinely distinct values look the same.
/// - **C0 controls.** NUL, BEL and ESC passed straight to the label; a newline
///   inside one value would read as two.
/// - **Line and paragraph separators.** U+2028, U+2029 and U+0085 (NEL) are
///   mandatory line breaks that AppKit obeys, so a single-line label silently
///   becomes two.
///
/// # Display only
///
/// Nothing here may touch a value on its way to the pasteboard, to a file, to
/// SQLite, or into a find/filter/sort comparison. An escaped indicator pasted
/// into another system is a corrupt indicator, and a comparison against an
/// escaped string answers a different question than the user asked. Callers own
/// that split and each one states it beside the call.
///
/// # Two tiers
///
/// `changesLayout` (tier A) is what makes a label LIE: a bidi control reorders
/// the text, a line separator moves part of it out of sight. `hidesDifference`
/// (tier B), with edge spaces, only makes two distinct values look alike.
/// Names disclose both always. Result DATA discloses tier A always and tier B
/// only when the user turns on Settings ▸ Results ▸ Cells ▸ Show invisible
/// characters (`escapedCell`, `escapedMultilineValue`).
///
/// # Home
///
/// `Pharos/Core/` rather than the results-grid folder because the grid is only
/// one of many callers, and because the pure `swiftc` harnesses that compile it
/// (13 of them today) must not have to drag `AnyCodable` and `PGTypeCategory`
/// in behind it.
enum DisplayEscape {

    /// Scalars that must never reach a label as themselves.
    ///
    /// Every case above tops out at U+FEFF — the whole set lives inside the
    /// BMP, so no scalar this function calls hostile can be one half of a
    /// surrogate pair. A consumer that walks UTF-16 units one at a time and
    /// tests each as its own scalar (`FoldingLayoutManager`'s per-unit scan)
    /// relies on that: it never has to reassemble a pair to find one. If a
    /// non-BMP scalar is ever added here — the U+E0020–U+E007F tag characters
    /// are the realistic candidate — that per-unit walk stops seeing it and
    /// must become a scalar walk instead.
    ///
    /// The union of the two tiers below. Names (connections, schemas, tags,
    /// column headers) disclose both tiers always; only result DATA lets the
    /// user hide the second one (`escapedCell`, `escapedMultilineValue`).
    static func mustEscape(_ scalar: Unicode.Scalar) -> Bool {
        changesLayout(scalar) || hidesDifference(scalar)
    }

    /// Tier A: scalars that change the ORDER or the LAYOUT of what is drawn.
    /// A data surface discloses these whatever the user's setting says,
    /// because the label otherwise reads as something the data does not hold.
    ///
    /// The line breakers were measured on a single-line `NSTextField` set up
    /// as a results cell (2026-10-26): FF, NEL, U+2028 and U+2029 push the
    /// rest of the value onto a clipped second line, exactly as LF does. VT
    /// does not, so it is tier B.
    static func changesLayout(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F, 0x061C: return true     // LRM, RLM, ALM
        case 0x202A...0x202E: return true            // the embedding/override set
        case 0x2066...0x2069: return true            // the isolate set
        case 0x2028, 0x2029, 0x0085, 0x000C: return true  // line/paragraph separators, NEL, FF
        default: return false
        }
    }

    /// Tier B: scalars that draw as nothing, or as an ordinary space, so they
    /// only hide a DIFFERENCE between two values. Disclosed on a data surface
    /// only when Settings ▸ Results ▸ Cells ▸ Show invisible characters is on.
    static func hidesDifference(_ scalar: Unicode.Scalar) -> Bool {
        if changesLayout(scalar) { return false }
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true   // C0 controls, DEL, C1 controls
        case 0x200B...0x200D, 0x2060, 0xFEFF, 0x180E: return true  // zero-width, BOM, MVS
        case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true  // spaces
        default: return false
        }
    }

    /// Whether a scalar is hostile in FLOWING text — a SQL preview, an editor,
    /// any multi-line body where `\n`, `\r` and `\t` are the text's own
    /// formatting rather than smuggled controls. `\r` is relaxed because a
    /// CRLF document is an ordinary Windows `.sql` file, not an attack:
    /// AppKit does NOT normalise pasted CRLF (measured for both
    /// `NSTextView.string =` and `insertText`), so treating CR as hostile put a
    /// `<U+000D>` pill at the end of EVERY line of such a file. Everything else
    /// `mustEscape` names stays hostile. This is a SUBSET of `mustEscape`, not
    /// a superset: it relaxes exactly those three scalars and nothing else —
    /// notably NOT the vertical tab or form feed that sit between them.
    ///
    /// The relaxed set is deliberately not the contiguous run 0x09...0x0D:
    /// VT (0x0B) and FF (0x0C) are still disclosed, because neither is a line
    /// ending any editor or database produces on purpose.
    ///
    /// Relaxing `\r` deliberately also stops `escapedMultiline` — the
    /// destructive-query preview — from disclosing CR. That is an improvement
    /// for the same reason: a CRLF query previously showed `<U+000D>` at every
    /// line end. `escaped()`, which renders SINGLE-line labels where a CR is
    /// never legitimate formatting, is unaffected and still discloses it.
    ///
    /// One definition, two consumers: `escapedMultiline` renders a hit as
    /// `<U+XXXX>` text, and `FoldingLayoutManager` renders a hit as a pill
    /// without touching the text — "escape" is the wrong verb for that second
    /// consumer, which is why this predicate is named for the property
    /// ("hostile") rather than the action. They must never disagree about
    /// what counts.
    ///
    /// Inherits `mustEscape`'s BMP invariant: the highest scalar this can ever
    /// call hostile is U+FEFF, so a caller that walks UTF-16 code units one at
    /// a time and builds a scalar per unit — as `FoldingLayoutManager` does —
    /// can never have a hostile hit land on either half of a surrogate pair.
    /// See `mustEscape`'s doc comment for what breaks that invariant.
    static func isHostileInFlowingText(_ scalar: Unicode.Scalar) -> Bool {
        mustEscape(scalar) && scalar != "\n" && scalar != "\t" && scalar != "\r"
    }

    /// Whether `escaped(_:)` would change this string.
    ///
    /// Exposed so the answer can be tested directly, and used by `escaped` as a
    /// scan-only fast path: the grid calls this per visible cell on every
    /// realize and every scroll tick, and the overwhelmingly common case —
    /// ordinary data — must not allocate a rebuilt string.
    static func needsEscaping(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        // Edge spaces are marked even though a plain space is legal mid-value:
        // at the edge of a label it is invisible, and "which of these two rows
        // has the trailing space?" is a question the reader must be able to
        // answer.
        if scalars.first == " " || scalars.last == " " { return true }
        return scalars.contains(where: mustEscape)
    }

    /// Render text so that what is read is what the data holds.
    ///
    /// Offending scalars become `<U+XXXX>`. A RUN of the same offending scalar
    /// becomes one `<U+XXXX×N>` token instead of N tokens: PostgreSQL returns
    /// `character(n)` columns space-padded, and one token per pad space would
    /// turn `US` in a `char(20)` into 162 characters of escape — mangling
    /// ordinary data, which is a worse outcome than the bug this fixes.
    ///
    /// Leading and trailing PLAIN spaces are marked; interior ones are not, so
    /// `CN=evil corp, O=x` and `café ☕ 日本` come back untouched.
    static func escaped(_ text: String) -> String {
        guard needsEscaping(text) else { return text }

        let scalars = Array(text.unicodeScalars)
        let (lead, trail) = edgeSpaceBounds(scalars)
        return escapedCore(scalars) { index in
            index < lead || index >= trail || mustEscape(scalars[index])
        }
    }

    /// Trim edge whitespace, THEN escape — the order `TagManagerSheet.displayName`
    /// established for a tag name, now the one producer shared by every surface
    /// that draws one: the whole-tag delete confirmation, the Inspector's tag
    /// header, the grid row's tag tooltip, and the Tag Manager sheet itself.
    ///
    /// The order is load-bearing. Trimming FIRST means a name saved before this
    /// app trimmed on input renders its stray edge space gone rather than as a
    /// mid-word `<U+0020>` — the display defect this function exists to fix, not
    /// a second copy of it. Escaping SECOND, rather than routing the trimmed
    /// text through `AuthoredLabelSanitizer.sanitized`, means a bidi override or
    /// a zero-width character survives to be DISCLOSED: sanitising REMOVES such
    /// a scalar outright, so a caller that sanitised here would render a hostile
    /// name as though it were clean — the exact failure this function exists to
    /// prevent.
    ///
    /// `.whitespacesAndNewlines` is never the scalar an override, an isolate, a
    /// zero-width character, or a bidi mark hides behind — none of those sit in
    /// Unicode's whitespace or newline categories — so trimming with it can
    /// never swallow the scalars that make a label lie about identity. It CAN
    /// trim away an edge NBSP or ideographic space (both `mustEscape` marks)
    /// before `escaped` gets a chance to disclose them; that is
    /// `TagManagerSheet.displayName`'s existing behaviour, carried here rather
    /// than narrowed, so every caller trims the same way.
    static func escapedTrimmed(_ text: String) -> String {
        escaped(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Multi-line preview variant. Which scalars are hostile is decided by
    /// `isHostileInFlowingText` (edge spaces are ordinary indentation here
    /// too, so they are never marked); every hit is disclosed exactly as
    /// `escaped` discloses it, run-collapsing included.
    static func escapedMultiline(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        return escapedCore(scalars) { index in
            isHostileInFlowingText(scalars[index])
        }
    }

    /// A `schema.table` label with each part escaped separately.
    ///
    /// Per part, not on the joined string: the dot is OUR separator, so
    /// escaping `"\(schema).\(table)"` as one string demotes each part's edge
    /// space to an interior space and loses its disclosure. Six sites render
    /// this pair; they must all render it the same way — one adopts this so
    /// far, the rest follow in the tier-3 sweep.
    /// A captured VALUE that may span lines: its own newlines are formatting,
    /// but its edge spaces are still data.
    ///
    /// The third point on two axes, and both matter:
    ///
    ///  - `escaped` treats a newline as hostile, because its callers draw on ONE
    ///    line, where a `\n` cannot render and its absence would hide that the
    ///    value spans lines at all.
    ///  - `escapedMultiline` treats leading spaces as indentation, because its
    ///    callers show a SQL preview or an error, where the layout is the
    ///    author's own and disclosing it would be noise.
    ///
    /// The Inspector's value pane is neither. The label wraps
    /// (`maximumNumberOfLines = 0`), so a newline renders correctly and escaping
    /// it produces the `<U+000A>` litter this function exists to stop. But the
    /// text is somebody else's DATA, so a trailing run of spaces is the
    /// `char(20)` padding an analyst needs to see — exactly what
    /// `escapedMultiline` would swallow.
    ///
    /// So: `isHostileInFlowingText` for the body, and `escaped`'s own edge-space
    /// walk unchanged.
    ///
    /// `showInvisibles` is Settings ▸ Results ▸ Cells ▸ Show invisible
    /// characters, the same switch the grid obeys: off, only tier A
    /// (`changesLayout`) is disclosed and everything else is drawn raw.
    static func escapedMultilineValue(_ text: String, showInvisibles: Bool) -> String {
        let scalars = Array(text.unicodeScalars)
        guard showInvisibles else {
            return escapedCore(scalars) { index in changesLayout(scalars[index]) }
        }
        let (lead, trail) = edgeSpaceBounds(scalars)
        return escapedCore(scalars) { index in
            index < lead || index >= trail || isHostileInFlowingText(scalars[index])
        }
    }

    /// What a results cell draws for a value: the text, and the UTF-16 ranges
    /// in it that are tier B marks, which the cell draws dimmed.
    struct CellText: Equatable {
        var text: String
        var dimmedRanges: [NSRange]
    }

    /// The results-cell renderer.
    ///
    /// Tier A (`changesLayout`) is ALWAYS disclosed as `<U+XXXX>`, at full
    /// strength: an override that reorders a value is the one thing the
    /// setting must never be able to hide.
    ///
    /// Tier B is disclosed only when `showInvisibles` is on, and as a dimmed
    /// mark rather than as text the data could hold:
    /// - a leading or trailing plain space is `·`, one per space, so the
    ///   column is exactly as wide as the raw value would make it;
    /// - a tab is `→`;
    /// - anything else (NBSP, a zero-width character, NUL) is `<U+XXXX>`,
    ///   run-collapsed, because the code point IS the information: U+00A0 and
    ///   U+2009 must not draw alike.
    ///
    /// Off, tier B is drawn raw, which is what every other SQL client does.
    static func escapedCell(_ text: String, showInvisibles: Bool) -> CellText {
        let scalars = Array(text.unicodeScalars)
        let needsWork = showInvisibles ? needsEscaping(text) : scalars.contains(where: changesLayout)
        guard needsWork else { return CellText(text: text, dimmedRanges: []) }

        let (lead, trail) = showInvisibles ? edgeSpaceBounds(scalars) : (0, scalars.count)
        var out = ""
        var length = 0          // `out`'s UTF-16 length, kept by hand: NSRange counts UTF-16
        var dimmed: [NSRange] = []
        func append(_ piece: String, dim: Bool) {
            let pieceLength = piece.utf16.count
            if dim {
                // Adjacent marks share one range, so `···` is one run to colour.
                if let last = dimmed.last, NSMaxRange(last) == length {
                    dimmed[dimmed.count - 1].length += pieceLength
                } else {
                    dimmed.append(NSRange(location: length, length: pieceLength))
                }
            }
            out += piece
            length += pieceLength
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if changesLayout(scalar) {
                let run = runLength(scalars, from: index)
                append(token(scalar, run: run), dim: false)
                index += run
            } else if showInvisibles, scalar == " ", index < lead || index >= trail {
                append("\u{00B7}", dim: true)
                index += 1
            } else if showInvisibles, scalar == "\t" {
                append("\u{2192}", dim: true)
                index += 1
            } else if showInvisibles, hidesDifference(scalar) {
                let run = runLength(scalars, from: index)
                append(token(scalar, run: run), dim: true)
                index += run
            } else {
                append(String(Character(scalar)), dim: false)
                index += 1
            }
        }
        return CellText(text: out, dimmedRanges: dimmed)
    }

    static func escapedQualified(schema: String, table: String) -> String {
        "\(escaped(schema)).\(escaped(table))"
    }

    /// The scalar walk shared by `escaped` and `escapedMultiline`: each caller
    /// supplies only which scalars are marked, and this collapses a run of the
    /// same marked scalar into one `<U+XXXX×N>` token instead of N.
    private static func escapedCore(_ scalars: [Unicode.Scalar], isMarked: (Int) -> Bool) -> String {
        var out = ""
        var index = 0
        while index < scalars.count {
            guard isMarked(index) else {
                out.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }
            let scalar = scalars[index]
            var run = 1
            while index + run < scalars.count,
                  scalars[index + run] == scalar,
                  isMarked(index + run) { run += 1 }
            out += token(scalar, run: run)
            index += run
        }
        return out
    }

    /// `<U+XXXX>` for one scalar, `<U+XXXX×N>` for a run of N.
    private static func token(_ scalar: Unicode.Scalar, run: Int) -> String {
        run == 1
            ? String(format: "<U+%04X>", scalar.value)
            : String(format: "<U+%04X\u{00D7}%d>", scalar.value, run)
    }

    /// How many copies of `scalars[index]` start at `index`.
    private static func runLength(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        var run = 1
        while index + run < scalars.count, scalars[index + run] == scalars[index] { run += 1 }
        return run
    }

    /// The first index past the leading plain spaces, and the first index of
    /// the trailing ones. An all-space value is all lead.
    private static func edgeSpaceBounds(_ scalars: [Unicode.Scalar]) -> (lead: Int, trail: Int) {
        var lead = 0
        while lead < scalars.count, scalars[lead] == " " { lead += 1 }
        var trail = scalars.count
        while trail > lead, scalars[trail - 1] == " " { trail -= 1 }
        return (lead, trail)
    }
}
