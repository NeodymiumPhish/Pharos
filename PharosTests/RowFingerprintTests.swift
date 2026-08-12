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
    expectEqual(RowFingerprint.column("é"), "K2:é", "a column name counts bytes too")

    // Without the length prefixes these two rows are the same text. With them they differ.
    expectEqual(RowFingerprint.encode(columns: ["a"], values: ["xK1:bV1:y"]),
                "K1:aV9:xK1:bV1:y", "a value cannot forge a second field")
    expectEqual(RowFingerprint.encode(columns: ["a", "b"], values: ["x", "y"]),
                "K1:aV1:xK1:bV1:y", "the honest two-field row")

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

    // PostgreSQL freely returns two columns with the same name (an unaliased
    // join on `id`, for example). The comparator must still be total: the pair
    // keeps a stable, deterministic order (by original position).
    expectEqual(
        RowFingerprint.encode(columns: ["id", "id"], values: ["1", "2"]),
        "K2:idV1:1K2:idV1:2",
        "two same-named columns keep result order"
    )
    // and swapping only the VALUES (not the tie-break) must give a different string —
    // proof the comparator is not secretly keying off the value to break the tie.
    expectEqual(
        RowFingerprint.encode(columns: ["id", "id"], values: ["2", "1"]),
        "K2:idV1:2K2:idV1:1",
        "swapping only the values of same-named columns changes the string"
    )

    // The empty string is the "no identity" sentinel for the strong tiers. Any
    // non-empty column list yields at least "K0:", so `encode` must never
    // collapse into that sentinel by accident.
    expectEqual(RowFingerprint.encode(columns: ["a"], values: [""]), "K1:aV0:",
                "an empty value still yields a non-empty string, never the sentinel")

    if failures == 0 {
        print("\nAll RowFingerprint tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
