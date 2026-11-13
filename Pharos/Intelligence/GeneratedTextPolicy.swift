import Foundation

/// What Pharos does to text a model wrote before it is shown or inserted.
///
/// The on-device model is held to the shape of an answer as it writes: a
/// list asked for with one to three items has one to three. A custom
/// endpoint is only ASKED for that shape, and what it returns is whatever
/// the model at the other end produced. Nothing here trusts it: a length is
/// capped, a list is cut to the count that was asked for, and the characters
/// that make text read as something it is not are taken out.
///
/// Applied to every answer, whichever model wrote it. For an answer that
/// already has the right shape this changes nothing.
///
/// Names, charts and the names in a draft have validators of their own
/// (`NameSuggestionPolicy`, `ChartSuggestionPolicy`, `SQLDraftChecker`).
/// This covers the rest: prose shown as it is, and SQL put in the editor.
enum GeneratedTextPolicy {

    /// One sentence: an error's cause, a single fix, a suggestion.
    static let sentenceLimit = 400
    /// A few sentences: a plan's summary.
    static let paragraphLimit = 900
    /// A place or a thing: where in the statement, which plan step.
    static let phraseLimit = 200
    /// The fixes an explanation was asked for.
    static let fixLimit = 3

    /// Prose for a label: one paragraph, as the model was asked to write it.
    ///
    /// Bidi controls, zero-width characters and other controls go, as they do
    /// from a name the user types (`AuthoredLabelSanitizer`): a generated
    /// sentence is drawn in Pharos's own voice, above a statement the user
    /// is about to change. Line breaks and runs of spaces become one space.
    /// Anything past `limit` characters is cut at a word, with an ellipsis.
    static func prose(_ raw: String?, limit: Int) -> String {
        guard let raw else { return "" }
        let words = AuthoredLabelSanitizer.sanitized(raw).split(whereSeparator: \.isWhitespace)
        let text = words.joined(separator: " ")
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        // Back to the last whole word, unless that would lose most of it.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// A list of sentences: each one cleaned, the empty ones dropped, and no
    /// more than `count` kept.
    static func list(_ raw: [String]?, count: Int, limit: Int) -> [String] {
        Array((raw ?? []).lazy.map { prose($0, limit: limit) }.filter { !$0.isEmpty }.prefix(count))
    }

    /// SQL for the editor.
    ///
    /// The statement keeps its line breaks, tabs and spacing. What goes is
    /// what cannot be seen and changes what is read: bidi controls, which
    /// can show a statement in an order it does not run in; zero-width
    /// characters, which make two identifiers look the same; and the other
    /// controls. An unusual space becomes an ordinary one. The analyst reads
    /// a draft before running it, so the draft must be what it looks like.
    static func code(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                out.append(scalar)
            default:
                switch AuthoredLabelSanitizer.disposition(of: scalar) {
                case .keep: out.append(scalar)
                case .foldToSpace: out.append(" ")
                case .remove: continue
                }
            }
        }
        return String(out)
    }
}
