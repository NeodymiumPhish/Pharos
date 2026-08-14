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

/// Minimal match fixture. `matchedColumns` matters to the tint-map tests; the
/// tuple ids are filler the palette never reads.
private func match(_ tagId: String, _ state: TagMatchState,
                   columns: [Int] = [0]) -> TagRowMatch {
    TagRowMatch(tagId: tagId, state: state, matchedColumns: columns,
                matchedTupleIds: ["u1"], solidTupleIds: state == .solid ? ["u1"] : [])
}

private let colors = ["red-tag": NSColor.systemRed, "blue-tag": NSColor.systemBlue,
                      "green-tag": NSColor.systemGreen, "purple-tag": NSColor.systemPurple]
private let names = ["red-tag": "Reds", "blue-tag": "Blues", "green-tag": "Greens",
                     "purple-tag": "Purples"]

func runTests() {

    // MARK: - 1. color(at:) returns the right palette entry, wrapping out of range

    expectEqual(TagPalette.color(at: 0), TagPalette.colors[0], "color(at: 0) is the first palette entry")
    let lastIndex = TagPalette.colors.count - 1
    expectEqual(TagPalette.color(at: lastIndex), TagPalette.colors[lastIndex],
                "color(at: last) is the last palette entry")
    expectEqual(TagPalette.color(at: TagPalette.colors.count),
                TagPalette.colors[0],
                "an index one past the end wraps to the first entry")
    expectEqual(TagPalette.color(at: TagPalette.colors.count * 3 + 2),
                TagPalette.colors[2],
                "a large out-of-range index wraps via modulo")
    expectEqual(TagPalette.color(at: -1),
                TagPalette.colors[TagPalette.colors.count - 1],
                "a negative index wraps to the last entry, not a trap")

    // MARK: - 2. segments map through displayRows, not the raw row index

    do {
        let displayRows = [5, 2, 9]
        let matchesByRow: [Int: [TagRowMatch]] = [2: [match("red-tag", .solid)]] // DATA row 2

        let hit = TagPalette.segments(row: 1, displayRows: displayRows,
                                      matchesByRow: matchesByRow, tagColors: colors)
        expectEqual(hit.count, 1, "row 1 (display row 2, the matched data row) hits")
        expectEqual(hit.first?.color, NSColor.systemRed, "the hit carries the tag's colour")
        expectEqual(hit.first?.isPartial, false, "a solid match is not partial")

        // `matchesByRow[0]` is also absent, so a version indexing by `row`
        // directly would miss here too — this assertion alone does not
        // distinguish the two implementations. It exists to pin the "row 0
        // has no tag" case on its own terms; the hit above and the
        // wrong-hit-direction check below are what actually discriminate.
        expectTrue(TagPalette.segments(row: 0, displayRows: displayRows,
                                       matchesByRow: matchesByRow, tagColors: colors).isEmpty,
                   "row 0 (display row 5, untagged) misses")

        // The wrong-hit direction: matchesByRow[2] holds a match, but display
        // row 2 shows DATA row 9, which is untagged. A version indexing by
        // `row` instead of `displayRows[row]` returns a segment here.
        expectTrue(TagPalette.segments(row: 2, displayRows: displayRows,
                                       matchesByRow: matchesByRow, tagColors: colors).isEmpty,
                   "row 2 (display row 9, untagged) misses even though matchesByRow[2] holds a match")
    }

    // MARK: - 3. tooltip maps through displayRows too, and never traps on an out-of-range row

    do {
        // Reuses section 2's fixture: DATA row 2 (display row 1) is the only
        // tagged row; DATA row 9 (display row 2) is untagged despite
        // `matchesByRow[2]` holding a match for a DIFFERENT data row.
        let displayRows = [5, 2, 9]
        let matchesByRow: [Int: [TagRowMatch]] = [2: [match("red-tag", .solid)]]

        expectEqual(TagPalette.tooltip(row: 1, displayRows: displayRows,
                                       matchesByRow: matchesByRow, tagNames: names),
                    "Reds — solid",
                    "row 1 (display row 2, the matched data row) gets the red line")
        expectNil(TagPalette.tooltip(row: 2, displayRows: displayRows,
                                     matchesByRow: matchesByRow, tagNames: names),
                  "row 2 (display row 9, untagged) has no tooltip even though matchesByRow[2] holds a match")

        // `displayRows` can be momentarily stale against the table during a
        // reload — an unguarded subscript here would trap, not just miss.
        expectNil(TagPalette.tooltip(row: -1, displayRows: displayRows,
                                     matchesByRow: matchesByRow, tagNames: names),
                  "a negative row index returns nil rather than trapping")
        expectNil(TagPalette.tooltip(row: displayRows.count, displayRows: displayRows,
                                     matchesByRow: matchesByRow, tagNames: names),
                  "a row index at displayRows.count (one past the end) returns nil rather than trapping")
    }

    // MARK: - 4. Segment order and states follow the matcher's order, never re-sorted

    do {
        let segs = TagPalette.segments(
            row: 0, displayRows: [7],
            matchesByRow: [7: [match("blue-tag", .solid), match("red-tag", .dashed)]],
            tagColors: colors)
        expectEqual(segs, [TagPalette.Segment(color: .systemBlue, isPartial: false),
                           TagPalette.Segment(color: .systemRed, isPartial: true)],
                   "solid-then-dashed in the matcher becomes solid-then-dashed in the segments")
    }

    do {
        // The matcher put the DASHED match first here. A stable "solid
        // first" sort inside `segments` would silently reorder this and
        // still pass the solid-then-dashed fixture above.
        let segs = TagPalette.segments(
            row: 0, displayRows: [7],
            matchesByRow: [7: [match("red-tag", .dashed), match("blue-tag", .solid)]],
            tagColors: colors)
        expectEqual(segs, [TagPalette.Segment(color: .systemRed, isPartial: true),
                           TagPalette.Segment(color: .systemBlue, isPartial: false)],
                   "the palette must not re-sort: dashed-first-in-the-matcher stays first")
    }

    // MARK: - 5. Segments cap at three, filtering before capping; the tooltip carries the full list

    do {
        let four = [match("blue-tag", .solid), match("green-tag", .solid),
                    match("purple-tag", .dashed), match("red-tag", .dashed)]
        let segs = TagPalette.segments(row: 0, displayRows: [0],
                                       matchesByRow: [0: four], tagColors: colors)
        expectEqual(segs.count, TagPalette.maxSegments, "four matches draw maxSegments segments")
        expectEqual(segs.map(\.color), [NSColor.systemBlue, .systemGreen, .systemPurple],
                    "the cap keeps the FIRST three, in order")

        let tip = TagPalette.tooltip(row: 0, displayRows: [0],
                                     matchesByRow: [0: four], tagNames: names)
        expectEqual(tip, "Blues — solid\nGreens — solid\nPurples — dashed\nReds — dashed",
                    "the tooltip lists all four with their states")
    }

    do {
        // A colourless tag sits among the first three. Capping BEFORE
        // filtering would keep only the two coloured survivors of that
        // first three (ghost, blue, green -> blue, green); filtering first
        // drops the colourless one and lets the fourth coloured tag fill
        // the third band.
        let matches: [TagRowMatch] = [match("ghost-tag", .solid), match("blue-tag", .solid),
                                      match("green-tag", .dashed), match("purple-tag", .dashed),
                                      match("red-tag", .dashed)]
        let segs = TagPalette.segments(row: 0, displayRows: [0],
                                       matchesByRow: [0: matches], tagColors: colors)
        expectEqual(segs.count, TagPalette.maxSegments,
                    "the colourless tag is filtered out before the cap, so three coloured bands survive")
    }

    // MARK: - 6. A tag with no colour entry is skipped, not fatal to the row

    do {
        let segs = TagPalette.segments(
            row: 0, displayRows: [0],
            matchesByRow: [0: [match("ghost-tag", .solid), match("red-tag", .dashed)]],
            tagColors: colors)
        expectEqual(segs.count, 1, "the colourless tag is skipped; the coloured one survives")
        expectEqual(segs.first?.color, NSColor.systemRed, "the surviving segment is the coloured tag's")
    }

    // MARK: - 7. Edge rows and empty inputs

    do {
        let matchesByRow: [Int: [TagRowMatch]] = [0: [match("blue-tag", .solid)]]
        expectTrue(TagPalette.segments(row: -1, displayRows: [0],
                                       matchesByRow: matchesByRow, tagColors: colors).isEmpty,
                   "a negative row index returns no segments")
        expectTrue(TagPalette.segments(row: 1, displayRows: [0],
                                       matchesByRow: matchesByRow, tagColors: colors).isEmpty,
                   "a row index past displayRows returns no segments")
        expectTrue(TagPalette.segments(row: 0, displayRows: [7],
                                       matchesByRow: [7: []], tagColors: colors).isEmpty,
                   "an empty match list draws nothing")
        expectNil(TagPalette.tooltip(row: 0, displayRows: [7],
                                     matchesByRow: [7: []], tagNames: names),
                  "an empty match list has no tooltip")
        expectNil(TagPalette.tooltip(row: 0, displayRows: [7],
                                     matchesByRow: [:], tagNames: names),
                  "an unmatched row has no tooltip")
    }

    // MARK: - 8. tooltip skips a tag that is no longer in the store

    do {
        // `tagNames` and `tagColors` are built together from the same
        // `TagStore.shared.tags` in one `applyTagMap`, so a name missing here
        // is the same condition `segments` already treats as "this tag is
        // gone" — the tooltip must agree, not fall back to a placeholder name.
        expectNil(TagPalette.tooltip(row: 0, displayRows: [0],
                                     matchesByRow: [0: [match("ghost-tag", .dashed)]],
                                     tagNames: names),
                  "a match whose tag has no name is dropped, and dropping the only match leaves no tooltip")

        expectEqual(TagPalette.tooltip(row: 0, displayRows: [0],
                                       matchesByRow: [0: [match("ghost-tag", .dashed),
                                                          match("red-tag", .solid)]],
                                       tagNames: names),
                    "Reds — solid",
                    "a nameless tag's line is dropped; a real tag beside it still gets its line")
    }

    // MARK: - 9. The cell-tint map: the strongest match claims a contested column

    do {
        let tints = TagPalette.tintTagByColumn(matches: [
            match("blue-tag", .solid, columns: [1, 3]),
            match("red-tag", .dashed, columns: [3, 4]),
        ])
        expectEqual(tints[1], "blue-tag", "column 1 tints in the only matching tag")
        expectEqual(tints[3], "blue-tag", "the CONTESTED column tints in the strongest tag")
        expectEqual(tints[4], "red-tag", "the weaker tag keeps its uncontested column")
        expectNil(tints[0], "an unmatched column has no tint")
    }

    expectTrue(TagPalette.tintTagByColumn(matches: []).isEmpty,
               "no matches, no tints")

    // MARK: - 10. The tint alpha sits between the wash and the find highlight

    expectTrue(TagPalette.cellTintAlpha > 0.15 && TagPalette.cellTintAlpha < 0.4,
               "cellTintAlpha is above the 0.15 wash and below the 0.4 find highlight")

    if failures == 0 {
        print("\nAll TagAppearance tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
