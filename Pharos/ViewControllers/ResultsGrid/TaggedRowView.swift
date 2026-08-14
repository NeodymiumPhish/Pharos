import AppKit

// MARK: - TaggedRowView

/// The row background for a tagged row: a wash of the tag colour, plus a bar at
/// the leading edge.
///
/// It sits BELOW the cells on purpose, and that z-order is the whole of what is
/// guaranteed:
/// - Cell selection truly WINS where it overlaps the wash: `selectedContentBackgroundColor`
///   (`ResultsDataSource.swift` around line 109) is opaque, so it fully replaces the wash
///   underneath, not just for cells it does not cover.
/// - The find highlight does NOT win, it BLENDS: both find colours are translucent
///   (`systemYellow.withAlphaComponent(0.4)` and `0.15`, `ResultsDataSource.swift:107-108`),
///   so a find match on a tagged row shows the wash showing through the yellow, not a clean
///   yellow. That is an acceptable read, not a precedence win.
/// - `super.drawBackground` is not a no-op in the real app: `ResultsGridVC.swift:98` sets
///   `usesAlternatingRowBackgroundColors = true`, so odd/even rows already get an opaque
///   stripe before the wash is drawn on top. The harness cannot see this — a bare
///   `TaggedRowView` outside a real table paints no alternating stripe — so do not expect a
///   headless pixel test to catch a regression here.
///
/// Geometry is exposed through `barRect(in:)` and `tintAlpha` so a headless
/// harness can assert it — see `scripts/test-tagged-row-view.sh`. Nothing here
/// reads the store: `ResultsDataSource` configures each row view.
final class TaggedRowView: NSTableRowView {

    /// The bar width. Fixed, not a fraction of the row: a taller row must not get
    /// a fatter bar.
    ///
    /// It is also the width of the grid's leading gutter. `ResultsGridVC` sets
    /// `tableView.style = .fullWidth` so no framework padding sits to the left of
    /// it, and the row-number cell's 6pt text inset leaves a 2pt gap after it. The
    /// bar is therefore the only thing in that space, which is why it can carry the
    /// tag on its own and the row-number dot was removed.
    static let barWidth: CGFloat = 4

    private(set) var tagColor: NSColor?

    /// A PARTIAL match: some of the tag's values are present in this row, but no
    /// single tuple is complete. It draws fainter and dashed, so the two states
    /// are distinguishable without reading anything.
    ///
    /// This is the stored property, and both the wash alpha and the bar style
    /// derive from it. Do not reverse that: deriving the alpha from
    /// `isBarDashed` would link the wash to the bar STYLE, so a later reason to
    /// dash the bar would silently change the wash too.
    private(set) var isPartial = false

    /// True when the bar draws dashed. Derived: a partial match is the only reason today.
    var isBarDashed: Bool { isPartial }

    /// 15% for a solid match, 8% for a partial one, 0 when untagged.
    var tintAlpha: CGFloat {
        guard tagColor != nil else { return 0 }
        return isPartial ? 0.08 : 0.15
    }

    /// - Parameter isPartial: see the `isPartial` property doc.
    func configure(color: NSColor, isPartial: Bool) {
        tagColor = color
        self.isPartial = isPartial
        needsDisplay = true
    }

    /// Reset for reuse. `NSTableView` recycles row views, so a row that loses its
    /// tag must lose its paint too.
    func clearTag() {
        tagColor = nil
        isPartial = false
        needsDisplay = true
    }

    /// The leading bar, or `.zero` when the row carries no tag.
    ///
    /// - Parameter bounds: in production this is always `self.bounds` — it is a
    ///   parameter rather than reading `bounds` directly only so a headless test
    ///   can ask "what would the bar be on a 60pt row?" without actually resizing
    ///   the view. It is a test seam, not general flexibility.
    func barRect(in bounds: NSRect) -> NSRect {
        guard tagColor != nil else { return .zero }
        return NSRect(x: bounds.minX, y: bounds.minY,
                      width: Self.barWidth, height: bounds.height)
    }

    /// The WASH only. It belongs under the selection, which is why it lives here.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tagColor else { return }
        tagColor.withAlphaComponent(tintAlpha).setFill()
        bounds.fill()
    }

    /// The BAR, painted after `super.draw` and therefore ABOVE the selection.
    ///
    /// `NSTableRowView.draw(_:)` calls `drawBackground`, then `drawSelection`, then
    /// the separator. Drawing the bar in `drawBackground` — where it used to live —
    /// left it underneath an opaque selection fill. It survived only because the
    /// table's `.inset` style insets the selection past the leading edge, and that
    /// accident disappears with `.fullWidth`, where the selection spans the whole row.
    ///
    /// Since the bar is now the ONLY marker on a tagged row — the row-number dot was
    /// removed — losing it on a selected row would mean losing the tag entirely. The
    /// dot survived selection because it was drawn in a cell, above the row view;
    /// this gives the bar the same guarantee by construction rather than by luck.
    /// `scripts/test-tagged-row-view.sh` pins it with `isSelected` set.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tagColor else { return }

        let bar = barRect(in: bounds)
        // Belt-and-braces: `barRect` only ever returns `.zero` when `tagColor`
        // is nil, and the guard above has already handled that case, so this
        // can never actually fire today.
        guard !bar.isEmpty else { return }
        if isBarDashed {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bar.midX, y: bar.minY))
            path.line(to: NSPoint(x: bar.midX, y: bar.maxY))
            path.lineWidth = Self.barWidth
            path.setLineDash([4, 3], count: 2, phase: 0)
            tagColor.setStroke()
            path.stroke()
        } else {
            tagColor.setFill()
            bar.fill()
        }
    }
}
