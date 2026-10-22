import AppKit

/// A single-instance utility window (the Variable Manager, the Tag Manager):
/// the Settings window's treatment without its toolbar — one remembered frame,
/// no tabbing, no restoration, released never, closed with ⌘W.
final class UtilityWindow: NSWindow {
    /// Called as the window closes, before it goes: the owner settles a
    /// pending edit, or asks about unsaved ones (return false to stay open).
    var shouldClose: (() -> Bool)?

    convenience init(autosaveName: String, title: String, defaultSize: NSSize, minimumSize: NSSize) {
        self.init(contentRect: NSRect(origin: .zero, size: defaultSize),
                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                  backing: .buffered, defer: false)
        self.title = title
        minSize = minimumSize
        // The singleton controller holds the window; without this, AppKit
        // frees it on close and the next open finds a zombie.
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        toolbarStyle = .unified
        setFrameAutosaveName(autosaveName)
    }

    override func performClose(_ sender: Any?) {
        guard shouldClose?() ?? true else { return }
        super.performClose(sender)
    }

    // Escape with nothing to cancel closes the window, as in a panel.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
