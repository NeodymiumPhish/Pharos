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

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
