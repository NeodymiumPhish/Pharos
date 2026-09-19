// Standalone test runner for CellMatcher — the ONE rule the results Find
// field matches a cell by. Not part of the app target; compiled together with
// the implementation by scripts/test-cell-matcher.sh.
//
// The find path has no other home for this logic, so everything that can go
// wrong with a search — a half-typed regular expression, a "whole word" that
// matches inside a word, case folding applied on the wrong side — is a defect
// in this file's subject and nowhere else.
import Foundation

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectFalse(_ actual: Bool, _ name: String) {
    if !actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected false") }
}

private func matcher(_ pattern: String, _ mode: FindMode, matchCase: Bool = false) -> CellMatcher {
    CellMatcher(pattern: pattern, mode: mode, matchCase: matchCase)
}

func runTests() {

    // MARK: - Contains

    let contains = matcher("host", .contains)
    expectTrue(contains.isValid, "contains: any text is a valid pattern")
    expectTrue(contains.matches("localhost"), "contains: matches inside a longer word")
    expectTrue(contains.matches("HOST"), "contains: case-insensitive by default")
    expectFalse(contains.matches("hots"), "contains: a near miss does not match")

    let containsCased = matcher("host", .contains, matchCase: true)
    expectTrue(containsCased.matches("localhost"), "contains + match case: exact case matches")
    expectFalse(containsCased.matches("LOCALHOST"), "contains + match case: other case does not")

    // A regular-expression metacharacter is LITERAL text in this mode.
    expectFalse(matcher("a.c", .contains).matches("abc"), "contains: `.` is a full stop, not a wildcard")
    expectTrue(matcher("a.c", .contains).matches("xa.cy"), "contains: `.` matches a real full stop")

    // MARK: - Whole word

    let word = matcher("host", .wholeWord)
    expectTrue(word.isValid, "whole word: any text is a valid pattern")
    expectTrue(word.matches("the host is up"), "whole word: matches a standalone word")
    expectFalse(word.matches("localhost"), "whole word: does NOT match inside a longer word")
    expectFalse(word.matches("hostname"), "whole word: does NOT match a longer word's prefix")
    expectTrue(word.matches("host"), "whole word: the whole cell is the word")
    expectTrue(word.matches("db-host-1"), "whole word: punctuation is a boundary")
    expectTrue(word.matches("HOST down"), "whole word: case-insensitive by default")
    expectFalse(matcher("host", .wholeWord, matchCase: true).matches("HOST down"),
                "whole word + match case: other case does not match")

    // The pattern is literal here too, or a user searching for `a.b` would get
    // a wildcard they never asked for.
    expectFalse(matcher("a.c", .wholeWord).matches("abc"), "whole word: the pattern is escaped, not compiled")
    expectTrue(matcher("a.c", .wholeWord).matches("x a.c y"), "whole word: the escaped pattern still matches itself")

    // MARK: - Regular expression

    let regex = matcher("^10\\.0\\.0\\.[0-9]+$", .regularExpression)
    expectTrue(regex.isValid, "regex: a well-formed pattern is valid")
    expectTrue(regex.matches("10.0.0.1"), "regex: anchors match the whole cell")
    expectFalse(regex.matches("x10.0.0.1"), "regex: a leading anchor really anchors")
    expectFalse(regex.matches("10.0.0.1y"), "regex: a trailing anchor really anchors")
    expectTrue(matcher("^ab", .regularExpression).matches("abc"), "regex: ^ matches at the start")
    expectFalse(matcher("^bc", .regularExpression).matches("abc"), "regex: ^ does not match mid-cell")
    expectTrue(matcher("c$", .regularExpression).matches("abc"), "regex: $ matches at the end")
    expectFalse(matcher("a$", .regularExpression).matches("abc"), "regex: $ does not match mid-cell")

    expectTrue(matcher("ERR[0-9]+", .regularExpression).matches("err404"),
               "regex: case-insensitive by default")
    expectFalse(matcher("ERR[0-9]+", .regularExpression, matchCase: true).matches("err404"),
                "regex + match case: other case does not match")

    // MARK: - An invalid pattern

    // A half-typed expression is the normal state of the field while the user
    // types one. It must report itself invalid and match NOTHING — matching
    // everything would silently present the whole result as a hit.
    let broken = matcher("[unclosed", .regularExpression)
    expectFalse(broken.isValid, "regex: an unclosed class is invalid")
    expectFalse(broken.matches("unclosed"), "an invalid matcher matches nothing")
    expectFalse(broken.matches(""), "an invalid matcher matches nothing, empty cell included")

    let brokenQuantifier = matcher("*abc", .regularExpression)
    expectFalse(brokenQuantifier.isValid, "regex: a leading quantifier is invalid")
    expectFalse(brokenQuantifier.matches("abc"), "an invalid quantifier matches nothing")

    // The same text is perfectly valid in the other two modes.
    expectTrue(matcher("[unclosed", .contains).isValid, "contains: `[unclosed` is just text")
    expectTrue(matcher("[unclosed", .contains).matches("a [unclosed b"), "contains: and it matches itself")
    expectTrue(matcher("*abc", .wholeWord).isValid, "whole word: `*abc` is just text")

    // MARK: - The empty pattern

    // "No query yet". Every mode agrees, and none of them is invalid.
    for mode in FindMode.allCases {
        let empty = CellMatcher(pattern: "", mode: mode, matchCase: false)
        expectTrue(empty.isValid, "empty pattern is valid (\(mode.rawValue))")
        expectTrue(empty.matches("anything"), "empty pattern matches everything (\(mode.rawValue))")
        expectTrue(empty.matches(""), "empty pattern matches an empty cell (\(mode.rawValue))")
    }

    // MARK: - Text the grid really holds

    // Cells arrive as raw text, accents, emoji and all; none of the modes may
    // mangle one on the way through.
    expectTrue(matcher("café", .contains).matches("le café noir"), "contains: accents match")
    expectTrue(matcher("café", .wholeWord).matches("le café noir"), "whole word: accents match")
    expectTrue(matcher("日本", .contains).matches("日本語"), "contains: CJK matches")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    if failures > 0 { exit(1) }
}
