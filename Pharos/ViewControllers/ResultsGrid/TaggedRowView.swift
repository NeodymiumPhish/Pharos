import AppKit

// MARK: - TaggedRowView

/// The row background for a tagged row: a wash of the strongest tag's colour,
/// plus a bar at the leading edge — one vertical band per matching tag,
/// strongest first, capped upstream at `TagPalette.maxSegments`.
///
/// Z-order guarantees (unchanged from Phase 4):
/// - The WASH draws in `drawBackground(in:)`, below the cells and below the
///   selection. Cell selection truly WINS where it overlaps the wash:
///   `selectedContentBackgroundColor` (`ResultsDataSource.swift`) is opaque.
/// - The BAR draws in `draw(_:)` after `super`, ABOVE the selection.
///   `NSTableRowView.draw(_:)` runs drawBackground, then drawSelection, then
///   the separator; a bar drawn in drawBackground sits underneath an opaque
///   selection fill under the table's `.fullWidth` style. A tagged row carries
///   three markers — this wash, this bar, and a matched cell's tint — but the
///   bar is the only one that SURVIVES a selection: the wash draws below it
///   here, and the tint sits below it in the data source's precedence chain by
///   design. So the bar must clear the selection by construction, or a
///   selected tagged row would show nothing at all.
/// - `super.drawBackground` is not a no-op in the real app:
///   `usesAlternatingRowBackgroundColors = true` paints an opaque stripe under
///   the wash. A bare `TaggedRowView` outside a real table paints no stripe,
///   so headless pixel tests cannot see a regression there.
///
/// Geometry is exposed through `barRect(in:)`, `segmentRects(in:)` and
/// `tintAlpha` so a headless harness can assert it — see
/// `scripts/test-tagged-row-view.sh`. Nothing here reads the store or any
/// tag type: `ResultsDataSource` configures each row view with plain values,
/// which is what keeps this file compiling standalone in its harness.
final class TaggedRowView: NSTableRowView {

    /// The bar width. Fixed, not a fraction of the row: a taller row must not
    /// get a fatter bar. It is also the width of the grid's leading gutter —
    /// see the Phase 4 comment history for why the bar can carry the tag with
    /// no cell inset.
    static let barWidth: CGFloat = 4

    /// The dash pattern for a partial band's centre line, shared with Phase 4.
    /// A `static let` rather than a literal built inside `draw(_:)`, so the
    /// rhythm lives in exactly one named place instead of being re-typed
    /// wherever a partial band draws.
    static let dashPattern: [CGFloat] = [4, 3]

    /// The bands, strongest first. Empty when the row is untagged.
    private(set) var segments: [(color: NSColor, isPartial: Bool)] = []

    /// The wash derives from the FIRST band only — the strongest match owns
    /// the row-level paint, exactly as Phase 4's single tag did. Segments
    /// beyond the first only affect the bar.
    var isPartial: Bool { segments.first?.isPartial ?? false }

    /// 15% for a solid strongest match, 8% for a partial one, 0 when untagged.
    /// This file keeps zero non-AppKit dependencies (plan scope decision 12),
    /// so this literal cannot become a shared CONSTANT with anything in
    /// `TagPalette`. The actual duplicate to watch is prose, not a constant:
    /// `TagPalette.cellTintAlpha`'s doc comment ("Above the 0.15 row wash…",
    /// `TagPalette.swift`) hardcodes this same 0.15 in words. Change the
    /// number here, and go check that comment too.
    var tintAlpha: CGFloat {
        guard let first = segments.first else { return 0 }
        return first.isPartial ? 0.08 : 0.15
    }

    func configure(segments: [(color: NSColor, isPartial: Bool)]) {
        self.segments = segments
        needsDisplay = true
    }

    /// Reset for reuse. `NSTableView` recycles row views, so a row that loses
    /// its tags must lose its paint too. Equivalent to `configure(segments: [])`
    /// — kept as the intention-revealing name for the reuse path, which is
    /// what `ResultsDataSource` actually calls.
    func clearTag() {
        segments = []
        needsDisplay = true
    }

    /// The whole leading bar, or `.zero` when the row carries no tag. The
    /// single source of the bar's geometry: `segmentRects(in:)` slices THIS
    /// rect into bands rather than recomputing x, width or height on its
    /// own, so there is one place — not two — that can drift from the bar
    /// `draw(_:)` actually paints.
    ///
    /// `bounds` is a parameter only as a test seam — production always passes
    /// `self.bounds`.
    func barRect(in bounds: NSRect) -> NSRect {
        guard !segments.isEmpty else { return .zero }
        return NSRect(x: bounds.minX, y: bounds.minY,
                      width: Self.barWidth, height: bounds.height)
    }

    /// Equal vertical bands sliced from `barRect`, FIRST band at the VISUAL
    /// top — `bar.minY`, since `NSTableRowView` is flipped. See the fact-pin
    /// assertion in `TaggedRowViewTests` for why that assumption is safe to
    /// bake in here rather than branch on `isFlipped`.
    ///
    /// The LAST band takes the remainder rather than another equal
    /// `bandHeight`. This is defensive, not visible: on a height that does
    /// not divide evenly, summing equal `bandHeight`s can miss `bar.maxY` by
    /// an exact-arithmetic drift on the order of 1e-15pt — far below one
    /// pixel — but taking the remainder makes the far edge land exactly on
    /// `bar.maxY`, bit for bit, for free.
    func segmentRects(in bounds: NSRect) -> [NSRect] {
        let bar = barRect(in: bounds)
        guard !segments.isEmpty else { return [] }
        let bandHeight = bar.height / CGFloat(segments.count)
        return segments.indices.map { index in
            let y = bar.minY + CGFloat(index) * bandHeight
            let height = index == segments.count - 1 ? bar.maxY - y : bandHeight
            return NSRect(x: bar.minX, y: y, width: bar.width, height: height)
        }
    }

    /// The WASH only. It belongs under the selection, which is why it lives here.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let first = segments.first else { return }
        first.color.withAlphaComponent(tintAlpha).setFill()
        bounds.fill()
    }

    /// The BAR's bands, painted after `super.draw` and therefore ABOVE the
    /// selection. A solid band fills its rect; a partial band strokes a
    /// dashed centre line at `Self.dashPattern`, the Phase 4 dash pattern per
    /// band.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !segments.isEmpty else { return }
        for (segment, rect) in zip(segments, segmentRects(in: bounds)) {
            if segment.isPartial {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: rect.midX, y: rect.minY))
                path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
                path.lineWidth = Self.barWidth
                path.setLineDash(Self.dashPattern, count: Self.dashPattern.count, phase: 0)
                segment.color.setStroke()
                path.stroke()
            } else {
                segment.color.setFill()
                rect.fill()
            }
        }
    }
}
