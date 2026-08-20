import Foundation

/// Makes hostile text safe to LOOK AT.
///
/// This app inspects somebody else's dataset, so every string it draws is
/// attacker-controlled until proven otherwise, and an AppKit label obeys what
/// it is given. Three families were measured rendering wrong on real labels:
///
/// - **Bidi controls.** `safe\u{202E}gpj.exe` DISPLAYS as `safeexe.jpg`. The
///   reader sees a different filename than the data holds. This is the one that
///   turns a label into a lie.
/// - **Zero-width and unusual spaces.** `10.0.0.1`, `10.0.0.1\u{200B}`,
///   `10.0.0\u{A0}.1` and `10.0.0.1 ` otherwise render identically, so
///   genuinely distinct values look the same.
/// - **C0 controls.** NUL, BEL and ESC passed straight to the label; a newline
///   inside one value would read as two.
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
/// one of four callers (the Inspector, the tag sheets and the removal sheet are
/// the others) and because the pure `swiftc` harnesses that compile it must not
/// have to drag `AnyCodable` and `PGTypeCategory` in behind it.
enum DisplayEscape {

    /// Scalars that must never reach a label as themselves.
    static func mustEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F: return true          // C0 controls and DEL
        case 0x200E, 0x200F, 0x061C: return true     // LRM, RLM, ALM
        case 0x202A...0x202E: return true            // the embedding/override set
        case 0x2066...0x2069: return true            // the isolate set
        case 0x2028, 0x2029: return true             // line/paragraph separators
        case 0x200B...0x200D, 0x2060, 0xFEFF, 0x180E: return true  // zero-width, BOM, MVS
        case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true  // spaces
        default: return false
        }
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

        func isMarked(_ index: Int) -> Bool {
            index < lead || index >= trail || mustEscape(scalars[index])
        }

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
