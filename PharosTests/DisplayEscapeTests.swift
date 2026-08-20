// Standalone test runner for DisplayEscape. Pure Foundation, no AppKit.
// Compiled with the implementation by scripts/test-display-escape.sh.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {

    // MARK: - 1. The three families that were measured rendering wrong

    do {
        // The bidi override is the one that turns a label into a lie: raw, this
        // string DISPLAYS as "safeexe.jpg" in an AppKit label, so the reader
        // sees a filename the data does not hold.
        expectEqual(DisplayEscape.escaped("safe\u{202E}gpj.exe"),
                    "safe<U+202E>gpj.exe",
                    "a right-to-left override is shown, not obeyed")
        expectEqual(DisplayEscape.escaped("\u{200B}\u{200D}\u{FEFF}"),
                    "<U+200B><U+200D><U+FEFF>",
                    "zero-width characters cannot hide inside a value")
        expectEqual(DisplayEscape.escaped("10.0.0\u{A0}.1"), "10.0.0<U+00A0>.1",
                    "a non-breaking space is not a space")
        expectEqual(DisplayEscape.escaped("a\nb\tc"), "a<U+000A>b<U+0009>c",
                    "C0 controls are shown, not fed to the label")
        expectEqual(DisplayEscape.escaped("a\u{0000}b\u{0007}c\u{001B}d"),
                    "a<U+0000>b<U+0007>c<U+001B>d",
                    "NUL, BEL and ESC are named — all three used to reach the label raw")
        expectEqual(DisplayEscape.escaped("a\u{007F}b"), "a<U+007F>b",
                    "DEL is escaped too")
        // The invisible bidi MARKS, not just the override/embedding set. A LRM
        // is enough to flip the rendered order of neighbouring digits, so
        // `10.0.0.1` and a mark-carrying twin must not read alike.
        expectEqual(DisplayEscape.escaped("a\u{200E}b\u{200F}c\u{061C}d"),
                    "a<U+200E>b<U+200F>c<U+061C>d",
                    "LRM, RLM and ALM are escaped — invisible marks, not just overrides")
        // The isolates, the other half of the bidi control set.
        expectEqual(DisplayEscape.escaped("a\u{2066}b\u{2069}c"), "a<U+2066>b<U+2069>c",
                    "the isolate set is escaped")
        // The remaining unusual spaces beside NBSP.
        expectEqual(DisplayEscape.escaped("a\u{2003}b\u{202F}c\u{3000}d"),
                    "a<U+2003>b<U+202F>c<U+3000>d",
                    "em space, narrow NBSP and ideographic space are escaped")
        expectEqual(DisplayEscape.escaped("a\u{2060}b"), "a<U+2060>b",
                    "the word joiner is escaped")
    }

    // MARK: - 2. Distinct values must not render alike

    do {
        // Four values that otherwise render as four identical labels. This is
        // the reason the edge-space rule exists at all.
        let lookalikes = ["10.0.0.1", "10.0.0.1\u{200B}", "10.0.0\u{A0}.1", "10.0.0.1 "]
            .map(DisplayEscape.escaped)
        expectEqual(Set(lookalikes).count, 4,
                    "four look-alike values render four distinguishable ways")

        expectEqual(DisplayEscape.escaped("10.0.0.1 "), "10.0.0.1<U+0020>",
                    "a trailing space is marked — at the end of a label it is invisible")
        expectEqual(DisplayEscape.escaped(" 10.0.0.1"), "<U+0020>10.0.0.1",
                    "and so is a leading one")
    }

    // MARK: - 3. Ordinary data is NOT mangled

    do {
        expectEqual(DisplayEscape.escaped("CN=evil corp, O=x"), "CN=evil corp, O=x",
                    "an ordinary interior space is left alone — this is not a mangler")
        expectEqual(DisplayEscape.escaped("café ☕ 日本"), "café ☕ 日本",
                    "accents, emoji and CJK survive untouched")
        expectEqual(DisplayEscape.escaped("Ω≈ç√∫˜µ"), "Ω≈ç√∫˜µ",
                    "assorted printable non-ASCII is left alone")
        expectEqual(DisplayEscape.escaped(""), "", "the empty string escapes to itself")
        expectEqual(DisplayEscape.escaped("plain"), "plain", "plain text escapes to itself")
        // Combining marks and surrogate-pair emoji must not be split or renamed.
        expectEqual(DisplayEscape.escaped("e\u{0301}"), "e\u{0301}",
                    "a combining acute is not a control and survives")
        expectEqual(DisplayEscape.escaped("☕😀🇬🇧"), "☕😀🇬🇧",
                    "emoji without joiners — including a flag pair — survive untouched")
        // Deliberate and named: a ZWJ family emoji comes apart, because U+200D
        // is exactly where a hostile string hides. Escaping it is worth the
        // cost of an odd-looking family emoji in a result cell; NOT escaping it
        // would leave the documented `10.0.0.1<ZWSP>` class of look-alike open.
        expectEqual(DisplayEscape.escaped("👨‍👩‍👧"), "👨<U+200D>👩<U+200D>👧",
                    "a ZWJ sequence shows its joiners — a joiner IS the hiding place")
    }

    // MARK: - 4. Runs of one escaped scalar collapse

    do {
        // char(n) columns arrive from PostgreSQL space-padded. One token per
        // space would turn `US` in a char(20) into 162 characters of escape and
        // mangle the grid — the failure mode this rule exists to avoid — so a
        // run of the SAME escaped scalar carries its count instead.
        expectEqual(DisplayEscape.escaped("US" + String(repeating: " ", count: 18)),
                    "US<U+0020\u{00D7}18>",
                    "char(20) padding stays one short token, not eighteen")
        expectEqual(DisplayEscape.escaped("   "), "<U+0020\u{00D7}3>",
                    "an all-space value reports how many spaces it is")
        expectEqual(DisplayEscape.escaped("a\u{200B}\u{200B}b"), "a<U+200B\u{00D7}2>b",
                    "the rule is per-scalar, not space-specific")
        expectEqual(DisplayEscape.escaped("a\u{200B}\u{200C}b"), "a<U+200B><U+200C>b",
                    "two DIFFERENT scalars do not merge into one count")
        expectEqual(DisplayEscape.escaped(" a "), "<U+0020>a<U+0020>",
                    "a single edge space carries no count suffix")
    }

    // MARK: - 5. Interior spaces are not edge spaces

    do {
        expectEqual(DisplayEscape.escaped("a  b"), "a  b",
                    "a doubled INTERIOR space is ordinary text and is left alone")
        expectEqual(DisplayEscape.escaped("  a  b  "),
                    "<U+0020\u{00D7}2>a  b<U+0020\u{00D7}2>",
                    "only the edges are marked; the middle keeps its real spaces")
    }

    // MARK: - 6. The fast path returns the SAME string, not a rebuilt copy

    do {
        // Not cosmetic: this runs for every visible grid cell on every scroll
        // tick, so the common case must not allocate.
        let plain = "10.0.0.1"
        expectEqual(DisplayEscape.needsEscaping(plain), false,
                    "a clean value reports that it needs nothing")
        expectEqual(DisplayEscape.needsEscaping("10.0.0.1 "), true,
                    "a trailing space alone is enough to need escaping")
        expectEqual(DisplayEscape.needsEscaping(" 10.0.0.1"), true,
                    "a leading space alone is enough")
        expectEqual(DisplayEscape.needsEscaping("a\u{202E}b"), true,
                    "an override alone is enough")
        expectEqual(DisplayEscape.needsEscaping(""), false,
                    "the empty string needs nothing")
        expectEqual(DisplayEscape.escaped(plain), plain,
                    "and the fast path yields an equal string")
    }

    // MARK: - 7. escaped() is idempotent-safe on its own output shape

    do {
        // NOT a claim that escaping twice is a no-op — it is not, and no call
        // site does it. The claim is narrower: the token text itself contains
        // nothing that would be escaped again, so a double application cannot
        // corrupt a token into something unreadable.
        let once = DisplayEscape.escaped("a\u{202E}b")
        expectEqual(DisplayEscape.escaped(once), once,
                    "the token text is plain ASCII and survives a second pass")
    }

    // MARK: - Scalars added by the hostile-text hardening phase

    do {
        // U+2028/U+2029 break a single-line label into two apparent values.
        expectEqual(DisplayEscape.escaped("one\u{2028}two"),
                    "one<U+2028>two",
                    "a line separator is shown, not obeyed")
        expectEqual(DisplayEscape.escaped("one\u{2029}two"),
                    "one<U+2029>two",
                    "a paragraph separator is shown, not obeyed")
        // U+1680 renders as a space on most fonts: an unusual-space twin.
        expectEqual(DisplayEscape.escaped("a\u{1680}b"),
                    "a<U+1680>b",
                    "the ogham space mark is disclosed")
        // U+180E is format (Cf) since Unicode 6.3: fully invisible.
        expectEqual(DisplayEscape.escaped("a\u{180E}b"),
                    "a<U+180E>b",
                    "the Mongolian vowel separator is disclosed")
        expectEqual(DisplayEscape.needsEscaping("plain text"), false,
                    "ordinary text still passes the fast path untouched")
        // U+0085 (NEL) is the fifth mandatory line break AppKit obeys; the rest
        // of C1 is invisible control noise, exactly like C0.
        expectEqual(DisplayEscape.escaped("one\u{0085}two"),
                    "one<U+0085>two",
                    "a next-line control is shown, not obeyed")
        expectEqual(DisplayEscape.escaped("a\u{009B}b"),
                    "a<U+009B>b",
                    "a C1 control is disclosed")
    }

    // MARK: - 8. escapedMultiline: a SQL preview's own formatting is not hostile

    do {
        expectEqual(DisplayEscape.escapedMultiline("DROP TABLE a;\n\tDELETE FROM b;"),
                    "DROP TABLE a;\n\tDELETE FROM b;",
                    "newlines and tabs are the query's own formatting")
        expectEqual(DisplayEscape.escapedMultiline("  SELECT 1"),
                    "  SELECT 1",
                    "leading spaces are indentation, not edge-space disclosure")
        expectEqual(DisplayEscape.escapedMultiline("DROP \u{202E}x\nGO"),
                    "DROP <U+202E>x\nGO",
                    "a hostile scalar inside a line is still disclosed")
        expectEqual(DisplayEscape.escapedMultiline("a\u{200B}\u{200B}\u{200B}b"),
                    "a<U+200B\u{00D7}3>b",
                    "run collapsing works in the multi-line variant too")
        expectEqual(DisplayEscape.escapedMultiline("one\u{2028}two"),
                    "one<U+2028>two",
                    "a line SEPARATOR is not a newline and is still disclosed")
    }

    // The predicate shared by the multi-line escaper and the editor's pill
    // rendering: in flowing text, `\n` and `\t` are the text's own formatting.
    expectEqual(DisplayEscape.isHostileInFlowingText("\u{202E}"), true,
                "a bidi override is hostile in flowing text")
    expectEqual(DisplayEscape.isHostileInFlowingText("\u{200B}"), true,
                "a zero-width space is hostile in flowing text")
    expectEqual(DisplayEscape.isHostileInFlowingText("\n"), false,
                "a newline is the text's own formatting")
    expectEqual(DisplayEscape.isHostileInFlowingText("\t"), false,
                "a tab is the text's own formatting")
    expectEqual(DisplayEscape.isHostileInFlowingText("\r"), true,
                "a stray carriage return is still disclosed")
    expectEqual(DisplayEscape.isHostileInFlowingText("A"), false,
                "an ordinary letter is not hostile")
    expectEqual(DisplayEscape.isHostileInFlowingText(" "), false,
                "a plain space is not hostile in flowing text — indentation is normal")
    // Only \n and \t are relaxed — a mutant that widens the relaxed range to
    // 0x09...0x0C would pass every assertion above without these three.
    expectEqual(DisplayEscape.isHostileInFlowingText("\u{0B}"), true,
                "a vertical tab is not the text's own formatting — only \\n and \\t are")
    expectEqual(DisplayEscape.isHostileInFlowingText("\u{0C}"), true,
                "a form feed is still disclosed")
    expectEqual(DisplayEscape.isHostileInFlowingText("\u{0085}"), true,
                "NEL is a line break the predicate still discloses")

    if failures == 0 {
        print("\nAll DisplayEscape tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
