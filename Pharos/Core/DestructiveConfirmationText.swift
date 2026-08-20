import Foundation

/// Builds every destructive-flow string into which a server-supplied name or
/// user-written SQL is interpolated.
///
/// The confirm titles gate the irreversible action; the object names inside
/// them come from the server — attacker-controlled in this app's threat
/// model. A bidi override in a table name can make `Truncate "X"?` name a
/// different table than the statement acts on (Trojan Source). The two info
/// messages gate nothing — by the time they are shown the loss has already
/// happened — but they name the same attacker-controlled object, so they get
/// the same disclosure for a consistent record of what was destroyed. Either
/// way, every name and every SQL preview is rendered through `DisplayEscape`
/// HERE, in the one place these strings are built. (The rest of each dialog's
/// copy — buttons, icons — stays at the call site.)
///
/// Display only: the statement that executes is built from the raw name by
/// the caller. Both derive from the same raw string; only the eyes' copy is
/// escaped.
enum DestructiveConfirmationText {

    /// The longest raw SQL prefix shown in `destructiveQueryMessage` before
    /// an ellipsis takes over.
    private static let sqlPreviewMaxLength = 200

    static func truncateConfirmTitle(table: String) -> String {
        "Truncate \"\(DisplayEscape.escaped(table))\"?"
    }

    static func truncatedInfoMessage(table: String) -> String {
        "\"\(DisplayEscape.escaped(table))\" has been truncated."
    }

    static func dropConfirmTitle(name: String) -> String {
        "Drop \"\(DisplayEscape.escaped(name))\"?"
    }

    static func droppedInfoMessage(name: String) -> String {
        "\"\(DisplayEscape.escaped(name))\" has been dropped."
    }

    /// The editor's destructive-query confirmation body. The RAW SQL is
    /// truncated first (String.prefix is grapheme-safe), escaped after —
    /// escaping first and truncating second could cut a `<U+XXXX>` token in
    /// half, and a half token misreads as literal data. The escape uses the
    /// multi-line variant: ordinary editor SQL is indented and multi-line, so
    /// its own newlines, tabs and leading whitespace are not disclosure
    /// targets — only genuinely hostile scalars are.
    static func destructiveQueryMessage(keywords: [String], sql: String) -> String {
        let preview = sql.count > sqlPreviewMaxLength
            ? String(sql.prefix(sqlPreviewMaxLength)) + "…" : sql
        return "This SQL contains \(keywords.joined(separator: ", ")):\n\n\(DisplayEscape.escapedMultiline(preview))"
    }
}
