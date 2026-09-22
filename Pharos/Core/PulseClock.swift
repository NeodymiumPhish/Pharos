import AppKit
import Combine
import QuartzCore

/// Shared pulse source driving the "query running" breathing animation across
/// the gutter, the results action bar, and the per-tab indicator dots.
///
/// The clock publishes a value in [0, 1] following a sine wave with a 1.2s period.
/// All three surfaces subscribe to the same publisher so their animations stay
/// phase-locked.
///
/// The underlying `CADisplayLink` is reference-counted: it starts on the first
/// `observe()` call and stops when the observer count returns to zero, so idle
/// sessions have zero CPU cost.
///
/// When the system-wide "Reduce Motion" accessibility setting is enabled, the
/// published value is pinned to `1.0`, which renders each surface in its static
/// peak-accent state (same informational content, no motion).
final class PulseClock {

    static let shared = PulseClock()

    /// Breathing value in [0, 1]. Continuous while one or more clients are observing.
    let value = CurrentValueSubject<CGFloat, Never>(1.0)

    /// Whether the system is in Reduce Motion mode. Re-read on change notifications.
    private(set) var reduceMotion: Bool

    // MARK: - Internals

    private var displayLink: CADisplayLink?
    private var observerCount: Int = 0
    private let lock = NSLock()
    private let startTime = CACurrentMediaTime()
    private let period: CFTimeInterval = 1.2

    private init() {
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Subscribe to the pulse. Returns a token; when the token is cancelled or
    /// deallocated, the observer count decrements and the display link stops
    /// if this was the last observer.
    func observe() -> AnyCancellable {
        start()
        return AnyCancellable { [weak self] in
            self?.stop()
        }
    }

    // MARK: - Display Link Lifecycle

    private func start() {
        lock.lock()
        defer { lock.unlock() }

        observerCount += 1
        guard observerCount == 1, displayLink == nil else { return }

        // `NSScreen.displayLink` replaces `CVDisplayLink`, deprecated in macOS
        // 15. The callback arrives on the run loop the link is added to — the
        // main one — instead of on a CV thread, so the callback publishes straight
        // to the subject rather than hopping through `DispatchQueue.main.async`.
        guard let screen = NSScreen.main else {
            // No screen — roll back the refcount so a future observe() can retry.
            observerCount -= 1
            return
        }

        let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
        // `.common`, so the pulse keeps running while a menu or a resize has
        // the run loop in a tracking mode.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }

        observerCount = max(0, observerCount - 1)
        guard observerCount == 0, let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
    }

    // MARK: - Tick

    /// Display-link callback. Runs on the main run loop, so it publishes
    /// directly — the `DispatchQueue.main.async` hops the `CVDisplayLink`
    /// version needed are gone with it.
    @objc private func displayTick(_ link: CADisplayLink) {
        if reduceMotion {
            // Static peak — publish only once per change, not every frame.
            if value.value != 1.0 { value.send(1.0) }
            return
        }

        let t = CACurrentMediaTime() - startTime
        let phase = (t.truncatingRemainder(dividingBy: period)) / period
        let sine = sin(phase * 2 * .pi)
        let normalized = CGFloat(0.5 + 0.5 * sine)  // [0, 1]

        value.send(normalized)
    }

    @objc private func reduceMotionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            DispatchQueue.main.async { [weak self] in self?.value.send(1.0) }
        }
    }
}
