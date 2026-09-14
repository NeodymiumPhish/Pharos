import AppKit
import Combine

class MainWindowController: NSWindowController {

    let splitViewController = PharosSplitViewController()
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var toolbarController: MainToolbarController?

    private static let frameAutosaveKey = "PharosMainWindow"

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
