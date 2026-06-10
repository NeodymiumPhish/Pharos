// Standalone test runner for SQLListFormatter. Not part of the app target —
// compiled together with the implementation by scripts/test-sql-list-formatter.sh.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

func runTests() {
    // MARK: - Detection

    expectTrue(SQLListFormatter.looksLikeBareList("10.0.0.1\n10.0.0.2\n10.0.0.3"), "bare IP list")
    expectTrue(SQLListFormatter.looksLikeBareList("abc\ndef"), "two bare strings")
    expectFalse(SQLListFormatter.looksLikeBareList("10.0.0.1"), "single line never offers")
    expectFalse(SQLListFormatter.looksLikeBareList("SELECT *\nFROM users\nWHERE id = 1"), "SQL query never offers")
    expectFalse(SQLListFormatter.looksLikeBareList("'a',\n'b',\n'c'"), "already formatted list never offers")
    expectTrue(SQLListFormatter.looksLikeBareList("'a'\n'b'\n'c'"), "quoted but uncomma'd still offers")
    expectTrue(SQLListFormatter.looksLikeBareList("OR\nIN\nCA\nWA"), "state codes incl OR/IN offer (short keywords excluded)")
    expectFalse(SQLListFormatter.looksLikeBareList("delete from t\nx"), "strong SQL keyword blocks offer")
    expectTrue(SQLListFormatter.looksLikeBareList("ip address\na\nb\nc\nd"), "one multi-word header among five lines passes 80% rule")
    expectFalse(SQLListFormatter.looksLikeBareList("new york\nlos angeles"), "all multi-word lines fail 80% rule")
    expectFalse(SQLListFormatter.looksLikeBareList("\n  \n"), "blank input never offers")

    // MARK: - Transform: quoting and type inference

    expectEqual(SQLListFormatter.sqlize("a\nb\nc"), "'a',\n'b',\n'c'", "strings quoted, list view kept, no trailing comma")
    expectEqual(SQLListFormatter.sqlize("1\n2\n3"), "1,\n2,\n3", "all-integer list unquoted")
    expectEqual(SQLListFormatter.sqlize("1.5\n-2\n3.25"), "1.5,\n-2,\n3.25", "decimals and negatives unquoted")
    expectEqual(SQLListFormatter.sqlize("true\nFALSE"), "true,\nFALSE", "all-boolean list unquoted, case kept")
    expectEqual(SQLListFormatter.sqlize("NULL\nnull"), "NULL,\nnull", "all-NULL list unquoted")
    expectEqual(SQLListFormatter.sqlize("1\nabc"), "'1',\n'abc'", "mixed types: quote everything")
    expectEqual(SQLListFormatter.sqlize("O'Brien\nD'Arcy"), "'O''Brien',\n'D''Arcy'", "embedded apostrophes escaped")

    // MARK: - Transform: normalization of partly formatted input

    expectEqual(SQLListFormatter.sqlize("'a'\nb\n\"c\""), "'a',\n'b',\n'c'", "mixed pre-quoting normalized to single quotes")
    expectEqual(SQLListFormatter.sqlize("a,\nb,\nc"), "'a',\n'b',\n'c'", "existing trailing commas stripped before re-joining")
    expectEqual(SQLListFormatter.sqlize("'O''Brien'\n'x'"), "'O''Brien',\n'x'", "pre-escaped quotes not double-escaped")

    // MARK: - Transform: layout

    expectEqual(SQLListFormatter.sqlize("  a\n  b"), "  'a',\n  'b'", "leading indentation preserved per line")
    expectEqual(SQLListFormatter.sqlize("a\n\nb"), "'a',\n'b'", "blank lines dropped")
    expectEqual(SQLListFormatter.sqlize("abc"), "'abc'", "single value gets no comma")
    expectEqual(SQLListFormatter.sqlize("   \n  "), "   \n  ", "all-blank input returned unchanged")

    // MARK: - Adversarial / regression

    expectFalse(SQLListFormatter.looksLikeBareList("'a','b'\n'c','d'"), "inline quoted CSV rows never offer")
    expectTrue(SQLListFormatter.looksLikeBareList("a\r\nb\r\nc"), "CRLF input still offers")
    expectEqual(SQLListFormatter.sqlize("a\r\nb"), "'a',\n'b'", "CRLF input transforms cleanly")
    expectEqual(SQLListFormatter.sqlize("'\nx"), "'''',\n'x'", "quote-only token safely escaped")
    expectEqual(SQLListFormatter.sqlize("\"O'Brien\"\n\"x\""), "'O''Brien',\n'x'", "double-quoted token with apostrophe escaped once")
    expectEqual(
        SQLListFormatter.sqlize("a\n'); DROP TABLE users; --"),
        "'a',\n'''); DROP TABLE users; --'",
        "injection-style value stays one escaped literal"
    )
    expectTrue(SQLListFormatter.looksLikeBareList(Array(repeating: "x", count: 5_000).joined(separator: "\n")), "5000 lines accepted")
    expectFalse(SQLListFormatter.looksLikeBareList(Array(repeating: "x", count: 5_001).joined(separator: "\n")), "5001 lines rejected")
    expectTrue(SQLListFormatter.looksLikeBareList(Array(repeating: "x", count: 3_000).joined(separator: "\r\n")), "3000 CRLF lines accepted (cap counts values, not raw lines)")

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
