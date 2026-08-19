// Standalone test for SqlIdentifierQuoting. Compiled with
// Pharos/Utilities/SqlIdentifierQuoting.swift only (pure Foundation).
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // Plain identifier: wrapped in quotes, contents unchanged.
    expect(quotedSqlIdentifier("users") == "\"users\"", "plain identifier wrapped unchanged")

    // The injection case: embedded quote is doubled, so the hostile name
    // stays ONE quoted identifier with no breakout.
    expect(
        quotedSqlIdentifier(#"a"; DROP TABLE x; --"#) == #""a""; DROP TABLE x; --""#,
        "embedded quote doubled — no SQL breakout"
    )

    // Multiple embedded quotes: every one doubled.
    expect(quotedSqlIdentifier(#"a"b"c"#) == #""a""b""c""#, "multiple embedded quotes all doubled")
    expect(quotedSqlIdentifier(#""""#) == #""""""""#, "identifier of only quotes: each doubled")

    // Qualified name joins schema and table with a dot, both quoted.
    expect(
        quotedQualifiedName(schema: "public", table: "users") == "\"public\".\"users\"",
        "qualified name joins with dot"
    )

    // Qualified name quotes hostile parts on BOTH sides.
    expect(
        quotedQualifiedName(schema: #"s"x"#, table: #"t"; DROP TABLE y; --"#)
            == #""s""x"."t""; DROP TABLE y; --""#,
        "qualified name doubles quotes in schema and table"
    )

    // A quote fused to a combining mark is still ONE grapheme; grapheme-aware
    // replacement would leave it undoubled and the identifier would break out.
    // The quote must be doubled and the combining mark preserved after it.
    expect(
        quotedSqlIdentifier("a\"\u{0301}; DROP TABLE x; --") == "\"a\"\"\u{0301}; DROP TABLE x; --\"",
        "quote fused to combining mark is doubled — no breakout"
    )

    // Empty string still yields a quoted empty identifier, no crash.
    expect(quotedSqlIdentifier("") == "\"\"", "empty string yields quoted empty identifier")

    // Names that merely LOOK special stay verbatim inside the quotes.
    expect(quotedSqlIdentifier("select") == "\"select\"", "keyword-like name quoted verbatim")
    expect(quotedSqlIdentifier("MiXeD.case name") == "\"MiXeD.case name\"", "dots and spaces preserved inside quotes")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
