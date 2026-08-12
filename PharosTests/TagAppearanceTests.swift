// Standalone test runner for TagLabelPalette. Pure AppKit + Foundation, no FFI.
// Compiled with the implementation by scripts/test-tag-appearance.sh.
import AppKit

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectNil<T>(_ actual: T?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: nil\n  actual:   \(String(describing: actual))")
    }
}

func expectNotNil<T>(_ actual: T?, _ name: String) {
    if actual != nil { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected non-nil") }
}

/// Minimal RowTag fixture. Only `labelId` and `primaryKind` vary per test —
/// everything else is filler that `appearance` never reads.
func makeTag(labelId: String = "label-1", primaryKind: String = "pk") -> RowTag {
    RowTag(
        id: "tag-1",
        connectionId: "conn-1",
        labelId: labelId,
        note: nil,
        primaryKind: primaryKind,
        tableKey: "oid:1",
        tableDisplay: "public.t",
        identityColumns: ["id"],
        identityValues: ["1"],
        keys: [RowTagKey(identityKind: primaryKind, identityValue: "1")],
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z"
    )
}

func runTests() {

    // MARK: - 1. color(at:) returns the right palette entry

    expectEqual(TagLabelPalette.color(at: 0), TagLabelPalette.colors[0], "color(at: 0) is the first palette entry")
    let lastIndex = TagLabelPalette.colors.count - 1
    expectEqual(TagLabelPalette.color(at: lastIndex), TagLabelPalette.colors[lastIndex],
                "color(at: last) is the last palette entry")

    // MARK: - 2. Out-of-range indices wrap rather than trapping

    expectEqual(TagLabelPalette.color(at: TagLabelPalette.colors.count),
                TagLabelPalette.colors[0],
                "an index one past the end wraps to the first entry")
    expectEqual(TagLabelPalette.color(at: TagLabelPalette.colors.count * 3 + 2),
                TagLabelPalette.colors[2],
                "a large out-of-range index wraps via modulo")
    expectEqual(TagLabelPalette.color(at: -1),
                TagLabelPalette.colors[TagLabelPalette.colors.count - 1],
                "a negative index wraps to the last entry, not a trap")
    expectEqual(TagLabelPalette.color(at: -TagLabelPalette.colors.count - 1),
                TagLabelPalette.colors[TagLabelPalette.colors.count - 1],
                "a large negative index still wraps correctly")

    // MARK: - 3. appearance maps through displayRows, not raw row index

    do {
        let displayRows = [5, 2, 9]
        let tag = makeTag(labelId: "label-1")
        let tagsByRow: [Int: RowTag] = [2: tag] // tag is on DATA row 2
        let labelColors: [String: NSColor] = ["label-1": .systemRed]

        let hit = TagLabelPalette.appearance(row: 1, displayRows: displayRows,
                                              tagsByRow: tagsByRow, labelColors: labelColors)
        expectNotNil(hit, "row 1 (display row 2, the tagged data row) hits")
        if let hit { expectEqual(hit.color, NSColor.systemRed, "the hit reports the tag's colour") }

        let miss = TagLabelPalette.appearance(row: 0, displayRows: displayRows,
                                               tagsByRow: tagsByRow, labelColors: labelColors)
        // `tagsByRow[0]` is also absent, so a version indexing by `row` directly
        // would miss here too — this assertion alone does not distinguish the two
        // implementations. It exists to pin the "row 0 has no tag" case on its own
        // terms; row 1 above and row 2 below are what actually discriminate.
        expectNil(miss, "row 0 (display row 5, untagged) misses")

        // The wrong-hit direction. `displayRows[2]` is 9 and untagged, but `tagsByRow[2]`
        // holds the tag — so a version indexing by `row` instead of by `displayRows[row]`
        // returns a tag here. Row 1's hit alone cannot catch that: this is the assertion
        // that actually proves the mapping goes through `displayRows`, not just that it
        // is consistent with doing so.
        let wrongHit = TagLabelPalette.appearance(row: 2, displayRows: displayRows,
                                                   tagsByRow: tagsByRow, labelColors: labelColors)
        expectNil(wrongHit, "row 2 (display row 9, untagged) misses even though tagsByRow[2] holds a tag")
    }

    // MARK: - 4. appearance returns nil for an out-of-bounds row index

    do {
        let displayRows = [0, 1, 2]
        let tag = makeTag()
        let tagsByRow: [Int: RowTag] = [0: tag, 1: tag, 2: tag]
        let labelColors: [String: NSColor] = ["label-1": .systemBlue]

        expectNil(TagLabelPalette.appearance(row: -1, displayRows: displayRows,
                                              tagsByRow: tagsByRow, labelColors: labelColors),
                  "a negative row index returns nil")
        expectNil(TagLabelPalette.appearance(row: displayRows.count, displayRows: displayRows,
                                              tagsByRow: tagsByRow, labelColors: labelColors),
                  "a row index at displayRows.count (one past the end) returns nil")
        expectNil(TagLabelPalette.appearance(row: displayRows.count + 5, displayRows: displayRows,
                                              tagsByRow: tagsByRow, labelColors: labelColors),
                  "a row index well past the end returns nil")
    }

    // MARK: - 5. appearance returns nil when the label has no colour

    do {
        let displayRows = [0]
        let tag = makeTag(labelId: "label-unknown")
        let tagsByRow: [Int: RowTag] = [0: tag]
        let labelColors: [String: NSColor] = ["label-1": .systemGreen] // does not contain "label-unknown"

        expectNil(TagLabelPalette.appearance(row: 0, displayRows: displayRows,
                                              tagsByRow: tagsByRow, labelColors: labelColors),
                  "a tag whose labelId has no entry in labelColors misses")
    }

    // MARK: - 6. isWeak is true only for primaryKind == "fingerprint"

    do {
        let displayRows = [0]
        let labelColors: [String: NSColor] = ["label-1": .systemPurple]

        for kind in ["pk", "unique"] {
            let tagsByRow: [Int: RowTag] = [0: makeTag(primaryKind: kind)]
            let result = TagLabelPalette.appearance(row: 0, displayRows: displayRows,
                                                     tagsByRow: tagsByRow, labelColors: labelColors)
            expectNotNil(result, "a \"\(kind)\" tag still produces an appearance")
            if let result { expectTrue(!result.isWeak, "primaryKind \"\(kind)\" is NOT weak") }
        }

        let fingerprintTagsByRow: [Int: RowTag] = [0: makeTag(primaryKind: "fingerprint")]
        let fingerprintResult = TagLabelPalette.appearance(row: 0, displayRows: displayRows,
                                                            tagsByRow: fingerprintTagsByRow, labelColors: labelColors)
        expectNotNil(fingerprintResult, "a \"fingerprint\" tag produces an appearance")
        if let fingerprintResult { expectTrue(fingerprintResult.isWeak, "primaryKind \"fingerprint\" IS weak") }

        // Rust stores primaryKind verbatim and never validates it — record what
        // an unexpected value actually does: it falls through to the non-weak
        // (strong) styling, since the check is a positive match on
        // "fingerprint" rather than a negative match on the known strong kinds.
        let unexpectedTagsByRow: [Int: RowTag] = [0: makeTag(primaryKind: "fp")]
        let unexpectedResult = TagLabelPalette.appearance(row: 0, displayRows: displayRows,
                                                           tagsByRow: unexpectedTagsByRow, labelColors: labelColors)
        expectNotNil(unexpectedResult, "an unexpected primaryKind still produces an appearance")
        if let unexpectedResult {
            expectTrue(!unexpectedResult.isWeak,
                       "an unrecognised primaryKind (\"fp\") is treated as strong (not weak), since only an exact " +
                       "\"fingerprint\" match sets isWeak")
        }
    }

    if failures == 0 {
        print("\nAll TagAppearance tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
