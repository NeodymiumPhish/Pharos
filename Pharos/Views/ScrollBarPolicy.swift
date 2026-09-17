import AppKit
import Combine

/// Keeps one scroll view's scroll bars in line with the "Always show scroll
/// bars in the editor and results" setting.
///
/// Off (the default) follows the system: the scroll view takes the style from
/// System Settings ▸ Appearance ▸ Show scroll bars and hides its scrollers
/// when nothing overflows — what the HIG asks of an app that does not have a
/// reason of its own. On uses the legacy style with the scrollers always
/// present, which is what the results grid did unconditionally before the
/// setting existed: an analyst reading a wide result wants to see at a glance
/// how much of it is off screen.
///
/// Setting `scrollerStyle` once is not enough for the "follow the system"
/// case — a scroll view given an explicit style stops tracking the preference
/// — so this object also listens for the preference changing and re-applies.
final class ScrollBarPolicy {

    private weak var scrollView: NSScrollView?
    private var alwaysVisible = false
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter alwaysVisible: the setting, as it changes. The app passes
    ///   `AppStateManager.shared.$settings.map(\.alwaysShowScrollBars)`.
    init(scrollView: NSScrollView, alwaysVisible: AnyPublisher<Bool, Never>) {
        self.scrollView = scrollView

        alwaysVisible
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                self.alwaysVisible = on
                self.apply()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
    }

    private func apply() {
        guard let scrollView else { return }
        Self.apply(alwaysVisible: alwaysVisible, to: scrollView)
    }

    /// The whole rule, as a pure function of the setting: legacy and pinned
    /// when the setting is on, the system's preferred style and auto-hiding
    /// when it is off.
    static func apply(alwaysVisible: Bool, to scrollView: NSScrollView) {
        if alwaysVisible {
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
        } else {
            scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
            scrollView.autohidesScrollers = true
        }
    }
}
