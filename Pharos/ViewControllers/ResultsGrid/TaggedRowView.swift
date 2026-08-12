import AppKit

// MARK: - TaggedRowView

/// The row background for a tagged row: a wash of the label colour, plus a bar at
/// the leading edge.
///
/// It sits BELOW the cells on purpose. The find highlight and the cell selection
/// paint cell backgrounds, so they still win where they overlap, and the existing
/// precedence chain does not change. The wash stays visible at the row edges,
/// which is enough to read.
///
/// Geometry is exposed through `barRect(in:)` and `tintAlpha` so a headless
/// harness can assert it — see `scripts/test-tagged-row-view.sh`. Nothing here
/// reads the store: `ResultsDataSource` configures each row view.
final class TaggedRowView: NSTableRowView {

    /// The bar width. Fixed, not a fraction of the row: a taller row must not get
    /// a fatter bar.
    static let barWidth: CGFloat = 3

    private(set) var tagColor: NSColor?

    /// A fingerprint match. It draws fainter and dashed, so the two trust levels are
    /// distinguishable without reading anything.
    ///
    /// This is the stored property, and both the wash alpha and the bar style derive
    /// from it. Do not reverse that: deriving the alpha from `isBarDashed` would link
    /// the wash to the bar STYLE, so a later reason to dash the bar — a note marker,
    /// a third trust tier — would silently change the wash too.
    private(set) var isWeak = false

    /// True when the bar draws dashed. Derived: a weak match is the only reason today.
    var isBarDashed: Bool { isWeak }

    /// 15% for a strong match, 8% for a fingerprint, 0 when untagged.
    var tintAlpha: CGFloat {
        guard tagColor != nil else { return 0 }
        return isWeak ? 0.08 : 0.15
    }

    /// - Parameter isWeak: a fingerprint match. It draws fainter and dashed, so the
    ///   two trust levels are distinguishable without reading anything.
    func configure(color: NSColor, isWeak: Bool) {
        tagColor = color
        self.isWeak = isWeak
        needsDisplay = true
    }

    /// Reset for reuse. `NSTableView` recycles row views, so a row that loses its
    /// tag must lose its paint too.
    func clearTag() {
        tagColor = nil
        isWeak = false
        needsDisplay = true
    }

    /// The leading bar, or `.zero` when the row carries no tag.
    func barRect(in bounds: NSRect) -> NSRect {
        guard tagColor != nil else { return .zero }
        return NSRect(x: bounds.minX, y: bounds.minY,
                      width: Self.barWidth, height: bounds.height)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tagColor else { return }

        tagColor.withAlphaComponent(tintAlpha).setFill()
        bounds.fill()

        let bar = barRect(in: bounds)
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
