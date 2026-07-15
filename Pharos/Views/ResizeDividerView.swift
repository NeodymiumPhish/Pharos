import AppKit

/// A thin vertical drag handle. Reports horizontal drag deltas (in the parent's
/// coordinate space) via `onDrag`. Shows a resize cursor on hover.
final class ResizeDividerView: NSView {

    /// Called with the horizontal delta (points) as the user drags.
    /// Positive delta = dragged right.
    var onDrag: ((CGFloat) -> Void)?

    private var lastX: CGFloat = 0
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
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        let delta = x - lastX
        lastX = x
        onDrag?(delta)
    }
}
