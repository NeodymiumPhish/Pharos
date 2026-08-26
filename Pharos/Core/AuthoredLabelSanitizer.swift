import Foundation

/// Keeps an AUTHORED LABEL from being able to misrepresent itself.
///
/// An authored label is not captured data. It is a NAME the analyst types for
/// their own object, and the app then draws it back as its own voice: on the
/// grid row's tooltip, in the Inspector's Tags section, as the group header of
/// the removal sheet, in the "Add to existing tag" popup, in the delete
/// confirmation, and — beyond tags — in folder names, workspace names,
/// saved-query names, connection names, editor tab names, table names (via
/// the clone-table sheet), and variable names. `safe` + `U+202E` + `gpj.exe`
/// typed into any of these fields DISPLAYS as `safeexe.jpg`, so an object can
/// be created or renamed under a label that reads as something it is not —
/// including on a destructive confirmation.
///
/// # Why not `DisplayEscape`
///
/// `DisplayEscape` covers the same character families and is the right answer
/// for captured data: a value must be shown exactly as it is held, so the
/// hostile scalar is DISCLOSED as `<U+202E>` and nothing is altered. A name is
/// the opposite case. Nothing downstream needs it byte-for-byte, so the
/// deceptive scalar can simply be denied entry — and it must be, because the
/// field it is typed into is read back and written to the store, so escaping
/// there would save the token text itself.
///
/// # The rule
///
/// - Bidi controls — the marks (LRM, RLM, ALM), the embedding/override set and
///   the isolates — are REMOVED. These are the family that reorders a label.
/// - C0 and C1 controls and DEL are REMOVED, except the whitespace controls
///   (tab, LF, VT, FF, CR, NEL) and the line/paragraph separators (U+2028,
///   U+2029), which FOLD to a space: a name pasted out of a cell or a
///   multi-line source can carry one of these, and joining `alpha` to `beta`
///   would be its own small misreading.
/// - Zero-width characters, the BOM and the Mongolian vowel separator are
///   REMOVED. They are invisible, so two names that differ only by one are
///   two names that read identically.
/// - Unusual spaces (NBSP, the ogham space mark, and their relatives) FOLD to
///   a normal space rather than being removed. Removing them would close up a
///   gap the author can see and did intend; folding leaves the name looking
///   exactly as it did while making it the string it appears to be —
///   searchable, re-typable, and no longer a twin of the name beside it.
///
/// Nothing else is touched: no case folding, no trimming, no collapsing of
/// repeated spaces. Trimming in particular belongs at save (both sheets already
/// trim there) — a sanitiser that ate the space you just typed would fight
/// ordinary typing.
///
/// Sanitising is applied as the field CHANGES, so the field never holds a
/// deceptive name and what is saved is what was on screen. `sanitized` is
/// therefore idempotent by construction: its output holds only kept scalars.
enum AuthoredLabelSanitizer {

    /// What `sanitized` does with one scalar.
    enum Disposition: Equatable {
        case keep
        case foldToSpace
        case remove
    }

    static func disposition(of scalar: Unicode.Scalar) -> Disposition {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return .foldToSpace  // the C0 whitespace
        case 0x0085, 0x2028, 0x2029: return .foldToSpace        // NEL, line/paragraph separators
        case 0x00...0x1F, 0x7F...0x9F: return .remove           // the rest of C0, DEL, the rest of C1
        case 0x200E, 0x200F, 0x061C: return .remove             // LRM, RLM, ALM
        case 0x202A...0x202E: return .remove                    // embeddings and overrides
        case 0x2066...0x2069: return .remove                    // the isolate set
        case 0x200B...0x200D, 0x2060, 0xFEFF, 0x180E: return .remove  // zero-width, BOM, MVS
        case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return .foldToSpace
        default: return .keep
        }
    }

    /// Whether `sanitized` would change this string.
    ///
    /// Exposed because it is also the guard that keeps ordinary typing alone:
    /// the field is only ever rewritten — insertion point and all — when the
    /// answer here is true.
    static func needsSanitizing(_ text: String) -> Bool {
        text.unicodeScalars.contains { disposition(of: $0) != .keep }
    }

    /// The name as the STORE receives it: sanitised, then trimmed.
    ///
    /// One producer for every authored label on its way to the store — a tag
    /// name, a workspace name, a connection name — because two save paths that
    /// trim differently are how a stored name and the label drawn for it come
    /// to disagree.
    ///
    /// `sanitized` deliberately does not trim (see the note above: a sanitiser
    /// that ate the space you just typed would fight ordinary typing), so the
    /// trim belongs here, at save, and not a keystroke earlier.
    ///
    /// The order is load-bearing. Sanitising FIRST folds an edge NBSP or
    /// ideographic space to a plain space and REMOVES an edge zero-width
    /// character, so the trim that follows can see both. Trimming first would
    /// stop at a zero-width space — which is not whitespace — and leave the
    /// ordinary space behind it in the stored name.
    ///
    /// May return an empty string, when the name held nothing but scalars that
    /// are denied entry. Every caller already refuses an empty name; none may
    /// stop doing so.
    static func committed(_ text: String) -> String {
        sanitized(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name with every deceptive scalar denied entry.
    static func sanitized(_ text: String) -> String {
        guard needsSanitizing(text) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch disposition(of: scalar) {
            case .keep: out.append(scalar)
            case .foldToSpace: out.append(" ")
            case .remove: continue
            }
        }
        return String(out)
    }

    /// Where a caret standing `offset` UTF-16 units into `text` lands once
    /// `sanitized` has rewritten it.
    ///
    /// The insertion point has to be carried across the rewrite by hand:
    /// characters BEFORE the caret can disappear, so leaving the offset alone
    /// would move the caret rightwards through the text on every paste, and
    /// restoring it to the end would send it there mid-word.
    ///
    /// Offsets are UTF-16 because that is the unit `NSTextView.selectedRange`
    /// speaks. An offset that falls inside a surrogate pair cannot arrive from
    /// a real selection, and is treated as the start of that pair rather than
    /// being rejected.
    static func sanitizedCaret(in text: String, at offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        var consumed = 0
        var result = 0
        for scalar in text.unicodeScalars {
            guard consumed < offset else { break }
            consumed += UTF16.width(scalar)
            switch disposition(of: scalar) {
            case .keep: result += UTF16.width(scalar)
            case .foldToSpace: result += 1
            case .remove: continue
            }
        }
        return result
    }
}
