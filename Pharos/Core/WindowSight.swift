import AppKit

/// Whether a window is out of the user's sight: not on screen, minimised, or a
/// tab of its group that is not the one showing. Every query tab is a window,
/// so "a background tab" is a question about its window.
///
/// A pane in such a window can leave app-wide change notifications for later:
/// nobody can see it, and it refreshes when its window becomes key or main
/// (selecting a tab does both). Doing the work in every window on every change
/// made each change cost once per open tab.
enum WindowSight {
    static func isOutOfSight(_ window: NSWindow?) -> Bool {
        guard let window, window.isVisible else { return true }
        if window.isMiniaturized { return true }
        if let group = window.tabGroup, group.selectedWindow !== window { return true }
        return false
    }

    /// Observe `window` coming into sight — it becomes key or main, which
    /// selecting its tab, de-minimising it and clicking it all do — and call
    /// `body`. The window is read at post time through `window()`, so a pane
    /// can install this before its view is in a window. Returns the tokens to
    /// remove.
    static func observeComingIntoSight(of window: @escaping () -> NSWindow?,
                                       _ body: @escaping () -> Void) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { note in
            MainActor.assumeIsolated {
                guard let posted = note.object as? NSWindow, posted === window() else { return }
                body()
            }
        }
        // `object: nil` and a pointer test, not `object: window`: the pane's
        // view may not be in its window yet when it installs this.
        return [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler),
            center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main, using: handler),
        ]
    }
}
