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

    /// The saved-connection delete confirmation.
    ///
    /// TRIMMED then escaped, unlike the table and query titles above. A table
    /// name is captured from the server, where an edge space is real data an
    /// analyst must be able to see. A connection name is an AUTHORED LABEL, and
    /// the save path now trims one, so an edge space in a stored name is a
    /// record written before it did — old data, whose stray space should read as
    /// gone rather than as a mid-word `<U+0020>` token.
    ///
    /// Trimmed, never SANITISED: sanitising removes a bidi override outright,
    /// so this title would draw a hostile name as though it were clean, which
    /// is the exact failure it exists to prevent.
    static func deleteConnectionConfirmTitle(name: String) -> String {
        "Delete \"\(DisplayEscape.escapedTrimmed(name))\"?"
    }

    /// The workspace delete confirmation. Trimmed for the same reason as
    /// `deleteConnectionConfirmTitle`: workspace rename trims at save, so an
    /// edge space in a stored workspace name is old data too.
    static func deleteWorkspaceConfirmTitle(name: String) -> String {
        "Delete workspace \"\(DisplayEscape.escapedTrimmed(name))\"?"
    }

    /// The saved-query delete confirmation. Trimmed for the same reason as
    /// `deleteConnectionConfirmTitle`: a saved-query name is an authored
    /// label, and both save paths — the save sheet and the rename sheet — now
    /// put it through `AuthoredLabelSanitizer.committed`, which trims.
    static func deleteSavedQueryConfirmTitle(name: String) -> String {
        "Delete \"\(DisplayEscape.escapedTrimmed(name))\"?"
    }

    /// The folder delete confirmation. A folder is not a stored record of its
    /// own: it is the `folder` field of every query inside it, written by the
    /// same two save paths, so it trims at save exactly as a query name does.
    ///
    /// This title gates the loss of EVERY query in the folder, so naming the
    /// wrong folder costs more than naming the wrong query.
    static func deleteFolderConfirmTitle(name: String) -> String {
        "Delete folder \"\(DisplayEscape.escapedTrimmed(name))\"?"
    }

    /// The unsaved-changes prompt of the connections manager.
    ///
    /// Not a delete: its "Don't Save" button loses the pending edits, which is
    /// a smaller loss than the titles above gate. It is here because the name
    /// it draws is the same authored connection name that
    /// `deleteConnectionConfirmTitle` draws, and one name must not read two
    /// ways in one window.
    ///
    /// Trimmed, and here the trim carries more than old data: this name is the
    /// LIVE draft, and the Save this prompt offers commits that draft through
    /// `AuthoredLabelSanitizer.committed`. The prompt therefore names the
    /// connection as it will be SAVED, not as it is typed.
    static func unsavedChangesConfirmTitle(name: String) -> String {
        "Save changes to \"\(DisplayEscape.escapedTrimmed(name))\"?"
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
