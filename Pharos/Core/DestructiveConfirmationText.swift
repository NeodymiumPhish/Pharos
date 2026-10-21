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

    /// The body of the truncate confirmation.
    ///
    /// `TRUNCATE TABLE x` carries no `ONLY`, and PostgreSQL empties every
    /// table that inherits from `x` as well — measured, on PostgreSQL 16: two
    /// rows in a child were gone after truncating the parent, and survived
    /// `TRUNCATE ONLY`. The old wording promised "all rows in the table",
    /// which for a legacy partitioning root is every row in the whole
    /// archive. No count is given because the count that is known is of the
    /// DIRECT children, and the statement reaches all the way down.
    static func truncateConfirmMessage(hasInheritedChildren: Bool) -> String {
        guard hasInheritedChildren else {
            return "This will permanently delete all rows in the table. This cannot be undone."
        }
        return "Other tables inherit from this one, and PostgreSQL empties the whole tree: "
            + "every row in every table below it goes too, not only this table's. "
            + "This cannot be undone."
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

    /// The Connections Manager's delete alert: title, text and button. A
    /// DuckDB record is only Pharos's note of a file, so removing it is
    /// "Remove … from Pharos" and the text says the file stays; PostgreSQL
    /// keeps "Delete" and the stored password. `openInMemory`: in-memory
    /// records that are connected now, whose tables go with them.
    static func deleteConnectionsAlert(_ selected: [ConnectionConfig], openInMemory: Set<String> = [])
        -> (title: String, message: String, button: String) {
        let ducks = selected.filter(\.isDuckDB)
        let losesTables = ducks.contains { $0.isInMemoryDuckDB && openInMemory.contains($0.id) }
        let tablesLost = losesTables
            ? (ducks.count == 1 ? " " + String(localized: "Its tables are lost.")
                                : " " + String(localized: "The tables of open in-memory databases are lost."))
            : ""
        if !ducks.isEmpty, ducks.count == selected.count {
            if selected.count == 1 {
                let d = selected[0]
                let name = DisplayEscape.escapedTrimmed(d.name)
                let where_ = d.isInMemoryDuckDB ? ""
                    : String(localized: "The file \(DisplayEscape.escaped(d.locationDescription)) stays where it is.") + " "
                return (String(localized: "Remove “\(name)” from Pharos?"),
                        where_ + String(localized: "Saved Sessions on it lose their connection.") + tablesLost,
                        String(localized: "Remove"))
            }
            return (String(localized: "Remove \(selected.count) DuckDB databases from Pharos?"),
                    String(localized: "The files stay where they are. Saved Sessions on them lose their connection.") + tablesLost,
                    String(localized: "Remove"))
        }
        let title = selected.count == 1 ? deleteConnectionConfirmTitle(name: selected[0].name)
                                        : "Delete \(selected.count) connections?"
        var message = selected.count == 1
            ? "This will remove the saved configuration and stored password."
            : "This will remove the saved configurations and stored passwords."
        if !ducks.isEmpty { message += " " + String(localized: "The DuckDB files stay where they are.") + tablesLost }
        return (title, message, "Delete")
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
    /// Keywords that destroy rows or objects, as opposed to the ones that only
    /// write or re-permission. The confirmation is worded from this: calling an
    /// `INSERT` a destructive query is both wrong and the kind of wrong that
    /// teaches people to click through the sheet without reading it.
    private static let destroying: Set<String> = ["DROP", "DELETE", "TRUNCATE"]

    /// Title for the run confirmation.
    static func destructiveQueryTitle(keywords: [String]) -> String {
        keywords.contains(where: destroying.contains)
            ? String(localized: "Run destructive query?")
            : String(localized: "Run query that changes the database?")
    }

    static func destructiveQueryMessage(keywords: [String], sql: String) -> String {
        let preview = sql.count > sqlPreviewMaxLength
            ? String(sql.prefix(sqlPreviewMaxLength)) + "…" : sql
        return "This SQL contains \(keywords.joined(separator: ", ")):\n\n\(DisplayEscape.escapedMultiline(preview))"
    }
}
