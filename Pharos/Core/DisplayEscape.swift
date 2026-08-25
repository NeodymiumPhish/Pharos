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
    static func mustEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true   // C0 controls, DEL, C1 controls (incl. NEL)
        case 0x200E, 0x200F, 0x061C: return true     // LRM, RLM, ALM
        case 0x202A...0x202E: return true            // the embedding/override set
        case 0x2066...0x2069: return true            // the isolate set
        case 0x2028, 0x2029: return true             // line/paragraph separators
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
        var lead = 0
        while lead < scalars.count, scalars[lead] == " " { lead += 1 }
        var trail = scalars.count
        while trail > lead, scalars[trail - 1] == " " { trail -= 1 }

        return escapedCore(scalars) { index in
            index < lead || index >= trail || mustEscape(scalars[index])
        }
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
    static func escapedMultilineValue(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var lead = 0
        while lead < scalars.count, scalars[lead] == " " { lead += 1 }
        var trail = scalars.count
        while trail > lead, scalars[trail - 1] == " " { trail -= 1 }
        return escapedCore(scalars) { index in
            index < lead || index >= trail || isHostileInFlowingText(scalars[index])
        }
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
            if run == 1 {
                out += String(format: "<U+%04X>", scalar.value)
            } else {
                out += String(format: "<U+%04X\u{00D7}%d>", scalar.value, run)
            }
            index += run
        }
        return out
    }
}
