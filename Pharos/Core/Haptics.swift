import AppKit

/// A short alignment tap confirming a discrete drag-driven state change —
/// the editor/results split leaving an expanded state, or a saved query
/// landing in a new folder. `.alignment` is the pattern AppKit defines for
/// "a dragged thing reached a position"; `.levelChange` is for a control and
/// `.generic` says nothing. Fired only from the exact gesture that produced
/// the change, never from a repeated callback (drag-validate, a clamp) or
/// from a click/launch path that reaches the same state without a drag.
///
/// Reduce Motion is deliberately NOT a gate here — a haptic is not motion.
/// The system's own switch is the trackpad "Force Click and haptic feedback"
/// setting in System Settings, and `NSHapticFeedbackManager` respects it on
/// its own; the performer is also a no-op on hardware that cannot do it, so
/// no capability check is needed either.
enum Haptics {
    /// Test seam: a test replaces this to count calls instead of touching
    /// real trackpad hardware. Production code never reassigns it.
    static var performer: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func alignment() {
        performer()
    }

    /// Whether a discrete state change deserves a tap: the state actually
    /// changed, and it changed AWAY from `normal` — reaching `normal` from a
    /// click or a launch restore does not count; only leaving an expanded
    /// state via the one gesture that calls this does.
    ///
    /// Generic over `Equatable` rather than typed on `ContentExpandState`:
    /// that enum is nested inside `ContentViewController`, a large AppKit
    /// view controller with FFI dependencies that a standalone test binary
    /// cannot compile in isolation. Genericizing keeps this file (and its
    /// test suite) independent of that type.
    static func shouldTap<T: Equatable>(from: T, to: T, normal: T) -> Bool {
        from != to && from != normal
    }

    /// Whether a folder drop deserves a tap: at least one dragged query
    /// landed in a folder different from the one it started in. A drop back
    /// into the same folder changed nothing and must stay silent.
    static func shouldTapForFolderDrop(moves: [(from: String?, to: String?)]) -> Bool {
        moves.contains { $0.from != $0.to }
    }
}
