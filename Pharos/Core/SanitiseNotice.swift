import Foundation

/// What to say when an authored-label field rewrites what was just pasted.
///
/// `AuthoredLabelSanitizer` denies a hostile scalar entry rather than
/// disclosing it, and that is right: the field is read back and written to the
/// store, so an escape token would be saved as literal text inside the name.
/// But it is also SILENT — paste thirteen characters into a tag name, get
/// eleven, and nothing says why. This is what says why.
///
/// The original is shown ESCAPED, and this is the one place the two mechanisms
/// meet on purpose: the FIELD holds the sanitised name, and this notice shows
/// what arrived with its invisible characters made visible, so the difference
/// between the two is legible instead of being a silent deletion. The notice is
/// display-only and is never stored, which is exactly the condition under which
/// escaping is the correct tool.
enum SanitiseNotice {

    /// Longest original shown before truncation. A notice is one or two lines,
    /// and a pasted name can be arbitrarily long.
    private static let originalLimit = 80

    /// The message, or nil when the sanitiser changed nothing.
    ///
    /// Counts are split because "removed" and "replaced" are different events
    /// and a reader who pasted a non-breaking space has not lost a character —
    /// the gap they meant is still there, it is simply a plain space now.
    static func message(raw: String, sanitised: String) -> String? {
        guard raw != sanitised else { return nil }

        var removed = 0
        var folded = 0
        for scalar in raw.unicodeScalars {
            switch AuthoredLabelSanitizer.disposition(of: scalar) {
            case .keep: continue
            case .remove: removed += 1
            case .foldToSpace: folded += 1
            }
        }

        let summary: String
        switch (removed, folded) {
        case (0, 0):
            // Unreachable while `raw != sanitised` — the sanitiser only ever
            // changes a scalar it dispositions as remove or fold — but a nil
            // here is a silent no-op rather than a wrong sentence.
            return nil
        case (let r, 0):
            summary = "Removed \(r) invisible character\(r == 1 ? "" : "s")."
        case (0, let f):
            summary = "Replaced \(f) unusual space\(f == 1 ? "" : "s")."
        case (let r, let f):
            summary = "Removed \(r) invisible character\(r == 1 ? "" : "s")"
                + " and replaced \(f) unusual space\(f == 1 ? "" : "s")."
        }

        // Truncate the RAW string, then escape — the house order. Escaping
        // first and cutting second can slice a `<U+XXXX>` token in half, and a
        // half token reads as literal data.
        let shown = raw.count > originalLimit
            ? String(raw.prefix(originalLimit)) + "\u{2026}"
            : raw
        return "\(summary) You pasted: \(DisplayEscape.escaped(shown))"
    }
}
