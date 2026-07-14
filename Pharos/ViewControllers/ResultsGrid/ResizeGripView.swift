import AppKit

/// A small bottom-right resize grip. Draws the standard diagonal-lines glyph and
/// reports cumulative drag deltas (from the drag's start point) via closures.
/// Self-contained: knows nothing about what it resizes.
final class ResizeGripView: NSView {

    /// Called on mouse-down, before any drag delta is reported.
    var onDragBegan: (() -> Void)?
    /// Cumulative delta from the drag's start point. dx > 0 = dragged right,
    /// dy > 0 = dragged down. Reported on every mouse-dragged event.
    var onDrag: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    /// Called on mouse-up (drag finished).
    var onDragEnded: (() -> Void)?

    private var startOnScreen: NSPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let w = bounds.width
        // Three short diagonal ticks tucked into the corner.
        for offset in stride(from: CGFloat(3), through: w - 1, by: 4) {
            path.move(to: NSPoint(x: w - 1, y: offset))
            path.line(to: NSPoint(x: offset, y: 1))
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startOnScreen = NSEvent.mouseLocation
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Screen coordinates are invariant to the popover window moving/growing
        // during the drag (NSPopover repositions itself as its content size changes),
        // which window-relative coordinates are not.
        let p = NSEvent.mouseLocation
        let dx = p.x - startOnScreen.x
        // Screen coords are y-up (origin bottom-left), so dragging DOWN lowers y →
        // startY - currentY is positive, which we treat as "grow height".
        let dy = startOnScreen.y - p.y
        onDrag?(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
