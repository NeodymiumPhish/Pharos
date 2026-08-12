import AppKit

// MARK: - TagLabelPalette

/// The fixed colour palette a label's `colorIndex` points into.
///
/// An index, not a hex string: the stored value stays meaningful when the palette
/// is restyled, and it cannot carry an unreadable colour. An out-of-range index
/// wraps rather than trapping, because the value comes from the database.
enum TagLabelPalette {
    static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple,
    ]

    static func color(at index: Int) -> NSColor {
        guard !colors.isEmpty else { return .systemGray }
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// How a row should be painted, or nil when it carries no tag.
    ///
    /// Extracted from `ResultsDataSource.tableView(_:rowViewForRow:)` so it can be
    /// tested: the data source itself is too entangled to compile in a standalone
    /// harness. The delegate keeps only the view plumbing.
    ///
    /// `row` indexes `displayRows`, NOT `rows`. Mapping through it is what keeps the
    /// highlight on the right row once a filter or a sort is active.
    static func appearance(
        row: Int,
        displayRows: [Int],
        tagsByRow: [Int: RowTag],
        labelColors: [String: NSColor]
    ) -> (color: NSColor, isWeak: Bool)? {
        guard row >= 0, row < displayRows.count,
              let tag = tagsByRow[displayRows[row]],
              let color = labelColors[tag.labelId]
        else { return nil }
        return (color, tag.primaryKind == "fingerprint")
    }
}
