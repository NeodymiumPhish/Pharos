// Standalone test runner for TagPalette. Pure AppKit + Foundation, no FFI.
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

/// Minimal match fixture. Only the tag id and the state vary per test —
/// everything else is filler that `appearance` never reads.
private func match(_ tagId: String, _ state: TagMatchState) -> TagRowMatch {
    TagRowMatch(tagId: tagId, state: state, matchedColumns: [0],
                matchedTupleIds: ["u1"], solidTupleIds: state == .solid ? ["u1"] : [])
}

private let colors = ["red-tag": NSColor.systemRed, "blue-tag": NSColor.systemBlue]

func runTests() {

    // MARK: - 1. color(at:) returns the right palette entry

    expectEqual(TagPalette.color(at: 0), TagPalette.colors[0], "color(at: 0) is the first palette entry")
    let lastIndex = TagPalette.colors.count - 1
    expectEqual(TagPalette.color(at: lastIndex), TagPalette.colors[lastIndex],
                "color(at: last) is the last palette entry")

    // MARK: - 2. Out-of-range indices wrap rather than trapping

    expectEqual(TagPalette.color(at: TagPalette.colors.count),
                TagPalette.colors[0],
                "an index one past the end wraps to the first entry")
    expectEqual(TagPalette.color(at: TagPalette.colors.count * 3 + 2),
                TagPalette.colors[2],
                "a large out-of-range index wraps via modulo")
    expectEqual(TagPalette.color(at: -1),
                TagPalette.colors[TagPalette.colors.count - 1],
                "a negative index wraps to the last entry, not a trap")
    expectEqual(TagPalette.color(at: -TagPalette.colors.count - 1),
                TagPalette.colors[TagPalette.colors.count - 1],
                "a large negative index still wraps correctly")

    // MARK: - 3. appearance maps through displayRows, not raw row index

    do {
        let displayRows = [5, 2, 9]
        let matchesByRow: [Int: [TagRowMatch]] = [2: [match("red-tag", .solid)]] // DATA row 2

        let hit = TagPalette.appearance(row: 1, displayRows: displayRows,
                                        matchesByRow: matchesByRow, tagColors: colors)
        expectNotNil(hit, "row 1 (display row 2, the matched data row) hits")
        if let hit { expectEqual(hit.color, NSColor.systemRed, "the hit reports the tag's colour") }

        let miss = TagPalette.appearance(row: 0, displayRows: displayRows,
                                         matchesByRow: matchesByRow, tagColors: colors)
        // `matchesByRow[0]` is also absent, so a version indexing by `row` directly
        // would miss here too — this assertion alone does not distinguish the two
        // implementations. It exists to pin the "row 0 has no tag" case on its own
        // terms; row 1 above and row 2 below are what actually discriminate.
        expectNil(miss, "row 0 (display row 5, untagged) misses")

        // The wrong-hit direction. `displayRows[2]` is 9 and untagged, but
        // `matchesByRow[2]` holds a match — so a version indexing by `row` instead
        // of by `displayRows[row]` returns a tag here. Row 1's hit alone cannot
        // catch that: this is the assertion that actually proves the mapping goes
        // through `displayRows`, not just that it is consistent with doing so.
        let wrongHit = TagPalette.appearance(row: 2, displayRows: displayRows,
                                             matchesByRow: matchesByRow, tagColors: colors)
        expectNil(wrongHit, "row 2 (display row 9, untagged) misses even though matchesByRow[2] holds a match")
    }

    // MARK: - 4. appearance returns nil for an out-of-bounds row index

    do {
        let displayRows = [0, 1, 2]
        let matchesByRow: [Int: [TagRowMatch]] = [
            0: [match("blue-tag", .solid)],
            1: [match("blue-tag", .solid)],
            2: [match("blue-tag", .solid)],
        ]

        expectNil(TagPalette.appearance(row: -1, displayRows: displayRows,
                                        matchesByRow: matchesByRow, tagColors: colors),
                  "a negative row index returns nil")
        expectNil(TagPalette.appearance(row: displayRows.count, displayRows: displayRows,
                                        matchesByRow: matchesByRow, tagColors: colors),
                  "a row index at displayRows.count (one past the end) returns nil")
        expectNil(TagPalette.appearance(row: displayRows.count + 5, displayRows: displayRows,
                                        matchesByRow: matchesByRow, tagColors: colors),
                  "a row index well past the end returns nil")
    }

    // MARK: - 5. appearance returns nil when the tag has no colour

    do {
        let displayRows = [0]
        let matchesByRow: [Int: [TagRowMatch]] = [0: [match("green-tag", .solid)]]

        expectNil(TagPalette.appearance(row: 0, displayRows: displayRows,
                                        matchesByRow: matchesByRow, tagColors: colors),
                  "a match whose tagId has no entry in tagColors misses")
    }

    // MARK: - 6. solid paints an unbroken bar; dashed paints a partial one

    // A solid match paints an unbroken bar; a partial one dashes.
    expectEqual(TagPalette.appearance(row: 0, displayRows: [7],
                                      matchesByRow: [7: [match("red-tag", .solid)]],
                                      tagColors: colors)?.isPartial,
                false, "a solid match is not partial")
    expectEqual(TagPalette.appearance(row: 0, displayRows: [7],
                                      matchesByRow: [7: [match("red-tag", .dashed)]],
                                      tagColors: colors)?.isPartial,
                true, "a dashed match is partial")

    // Phase 4 paints the STRONGEST match only, and the matcher has already put it
    // first — the appearance rule must not re-sort or pick by dictionary order.
    expectEqual(TagPalette.appearance(row: 0, displayRows: [7],
                                      matchesByRow: [7: [match("blue-tag", .solid),
                                                         match("red-tag", .dashed)]],
                                      tagColors: colors)?.color,
                NSColor.systemBlue, "the first match owns the bar")

    // MARK: - 7. An empty match list is not a match

    expectNil(TagPalette.appearance(row: 0, displayRows: [7],
                                    matchesByRow: [7: []], tagColors: colors),
              "a row with an empty match list paints nothing")

    if failures == 0 {
        print("\nAll TagAppearance tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
