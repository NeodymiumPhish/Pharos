import Foundation

/// Builds the text of every dialog that gates irreversible loss.
///
/// The dialog is the last thing the analyst reads before approving, and the
/// object names inside it come from the server — attacker-controlled in this
/// app's threat model. A bidi override in a table name can make
/// `Truncate "X"?` name a different table than the statement acts on
/// (Trojan Source). So every name and every SQL preview is rendered through
/// `DisplayEscape` HERE, in the one place these strings are built.
///
/// Display only: the statement that executes is built from the raw name by
/// the caller. Both derive from the same raw string; only the eyes' copy is
/// escaped.
enum DestructiveConfirmationText {

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
    /// half, and a half token misreads as literal data.
    static func destructiveQueryMessage(keywords: [String], sql: String) -> String {
        let preview = sql.count > 200 ? String(sql.prefix(200)) + "…" : sql
        return "This SQL contains \(keywords.joined(separator: ", ")):\n\n\(DisplayEscape.escaped(preview))"
    }
}
