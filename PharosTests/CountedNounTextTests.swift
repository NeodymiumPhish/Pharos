// Standalone test runner for CountedNounText — the automatic-inflection
// helper behind the app's nine hand-built plurals. Compiled with the
// implementation by scripts/test-localized-plurals.sh.
//
// This is also the harness that PROVES the inflector's coverage: it is what
// caught "tuple" not pluralising on its own, which is why CountedNounText
// special-cases it instead of shipping "2 tuple".
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // MARK: Ordinary nouns — resolved by automatic grammatical agreement.

    expectEqual(CountedNounText.phrase(0, "row"), "0 rows", "zero rows")
    expectEqual(CountedNounText.phrase(1, "row"), "1 row", "one row stays singular")
    expectEqual(CountedNounText.phrase(2, "row"), "2 rows", "two rows pluralise")
    expectEqual(CountedNounText.phrase(2500, "row"), "2,500 rows", "a grouped count still pluralises, with thousands separators")

    expectEqual(CountedNounText.phrase(1, "rule"), "1 rule", "one rule stays singular")
    expectEqual(CountedNounText.phrase(2, "rule"), "2 rules", "two rules pluralise")

    expectEqual(CountedNounText.phrase(1, "value"), "1 value", "one value stays singular")
    expectEqual(CountedNounText.phrase(2, "value"), "2 values", "two values pluralise")

    expectEqual(CountedNounText.phrase(1, "tag"), "1 tag", "one tag stays singular")
    expectEqual(CountedNounText.phrase(2, "tag"), "2 tags", "two tags pluralise")

    // The query plan header counts its nodes.
    expectEqual(CountedNounText.phrase(1, "node"), "1 node", "one node stays singular")
    expectEqual(CountedNounText.phrase(4, "node"), "4 nodes", "four nodes pluralise")

    expectEqual(CountedNounText.phrase(1, "invisible character"), "1 invisible character", "one invisible character stays singular")
    expectEqual(CountedNounText.phrase(2, "invisible character"), "2 invisible characters", "two invisible characters pluralise — the noun phrase's head word inflects")

    expectEqual(CountedNounText.phrase(1, "unusual space"), "1 unusual space", "one unusual space stays singular")
    expectEqual(CountedNounText.phrase(2, "unusual space"), "2 unusual spaces", "two unusual spaces pluralise")

    // MARK: "tuple" — the noun the automatic inflector does NOT know.
    //
    // Left to `^[...](inflect: true)` alone this comes back "2 tuple": the
    // engine's English dictionary does not carry the word, so it declines to
    // guess and leaves it singular. CountedNounText special-cases it — this
    // is the assertion that would fail if that override were ever removed.

    expectEqual(CountedNounText.phrase(1, "tuple"), "1 tuple", "one tuple stays singular")
    expectEqual(CountedNounText.phrase(2, "tuple"), "2 tuples", "two tuples pluralise via the override, not the inflector")
    expectEqual(CountedNounText.phrase(0, "tuple"), "0 tuples", "zero tuples pluralise via the override too")
    expectEqual(CountedNounText.phrase(2500, "tuple"), "2,500 tuples", "the override still groups thousands")

    print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) FAILED.")
    exit(failures == 0 ? 0 : 1)
}
