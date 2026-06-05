import AppKit
import Combine

class MainWindowController: NSWindowController {

    let splitViewController = PharosSplitViewController()
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var didInstallTitlebarAccessory = false

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

        // Setup toolbar (only flexible space + inspector toggle remain)
        let toolbar = NSToolbar(identifier: "PharosToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    // Manual — setFrameAutosaveName doesn't reliably write on resize under macOS 26.
    // A saved frame from a previous session may be 0x0 or on a disconnected display;
    // either would hand the titlebar accessory an invalid layout context on first show.
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

    // Attached post-show (from windowDidBecomeKey) rather than in init. Attaching
    // before the window is on screen triggers _auxiliaryViewFrameChanged: to assert
    // on macOS 26 when the first layout pass runs during makeKeyAndOrderFront.
    private func installTitlebarAccessoryIfNeeded() {
        guard !didInstallTitlebarAccessory else { return }
        guard let window = window, window.styleMask.contains(.titled) else { return }

        let accessorySize = NSSize(width: 36, height: 28)
        let container = NSView(frame: NSRect(origin: .zero, size: accessorySize))
        container.autoresizingMask = []

        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(systemSymbolName: "sidebar.leading",
                               accessibilityDescription: "Toggle Sidebar")?
            .withSymbolConfiguration(symbolConfig)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.target = nil
        button.action = #selector(PharosSplitViewController.pharosToggleSidebar(_:))

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.view = container
        accessoryVC.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessoryVC)

        didInstallTitlebarAccessory = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Connection Actions (called from menu bar)

    @objc func showConnectionsManager() {
        ConnectionsManagerWindowController.show()
    }
}

// MARK: - NSToolbarDelegate

extension NSToolbarItem.Identifier {
    /// Custom inspector toggle. The system `.toggleInspector` identifier
    /// auto-wires to `NSSplitViewController.toggleInspector:`, which our
    /// non-`.inspector`-behavior split items can't satisfy — using our own
    /// identifier lets us bind the action to `pharosToggleInspector(_:)`.
    static let pharosToggleInspector = NSToolbarItem.Identifier("PharosToggleInspector")
}

extension MainWindowController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .pharosToggleInspector:
            let item = NSToolbarItem(itemIdentifier: .pharosToggleInspector)
            item.label = "Inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing",
                                 accessibilityDescription: "Toggle Inspector")
            item.action = #selector(PharosSplitViewController.pharosToggleInspector(_:))
            return item

        case .flexibleSpace:
            return NSToolbarItem(itemIdentifier: .flexibleSpace)

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .flexibleSpace,
            .pharosToggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .flexibleSpace,
            .pharosToggleInspector,
        ]
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    func windowDidBecomeKey(_ notification: Notification) {
        installTitlebarAccessoryIfNeeded()
    }
}
