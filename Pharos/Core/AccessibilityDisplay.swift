import AppKit
import Combine

/// The user's accessibility display settings, read once and kept current.
///
/// Views that draw a signal with colour alone consult
/// `differentiateWithoutColor` and add a second channel (a shape, a
/// pattern or text). Views with faint separators consult `increaseContrast`
/// and raise their alphas. `PulseClock` reads `reduceMotion` on its own for
/// historical reasons; new code reads it here.
///
/// Observe with Combine (`$differentiateWithoutColor`) or with the
/// `AccessibilityDisplay.didChange` notification for views without a
/// subscription slot; both fire on the main thread after the values update.
@MainActor
final class AccessibilityDisplay: ObservableObject {

    static let shared = AccessibilityDisplay()

    static let didChange = Notification.Name("PharosAccessibilityDisplayDidChange")

    @Published private(set) var differentiateWithoutColor: Bool
    @Published private(set) var increaseContrast: Bool
    @Published private(set) var reduceMotion: Bool

    private var observer: NSObjectProtocol?

    private init() {
        let ws = NSWorkspace.shared
        differentiateWithoutColor = ws.accessibilityDisplayShouldDifferentiateWithoutColor
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let ws = NSWorkspace.shared
        differentiateWithoutColor = ws.accessibilityDisplayShouldDifferentiateWithoutColor
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Test seam: forces the values without touching System Settings.
    /// Production code never calls this.
    func overrideForTesting(differentiateWithoutColor d: Bool? = nil, increaseContrast c: Bool? = nil, reduceMotion m: Bool? = nil) {
        if let d { differentiateWithoutColor = d }
        if let c { increaseContrast = c }
        if let m { reduceMotion = m }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
