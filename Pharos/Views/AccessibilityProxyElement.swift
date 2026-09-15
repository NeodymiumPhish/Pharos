import AppKit

/// An accessibility element that stands in for something a view DRAWS rather
/// than hosts as a subview.
///
/// Three of this app's surfaces paint their controls straight into one view's
/// `draw(_:)` — the results header's column titles and funnel icons, the result
/// tab bar's tabs and close glyphs, the editor tab bar's hidden close buttons.
/// A screen reader sees one opaque rectangle for each of them, because there is
/// no subview to describe. These elements put the parts back into the tree: one
/// per thing the eye can see and the mouse can hit, with the label, the role and
/// the press the drawn thing would have had.
///
/// Held by the drawing view and cached across redraws, so an element's identity
/// survives a repaint — a fresh element per draw makes VoiceOver lose its place.
/// Frames are in SCREEN coordinates (AppKit's rule for
/// `setAccessibilityFrame`); `frameInScreen(of:in:)` is the one conversion.
final class AccessibilityProxyElement: NSAccessibilityElement {

    /// Run for an AX press. Returns whether the press did something, which is
    /// what `accessibilityPerformPress` must report.
    var onPress: (() -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        onPress?() ?? false
    }

    override func isAccessibilityElement() -> Bool { true }

    /// `rect`, given in `view`'s own coordinates, in screen coordinates.
    ///
    /// Returns `.zero` for a view that is not in a window yet: an element with
    /// no frame is merely unreachable by a pointer, whereas converting through a
    /// nil window would put it at an arbitrary place on the desktop.
    static func frameInScreen(of rect: NSRect, in view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    /// The common shape: an element that presses something.
    static func button(label: String, frame: NSRect, parent: Any,
                       press: @escaping () -> Bool) -> AccessibilityProxyElement {
        let element = AccessibilityProxyElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel(label)
        element.setAccessibilityFrame(frame)
        element.setAccessibilityParent(parent)
        element.onPress = press
        return element
    }
}
