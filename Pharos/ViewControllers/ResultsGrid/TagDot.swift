import AppKit

// MARK: - TagDot

/// The tag marker drawn before a row number: filled for a strong match, hollow for
/// a fingerprint match.
///
/// This lives in its own file, not inside `ResultCellView`, because that class is
/// private to `ResultsDataSource.swift` and that file cannot compile in a standalone
/// harness. Keeping the drawing here means it can be pixel-tested — see
/// `scripts/test-tag-dot.sh`. `ResultCellView` keeps only the call.
enum TagDot {

    static let diameter: CGFloat = 6
    /// Inset from the cell's leading edge to the dot.
    static let leading: CGFloat = 5
    /// Where the row number starts when a dot is present: past the dot plus a gap.
    static let textInsetWithDot: CGFloat = leading + diameter + 4
    /// Where the row number starts otherwise. Matches the constraint the data source
    /// builds for every other column.
    static let textInsetPlain: CGFloat = 6

    /// The dot, vertically centred in `bounds`.
    static func rect(in bounds: NSRect) -> NSRect {
        NSRect(x: leading,
               y: (bounds.height - diameter) / 2,
               width: diameter,
               height: diameter)
    }

    /// Draw the dot. `filled` means a strong match; hollow means a fingerprint match,
    /// shown as the weaker claim it is.
    static func draw(color: NSColor, filled: Bool, in bounds: NSRect) {
        let path = NSBezierPath(ovalIn: rect(in: bounds).insetBy(dx: 0.5, dy: 0.5))
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
