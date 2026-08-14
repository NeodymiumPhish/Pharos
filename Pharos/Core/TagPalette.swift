import AppKit

// MARK: - TagPalette

/// The fixed colour palette a tag's `colorIndex` points into.
///
/// An index, not a hex string: the stored value stays meaningful when the
/// palette is restyled, and it cannot carry an unreadable colour. An
/// out-of-range index wraps rather than trapping, because the value comes from
/// the database.
enum TagPalette {
    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple,
    ]

    static func color(at index: Int) -> NSColor {
        guard !colors.isEmpty else { return .systemGray }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// One vertical band of the leading bar.
    struct Segment: Equatable {
        let color: NSColor
        let isPartial: Bool
    }

    /// The bar caps at three bands (spec, Rendering); the tooltip and the
    /// Inspector carry the full list.
    static let maxSegments = 3

    /// Matched-cell tint alpha. Above the 0.15 row wash so a matched cell
    /// reads against it, below the 0.4 find highlight so find still wins
    /// visually as well as by precedence.
    static let cellTintAlpha: CGFloat = 0.2

    /// The bounds guard and the display-row mapping shared by `segments` and
    /// `tooltip`: `row` indexes `displayRows`, NOT `rows`, and both callers
    /// must reject an out-of-range row rather than trap — `displayRows` can
    /// be momentarily stale against the table's row count during a reload.
    private static func matches(
        row: Int,
        displayRows: [Int],
        matchesByRow: [Int: [TagRowMatch]]
    ) -> [TagRowMatch] {
        guard row >= 0, row < displayRows.count else { return [] }
        return matchesByRow[displayRows[row]] ?? []
    }

    /// The bar's bands for one display row, strongest first, capped at
    /// `maxSegments`. Empty when the row is untagged.
    ///
    /// A tag id missing from `tagColors` (a delete landing mid-repaint) is
    /// filtered out BEFORE the cap, so a colourless tag never steals a slot
    /// from a coloured one behind it.
    static func segments(
        row: Int,
        displayRows: [Int],
        matchesByRow: [Int: [TagRowMatch]],
        tagColors: [String: NSColor]
    ) -> [Segment] {
        Array(
            matches(row: row, displayRows: displayRows, matchesByRow: matchesByRow)
                .compactMap { match in
                    tagColors[match.tagId].map {
                        Segment(color: $0, isPartial: match.state == .dashed)
                    }
                }
                .prefix(maxSegments)
        )
    }

    /// The full tag list for a row's tooltip, one "Name — state" line per
    /// matching tag, in the matcher's order. Nil when the row is untagged or
    /// every matching tag has been deleted mid-repaint.
    ///
    /// A tag id missing from `tagNames` is dropped, not shown as "Unnamed
    /// tag": `tagNames` and `tagColors` are built together from the same
    /// `TagStore.shared.tags` in one `applyTagMap`, so a missing name and a
    /// missing colour are the SAME condition (a deleted tag) — `segments`
    /// already skips that tag's bar, and the tooltip must agree rather than
    /// naming a tag that no longer exists.
    static func tooltip(
        row: Int,
        displayRows: [Int],
        matchesByRow: [Int: [TagRowMatch]],
        tagNames: [String: String]
    ) -> String? {
        let lines = matches(row: row, displayRows: displayRows, matchesByRow: matchesByRow)
            .compactMap { match in
                tagNames[match.tagId].map { "\($0) — \(match.state == .solid ? "solid" : "dashed")" }
            }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Which tag tints each DATA column of one row: the strongest match that
    /// matched the column claims it. `matches` must already be in the
    /// matcher's strongest-first order.
    static func tintTagByColumn(matches: [TagRowMatch]) -> [Int: String] {
        var map: [Int: String] = [:]
        for match in matches {
            for column in match.matchedColumns where map[column] == nil {
                map[column] = match.tagId
            }
        }
        return map
    }

    /// How a row should be painted, or nil when no tag matches it.
    ///
    /// Phase 4 paints the STRONGEST match only — `TagTupleMatcher.ordered` has
    /// already put it first. Phase 5 splits the bar into one segment per
    /// matching tag; the full list is already in `matches`, so that is drawing
    /// work, not matching work.
    ///
    /// `row` indexes `displayRows`, NOT `rows`. Mapping through it is what keeps
    /// the paint on the right row once a filter or a sort is active.
    ///
    /// Extracted from the data source so it can be tested: the data source
    /// itself is too entangled to compile in a standalone harness.
    static func appearance(
        row: Int,
        displayRows: [Int],
        matchesByRow: [Int: [TagRowMatch]],
        tagColors: [String: NSColor]
    ) -> (color: NSColor, isPartial: Bool)? {
        guard row >= 0, row < displayRows.count,
              let best = matchesByRow[displayRows[row]]?.first,
              let color = tagColors[best.tagId]
        else { return nil }
        return (color, best.state == .dashed)
    }
}
