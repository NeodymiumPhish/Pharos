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
                matchedRuleIds: ["u1"], solidRuleIds: state == .solid ? ["u1"] : [])
}

/// Minimal tag fixture. The colour index picks a palette entry the assertions
/// can name; timestamps and tuples are filler the palette never reads.
private func tag(_ id: String, _ name: String, colorIndex: Int) -> Tag {
    Tag(id: id, name: name, colorIndex: colorIndex, note: nil,
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
        rules: [])
}

// Palette indices: 0 red, 1 orange, 2 yellow, 3 green, 4 blue, 5 purple.
private let redTag = tag("red-tag", "Reds", colorIndex: 0)
private let greenTag = tag("green-tag", "Greens", colorIndex: 3)
private let blueTag = tag("blue-tag", "Blues", colorIndex: 4)
private let purpleTag = tag("purple-tag", "Purples", colorIndex: 5)
private let allTags = [redTag, greenTag, blueTag, purpleTag]

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

    // MARK: - 2. The display → data crossing: dataRow and tintTag
    //
    // Everything `bake` returns is keyed by DATA row; every grid caller holds
    // a DISPLAY row. Reversed, the grid paints the right colour on the wrong
    // row as soon as a filter or a sort is active, and nothing crashes. These
    // are the assertions that discriminate the two directions.

    do {
        let displayRows = [5, 2, 9]

        expectEqual(TagPalette.dataRow(displayRow: 1, displayRows: displayRows), 2,
                    "display row 1 maps to DATA row 2")
        expectEqual(TagPalette.dataRow(displayRow: 0, displayRows: displayRows), 5,
                    "display row 0 maps to DATA row 5")
        expectNil(TagPalette.dataRow(displayRow: -1, displayRows: displayRows),
                  "a negative display row maps to nil rather than trapping")
        expectNil(TagPalette.dataRow(displayRow: displayRows.count, displayRows: displayRows),
                  "a display row one past the end maps to nil rather than trapping")
        expectNil(TagPalette.dataRow(displayRow: 0, displayRows: []),
                  "no display rows at all, no data row")

        // DATA row 2 is tinted; it is shown at DISPLAY row 1.
        let tintByRow: [Int: [Int: String]] = [2: [1: "red-tag", 3: "blue-tag"]]

        expectEqual(TagPalette.tintTag(row: 1, displayRows: displayRows,
                                       tintByRow: tintByRow, column: 1),
                    "red-tag",
                    "display row 1 (DATA row 2) finds its tint")
        expectEqual(TagPalette.tintTag(row: 1, displayRows: displayRows,
                                       tintByRow: tintByRow, column: 3),
                    "blue-tag",
                    "a second tinted column on the same row keeps its own tag")

        // The wrong-hit direction: `tintByRow[2]` holds tints, but DISPLAY row
        // 2 shows DATA row 9, which matched nothing. A version indexing by
        // `row` instead of `displayRows[row]` tints this cell.
        expectNil(TagPalette.tintTag(row: 2, displayRows: displayRows,
                                     tintByRow: tintByRow, column: 1),
                  "display row 2 (DATA row 9, untagged) gets no tint even though tintByRow[2] is populated")
        expectNil(TagPalette.tintTag(row: 0, displayRows: displayRows,
                                     tintByRow: tintByRow, column: 1),
                  "display row 0 (DATA row 5) has no entry at all")
        expectNil(TagPalette.tintTag(row: 1, displayRows: displayRows,
                                     tintByRow: tintByRow, column: 0),
                  "an unmatched column on a tinted row has no tint")
        expectNil(TagPalette.tintTag(row: -1, displayRows: displayRows,
                                     tintByRow: tintByRow, column: 1),
                  "a negative row returns nil rather than trapping")
        expectNil(TagPalette.tintTag(row: displayRows.count, displayRows: displayRows,
                                     tintByRow: tintByRow, column: 1),
                  "a row past the end returns nil rather than trapping")
    }

    // MARK: - 3. Segment order and states follow the matcher's order, never re-sorted

    do {
        let segs = TagPalette.segments(
            matches: [match("blue-tag", .solid), match("red-tag", .dashed)],
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
            matches: [match("red-tag", .dashed), match("blue-tag", .solid)],
            tagColors: colors)
        expectEqual(segs, [TagPalette.Segment(color: .systemRed, isPartial: true),
                           TagPalette.Segment(color: .systemBlue, isPartial: false)],
                   "the palette must not re-sort: dashed-first-in-the-matcher stays first")
    }

    // MARK: - 4. Segments cap at three, filtering before capping; the tooltip carries the full list

    do {
        let four = [match("blue-tag", .solid), match("green-tag", .solid),
                    match("purple-tag", .dashed), match("red-tag", .dashed)]
        let segs = TagPalette.segments(matches: four, tagColors: colors)
        expectEqual(segs.count, TagPalette.maxSegments, "four matches draw maxSegments segments")
        expectEqual(segs.map(\.color), [NSColor.systemBlue, .systemGreen, .systemPurple],
                    "the cap keeps the FIRST three, in order")

        expectEqual(TagPalette.tooltip(matches: four, tagNames: names),
                    "Blues — solid\nGreens — solid\nPurples — dashed\nReds — dashed",
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
        expectEqual(TagPalette.segments(matches: matches, tagColors: colors).count,
                    TagPalette.maxSegments,
                    "the colourless tag is filtered out before the cap, so three coloured bands survive")
    }

    // MARK: - 5. A tag with no colour or no name is skipped, not fatal to the row

    do {
        let segs = TagPalette.segments(
            matches: [match("ghost-tag", .solid), match("red-tag", .dashed)],
            tagColors: colors)
        expectEqual(segs.count, 1, "the colourless tag is skipped; the coloured one survives")
        expectEqual(segs.first?.color, NSColor.systemRed, "the surviving segment is the coloured tag's")

        // `tagNames` and `tagColors` are built together from the same tag list
        // in one `bake`, so a name missing here is the same condition
        // `segments` already treats as "this tag is gone" — the tooltip must
        // agree, not fall back to a placeholder name.
        expectNil(TagPalette.tooltip(matches: [match("ghost-tag", .dashed)], tagNames: names),
                  "a match whose tag has no name is dropped, and dropping the only match leaves no tooltip")
        expectEqual(TagPalette.tooltip(matches: [match("ghost-tag", .dashed),
                                                 match("red-tag", .solid)],
                                       tagNames: names),
                    "Reds — solid",
                    "a nameless tag's line is dropped; a real tag beside it still gets its line")
    }

    // A tag name can predate the input sanitiser, so the store can hold a
    // hostile one — the row tooltip must disclose it. The `\n` join is ours
    // and must survive.
    do {
        let hostileName = "safe\u{202E}gpj.exe"
        let one = TagPalette.tooltip(matches: [match("h", .solid)], tagNames: ["h": hostileName])
        expectEqual(one, "safe<U+202E>gpj.exe — solid",
                    "the row tooltip discloses a bidi override in a tag name")
        let two = TagPalette.tooltip(matches: [match("h", .solid), match("red-tag", .dashed)],
                                     tagNames: ["h": hostileName, "red-tag": redTag.name])
        expectEqual(two, "safe<U+202E>gpj.exe — solid\nReds — dashed",
                    "two matches still join with a real newline")
    }

    // MARK: - 6. Empty inputs

    expectTrue(TagPalette.segments(matches: [], tagColors: colors).isEmpty,
               "an empty match list draws nothing")
    expectNil(TagPalette.tooltip(matches: [], tagNames: names),
              "an empty match list has no tooltip")
    expectTrue(TagPalette.tintTagByColumn(matches: []).isEmpty,
               "no matches, no tints")

    // MARK: - 7. The cell-tint map: the strongest match claims a contested column

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

    // MARK: - 8. bake: ONE survivor rule for bands, tooltip and tints
    //
    // The whole reason `bake` exists. A tag deleted while its result is on
    // screen must leave all three outputs in the same repaint — the split
    // rules this replaced could show a band for a tag whose matched cell had
    // already lost its tint.

    do {
        let map: [Int: [TagRowMatch]] = [
            7: [match("ghost-tag", .solid, columns: [0, 1]),
                match("red-tag", .dashed, columns: [1, 2])],
        ]
        let state = TagPalette.bake(tags: [redTag, blueTag], matchesByRow: map)

        expectEqual(state.segmentsByRow[7]?.count, 1, "the dead tag draws no band")
        expectEqual(state.segmentsByRow[7]?.first?.color, NSColor.systemRed,
                    "the surviving band is the live tag's colour")
        expectEqual(state.segmentsByRow[7]?.first?.isPartial, true,
                    "the surviving band carries its dashed state")
        expectEqual(state.tooltipByRow[7], "Reds — dashed",
                    "the dead tag gets no tooltip line")
        expectNil(state.tintByRow[7]?[0],
                  "the dead tag's own column stays untinted")
        expectEqual(state.tintByRow[7]?[1], "red-tag",
                    "the column the dead tag matched FIRST tints in the live tag, not in the dead one")
        expectEqual(state.tintByRow[7]?[2], "red-tag",
                    "the live tag keeps its uncontested column")
        expectNil(state.tints["ghost-tag"], "a dead tag has no tint colour")
        expectTrue(state.tints["red-tag"] != nil, "a live tag has a tint colour")
        expectTrue(state.tints["red-tag"].map { abs($0.alpha - TagPalette.cellTintAlpha) < 0.0001 } ?? false,
                   "the baked tint carries cellTintAlpha")
    }

    do {
        // Every match on the row is dead: the row leaves all three outputs
        // together, rather than lingering in one of them.
        let state = TagPalette.bake(tags: [redTag],
                                    matchesByRow: [4: [match("ghost-tag", .solid)]])
        expectNil(state.segmentsByRow[4], "an all-dead row has no bands")
        expectNil(state.tooltipByRow[4], "an all-dead row has no tooltip")
        expectNil(state.tintByRow[4], "an all-dead row has no tints")
    }

    do {
        // The contested column, through bake: strongest SURVIVING match wins.
        let state = TagPalette.bake(
            tags: allTags,
            matchesByRow: [3: [match("blue-tag", .solid, columns: [1, 3]),
                               match("red-tag", .dashed, columns: [3, 4])]])
        expectEqual(state.tintByRow[3]?[3], "blue-tag",
                    "bake gives the contested column to the strongest match")
        expectEqual(state.tintByRow[3]?[4], "red-tag",
                    "bake leaves the weaker tag its uncontested column")
    }

    do {
        // The overflow disclosure: more tags than bands, all of them named.
        let state = TagPalette.bake(
            tags: allTags,
            matchesByRow: [0: [match("blue-tag", .solid), match("green-tag", .solid),
                               match("purple-tag", .dashed), match("red-tag", .dashed)]])
        expectEqual(state.segmentsByRow[0]?.count, TagPalette.maxSegments,
                    "four matching tags still draw only maxSegments bands")
        expectEqual(state.tooltipByRow[0],
                    "Blues — solid\nGreens — solid\nPurples — dashed\nReds — dashed",
                    "the tooltip lists MORE tags than the bar can draw — that is the overflow disclosure")
    }

    do {
        let state = TagPalette.bake(tags: allTags, matchesByRow: [:])
        expectTrue(state.segmentsByRow.isEmpty, "an empty map bakes no bands")
        expectTrue(state.tooltipByRow.isEmpty, "an empty map bakes no tooltips")
        expectTrue(state.tintByRow.isEmpty, "an empty map bakes no tints")
        expectEqual(state.tints.count, allTags.count,
                    "the per-tag tint colours do not depend on the map")
    }

    do {
        // Tag ids come from the database. `Dictionary(uniqueKeysWithValues:)`
        // would TRAP the whole app on a duplicate; first-wins must not.
        let dupes = [redTag, tag("red-tag", "Reds again", colorIndex: 4)]
        let state = TagPalette.bake(tags: dupes,
                                    matchesByRow: [1: [match("red-tag", .solid)]])
        expectEqual(state.segmentsByRow[1]?.count, 1,
                    "a duplicate tag id does not trap")
        expectEqual(state.segmentsByRow[1]?.first?.color, NSColor.systemRed,
                    "the FIRST duplicate's colour wins")
        expectEqual(state.tooltipByRow[1], "Reds — solid",
                    "the FIRST duplicate's name wins")
    }

    // MARK: - 9. The tint alpha sits between the wash and the CURRENT find match

    // Read from `FindMatchDecoration`, not from a literal: this pairing used to
    // name find's numbers in prose, which meant changing find silently
    // falsified the assertion instead of failing it.
    expectTrue(TagPalette.cellTintAlpha > 0.15,
               "cellTintAlpha is above the 0.15 row wash")
    expectTrue(FindMatchDecoration.fillAlpha(.current).map { TagPalette.cellTintAlpha < $0 } ?? false,
               "cellTintAlpha is below the CURRENT find match's fill")
    // The one that is NOT a strict ordering, and is documented as such on
    // `cellTintAlpha`: a non-current find match is a LIGHTER fill than a tag
    // tint even though it wins the precedence chain. Its border is what
    // identifies it, so a tint must never draw one.
    expectTrue(FindMatchDecoration.fillAlpha(.other).map { $0 < TagPalette.cellTintAlpha } ?? false,
               "a non-current find match's fill is LIGHTER than a matched-cell tint")
    expectEqual(FindMatchDecoration.borderWidth(.none), 0,
                "the no-match border width is 0 — a tag tint is a fill and only a fill")

    // MARK: - 10. normalizedColorIndex: a stored index can be anything

    expectEqual(TagPalette.normalizedColorIndex(0), 0, "an in-range index is itself")
    expectEqual(TagPalette.normalizedColorIndex(TagPalette.colors.count - 1),
                TagPalette.colors.count - 1, "the last palette index is itself")
    expectEqual(TagPalette.normalizedColorIndex(TagPalette.colors.count), 0,
                "an index one past the palette wraps to the first colour")
    // A plain `%` returns a NEGATIVE remainder here and would trap on subscript.
    expectEqual(TagPalette.normalizedColorIndex(-1), TagPalette.colors.count - 1,
                "a NEGATIVE stored index wraps to the LAST colour, it does not trap")
    expectEqual(TagPalette.normalizedColorIndex(-TagPalette.colors.count), 0,
                "a negative multiple of the palette size wraps to the first colour")

    // MARK: - 11. selectionAfterRemoval: the manage sheet's post-delete selection
    //
    // The rule the sheet used to get from `NSTableView` clipping an
    // out-of-range selection during `reloadData()` — which AppKit does not
    // promise. Made explicit here so it can be asserted at all.

    expectNil(TagPalette.selectionAfterRemoval(removedRow: 0, newCount: 0),
              "removing the ONLY tag selects nothing")
    expectNil(TagPalette.selectionAfterRemoval(removedRow: 3, newCount: 0),
              "an emptied list selects nothing whichever row went")

    expectEqual(TagPalette.selectionAfterRemoval(removedRow: 0, newCount: 2), 0,
                "removing the FIRST of three lands on the tag that was second")
    expectEqual(TagPalette.selectionAfterRemoval(removedRow: 1, newCount: 3), 1,
                "removing a MIDDLE tag lands on the one that followed it")

    // The case the old clipping-dependent code got inconsistent: it jumped to
    // the FIRST tag when the LAST was deleted, so deleting down a list bounced
    // back to the top on the final step.
    expectEqual(TagPalette.selectionAfterRemoval(removedRow: 3, newCount: 3), 2,
                "removing the LAST tag falls back one, to the NEW last — not to the first")
    expectEqual(TagPalette.selectionAfterRemoval(removedRow: 1, newCount: 1), 0,
                "removing the last of two lands on the survivor")

    // `tableView.selectedRow` is -1 when nothing is selected, and the delete
    // path reads it before the write. It must not become a negative index.
    expectEqual(TagPalette.selectionAfterRemoval(removedRow: -1, newCount: 2), 0,
                "a NO-SELECTION row index (-1) resolves to the first tag, never a negative")

    if failures == 0 {
        print("\nAll TagAppearance tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
