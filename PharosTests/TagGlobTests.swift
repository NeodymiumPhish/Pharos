// Standalone test for TagGlob. Compiled with Pharos/Core/TagGlob.swift only
// (pure Foundation).
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

/// Compile and match in one call, for the cases where compiling must succeed.
func glob(_ pattern: String, _ text: String) -> Bool {
    guard let tokens = TagGlob.compile(pattern) else { return false }
    return TagGlob.matches(tokens, text)
}

func runTests() {
    // The case this feature exists for.
    expect(glob("*.neodymiumphi.sh", "network.neodymiumphi.sh"), "suffix glob matches a subdomain")
    expect(!glob("*.neodymiumphi.sh", "neodymiumphi.sh"), "suffix glob needs the dot")
    expect(glob("*neodymiumphi.sh", "neodymiumphi.sh"), "bare star matches an empty run")

    // Anchoring: a glob matches the WHOLE value, never a substring.
    expect(!glob("evil", "evil.com"), "no implicit trailing wildcard")
    expect(!glob("com", "evil.com"), "no implicit leading wildcard")
    expect(glob("evil.com", "evil.com"), "an exact pattern still matches")

    // ? is exactly one.
    expect(glob("evil-??.com", "evil-42.com"), "two ? match two characters")
    expect(!glob("evil-??.com", "evil-4.com"), "? does not match nothing")
    expect(!glob("evil-??.com", "evil-423.com"), "? does not match two")

    // Backtracking. A naive greedy walk fails these.
    expect(glob("*a*b", "xxaxxbxxab"), "backtracks to a later a")
    expect(glob("*ab*cd*", "1ab2cd3"), "three runs")
    expect(!glob("*ab*cd*", "1cd2ab3"), "order still matters")
    expect(glob("****a", "a"), "a run of stars collapses")

    // Escapes. A LITERAL star, question mark or backslash.
    expect(glob(#"\*"#, "*"), "escaped star matches a literal star")
    expect(!glob(#"\*"#, "anything"), "escaped star is not a wildcard")
    expect(glob(#"a\?b"#, "a?b"), "escaped question mark")
    expect(!glob(#"a\?b"#, "axb"), "escaped question mark is not a wildcard")
    expect(glob(#"a\\b"#, #"a\b"#), "escaped backslash matches one backslash")

    // A trailing lone backslash has nothing to escape. It is REJECTED at
    // compile, not silently treated as a literal: guessing here would let a
    // typo match something the analyst never wrote.
    expect(TagGlob.compile(#"abc\"#) == nil, "trailing lone backslash fails to compile")
    expect(TagGlob.compile("") == nil, "empty pattern fails to compile")
    expect(TagGlob.compile("*") != nil, "a lone star compiles")

    // ? counts what the analyst can SEE. An accented letter written as a base
    // plus a combining mark is two scalars and ONE Character.
    expect(glob("a?c", "a\u{0065}\u{0301}c"), "? matches one grapheme of two scalars")

    // A star matches an empty run at either end.
    expect(glob("*", ""), "a lone star matches empty text")
    expect(glob("a*", "a"), "trailing star matches nothing")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
