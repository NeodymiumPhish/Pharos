// Standalone test runner for RowFingerprint — the canonical compare string.
// Compiled with the implementation by scripts/test-row-fingerprint.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected))\n  actual:   \(String(describing: actual))")
    }
}

func runTests() {
    // A field is length-prefixed so no value can forge a separator.
    expectEqual(RowFingerprint.field("1"), "V1:1", "a one-byte value")
    expectEqual(RowFingerprint.field("a@b.co"), "V6:a@b.co", "a six-byte value")
    expectEqual(RowFingerprint.field(""), "V0:", "an empty string is a value, not a NULL")
    expectEqual(RowFingerprint.field(nil), "N", "a NULL is N")

    // The count is BYTES, not characters. A multi-byte value must not report its
    // character count, or two different rows could collide.
    expectEqual(RowFingerprint.field("é"), "V2:é", "a two-byte character counts as two")
    expectEqual(RowFingerprint.field("✓"), "V3:✓", "a three-byte character counts as three")

    expectEqual(RowFingerprint.column("id"), "K2:id", "a column name is length-prefixed too")

    // The separator problem this encoding exists to solve: a value holding the
    // text of another field must not produce the same string as two fields.
    let forged = RowFingerprint.encode(columns: ["a"], values: ["K1:b"])
    let honest = RowFingerprint.encode(columns: ["a", "b"], values: ["", ""])
    if forged != nil && forged == honest {
        failures += 1
        print("FAIL a value cannot forge a second field")
    } else {
        print("PASS a value cannot forge a second field")
    }

    // Columns sort by name, so the same row gives the same string whatever order
    // the result presented its columns in.
    expectEqual(
        RowFingerprint.encode(columns: ["name", "id"], values: ["Ada", "1"]),
        "K2:idV1:1K4:nameV3:Ada",
        "columns sort by name"
    )
    expectEqual(
        RowFingerprint.encode(columns: ["id", "name"], values: ["1", "Ada"]),
        "K2:idV1:1K4:nameV3:Ada",
        "the reverse column order gives the same string"
    )

    // A NULL inside a fingerprint is a value like any other. It does NOT make the
    // row identity-less: that sentinel belongs to the strong tiers only.
    expectEqual(
        RowFingerprint.encode(columns: ["id", "note"], values: ["1", nil]),
        "K2:idV1:1K4:noteN",
        "a NULL column encodes as N"
    )

    // A mismatched pair is a programming error, not a row without identity.
    expectEqual(RowFingerprint.encode(columns: ["id"], values: []), nil,
                "a column/value count mismatch gives nil")

    // A zero-column row has no identity worth comparing.
    expectEqual(RowFingerprint.encode(columns: [], values: []), nil,
                "a row with no columns gives nil")

    if failures == 0 {
        print("\nAll RowFingerprint tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
