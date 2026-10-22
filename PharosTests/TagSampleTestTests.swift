// Standalone test for TagSampleTest — compiled by scripts/test-tag-sample-test.sh.
import Foundation

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func cond(_ family: String, _ kind: TagConditionKind, _ display: String, _ op2: String? = nil) -> TagCondition {
    TagCondition(family: family, kind: kind, value: TagValueNormalizer.normalize(display, family: family),
                 operand2: op2, display: display)
}

func runTests() {
    let A = TagValueNormalizer.addressFamily, T = TagValueNormalizer.textFamily, N = TagValueNormalizer.numericFamily
    let rules: [[TagCondition]] = [
        [cond(A, .cidr, "10.0.0.0/8")],
        [cond(A, .exact, "10.1.2.3")],
        [cond(T, .glob, "*.example.com")],
        [cond(A, .cidr, "10.0.0.0/8"), cond(N, .greaterThan, "443")],
        [cond(T, .exact, "Phish")],
    ]
    let r = TagSampleTest.evaluate("10.1.2.3", rules: rules)
    expect(r.map(\.isMatch), [true, true, false, false, false], "an address: in the range, and the exact one")
    expect(r[3].matched, 1, "a two-condition rule: one of two")
    expect(TagSampleTest.summary(r, sample: "10.1.2.3"), "Matches rule 1 and rule 2. Rule 4: 1 of 2 conditions.",
           "the summary")
    expect(TagSampleTest.evaluate("mail.example.com", rules: rules).map(\.isMatch), [false, false, true, false, false],
           "a pattern")
    expect(TagSampleTest.evaluate("phish", rules: rules)[4].isMatch, true, "text compares case-folded, as the grid does")
    expect(TagSampleTest.evaluate("8080", rules: [[cond(N, .greaterThan, "443")]])[0].isMatch, true, "a comparison")
    expect(TagSampleTest.evaluate("80", rules: [[cond(N, .greaterThan, "443")]])[0].isMatch, false, "and its other side")
    expect(TagSampleTest.summary(TagSampleTest.evaluate("nothing", rules: rules), sample: "nothing"),
           "No rule matches this value.", "no match says so")
    expect(TagSampleTest.summary([], sample: "  "), "", "an empty sample says nothing")
    expect(TagSampleTest.conditionMatches(TagCondition(family: T, kind: .unsupported("soundex"), value: "x", display: "x"),
                                          sample: "x"), false, "a kind from a newer build never matches")
    if failures == 0 { print("\nAll tag sample test tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
