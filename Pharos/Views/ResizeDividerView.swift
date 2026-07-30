import AppKit

/// A thin vertical drag handle. Reports how far the pointer has moved from where
/// the drag began via `onDrag`, and signals the start of a drag via `onDragBegan`
/// so the consumer can snapshot whatever it is about to resize.
///
/// Absolute offsets rather than per-event deltas, deliberately. A consumer that
/// clamps the size it derives — a panel with a min and max width — absorbs any
/// delta that would push past the clamp, and those absorbed points are gone. Drag
/// past the maximum, then back, and the size starts changing immediately while the
/// pointer is still far outside the range that produced it: the divider visibly
/// unsticks from the cursor. Reporting the offset from the origin lets the consumer
/// re-derive the size from scratch on every event, so it stays pinned at the clamp
/// until the pointer returns to the position where the clamp was reached.
final class ResizeDividerView: NSView {

    /// The user has started dragging. Snapshot the current size here.
    var onDragBegan: (() -> Void)?

    /// Points the pointer has moved since the drag began. Positive = dragged right.
    var onDrag: ((CGFloat) -> Void)?

    private var dragOriginX: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - dragOriginX)
    }
}
