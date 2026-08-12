import AppKit

// MARK: - TaggedRowView

/// The row background for a tagged row: a wash of the label colour, plus a bar at
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

    /// - Parameter isWeak: see the `isWeak` property doc.
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

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tagColor else { return }

        tagColor.withAlphaComponent(tintAlpha).setFill()
        bounds.fill()

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
