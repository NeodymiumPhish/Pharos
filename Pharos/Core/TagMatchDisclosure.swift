import Foundation

// MARK: - TagMatchDisclosure

/// What a captured value actually REACHES.
///
/// A `TagCondition` carries two forms of one cell: `display`, the text as
/// captured, and `value`, the normalized form `TagValueNormalizer` produced —
/// and matching compares only the second. Where the two differ, a surface
/// showing `display` alone UNDERSTATES the tag: `US` in a `char(20)` is
/// captured with its eighteen pad spaces and matches a plain `text` cell
/// holding `us`, which resembles neither. Case does the same thing more
/// quietly. On a destructive confirmation, understating reach is the defect
/// class this phase exists to prevent.
///
/// One producer for both surfaces that disclose a tuple — the removal sheet
/// and the Inspector's Tags section — so the two can never describe the same
/// value's reach differently. Same reasoning as
/// `TagInspectorModel.deleteConfirmation`, which is shared for the same cause.
enum TagMatchDisclosure {

    /// The extra line, ready to draw.
    struct Line: Equatable {
        /// Escaped, like every other captured text this app draws. The
        /// matching form is somebody else's data too, so an unescaped one
        /// could misrender exactly as the raw text could.
        let text: String
        /// The matching form holds nothing printable, so `text` names it with
        /// a stand-in word instead of showing captured data. Surfaces style it
        /// apart, exactly as `TagRemovalModel.ValueText` does.
        let isPlaceholder: Bool
    }

    /// The reason clause is GENERIC rather than per-family, deliberately.
    ///
    /// Three families normalize CONDITIONALLY: `numeric` keeps the exact text
    /// when the grammar or the digit width fails, `address` when
    /// `CIDRRange.canonical` returns nil, `temporal` when nothing parses. For
    /// a value that fell back, only whitespace trimming happened — so a clause
    /// reading "number formatting ignored" would be false for precisely those
    /// values, and telling a reader that more matches than really does is the
    /// same defect class as showing `display` alone. Deciding which branch ran
    /// would mean re-deriving the normalization here, and a second normalizer
    /// can disagree with the one that matching actually used.
    ///
    /// So this states the MECHANISM, which holds for every family and every
    /// fallback: the form below is what gets compared, and any cell reducing
    /// to it matches. "can match" and not "match" — only the spellings that
    /// reduce to this form do.
    private static let reason =
        "matching compares this form, so other spellings can match too"

    /// The sentence, or nil when the captured text IS the matching form.
    ///
    /// An identical pair adds nothing on purpose: a second line under every
    /// value would bury the ones where the reach really is wider.
    ///
    /// The comparison is on the RAW forms, before escaping. Escaping is a
    /// drawing rule and has no say in whether two values reach the same rows.
    ///
    /// Nothing is re-normalized here, and nothing may be. `TagDraft` fills
    /// `value` from `TagValueNormalizer.normalize` and `display` from the very
    /// same cell text (`Pharos/Core/TagDraft.swift:53-57`), so an inequality
    /// between them IS the whole rule.
    static func line(display: String, normalized: String) -> Line? {
        guard display != normalized else { return nil }
        let escaped = DisplayEscape.escaped(normalized)
        // An all-whitespace text cell normalizes to "", and a tag matching
        // every blank cell in every database is the loudest thing this
        // function can be asked to say — so it gets the stand-in word rather
        // than a pair of empty quotes that reads like a rendering fault.
        let subject = escaped.isEmpty ? "(empty)" : "\u{201C}\(escaped)\u{201D}"
        return Line(text: "matches as \(subject) — \(reason)",
                    isPlaceholder: escaped.isEmpty)
    }
}
