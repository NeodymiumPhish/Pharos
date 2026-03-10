import AppKit
import Combine

class MainWindowController: NSWindowController {

    let splitViewController = PharosSplitViewController()
    private let stateManager = AppStateManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
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

        window.contentViewController = splitViewController

        // Restore saved window frame (manual — setFrameAutosaveName doesn't
        // reliably write on resize under macOS 26).
        if !window.setFrameUsingName("PharosMainWindow") {
            window.center()
        }
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

        // Add sidebar toggle as titlebar accessory (next to traffic lights)
        let sidebarToggle = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 28))
        let btnConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        sidebarToggle.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")?.withSymbolConfiguration(btnConfig)
        sidebarToggle.bezelStyle = .recessed
        sidebarToggle.isBordered = false
        sidebarToggle.action = #selector(NSSplitViewController.toggleSidebar(_:))
        sidebarToggle.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.view = sidebarToggle
        accessoryVC.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessoryVC)
    }

    @objc private func saveWindowFrame() {
        window?.saveFrame(usingName: "PharosMainWindow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Connection Actions (called from menu bar)

    @objc func showAddConnectionSheet() {
        let sheet = ConnectionSheet.forNew { [weak self] config in
            self?.stateManager.saveConnection(config)
        }
        window?.contentViewController?.presentAsSheet(sheet)
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleInspector:
            let item = NSToolbarItem(itemIdentifier: .toggleInspector)
            item.label = "Inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing",
                                 accessibilityDescription: "Toggle Inspector")
            item.action = #selector(NSSplitViewController.toggleInspector(_:))
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
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .flexibleSpace,
            .toggleInspector,
        ]
    }
}
