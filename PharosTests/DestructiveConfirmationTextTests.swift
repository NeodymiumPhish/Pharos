// Standalone test runner for DestructiveConfirmationText. Pure Foundation.
// Compiled with the implementation by scripts/test-destructive-confirmation-text.sh.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // Ordinary names pass through looking ordinary.
    expectEqual(DestructiveConfirmationText.truncateConfirmTitle(table: "users"),
                "Truncate \"users\"?",
                "plain truncate title")
    expectEqual(DestructiveConfirmationText.dropConfirmTitle(name: "users"),
                "Drop \"users\"?",
                "plain drop title")
    expectEqual(DestructiveConfirmationText.truncatedInfoMessage(table: "users"),
                "\"users\" has been truncated.",
                "plain truncated message")
    expectEqual(DestructiveConfirmationText.droppedInfoMessage(name: "users"),
                "\"users\" has been dropped.",
                "plain dropped message")

    // The dialog gates irreversible loss: a bidi override in the name is
    // DISCLOSED, so the dialog cannot name a different object than it acts on.
    expectEqual(DestructiveConfirmationText.truncateConfirmTitle(table: "safe\u{202E}x"),
                "Truncate \"safe<U+202E>x\"?",
                "truncate title discloses a bidi override")
    expectEqual(DestructiveConfirmationText.dropConfirmTitle(name: "a\u{200B}b"),
                "Drop \"a<U+200B>b\"?",
                "drop title discloses a zero-width character")

    // The delete-workspace confirmation is the same shape: the last thing a
    // user reads before an irreversible delete, naming an attacker-controlled
    // workspace name.
    expectEqual(DestructiveConfirmationText.deleteWorkspaceConfirmTitle(name: "My Workspace"),
                "Delete workspace \"My Workspace\"?",
                "plain delete-workspace title")
    expectEqual(DestructiveConfirmationText.deleteWorkspaceConfirmTitle(name: "safe\u{202E}x"),
                "Delete workspace \"safe<U+202E>x\"?",
                "delete-workspace title discloses a bidi override")

    // The destructive-query preview: raw SQL truncated FIRST (grapheme-safe),
    // escaped AFTER, so an escape token is never cut in half.
    let msg = DestructiveConfirmationText.destructiveQueryMessage(
        keywords: ["DROP"], sql: "DROP TABLE \u{202E}x")
    expectEqual(msg,
                "This SQL contains DROP:\n\nDROP TABLE <U+202E>x",
                "query message escapes the preview")

    let longSQL = String(repeating: "S", count: 300) + "\u{202E}"
    let longMsg = DestructiveConfirmationText.destructiveQueryMessage(keywords: ["DELETE"], sql: longSQL)
    expectEqual(longMsg.hasSuffix("…"), true, "long SQL is truncated with an ellipsis")
    expectEqual(longMsg.contains("\u{202E}"), false,
                "nothing hostile survives into the preview even when truncated")
    expectEqual(longMsg.contains("<U+202E>"), false,
                "the scalar past the 200-char cut is gone entirely, not escaped")

    // Ordering is load-bearing and this input discriminates it: the override
    // sits at index 199, INSIDE the 200-char cut. Truncate-then-escape keeps
    // it and discloses it whole. Escape-then-truncate would expand it to an
    // 8-char token BEFORE the cut, and the cut would slice the token into a
    // bare "<" fragment.
    let boundarySQL = String(repeating: "S", count: 199) + "\u{202E}" + String(repeating: "S", count: 150)
    let boundaryMsg = DestructiveConfirmationText.destructiveQueryMessage(keywords: ["DROP"], sql: boundarySQL)
    expectEqual(boundaryMsg.contains("<U+202E>"), true,
                "a scalar inside the cut is disclosed whole — proves truncate-then-escape")
    expectEqual(boundaryMsg.hasSuffix("…"), true,
                "the boundary preview is still truncated")

    // Ordinary multi-line SQL must read as itself in the preview.
    expectEqual(DestructiveConfirmationText.destructiveQueryMessage(
                    keywords: ["DROP"], sql: "DROP TABLE a;\n\tDELETE FROM b;"),
                "This SQL contains DROP:\n\nDROP TABLE a;\n\tDELETE FROM b;",
                "multi-line SQL keeps its newlines and tabs")
    expectEqual(DestructiveConfirmationText.destructiveQueryMessage(
                    keywords: ["DROP", "TRUNCATE"], sql: "DROP TABLE x"),
                "This SQL contains DROP, TRUNCATE:\n\nDROP TABLE x",
                "keywords join with a comma and a space")


    // MARK: - The connection delete confirmation

    // The last thing a user reads before an irreversible delete of a saved
    // connection, naming a stored name. Plain names read as themselves.
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: "Prod Reporting"),
                "Delete \"Prod Reporting\"?",
                "plain delete-connection title")

    // The defect this function exists to stop: a bidi override made the
    // confirmation name a DIFFERENT connection than the one about to go.
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: "safe\u{202E}gpj.exe"),
                "Delete \"safe<U+202E>gpj.exe\"?",
                "delete-connection title discloses a bidi override")
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: "a\u{200B}b"),
                "Delete \"a<U+200B>b\"?",
                "delete-connection title discloses a zero-width character")

    // A name stored before the save path trimmed carries an edge space. It is
    // trimmed away rather than disclosed as a token: the stray space is the
    // display defect, not the payload.
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: "  Prod  "),
                "Delete \"Prod\"?",
                "delete-connection title trims edge spaces")

    // Trim FIRST, escape SECOND, and this input discriminates the order. Trim
    // then escape leaves the override at the head of the trimmed text and
    // discloses it. Escape then trim would turn the edge spaces into
    // <U+0020> tokens first, and nothing would be left at an edge to trim.
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: " \u{202E}x "),
                "Delete \"<U+202E>x\"?",
                "delete-connection title trims before it escapes")

    // Interior spaces are the author's own and survive untouched.
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: " a b "),
                "Delete \"a b\"?",
                "delete-connection title keeps interior spaces")

    // Sanitising is the WRONG half here. It would REMOVE the override, so the
    // dialog would draw a hostile name as though it were clean.
    expectEqual(DestructiveConfirmationText.deleteConnectionConfirmTitle(name: "safe\u{202E}x")
                    .contains("<U+202E>"),
                true,
                "the hostile scalar is disclosed, never removed")

    // The workspace title trims too. Workspace rename trims at save, so an
    // edge space in a stored workspace name is old data, exactly as it is for
    // a tag name and now for a connection name.
    expectEqual(DestructiveConfirmationText.deleteWorkspaceConfirmTitle(name: "  My Workspace "),
                "Delete workspace \"My Workspace\"?",
                "delete-workspace title trims edge spaces")
    expectEqual(DestructiveConfirmationText.deleteWorkspaceConfirmTitle(name: " \u{202E}x "),
                "Delete workspace \"<U+202E>x\"?",
                "delete-workspace title trims before it escapes")


    // MARK: - The saved-query and folder delete confirmations

    // The saved-query delete confirmation names a stored, authored name.
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: "Monthly Revenue"),
                "Delete \"Monthly Revenue\"?",
                "plain delete-saved-query title")

    // The defect this function exists to stop: a bidi override made the
    // confirmation name a DIFFERENT query than the one about to go.
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: "safe\u{202E}gpj.exe"),
                "Delete \"safe<U+202E>gpj.exe\"?",
                "delete-saved-query title discloses a bidi override")
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: "a\u{200B}b"),
                "Delete \"a<U+200B>b\"?",
                "delete-saved-query title discloses a zero-width character")

    // TRIMMED, because the save path trims: `SaveQuerySheet` and the rename
    // sheet both put the name through `AuthoredLabelSanitizer.committed`, so
    // an edge space in a stored name is a record written before they did.
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: "  Monthly  "),
                "Delete \"Monthly\"?",
                "delete-saved-query title trims edge spaces")
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: " \u{202E}x "),
                "Delete \"<U+202E>x\"?",
                "delete-saved-query title trims before it escapes")
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: " a b "),
                "Delete \"a b\"?",
                "delete-saved-query title keeps interior spaces")

    // The folder title is the same shape. It gates a MULTI-query delete, so
    // naming the wrong folder costs more than naming the wrong query.
    expectEqual(DestructiveConfirmationText.deleteFolderConfirmTitle(name: "Reports"),
                "Delete folder \"Reports\"?",
                "plain delete-folder title")
    expectEqual(DestructiveConfirmationText.deleteFolderConfirmTitle(name: "safe\u{202E}gpj.exe"),
                "Delete folder \"safe<U+202E>gpj.exe\"?",
                "delete-folder title discloses a bidi override")
    expectEqual(DestructiveConfirmationText.deleteFolderConfirmTitle(name: "a\u{200B}b"),
                "Delete folder \"a<U+200B>b\"?",
                "delete-folder title discloses a zero-width character")
    expectEqual(DestructiveConfirmationText.deleteFolderConfirmTitle(name: "  Reports "),
                "Delete folder \"Reports\"?",
                "delete-folder title trims edge spaces")
    expectEqual(DestructiveConfirmationText.deleteFolderConfirmTitle(name: " \u{202E}x "),
                "Delete folder \"<U+202E>x\"?",
                "delete-folder title trims before it escapes")

    // Sanitising is the WRONG half on both: it would REMOVE the override, so
    // each title would draw a hostile name as though it were clean.
    expectEqual(DestructiveConfirmationText.deleteSavedQueryConfirmTitle(name: "safe\u{202E}x")
                    .contains("<U+202E>"),
                true,
                "the saved-query title discloses, never removes")
    expectEqual(DestructiveConfirmationText.deleteFolderConfirmTitle(name: "safe\u{202E}x")
                    .contains("<U+202E>"),
                true,
                "the folder title discloses, never removes")


    // MARK: - The unsaved-changes prompt

    // Not a delete, but the "Don't Save" button loses the edits, and the name
    // it draws is the same authored connection name the rest of that view now
    // draws through `DisplayEscape`.
    expectEqual(DestructiveConfirmationText.unsavedChangesConfirmTitle(name: "Prod Reporting"),
                "Save changes to \"Prod Reporting\"?",
                "plain unsaved-changes title")
    expectEqual(DestructiveConfirmationText.unsavedChangesConfirmTitle(name: "safe\u{202E}gpj.exe"),
                "Save changes to \"safe<U+202E>gpj.exe\"?",
                "unsaved-changes title discloses a bidi override")
    expectEqual(DestructiveConfirmationText.unsavedChangesConfirmTitle(name: "a\u{200B}b"),
                "Save changes to \"a<U+200B>b\"?",
                "unsaved-changes title discloses a zero-width character")

    // TRIMMED: this name is the LIVE draft, and the save it offers puts that
    // draft through `AuthoredLabelSanitizer.committed`. The prompt must name
    // the connection as it will be SAVED, not as it is typed.
    expectEqual(DestructiveConfirmationText.unsavedChangesConfirmTitle(name: "  Prod  "),
                "Save changes to \"Prod\"?",
                "unsaved-changes title trims edge spaces")
    expectEqual(DestructiveConfirmationText.unsavedChangesConfirmTitle(name: " \u{202E}x "),
                "Save changes to \"<U+202E>x\"?",
                "unsaved-changes title trims before it escapes")

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
