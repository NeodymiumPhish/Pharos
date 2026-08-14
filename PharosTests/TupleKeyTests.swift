// Standalone runner for TupleKey. Foundation only.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let a = TagValueKey(family: "text", value: "abc")
    let b = TagValueKey(family: "address", value: "10.2.3.4")

    // 1. The grammar: K<byte count>:<family> then V<byte count>:<value>, and
    //    the pairs sort by family then value — so the order the analyst ticked
    //    the columns in cannot produce a second key for one finding.
    expectEqual(TupleKey.encode([a]), "K4:textV3:abc", "one pair encodes")
    expectEqual(TupleKey.encode([a, b]), TupleKey.encode([b, a]),
                "check order does not change the key")
    expectEqual(TupleKey.encode([b, a]), "K7:addressV8:10.2.3.4K4:textV3:abc",
                "pairs sort by family first")

    // 2. Length prefixes are BYTES, so a value cannot forge a field boundary.
    let forger = TagValueKey(family: "text", value: "K4:textV3:abc")
    expectEqual(TupleKey.encode([forger]), "K4:textV13:K4:textV3:abc",
                "a value that looks like the grammar is still one field")
    expectEqual(TupleKey.encode([TagValueKey(family: "text", value: "é")]), "K4:textV2:é",
                "the count is UTF-8 bytes, not characters")

    // 3. A repeated pair contributes once: presence is the test, not
    //    multiplicity, so two identical values are one fact.
    expectEqual(TupleKey.encode([a, a]), "K4:textV3:abc", "a repeated pair collapses")

    // 4. Nothing to encode is nil, not an empty string — an empty key would be
    //    shared by every empty tuple and the unique index would fuse them.
    expectEqual(TupleKey.encode([]), nil, "an empty tuple has no key")

    // 5. Two different findings never share a key.
    expectEqual(TupleKey.encode([a]) == TupleKey.encode([b]), false, "different values differ")
    expectEqual(TupleKey.encode([TagValueKey(family: "text", value: "10.2.3.4")])
                == TupleKey.encode([b]), false, "same text in another family differs")

    // 6. The byte-order rule, pinned. These two values sort one way by UTF-8 bytes
    //    and the other way by `String.<`, so this is the only assertion here that
    //    can tell the two comparators apart — and the rule matters because a key
    //    is STORED and re-derived on a later query, where a collation-sensitive
    //    order could silently stop a tuple matching itself.
    let combining = TagValueKey(family: "text", value: "a\u{0301}") // "a" + combining acute accent
    let plain = TagValueKey(family: "text", value: "b")
    expectEqual(TupleKey.encode([plain, combining]), "K4:textV3:áK4:textV1:b",
                "byte order, not String.<, decides value order")

    print(failures == 0 ? "\nAll TupleKey checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
