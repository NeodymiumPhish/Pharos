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
    ///
    /// - Parameter bounds: in production this is always the cell's own `bounds`,
    ///   whose origin is always zero — `NSTableCellView` never has a non-zero
    ///   origin, so `bounds.minX`/`bounds.minY` are not folded into `x`/`y` here.
    ///   `bounds` is a parameter, not read directly, only so a headless test can
    ///   ask "what would the dot be in a 60pt row?" without resizing a real view —
    ///   the same test-seam pattern as `TaggedRowView.barRect(in:)`.
    static func rect(in bounds: NSRect) -> NSRect {
        NSRect(x: leading,
               y: (bounds.height - diameter) / 2,
               width: diameter,
               height: diameter)
    }

    /// Whether the dot is filled, for a match of the given strength.
    ///
    /// A fingerprint match is HOLLOW — the weaker claim reads as the weaker mark.
    /// This exists as a named function because it is the feature's one decision, and
    /// inverting it at the call site passed every test in the repository.
    static func filled(forWeakMatch isWeak: Bool) -> Bool { !isWeak }

    /// Draw the dot. `filled` means a strong match; hollow means a fingerprint match,
    /// shown as the weaker claim it is.
    static func draw(color: NSColor, filled: Bool, in bounds: NSRect) {
        // The half-point inset shrinks the drawn circle from the 6pt bounding box
        // to a 5pt circle centred within it — for the stroke this centres the
        // 1.5pt band on that shrunk path's edge, rather than the fill sitting
        // flush against the outer rect. Removing it changes the actual drawn
        // diameter from 5pt to 6pt: a full point, not a sub-pixel shift, and it
        // shows up exactly where a 5pt and a 6pt circle diverge — at the dot's
        // EDGE pixels. TagDotTests.swift's hollow-rim "waist" check samples one
        // of those, so it catches this even though it exists to pin the rim's
        // COLOUR, not this inset.
        let path = NSBezierPath(ovalIn: rect(in: bounds).insetBy(dx: 0.5, dy: 0.5))
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            // The rim's THICKNESS is untested: the default line width is 1.0, so a
            // deleted `lineWidth` still paints a rim and every pixel check passes.
            // 1.0 against 1.5 is a cosmetic difference, not a correctness one, so
            // this is recorded rather than pinned.
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
