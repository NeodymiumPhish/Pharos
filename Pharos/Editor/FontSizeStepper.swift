import Foundation

/// Pure arithmetic for turning a trackpad pinch (or a keyboard step) into an
/// editor font size. No AppKit — kept separate from `QueryEditorVC` so the
/// magnification → steps → clamped-size math is unit-testable standalone
/// (`scripts/test-font-size-stepper.sh`).
enum FontSizeStepper {

    /// The editor's font size range, fixed in `EditorSettingsPaneVC`.
    static let range = 9...24

    /// How much `NSMagnificationGestureRecognizer.magnification` must
    /// accumulate for one font-size step. 0.25 keeps the pinch responsive
    /// without a step firing on every frame of a small gesture.
    static let magnificationPerStep: CGFloat = 0.25

    /// The font size a pinch produces, given the size in effect when the
    /// gesture began and the gesture's current accumulated magnification.
    /// Truncates toward zero so a partial step (< 0.25 in either direction)
    /// does not move the size, then clamps to `range`.
    static func size(start: Int, magnification: CGFloat) -> Int {
        let steps = Int((magnification / magnificationPerStep).rounded(.towardZero))
        return stepped(start, by: steps)
    }

    /// `size` shifted by `delta` steps and clamped to `range`. Shared by the
    /// pinch handler and the ⌘+ / ⌘− menu commands, which move by one step.
    static func stepped(_ size: Int, by delta: Int) -> Int {
        min(max(size + delta, range.lowerBound), range.upperBound)
    }
}
