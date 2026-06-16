import AppKit

/// An NSPopUpButton that presents a custom popover instead of its native menu,
/// while keeping the standard recessed/borderless arrow appearance so it matches
/// the adjacent connection popup. Both mouse clicks and keyboard activation
/// (Space / Return) open the popover, so the full schema list stays reachable for
/// keyboard users; the native menu (which carries only the current title item) is
/// never shown.
final class SchemaPopUpButton: NSPopUpButton {

    /// Invoked when the control is activated while enabled. The owner uses this
    /// to present the schema popover anchored to `self`.
    var onActivate: ((SchemaPopUpButton) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let onActivate else {
            super.mouseDown(with: event)
            return
        }
        onActivate(self)
    }

    override func keyDown(with event: NSEvent) {
        // Space / Return open the popover, matching the mouse path. Any other key
        // falls through to default handling, so this is purely additive — if the
        // event never reaches here, behavior is unchanged.
        let activationKeys: Set<String> = [" ", "\r", "\u{3}"]   // space, return, enter
        guard isEnabled, let onActivate,
              let chars = event.charactersIgnoringModifiers,
              activationKeys.contains(chars) else {
            super.keyDown(with: event)
            return
        }
        onActivate(self)
    }
}
