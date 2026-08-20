// Standalone tests for SavedQueryFilename — the one place a name becomes a
// filename. Pure Foundation.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // Behaviour that already existed, pinned before it is widened.
    expectEqual(SavedQueryFilename.sanitize("Case Alpha"), "Case Alpha",
                "an ordinary name is untouched")
    expectEqual(SavedQueryFilename.sanitize("a/b"), "a_b",
                "a path separator is replaced")
    expectEqual(SavedQueryFilename.sanitize("a:b"), "a_b",
                "a colon is replaced")
    expectEqual(SavedQueryFilename.sanitize(".hidden"), "hidden",
                "a leading dot is stripped so the file is not hidden")
    expectEqual(SavedQueryFilename.sanitize("   "), "untitled",
                "a name that sanitises to nothing falls back")
    expectEqual(SavedQueryFilename.sanitize(""), "untitled",
                "and so does an empty one")

    // The widening: every scalar DisplayEscape names is replaced, not removed,
    // so the substitution stays visible in the name the user is offered.
    expectEqual(SavedQueryFilename.sanitize("safe\u{202E}gpj.exe"), "safe_gpj.exe",
                "a bidi override cannot dress a filename up as another")
    expectEqual(SavedQueryFilename.sanitize("a\u{200B}b"), "a_b",
                "a zero-width character is replaced")
    expectEqual(SavedQueryFilename.sanitize("a\u{00A0}b"), "a_b",
                "a non-breaking space is replaced")
    expectEqual(SavedQueryFilename.sanitize("a\u{7F}b"), "a_b",
                "DEL is replaced — it is above the old <0x20 bound")
    expectEqual(SavedQueryFilename.sanitize("a\u{0085}b"), "a_b",
                "NEL is replaced — it is in the C1 range the old bound missed")
    expectEqual(SavedQueryFilename.sanitize("a\u{2028}b"), "a_b",
                "a line separator is replaced")

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
