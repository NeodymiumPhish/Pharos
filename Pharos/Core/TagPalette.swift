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
