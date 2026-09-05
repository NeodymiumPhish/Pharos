import AppKit

/// The vertical split between the editor panes (top) and the results area
/// (bottom). It draws NO divider of its own: the results area's action bar
/// is the divider. Its blank stretch is the drag zone — the delegate hands
/// the bar's frame back as the divider's additional effective rect, the way
/// Xcode's debug-area bar works — and a drawn divider would put a second
/// line under the bar's own top separator.
///
/// This replaces a hand-rolled tracking loop in the action bar that moved a
/// height constraint by hand. A real split view brings the standard drag
/// behaviour, min/max constraints through the delegate, and holding
/// priorities so the results area, not the editor, absorbs a window resize.
final class EditorResultsSplitView: NSSplitView {

    /// Called before the split view starts tracking a divider drag. The
    /// content controller uses it to leave an expanded state. NSSplitView
    /// then looks for the divider at the click point; the restored bar is
    /// elsewhere by then (it was parked in the min or max zone), so the
    /// gesture ends as a click that restores the layout, and the next drag
    /// on the bar resizes. The old tracking loop dragged from the first
    /// event; that continuation is the one behaviour this does not keep.
    var onWillBeginDividerDrag: (() -> Void)?

    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}

    /// NSSplitView claims EVERY point inside a divider's additional effective
    /// rect for itself (measured: a button centred in that rect hit-tests to
    /// the split view), which would make the action bar's controls dead. If
    /// a control sits under the point, the control wins; the blank bar still
    /// starts a divider drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        let local = convert(point, from: superview)
        for sub in subviews where !sub.isHidden {
            guard let deep = sub.hitTest(local), deep !== sub else { continue }
            var view: NSView? = deep
            while let current = view, current !== sub {
                if current is NSControl { return deep }
                view = current.superview
            }
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        onWillBeginDividerDrag?()
        super.mouseDown(with: event)
    }
}
