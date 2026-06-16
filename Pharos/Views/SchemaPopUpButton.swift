import AppKit

/// An NSPopUpButton that presents a custom popover instead of its native menu,
/// while keeping the standard recessed/borderless arrow appearance so it matches
/// the adjacent connection popup. The native menu carries only the current title
/// item (set by the owner), so keyboard activation degrades gracefully to showing
/// that single item rather than an empty menu.
final class SchemaPopUpButton: NSPopUpButton {

    /// Invoked on a mouse click when the control is enabled. The owner uses this
    /// to present the schema popover anchored to `self`.
    var onActivate: ((SchemaPopUpButton) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let onActivate else {
            super.mouseDown(with: event)
            return
        }
        onActivate(self)
    }
}
