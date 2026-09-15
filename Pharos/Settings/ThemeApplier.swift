import AppKit
import Combine

/// Keeps `NSApp.appearance` equal to the stored theme.
///
/// The Settings window has no Save button, so a theme chosen there has to take
/// effect the moment the segment is clicked. Rather than have the pane reach
/// for `NSApp`, the theme follows the STORED value: one subscriber, one place
/// that touches the application appearance, and the launch case is the same
/// code path as a change (the publisher delivers the current value when
/// `start()` subscribes).
@MainActor
final class ThemeApplier {

    static let shared = ThemeApplier()

    private var cancellable: AnyCancellable?

    private init() {}

    /// Apply the stored theme now, and on every change from here on.
    func start() {
        cancellable = AppStateManager.shared.$settings
            .map(\.theme)
            .removeDuplicates()
            .sink { theme in
                Self.apply(theme)
            }
    }

    static func apply(_ theme: ThemeMode) {
        switch theme {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
