import AppKit

/// A single-instance utility window (the Variable Manager, the Tag Manager):
/// the Settings window's treatment without its toolbar — one remembered frame,
/// no tabbing, no restoration, released never, closed with ⌘W.
final class UtilityWindow: NSWindow {
    /// Asked once each time the user closes the window — the title-bar close
    /// button, ⌘W (File ▸ Close Tab), or Escape — before it goes: the owner
    /// settles a pending edit, or asks about unsaved ones (return false to
    /// stay open). `close()` does not ask, so a prompt that answered "close"
    /// closes the window with it.
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

    /// The one place every close path asks. The close button's action
    /// (`_close:`) and `performClose(_:)` both send `windowShouldClose(_:)`
    /// to the window itself when its delegate does not answer it (measured
    /// on macOS 27, scripts/test-manager-sidebar.sh). An override of
    /// `performClose(_:)` alone left the close button unasked.
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldClose?() ?? true
    }

    /// AppKit asks a delegate that implements `windowShouldClose(_:)` INSTEAD
    /// of the window, which would skip `shouldClose` on every path.
    override weak var delegate: (any NSWindowDelegate)? {
        didSet {
            assert(delegate?.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) != true,
                   "A UtilityWindow's delegate must not implement windowShouldClose(_:); set shouldClose instead.")
        }
    }

    // Escape with nothing to cancel closes the window, as in a panel.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
