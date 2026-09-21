import AppKit

/// The Settings window itself. One remembered frame for every pane, no
/// minimize (HIG: dim it), no zoom, and a real toolbar: Back, Forward and the
/// pane title live in the TITLE BAR, as they do in Xcode and System Settings.
/// `SettingsToolbarController` builds it.
///
/// The only keys it claims are plain ⌘[ and ⌘] for Back and Forward, and only
/// while it is key — the View menu owns ⌘⇧[ / ⌘⇧] for the editor tabs.
final class SettingsWindow: NSWindow {

    enum NavigationDirection { case back, forward }

    /// Set by the split view controller; called for ⌘[ / ⌘].
    var navigationHandler: ((NavigationDirection) -> Void)?

    static let frameAutosaveName = "PharosSettingsWindow"
    static let minimumSize = NSSize(width: 720, height: 480)
    static let defaultSize = NSSize(width: 900, height: 640)

    convenience init() {
        self.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        minSize = Self.minimumSize
        // The singleton controller holds the window. Without this an
        // AppKit-created window frees itself on close and the second ⌘,
        // opens a zombie.
        isReleasedWhenClosed = false
        // Nothing here is worth restoring at the next launch; the window is
        // opened on demand, and its frame is remembered by the autosave name.
        isRestorable = false
        tabbingMode = .disallowed
        // The toolbar draws the pane's name, so the window's own centred title
        // would say it twice. `title` itself is still set on every navigation:
        // the Window menu and the accessibility tree read it.
        titleVisibility = .hidden
        // Matches the main window (`MainWindowController`), which is the point
        // of the exercise. `titlebarAppearsTransparent` and a `.none`
        // separator are deliberately NOT set: both existed to hide a title bar
        // that had nothing in it, and with a toolbar they would stop the
        // separator appearing when content scrolls under it.
        toolbarStyle = .unified
        standardWindowButton(.zoomButton)?.isEnabled = false
        setFrameAutosaveName(Self.frameAutosaveName)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow, let direction = Self.navigationDirection(for: event) {
            navigationHandler?(direction)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Plain ⌘[ → back, plain ⌘] → forward. Any other modifier (⇧, ⌥, ⌃)
    /// leaves the key to the menu bar.
    static func navigationDirection(for event: NSEvent) -> NavigationDirection? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, let chars = event.charactersIgnoringModifiers else { return nil }
        switch chars {
        case "[": return .back
        case "]": return .forward
        default: return nil
        }
    }
}
