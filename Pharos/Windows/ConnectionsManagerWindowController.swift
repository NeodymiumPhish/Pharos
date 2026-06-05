import AppKit

/// Free-floating window that hosts ConnectionsManagerVC. Singleton — calling
/// `show()` repeatedly brings the existing window forward instead of stacking.
final class ConnectionsManagerWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: ConnectionsManagerWindowController?
    private static let frameAutosaveKey = "PharosConnectionsManager"

    @MainActor
    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let wc = ConnectionsManagerWindowController()
        shared = wc
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let defaultRect = NSRect(x: 0, y: 0, width: 860, height: 560)
        // Standard (non-fullSizeContentView) title bar: content sits naturally
        // below the title bar, no overlap with the sidebar list, no scroll
        // view inset gymnastics for the right pane.
        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connections"
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = ConnectionsManagerVC()

        super.init(window: window)
        window.delegate = self

        if !window.setFrameUsingName(Self.frameAutosaveKey) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveKey)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
