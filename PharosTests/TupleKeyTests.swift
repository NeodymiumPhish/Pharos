// Standalone runner for RuleKey. Foundation only.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // Every condition below is `.exact`, because every key already in a user's
    // SQLite was written when exact was the only kind. The literals in this
    // file are therefore the ground truth for those stored keys: if one of them
    // has to change, re-tagging a row stops being a no-op.
    func exactKey(_ family: String, _ value: String) -> RuleConditionKey {
        RuleConditionKey(kind: .exact, family: family, value: value, operand2: nil)
    }

    let a = exactKey("text", "abc")
    let b = exactKey("address", "10.2.3.4")

    // 1. The grammar: K<byte count>:<family> then V<byte count>:<value>, and
    //    the pairs sort by family then value — so the order the analyst ticked
    //    the columns in cannot produce a second key for one finding.
    expectEqual(RuleKey.encode([a]), "K4:textV3:abc", "one pair encodes")
    expectEqual(RuleKey.encode([a, b]), RuleKey.encode([b, a]),
                "check order does not change the key")
    expectEqual(RuleKey.encode([b, a]), "K7:addressV8:10.2.3.4K4:textV3:abc",
                "pairs sort by family first")

    // 2. Length prefixes are BYTES, so a value cannot forge a field boundary.
    let forger = exactKey("text", "K4:textV3:abc")
    expectEqual(RuleKey.encode([forger]), "K4:textV13:K4:textV3:abc",
                "a value that looks like the grammar is still one field")
    expectEqual(RuleKey.encode([exactKey("text", "é")]), "K4:textV2:é",
                "the count is UTF-8 bytes, not characters")

    // 3. A repeated pair contributes once: presence is the test, not
    //    multiplicity, so two identical values are one fact.
    expectEqual(RuleKey.encode([a, a]), "K4:textV3:abc", "a repeated pair collapses")

    // 4. Nothing to encode is nil, not an empty string — an empty key would be
    //    shared by every empty tuple and the unique index would fuse them.
    expectEqual(RuleKey.encode([]), nil, "an empty tuple has no key")

    // 5. Two different findings never share a key.
    expectEqual(RuleKey.encode([a]) == RuleKey.encode([b]), false, "different values differ")
    expectEqual(RuleKey.encode([exactKey("text", "10.2.3.4")])
                == RuleKey.encode([b]), false, "same text in another family differs")

    // 6. The byte-order rule, pinned. These two values sort one way by UTF-8 bytes
    //    and the other way by `String.<`, so this is the only assertion here that
    //    can tell the two comparators apart — and the rule matters because a key
    //    is STORED and re-derived on a later query, where a collation-sensitive
    //    order could silently stop a tuple matching itself.
    let combining = exactKey("text", "a\u{0301}") // "a" + combining acute accent
    let plain = exactKey("text", "b")
    expectEqual(RuleKey.encode([plain, combining]), "K4:textV3:áK4:textV1:b",
                "byte order, not String.<, decides value order")

    // MARK: kinds in the grammar

    // A non-exact condition adds a P field. Every OLD key begins with "K", so a
    // P-prefixed key can never collide with one already stored.
    expectEqual(RuleKey.encode([RuleConditionKey(kind: .glob, family: "text",
                                                 value: "*.sh", operand2: nil)]),
                "P4:globK4:textV4:*.sh", "a glob condition carries its kind")

    expectEqual(RuleKey.encode([RuleConditionKey(kind: .between, family: "numeric",
                                                 value: "1000", operand2: "2000")]),
                "P7:betweenK7:numericV4:1000W4:2000",
                "between carries its second operand")

    expectEqual(RuleKey.encode([RuleConditionKey(kind: .cidr, family: "address",
                                                 value: "10.0.0.0/8", operand2: nil)]),
                "P4:cidrK7:addressV10:10.0.0.0/8", "a cidr condition carries its kind")

    // An unsupported kind encodes under its own raw name, so a rule written by
    // a newer build keeps its identity through this one.
    expectEqual(RuleKey.encode([RuleConditionKey(kind: .unsupported("startsWith"),
                                                 family: "text", value: "a", operand2: nil)]),
                "P10:startsWithK4:textV1:a", "an unknown kind encodes under its raw name")

    // THE dedupe fix. Left alone, Set would collapse these into one, because the
    // old identity was (family, value) only — silently narrowing the rule.
    let exactStar = exactKey("text", "*.sh")
    let globStar = RuleConditionKey(kind: .glob, family: "text", value: "*.sh", operand2: nil)
    expectEqual(RuleKey.encode([exactStar, globStar]) == RuleKey.encode([exactStar]), false,
                "an exact and a glob on the same text do NOT collapse")
    expectEqual(RuleKey.encode([exactStar, globStar]) == RuleKey.encode([globStar]), false,
                "and the glob alone is not the same key either")

    // operand2 is part of the identity too.
    let between1 = RuleConditionKey(kind: .between, family: "numeric", value: "1", operand2: "2")
    let between2 = RuleConditionKey(kind: .between, family: "numeric", value: "1", operand2: "3")
    expectEqual(RuleKey.encode([between1]) == RuleKey.encode([between2]), false,
                "two betweens differing only in their upper bound differ")

    // A genuine repeat still collapses: presence is the test, not multiplicity.
    expectEqual(RuleKey.encode([globStar, globStar]), RuleKey.encode([globStar]),
                "an identical condition twice still collapses")

    // Order of the conditions cannot produce a second key for one rule.
    expectEqual(RuleKey.encode([globStar, exactStar]), RuleKey.encode([exactStar, globStar]),
                "condition order does not change the key")

    print(failures == 0 ? "\nAll RuleKey checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
