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
/// The underlying `CVDisplayLink` is reference-counted: it starts on the first
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

    private var displayLink: CVDisplayLink?
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

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else {
            // Creation failed — roll back the refcount so a future observe() can retry.
            observerCount -= 1
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let clock = Unmanaged<PulseClock>.fromOpaque(userInfo).takeUnretainedValue()
            clock.tick()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stop() {
        lock.lock()
        defer { lock.unlock() }

        observerCount = max(0, observerCount - 1)
        guard observerCount == 0, let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - Tick

    private func tick() {
        if reduceMotion {
            // Static peak — publish only once per change, not every frame.
            if value.value != 1.0 {
                DispatchQueue.main.async { [weak self] in self?.value.send(1.0) }
            }
            return
        }

        let t = CACurrentMediaTime() - startTime
        let phase = (t.truncatingRemainder(dividingBy: period)) / period
        let sine = sin(phase * 2 * .pi)
        let normalized = CGFloat(0.5 + 0.5 * sine)  // [0, 1]

        DispatchQueue.main.async { [weak self] in self?.value.send(normalized) }
    }

    @objc private func reduceMotionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            DispatchQueue.main.async { [weak self] in self?.value.send(1.0) }
        }
    }
}
