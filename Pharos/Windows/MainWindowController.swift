import AppKit
import Combine

class MainWindowController: NSWindowController {

    let splitViewController = PharosSplitViewController()
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var toolbarController: MainToolbarController?

    private static let frameAutosaveKey = "PharosMainWindow"

    /// The window's restoration identity. AppKit writes it into the saved
    /// application state and hands it back to `restoreWindow(withIdentifier:…)`.
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("PharosMain")

    init() {
        let defaultContentRect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: defaultContentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pharos"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 800, height: 400)
        window.tabbingMode = .disallowed
        // Opts the window into full screen. AppKit then adds View > Enter Full
        // Screen itself — there is deliberately no menu item of our own.
        window.collectionBehavior = [.fullScreenPrimary]

        // Restoration: AppKit reopens the window after a relaunch (and after a
        // Force Quit or a restart with "reopen windows" ticked). The window's
        // FRAME is still saved by hand below — `setFrameAutosaveName` does not
        // reliably write on resize under macOS 26 — so restoration and the
        // manual frame path run side by side.
        window.isRestorable = true
        window.identifier = Self.mainWindowIdentifier
        window.restorationClass = MainWindowController.self

        super.init(window: window)

        window.delegate = self
        window.contentViewController = splitViewController

        restoreWindowFrame(defaultContentRect: defaultContentRect)

        NotificationCenter.default.addObserver(
            self, selector: #selector(saveWindowFrame),
            name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveWindowFrame),
            name: NSWindow.didMoveNotification, object: window)

        let toolbarController = MainToolbarController(
            contentVC: splitViewController.contentVC,
            sidebarVC: splitViewController.sidebarVC
        )
        toolbarController.install(on: window)
        self.toolbarController = toolbarController
    }

    // Manual — setFrameAutosaveName doesn't reliably write on resize under macOS 26.
    // A saved frame from a previous session may be 0x0 or on a disconnected display;
    // either would hand the first layout pass an invalid context on first show.
    private func restoreWindowFrame(defaultContentRect: NSRect) {
        guard let window = window else { return }
        let didRestore = window.setFrameUsingName(Self.frameAutosaveKey)
        if didRestore && isFrameValid(window.frame, minSize: window.minSize) {
            return
        }
        window.setFrame(defaultContentRect, display: false)
        window.center()
    }

    private func isFrameValid(_ frame: NSRect, minSize: NSSize) -> Bool {
        guard frame.size.width.isFinite, frame.size.height.isFinite else { return false }
        guard frame.size.width >= minSize.width, frame.size.height >= minSize.height else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    @objc private func saveWindowFrame() {
        window?.saveFrame(usingName: Self.frameAutosaveKey)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Connection Actions (called from menu bar)

    @objc func showConnectionsManager() {
        ConnectionsManagerWindowController.show()
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {}

// MARK: - NSWindowRestoration

extension MainWindowController: NSWindowRestoration {

    /// Hand AppKit the app's one main window. Pharos is single-window, so this
    /// never builds a second controller: it returns the existing one, or makes
    /// it the same way `AppStateManager.openTextFile(at:)` does when the app
    /// has none yet.
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        DispatchQueue.main.async {
            guard identifier == mainWindowIdentifier,
                  let app = NSApp.delegate as? AppDelegate else {
                completionHandler(nil, nil)
                return
            }
            if app.mainWindowController == nil {
                app.mainWindowController = MainWindowController()
            }
            completionHandler(app.mainWindowController?.window, nil)
        }
    }
}
