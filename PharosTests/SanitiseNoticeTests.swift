// Standalone tests for SanitiseNotice — the message that explains why a pasted
// authored label lost characters. Pure Foundation.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {

    // Nothing changed: no notice. This is the common case — every ordinary
    // keystroke goes through the caller, so a message here would be constant
    // noise.
    expectEqual(SanitiseNotice.message(raw: "case_alpha", sanitised: "case_alpha"), nil,
                "an untouched label produces no notice")
    expectEqual(SanitiseNotice.message(raw: "", sanitised: ""), nil,
                "an empty label produces no notice")

    // The case the user reported: a bidi override removed. The notice must show
    // the ORIGINAL with the override made visible, because the field itself can
    // only ever show the sanitised result.
    do {
        let raw = "safe\u{202E}gpj.exe"
        let notice = SanitiseNotice.message(raw: raw, sanitised: "safegpj.exe")
        expectEqual(notice,
                    "Removed 1 invisible character. You pasted: safe<U+202E>gpj.exe",
                    "the notice names the count and shows the override made visible")
        expectTrue(notice?.contains("<U+202E>") == true,
                   "the original is escaped, so the invisible character is legible")
        expectTrue(notice?.unicodeScalars.contains("\u{202E}") == false,
                   "the raw override is not itself in the notice — it would reorder the notice")
    }

    // Folding is not removal, and saying "removed" for a space the author can
    // still see would be wrong.
    expectEqual(SanitiseNotice.message(raw: "case\u{00A0}alpha", sanitised: "case alpha"),
                "Replaced 1 unusual space. You pasted: case<U+00A0>alpha",
                "a folded space is reported as replaced, not removed")

    // Plurals.
    expectEqual(SanitiseNotice.message(raw: "a\u{200B}\u{200C}b", sanitised: "ab"),
                "Removed 2 invisible characters. You pasted: a<U+200B><U+200C>b",
                "two removals pluralise")

    // Both kinds at once.
    do {
        let notice = SanitiseNotice.message(raw: "a\u{202E}b\u{00A0}c", sanitised: "ab c")
        expectEqual(notice,
                    "Removed 1 invisible character and replaced 1 unusual space."
                        + " You pasted: a<U+202E>b<U+00A0>c",
                    "a mixed paste reports both events")
    }

    // A long original is truncated, and truncation happens on the RAW string
    // before escaping — so no `<U+XXXX>` token can be cut in half.
    do {
        let raw = String(repeating: "x", count: 200) + "\u{202E}"
        let notice = SanitiseNotice.message(raw: raw, sanitised: String(repeating: "x", count: 200))
        expectTrue(notice?.contains("\u{2026}") == true,
                   "a long original is truncated with an ellipsis")
        expectTrue(notice?.contains("<U+") == false,
                   "a scalar past the cut is gone entirely, not shown as half a token")
    }

    // The boundary that proves the truncate-then-escape order: an override just
    // inside the cut must appear as a WHOLE token.
    do {
        let raw = String(repeating: "x", count: 79) + "\u{202E}" + String(repeating: "y", count: 40)
        let notice = SanitiseNotice.message(raw: raw,
                                           sanitised: String(repeating: "x", count: 79)
                                               + String(repeating: "y", count: 40))
        expectTrue(notice?.contains("<U+202E>") == true,
                   "an override inside the cut is shown whole — proves truncate-then-escape")
    }

    if failures == 0 { print("\nAll SanitiseNotice tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
